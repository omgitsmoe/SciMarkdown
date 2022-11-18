const std = @import("std");
const builtin = @import("builtin");
const log = std.log;

const utils = @import("utils.zig");

const tokenizer = @import("tokenizer.zig");
const Tokenizer = tokenizer.Tokenizer;
const Token = tokenizer.Token;
const TokenKind = tokenizer.TokenKind;

const ast = @import("ast.zig");
const Node = ast.Node;
const NodeKind = ast.NodeKind;

const code_chunks = @import("code_chunks.zig");
const Language = code_chunks.Language;

const csl = @import("csl_json.zig");

const bic = @import("builtin.zig");
const BuiltinCall = bic.BuiltinCall;
const builtin_call_info = bic.builtin_call_info;

pub const Parser = struct {
    allocator: *std.mem.Allocator,
    node_arena: std.heap.ArenaAllocator,
    string_arena: std.heap.ArenaAllocator,

    label_node_map: std.StringHashMap(*Node.NodeData),
    citations: std.ArrayList(*Node),

    run_languages: LangSet,

    tokenizer: Tokenizer,
    // NOTE: ArrayList: pointers to items are __invalid__ after resizing operations!!
    // so it doesn't make sense to keep a ptr to the current token
    token_buf: std.ArrayList(Token),
    tk_index: u32,

    current_document: *Node,
    // keep track of last text node so we don't have to create a new one for at least
    // every word
    // opening or closing of blocks sets this to null
    last_text_node: ?*Node,
    /// these are not blocks in the markdown sense but rather parent nodes
    /// in general
    /// first open_block is always current_document
    // TODO use an ArrayList instead?
    open_blocks: [50]*Node,
    open_block_idx: u8,

    bibliography: ?*Node = null,

    // each error name across the entire compilation gets assigned an unsigned
    // integer greater than 0. You are allowed to declare the same error name
    // more than once, and if you do, it gets assigned the same integer value
    //
    // inferred error sets:
    // When a function has an inferred error set, that function becomes generic
    // and thus it becomes trickier to do certain things with it, such as
    // obtain a function pointer, or have an error set that is consistent
    // across different build targets. Additionally, inferred error sets are
    // incompatible with recursion.
    // In these situations, it is recommended to use an explicit error set. You
    // can generally start with an empty error set and let compile errors guide
    // you toward completing the set.
    // e.g. changing !void to ParseError!void gives the error msg:
    // not a member of destination error set error{OutOfMemory}
    // TODO go over use of SyntaxError and specific ones
    const ParseError = error{
        OutOfMemory,
        SyntaxError,
        ExceededOrderedListDigits,
        BuiltinCallFailed,
    };

    const LangSet = std.enums.EnumSet(code_chunks.Language);

    pub fn init(allocator: *std.mem.Allocator, filename: []const u8) !Parser {
        var parser = Parser{
            .allocator = allocator,
            .node_arena = std.heap.ArenaAllocator.init(allocator),
            .string_arena = std.heap.ArenaAllocator.init(allocator),

            .label_node_map = std.StringHashMap(*Node.NodeData).init(allocator),
            .citations = std.ArrayList(*Node).init(allocator),

            .run_languages = LangSet.init(.{}),

            .tokenizer = try Tokenizer.init(allocator, filename),
            // TODO allocate a capacity for tokens with ensureCapacity based on filesize
            .token_buf = std.ArrayList(Token).init(allocator),
            .tk_index = 0,

            .current_document = undefined,
            .last_text_node = null,
            .open_blocks = undefined,
            .open_block_idx = 0,
        };

        // manually get the first token
        try parser.token_buf.append(try parser.tokenizer.get_token());

        // create() returns ptr to undefined memory
        var current_document = try Node.create(&parser.node_arena.allocator);
        current_document.data = .Document;
        parser.current_document = current_document;
        parser.open_blocks[0] = current_document;

        return parser;
    }

    pub fn deinit(self: *Parser) void {
        // free code string buffers from .FencedCode nodes
        self.string_arena.deinit();
        self.node_arena.deinit();
        self.tokenizer.deinit();
        self.token_buf.deinit();
        self.label_node_map.deinit();
        self.citations.deinit();
    }

    inline fn new_node(self: *Parser, parent: *Node) !*Node {
        std.debug.assert(ast.children_allowed(parent.data));
        const node = try Node.create(&self.node_arena.allocator);
        parent.append_child(node);
        // invalidate last text block; doing this manually was too error prone
        self.last_text_node = null;
        return node;
    }

    inline fn open_block(self: *Parser, block: *Node) void {
        self.open_block_idx += 1;
        self.open_blocks[self.open_block_idx] = block;
        self.last_text_node = null;
    }

    /// does no bounds checking
    inline fn get_last_block(self: *Parser) *Node {
        return self.open_blocks[self.open_block_idx];
    }

    inline fn get_last_container_block(self: *Parser) *Node {
        var i: u8 = self.open_block_idx;
        while (i > 0) : (i -= 1) {
            if (ast.is_container_block(self.open_blocks[i].data)) {
                return self.open_blocks[i];
            }
        }
        // return current_document which is open_blocks[0]
        return self.current_document;
    }

    inline fn get_last_leaf_block(self: *Parser) ?*Node {
        var i: u8 = self.open_block_idx;
        while (i > 0) : (i -= 1) {
            if (ast.is_leaf_block(self.open_blocks[i].data)) {
                return self.open_blocks[i];
            }
        }
        return null;
    }

    inline fn close_blocks_until(
        self: *Parser,
        comptime match: fn (kind: NodeKind) bool,
        comptime close_first_match: bool,
    ) void {
        var i: u8 = self.open_block_idx;
        while (i > 0) : (i -= 1) {
            if (match(self.open_blocks[i].data)) {
                self.open_block_idx = if (!close_first_match) i else i - 1;
                break;
            }
        }
    }

    inline fn close_blocks_until_kind(
        self: *Parser,
        comptime kind: NodeKind,
        comptime close_first_match: bool,
    ) void {
        var i: u8 = self.open_block_idx;
        while (i > 0) : (i -= 1) {
            if (self.open_blocks[i].data == kind) {
                self.open_block_idx = if (!close_first_match) i else i - 1;
                break;
            }
        }
    }

    inline fn close_last_block(self: *Parser) void {
        std.debug.assert(self.open_block_idx > 0);
        self.open_block_idx -= 1;
        self.last_text_node = null;
    }

    pub fn parse(self: *Parser) ParseError!void {
        // tokenize the whole file first so we can use ptrs that don't get invalidated
        // due to resizing; maybe also faster for successful compiles since
        // better cache friendlyness?
        var token: Token = undefined;
        token.token_kind = TokenKind.Invalid;
        while (token.token_kind != TokenKind.Eof) {
            token = self.tokenizer.get_token() catch return ParseError.SyntaxError;
            try self.token_buf.append(token);
        }

        while (self.peek_token().token_kind != TokenKind.Eof) {
            try self.parse_block(0, false);
        }
    }

    /// does no bounds checking beyond which is integrated with zig up to ReleaseSafe mode
    /// assumes caller doesn't call peek_next_token after receiving TokenKind.Eof
    inline fn eat_token(self: *Parser) void {
        std.debug.assert((self.tk_index + 1) < self.token_buf.items.len);
        self.tk_index += 1;
    }

    inline fn put_back(self: *Parser) void {
        self.tk_index -= 1;
    }

    inline fn peek_token(self: *Parser) *Token {
        return &self.token_buf.items[self.tk_index];
    }

    /// does no bounds checking beyond which is integrated with zig up to ReleaseSafe mode
    /// assumes caller doesn't call peek_next_token after receiving TokenKind.Eof
    inline fn peek_next_token(self: *Parser) *Token {
        return &self.token_buf.items[self.tk_index + 1];
    }

    inline fn require_token(
        self: *Parser,
        comptime token_kind: TokenKind,
        comptime expl_msg: []const u8,
    ) ParseError!void {
        const token = self.peek_token();
        if (token.token_kind != token_kind) {
            Parser.report_error(
                "ln:{}: Expected token '{s}' found '{s}'" ++ expl_msg ++ "\n",
                .{ token.line_nr, token_kind.name(), token.token_kind.name() },
            );
            return ParseError.SyntaxError;
        }
    }

    inline fn report_error(comptime err_msg: []const u8, args: anytype) void {
        log.err(err_msg, args);
    }

    inline fn skip_whitespace(self: *@This(), comptime skip_newline: bool) u32 {
        var tok = self.peek_token();
        var skipped: u32 = 0;
        while (true) : (tok = self.peek_token()) {
            switch (tok.token_kind) {
                .Space, .Tab => {
                    skipped += 1;
                    self.eat_token();
                },
                .Newline => {
                    if (skip_newline) {
                        skipped += 1;
                        self.eat_token();
                        continue;
                    }
                },
                else => break,
            }
        }

        return skipped;
    }

    fn skip_until_token(
        self: *@This(),
        comptime token_kind: TokenKind,
        comptime extra_msg: []const u8,
    ) ParseError!void {
        const start = self.peek_token();
        var ctoken_kind = start.token_kind;
        while (ctoken_kind != token_kind and ctoken_kind != .Eof) : ({
            self.eat_token();
            ctoken_kind = self.peek_token().token_kind;
        }) {}
        if (ctoken_kind == .Eof) {
            Parser.report_error(
                "ln:{}: Encountered end of file{s} while waiting for token {s}",
                .{ start.line_nr, extra_msg, token_kind.name() },
            );
            return ParseError.SyntaxError;
        }
    }

    fn parse_block(self: *Parser, indent_change: i8, prev_line_blank: bool) ParseError!void {
        switch (self.peek_token().token_kind) {
            TokenKind.Comment => {
                self.eat_token();
                // eat \n since the comment started the line
                self.eat_token(); // eat \n
                // @CleanUp don't emit .Comment at all?
                // comments are completely ignored so we need to pass along the
                // previous values for indent/blank lines
                return self.parse_block(indent_change, prev_line_blank);
            },
            TokenKind.Eof => {
                try self.handle_open_blocks(NodeKind.Undefined, 0, prev_line_blank);
            },
            TokenKind.Newline => {
                // close block on blank line otherwise ignore
                // blank lines are ignored
                // two \n (blank line) end a paragraph

                // self.current_document is always open_blocks[0]
                // container blocks can contain blank lines so we don't close them here
                if (self.open_block_idx > 0) {
                    if (self.peek_next_token().token_kind == TokenKind.Newline) {
                        log.debug(
                            "ln:{}: Close block (all): {s}\n",
                            .{ self.peek_token().line_nr, @tagName(self.get_last_block().data) },
                        );
                        // close ALL open blocks except blockquote
                        var idx = self.open_block_idx;
                        while (idx > 0) : (idx -= 1) {
                            if (self.open_blocks[idx].data == .BlockQuote) {
                                break;
                            }
                        }
                        self.open_block_idx = idx;

                        self.eat_token();
                        self.eat_token(); // eat both \n
                    } else {
                        if (!ast.is_container_block(self.get_last_block().data)) {
                            log.debug(
                                "ln:{}: Close block: {s}\n",
                                .{ self.peek_token().line_nr, @tagName(self.get_last_block().data) },
                            );
                            self.close_last_block();
                        }
                        // blank line in list -> loose list
                        // here we could also count the last blankline at the end of the list
                        // (list getting ended by another block not 2 blank lines)
                        // so count the lines
                        const last_container = self.get_last_container_block();
                        switch (last_container.data) {
                            .OrderedListItem => last_container.parent.?.data.OrderedList.blank_lines += 1,
                            .UnorderedListItem => last_container.parent.?.data.UnorderedList.blank_lines += 1,
                            else => {},
                        }
                        self.eat_token();
                        return self.parse_block(indent_change, true);
                    }
                } else {
                    self.eat_token();
                }
            },

            TokenKind.Decrease_indent => {
                self.eat_token();
                return self.parse_block(indent_change - 1, prev_line_blank);
            },
            TokenKind.Increase_indent => {
                self.eat_token();
                return self.parse_block(1, prev_line_blank); // can't get more than on +Indent
            },

            TokenKind.Double_quote_triple => {
                const start_tok_col = self.peek_token().column;
                self.eat_token();
                if (indent_change > 0) {
                    try self.require_token(TokenKind.Newline, " after blockquote opener '\"\"\"'!");
                    self.eat_token();

                    // start blockquote
                    try self.handle_open_blocks(NodeKind.BlockQuote, start_tok_col, prev_line_blank);
                    var blockquote_node: *Node = try self.new_node(self.get_last_block());
                    blockquote_node.data = .BlockQuote;
                    self.open_block(blockquote_node);
                } else if (self.peek_token().token_kind == TokenKind.Newline) {
                    self.eat_token();
                    // """ then blank line closes blockquote
                    try self.require_token(
                        TokenKind.Decrease_indent,
                        " after '\"\"\"\\n' when closing a blockquote!",
                    );
                    self.eat_token(); // eat -Indent
                    // end blockquote
                    switch (self.get_last_block().data) {
                        .Paragraph => {
                            try self.close_paragraph();
                            // close everything up to and including the blockquote
                            // (needed so open lists are also closed)
                            self.close_blocks_until_kind(NodeKind.BlockQuote, true);
                        },
                        .BlockQuote => {
                            self.close_last_block();
                        },
                        else => {
                            Parser.report_error(
                                "ln:{}: Unclosed block of type '{s}' prevented closing a blockquote!\n",
                                .{ self.peek_token().line_nr - 1, @tagName(self.get_last_block().data) },
                            );
                            return ParseError.SyntaxError;
                        },
                    }
                }
            },

            TokenKind.Hash => {
                // atx heading
                // 1-6 unescaped # followed by ' ' or end-of-line
                // not doing: optional closing # that don't have to match the number of opening #
                try self.handle_open_blocks(NodeKind.Heading, self.peek_token().column, prev_line_blank);

                var heading_lvl: u8 = 1;
                self.eat_token();
                while (self.peek_token().token_kind == TokenKind.Hash) {
                    heading_lvl += 1;
                    self.eat_token();
                }

                const tok_after_hashes = self.peek_token();
                if (heading_lvl > 6 or tok_after_hashes.token_kind != TokenKind.Space) {
                    // can't use self. otherwise self *Parser gets passed
                    Parser.report_error(
                        "ln:{}: Headings can only go up to level 6 and have to be followed by a" ++
                            " space and heading text! If you didn't want to create a heading" ++
                            " escape the first '#' with a '\\'",
                        .{tok_after_hashes.line_nr},
                    );
                    return ParseError.SyntaxError;
                } else {
                    self.eat_token(); // eat space

                    // TODO make sure we account for sudden Eof everywhere
                    if (self.peek_token().token_kind.ends_line()) {
                        Parser.report_error("ln:{}: Empty heading name!", .{self.peek_token().line_nr});
                        return ParseError.SyntaxError;
                    }

                    var heading_node: *Node = try self.new_node(self.get_last_block());
                    heading_node.data = .{
                        .Heading = .{ .level = heading_lvl },
                    };
                    self.open_block(heading_node);

                    log.debug("Heading: level {}\n", .{heading_node.data.Heading.level});
                    try self.parse_inline_until(TokenKind.Newline);
                    self.close_last_block();
                }
            },

            TokenKind.Dash, TokenKind.Plus => {
                // maybe thematic break: the same 3 or more *, - or _ followed by optional spaces
                // bullet list/list item
                // remove _ and * from being able to start a thematic break/unordered list
                // so we don't have to backtrack if parsing doesn't succeed when it was just
                // being used as emphasis
                const start_token = self.peek_token();
                const start_token_kind = start_token.token_kind;
                self.eat_token();

                const next_token = self.peek_token();
                log.debug(
                    "Start {} Next {} 3rd {}\n",
                    .{ start_token_kind, next_token.token_kind, self.peek_next_token().token_kind },
                );
                if (next_token.token_kind == TokenKind.Space) {
                    // unordered list (can be started while in a container block)

                    try self.require_token(TokenKind.Space, " after unordered list item starter!");
                    self.eat_token();

                    const skipped = self.skip_whitespace(false);
                    // 2 -> 1 for '-' or '+' and 1 for first space
                    const li_starter_offset = @intCast(u8, 2 + skipped);

                    try self.parse_unordered_list(
                        start_token_kind,
                        start_token.column,
                        li_starter_offset,
                        prev_line_blank,
                    );
                } else if (start_token_kind == TokenKind.Dash and
                    next_token.token_kind == TokenKind.Dash and
                    self.peek_next_token().token_kind == TokenKind.Dash)
                {
                    try self.handle_open_blocks(
                        NodeKind.ThematicBreak,
                        start_token.column,
                        prev_line_blank,
                    );

                    self.eat_token();
                    self.eat_token();

                    // thematic break
                    var token_kind = self.peek_token().token_kind;
                    while (token_kind == TokenKind.Dash or
                        token_kind == TokenKind.Comment or
                        token_kind == TokenKind.Space)
                    {
                        self.eat_token();
                        token_kind = self.peek_token().token_kind;
                    }

                    // CommonMark allows optional spaces after a thematic break - we don't!
                    // so the line the thematic break is in has to end in a newline right
                    // after the thematic break (---)
                    if (!self.peek_token().token_kind.ends_line()) {
                        // \\ starts a zig multiline string-literal that goes until the end
                        // of the line, \n is only added if the next line starts with a \\
                        // alternatively you could use ++ at the end of the line to concat
                        // the arrays
                        // recognizes --- of table sep as invalid thematic break
                        // -> always require table rows to start with |
                        log.err(
                            "Line {}: " ++
                                "A line with a thematic break (consisting of at least 3 '-'" ++
                                " can only contain whitespace, comments or the " ++
                                "character that started the break and has to end in a new line!\n",
                            .{self.peek_token().line_nr},
                        );
                        return ParseError.SyntaxError;
                    } else {
                        var thematic_break = try self.new_node(self.get_last_block());
                        thematic_break.data = .ThematicBreak;
                        log.debug("Found valid thematic break! starting with: '{}'\n", .{start_token_kind});
                    }
                } else {
                    // error here otherwise we'd have to backtrack - how often do you
                    // really want to start a paragraph with *-+_ without wanting
                    // a thematic break / list?
                    // still on 2nd #/-/_
                    Parser.report_error(
                        "ln:{}: Characters '-' and '+' that start a new paragraph need to " ++
                            "either be part of an unordered list ('- Text') or a thematic break " ++
                            "(at least three '-')!\n",
                        .{self.peek_token().line_nr},
                    );
                    return ParseError.SyntaxError;
                }
            },

            TokenKind.Digits => {
                // maybe ordered list
                // 1-9 digits (0-9) ending in a '.' or ')'

                const start_token = self.peek_token();
                const next_token_kind = self.peek_next_token().token_kind;
                if (next_token_kind == TokenKind.Period or
                    next_token_kind == TokenKind.Close_paren)
                {
                    self.eat_token(); // digits
                    self.eat_token(); // . or )

                    const start_num = std.fmt.parseUnsigned(
                        u16,
                        start_token.text(self.tokenizer.bytes),
                        10,
                    ) catch {
                        Parser.report_error(
                            "ln:{}: Numbers that start an ordered list need to be in base 10, " ++
                                "number was '{s}'\n",
                            .{ start_token.line_nr, start_token.text(self.tokenizer.bytes) },
                        );
                        return ParseError.SyntaxError;
                    };

                    try self.require_token(TokenKind.Space, " after ordered list item starter!");
                    self.eat_token();

                    const skipped = self.skip_whitespace(false);
                    // 2 -> 1 for '.' or ')' and 1 for first ' '
                    const li_starter_offset = @intCast(u8, start_token.len() + 2 + skipped);

                    try self.parse_ordered_list(
                        next_token_kind,
                        start_token.column,
                        prev_line_blank,
                        start_num,
                        '1',
                        li_starter_offset,
                    );
                } else {
                    try self.parse_paragraph(prev_line_blank);
                }
            },

            TokenKind.Backtick_triple => {
                try self.handle_open_blocks(NodeKind.FencedCode, self.peek_token().column, prev_line_blank);
                self.eat_token();

                // language name or newline
                const lang_name_start = self.peek_token().start;
                while (true) {
                    switch (self.peek_token().token_kind) {
                        .Newline, .Eof => break,
                        else => self.eat_token(),
                    }
                }
                const lang_name_end = self.peek_token().start;
                try self.require_token(.Newline, " after FencedCode block starter!");
                self.eat_token();

                var code_node = try self.new_node(self.get_last_block());
                code_node.data = .{
                    .FencedCode = .{
                        .language = Language.match(self.tokenizer.bytes[lang_name_start..lang_name_end]),
                        .code = undefined,
                        .run = true,
                    },
                };
                self.open_block(code_node);
                // mark language for running it later
                self.run_languages.insert(code_node.data.FencedCode.language);

                try self.parse_builtins_at_start_of_block(.FencedCode);

                log.debug(
                    "Found code block ln{}: lang_name {s}\n",
                    .{ self.peek_token().line_nr, @tagName(code_node.data.FencedCode.language) },
                );

                try self.parse_code_block();
            },

            TokenKind.Dollar_double => {
                try self.handle_open_blocks(
                    NodeKind.MathMultiline,
                    self.peek_token().column,
                    prev_line_blank,
                );

                self.eat_token();

                try self.require_token(.Newline, " after math equation block starter!");
                self.eat_token();

                const math_node = try self.new_node(self.get_last_block());
                math_node.data = .{ .MathMultiline = .{
                    .text = undefined,
                } };
                self.open_block(math_node); // so parents of present builtins are set properly
                try self.parse_builtins_at_start_of_block(.MathMultiline);

                const math_start = self.peek_token();
                try self.skip_until_token(.Dollar_double, " inside math environment ($$...$$)");

                math_node.data.MathMultiline.text =
                    self.tokenizer.bytes[math_start.start..self.peek_token().start];
                self.close_last_block();
                self.eat_token(); // eat closing $$

                log.debug(
                    "ln:{}: Math env: $${s}$$\n",
                    .{ math_start.line_nr, math_node.data.MathMultiline.text },
                );
            },

            TokenKind.Colon_open_bracket => {
                try self.handle_open_blocks(NodeKind.LinkRef, self.peek_token().column, prev_line_blank);

                // link reference definition
                if (self.open_block_idx > 0) {
                    Parser.report_error(
                        "ln:{}: References must be defined at the document level! " ++
                            "Definition found in '{s}' instead.\n",
                        .{ self.peek_token().line_nr, @tagName(self.get_last_block().data) },
                    );
                    return ParseError.SyntaxError;
                }
                self.eat_token();

                var token = self.peek_token();
                const ref_name_start = token.start;
                // CommonMark allows one \n inside a reference label
                // don't allow any for now!
                while (token.token_kind != TokenKind.Close_bracket_colon and
                    !token.token_kind.ends_line())
                {
                    self.eat_token();
                    token = self.peek_token();
                }
                const ref_name_end = self.peek_token().start;

                if (token.token_kind != TokenKind.Close_bracket_colon) {
                    Parser.report_error(
                        "ln:{}: Missing closing ']:' from reference label!\n",
                        .{self.peek_token().line_nr},
                    );
                    return ParseError.SyntaxError;
                }
                self.eat_token();

                if (ref_name_start == ref_name_end) {
                    Parser.report_error("ln:{}: Empty reference label!\n", .{self.peek_token().line_nr});
                    return ParseError.SyntaxError;
                }
                log.debug("ln:{}: Ref with label: '{s}'\n", .{ self.peek_token().line_nr, self.tokenizer.bytes[ref_name_start..ref_name_end] });

                try self.require_token(
                    TokenKind.Space,
                    ". A space is required between reference label and reference content!",
                );
                self.eat_token();

                // reference definitions are alywas direct children of the document
                var reference_def = try self.new_node(self.current_document);
                reference_def.data = .{
                    .LinkRef = .{
                        .label = self.tokenizer.bytes[ref_name_start..ref_name_end],
                        .url = undefined,
                        .title = null,
                    },
                };
                self.open_block(reference_def);

                // store entry in label_node_map with the label as key and the *Node as value
                // make sure we don't have a duplicate label!
                const entry_found = try self.label_node_map.getOrPut(reference_def.data.LinkRef.label.?);
                // ^ result will be a struct with a pointer to the HashMap.Entry and a bool
                // whether an existing value was found
                if (entry_found.found_existing) {
                    Parser.report_error(
                        "ln:{}: Duplicate reference label '{s}'!\n",
                        .{ self.peek_token().line_nr, reference_def.data.LinkRef.label.? },
                    );
                    return ParseError.SyntaxError;
                } else {
                    // actually write entry value (key was already written by getOrPut)
                    entry_found.value_ptr.* = &reference_def.data;
                }

                try self.parse_link_destination();
                self.close_last_block();
            },

            TokenKind.Exclamation_open_bracket => {
                try self.handle_open_blocks(NodeKind.Image, self.peek_token().column, prev_line_blank);
                self.eat_token();

                var img_node = try self.new_node(self.get_last_block());
                img_node.data = .{
                    .Image = .{
                        .alt = undefined,
                        .label = null,
                        .url = null,
                        .title = null,
                    },
                };
                self.open_block(img_node);

                const alt_start = self.peek_token();
                try self.skip_until_token(.Close_bracket, " inside image alt text '[...]'");
                const alt_end = self.peek_token();
                self.eat_token(); // eat ]
                img_node.data.Image.alt = self.tokenizer.bytes[alt_start.start..alt_end.start];

                switch (self.peek_token().token_kind) {
                    .Open_bracket => {
                        img_node.data.Image.label = try self.parse_link_ref_label(NodeKind.Image);
                    },
                    .Open_paren => try self.parse_link_destination(),
                    else => {
                        Parser.report_error(
                            "ln:{}: Expected image label '[' or image destination '(' starter, " ++
                                "got '{s}' instead!\n",
                            .{ self.peek_token().line_nr, self.peek_token().token_kind.name() },
                        );
                        return ParseError.SyntaxError;
                    },
                }
            },

            .Text => {
                switch (self.peek_next_token().token_kind) {
                    .Period, .Close_paren => {
                        const start_token = self.peek_token();
                        const start = start_token.text(self.tokenizer.bytes);
                        // allow single lower or uppercase ascii letters followed by '.' or ')'
                        // to start a list as well
                        if (start.len == 1) {
                            var ol_type: u8 = undefined;
                            var start_num: u16 = undefined;
                            switch (start[0]) {
                                'a'...'z' => {
                                    ol_type = 'a';
                                    start_num = start[0] - 'a' + 1;
                                },
                                'A'...'Z' => {
                                    ol_type = 'A';
                                    start_num = start[0] - 'A' + 1;
                                },
                                else => return try self.parse_paragraph(prev_line_blank),
                            }
                            self.eat_token();
                            const next_token = self.peek_token();
                            self.eat_token();

                            try self.require_token(
                                TokenKind.Space,
                                " after ordered (alt) list item starter!",
                            );
                            self.eat_token();

                            const skipped = self.skip_whitespace(false);
                            // 3 -> 1 for letter, 1 for '.' or ')' and 1 for first space
                            const li_starter_offset = @intCast(u8, 3 + skipped);

                            try self.parse_ordered_list(
                                next_token.token_kind,
                                start_token.column,
                                prev_line_blank,
                                start_num,
                                ol_type,
                                li_starter_offset,
                            );
                        } else {
                            try self.parse_paragraph(prev_line_blank);
                        }
                    },
                    else => try self.parse_paragraph(prev_line_blank),
                }
            },
            else => {
                try self.parse_paragraph(prev_line_blank);
            },
        }
    }

    fn parse_builtins_at_start_of_block(self: *@This(), comptime block_kind: NodeKind) ParseError!void {
        // allow builtin calls immediately after the first newline with each
        // builtin being separated by exactly one newline
        var tok_kind = self.peek_token().token_kind;
        const require_extra_newline = false;
        while (true) : (tok_kind = self.peek_token().token_kind) {
            if (tok_kind == .Builtin_call) {
                try self.parse_builtin(self.peek_token());
                try self.require_token(.Newline, " after builtin call before the code of a " ++
                    @tagName(block_kind) ++ " block!");
                self.eat_token();
            } else {
                if (require_extra_newline) {
                    // require two newlines after the last builtin call
                    try self.require_token(.Newline, " after the last builtin call inside of a " ++
                        @tagName(block_kind) ++ " block!");
                    self.eat_token();
                }
                break;
            }
        }
    }

    /// closes lists that don't match the current token's ident level
    /// (token.column == list.indent + list.li_starter_offset
    fn close_lists_not_matching_indent(
        self: *Parser,
        initial_last_container: Node.NodeData,
        starter_column: u32,
        initial_prev_line_blank: bool,
    ) void {
        var last_container: Node.NodeData = initial_last_container;
        var prev_line_blank = initial_prev_line_blank;

        // close __all__ lists that don't match our indent!
        // (col __after__ list item starter + space)
        while (true) {
            switch (last_container) {
                .UnorderedListItem => |item| {
                    if (item.indent + item.li_starter_offset != starter_column) {
                        self.close_blocks_until_kind(.UnorderedListItem, false);
                        self.close_list(prev_line_blank);
                        // prev_line_blank gets "used up" by the first list
                        prev_line_blank = false;
                    } else {
                        break;
                    }
                },
                .OrderedListItem => |item| {
                    if (item.indent + item.li_starter_offset != starter_column) {
                        self.close_blocks_until_kind(.OrderedListItem, false);
                        self.close_list(prev_line_blank);
                        // prev_line_blank gets "used up" by the first list
                        prev_line_blank = false;
                    } else {
                        break;
                    }
                },
                else => break,
            }

            last_container = self.get_last_block().data;
        }
    }

    fn handle_open_blocks(
        self: *Parser,
        comptime new_block: NodeKind,
        starter_column: u32, // column of the token that starts the block
        initial_prev_line_blank: bool,
    ) ParseError!void {
        std.debug.assert(new_block != .Paragraph);

        var last_block_kind: NodeKind = self.get_last_block().data;
        // there should be no remaining open inline elements
        // when opening new leaf/container blocks
        if (!ast.is_inline(new_block)) {
            if (ast.is_inline(last_block_kind)) {
                Parser.report_error(
                    "ln:{}: There was at least one unclosed inline element of type '{s}'\n",
                    .{ self.peek_token().line_nr, @tagName(last_block_kind) },
                );
                return ParseError.SyntaxError;
            }
        }

        if (last_block_kind == NodeKind.Paragraph) {
            try self.close_paragraph();
            last_block_kind = self.get_last_block().data;
        }

        switch (new_block) {
            // not necessary for lists, that is handled by can_list_continue
            // since new_block is comptime this switch should not incur any runtime cost
            .UnorderedListItem, .OrderedListItem, .OrderedList, .UnorderedList => {},
            else => {
                var last_container: Node.NodeData = self.get_last_container_block().data;
                if (last_container != new_block) {
                    self.close_lists_not_matching_indent(
                        last_container,
                        starter_column,
                        initial_prev_line_blank,
                    );
                    last_block_kind = self.get_last_block().data;
                }
            },
        }

        // otherwise check that old can hold new block kind
        if (!ast.can_hold(last_block_kind, new_block)) {
            Parser.report_error(
                "ln:{}: Previous block of type '{s}' can't hold new block of type '{s}'\n",
                .{ self.peek_token().line_nr, @tagName(last_block_kind), @tagName(new_block) },
            );
            return ParseError.SyntaxError;
        }
    }

    fn close_list(self: *Parser, prev_line_blank: bool) void {
        self.close_last_block();
        if (prev_line_blank) {
            // don't count a blank line if it occured before ending a list
            //
            // TODO OrderedList and UnorderedList have the same payload type
            // is there a way to access that without a switch?
            log.debug("ln:{}: One less blank!\n", .{self.peek_token().line_nr});
            switch (self.get_last_block().data) {
                .OrderedList, .UnorderedList => |*list| {
                    list.*.blank_lines -= 1;
                },
                else => unreachable,
            }
        }
        log.debug("ln:{}: Same blank!\n", .{self.peek_token().line_nr});
        self.close_last_block();
    }

    fn can_list_continue(
        self: *Parser,
        comptime new_list: NodeKind,
        start_token_kind: TokenKind,
        start_column: u16, // column the list item itself (not the content starts on): ->1. or ->-
        prev_line_blank: bool,
        ol_type: u8,
    ) bool {
        const last_block = self.get_last_block();
        const last_block_kind: NodeKind = last_block.data;
        var list_data: Node.ListItemData = undefined;
        switch (last_block.data) {
            .OrderedListItem, .UnorderedListItem => |data| {
                list_data = data;
            },
            else => return false,
        }
        // const union_field_name = @tagName(new_list);
        var other_list_type = switch (new_list) {
            .OrderedListItem => NodeKind.UnorderedListItem,
            .UnorderedListItem => NodeKind.OrderedListItem,
            else => unreachable,
        };

        // NOTE: list's loose status should already have been determined
        // before closing the list so we only have to check when we continue
        if (start_column == list_data.indent) {
            if (last_block_kind == new_list) {
                if (list_data.list_item_starter == start_token_kind and list_data.ol_type == ol_type) {
                    // if (last_block_kind == .OrderedListItem and list_data.ol_type != ol_type) {
                    //     // same list type, same indent, same 2nd list starter, different ol type
                    //     self.close_list(prev_line_blank);
                    //     return false;
                    // }
                    // same list type, same indent, same list starter
                    self.close_last_block();

                    return true;
                } else {
                    // same list type, same indent, __different__ list starter
                    self.close_list(prev_line_blank);
                    return false;
                }
            } else if (last_block_kind == other_list_type) {
                // diff list type, same indent
                // close previous list
                self.close_list(prev_line_blank);
                return false;
            }
        } else if (start_column < list_data.indent) {
            // previous list was on a farther indent
            // => close it
            self.close_list(prev_line_blank);
            // test again
            return self.can_list_continue(
                new_list,
                start_token_kind,
                start_column,
                prev_line_blank,
                ol_type,
            );
        } else {
            // start_column > indent
            // increased indent -> don't close anything
            return false;
        }

        unreachable;
    }

    fn parse_ordered_list(
        self: *Parser,
        start_token_kind: TokenKind, // list_item_starter e.g. '.', ')'
        start_column: u16, // column the list item starts on (not content): here ->1.
        prev_line_blank: bool,
        start_num: u16,
        ol_type: u8, // 1, a, A, i or I
        li_starter_offset: u8,
    ) ParseError!void {
        try self.handle_open_blocks(NodeKind.OrderedListItem, start_column, prev_line_blank);

        var list_node: *Node = undefined;
        // create new list if it can't continue
        if (!self.can_list_continue(
            NodeKind.OrderedListItem,
            start_token_kind,
            start_column,
            prev_line_blank,
            ol_type,
        )) {
            list_node = try self.new_node(self.get_last_block());
            list_node.data = .{
                .OrderedList = .{ .blank_lines = 0, .start_num = start_num, .ol_type = ol_type },
            };
            self.open_block(list_node);
        } else {
            list_node = self.get_last_block();
            std.debug.assert(list_node.data == NodeKind.OrderedList);
        }

        var list_item_node = try self.new_node(list_node);
        list_item_node.data = .{
            .OrderedListItem = .{
                .list_item_starter = start_token_kind,
                .indent = start_column,
                .ol_type = ol_type,
                .li_starter_offset = li_starter_offset,
            },
        };
        self.open_block(list_item_node);
    }

    fn parse_unordered_list(
        self: *Parser,
        start_token_kind: TokenKind,
        start_column: u16,
        li_starter_offset: u8,
        prev_line_blank: bool,
    ) ParseError!void {
        try self.handle_open_blocks(NodeKind.UnorderedListItem, start_column, prev_line_blank);
        // if one blank line is present in the contents of any of the list items
        // the list will be loose

        var list_node: *Node = undefined;
        // create new list if it can't continue
        if (!self.can_list_continue(
            NodeKind.UnorderedListItem,
            start_token_kind,
            start_column,
            prev_line_blank,
            0,
        )) {
            list_node = try self.new_node(self.get_last_container_block());
            list_node.data = .{
                .UnorderedList = .{ .blank_lines = 0, .start_num = 0, .ol_type = 0 },
            };
            self.open_block(list_node);
        } else {
            list_node = self.get_last_block();
            std.debug.assert(list_node.data == NodeKind.UnorderedList);
        }

        var list_node_item = try self.new_node(list_node);
        list_node_item.data = .{
            .UnorderedListItem = .{
                .list_item_starter = start_token_kind,
                .indent = start_column,
                .ol_type = 0,
                .li_starter_offset = li_starter_offset,
            },
        };
        self.open_block(list_node_item);
    }

    fn parse_paragraph(self: *Parser, prev_line_blank: bool) ParseError!void {
        // might have an open list that was not closed by two \n
        self.close_lists_not_matching_indent(
            self.get_last_container_block().data,
            self.peek_token().column,
            prev_line_blank,
        );

        // parse_inline stops on Increase_indent after first list item
        // even though we could continue (unless next line starts another block)
        // -> check last block and contiue paragraph if we can
        const last_leaf_block = self.get_last_leaf_block();
        if (last_leaf_block != null)
            log.debug(
                "ln:{}: Last leaf block {s}\n",
                .{ self.peek_token().line_nr, @tagName(last_leaf_block.?.data) },
            );
        if (last_leaf_block == null or last_leaf_block.?.data != NodeKind.Paragraph) {
            var paragraph = try self.new_node(self.get_last_block());
            paragraph.data = NodeKind.Paragraph;
            self.open_block(paragraph);
        }

        // stops on newline, eof, increase_indent, dedent
        while (try self.parse_inline(true)) {}

        switch (self.peek_token().token_kind) {
            .Newline => {
                // we need the soft line break here to output a space (or w/e)
                // between lines of the same paragraph that will end up being
                // printed on the same line
                var soft_line_break = try self.new_node(self.get_last_block());
                soft_line_break.data = NodeKind.SoftLineBreak;
                // text_node now can't continue anymore
                self.last_text_node = null;

                self.eat_token(); // \n
            },
            .Eof => try self.close_paragraph(),
            else => {},
        }
    }

    fn close_paragraph(self: *Parser) ParseError!void {
        if (self.get_last_block().data != NodeKind.Paragraph) {
            Parser.report_error(
                "ln:{}: There was at least one unclosed inline element of type '{s}'\n",
                .{ self.peek_token().line_nr, @tagName(self.get_last_block().data) },
            );
            return ParseError.SyntaxError;
        }

        self.close_last_block();
    }

    /// eats the token_kind token; EOF is not consumed
    fn parse_inline_until(self: *Parser, token_kind: TokenKind) ParseError!void {
        while (try self.parse_inline(false)) {
            if (self.peek_token().token_kind == token_kind) {
                self.eat_token();
                return;
            }
        }
    }

    fn parse_code_span(self: *Parser, delimiter: TokenKind, comptime run: bool) ParseError!void {
        // delimiter -> if code span contains a ` you can use `` to start/end a code span
        self.eat_token();

        const code_span = try self.new_node(self.get_last_block());

        const maybe_lang_tok = self.peek_token();
        const lang = Language.match(self.tokenizer.bytes[maybe_lang_tok.start..maybe_lang_tok.end]);
        code_span.data = .{ .CodeSpan = .{
            .language = lang,
            .code = undefined,
            .run = run,
        } };
        // eat lang name if it could be matched
        if (lang != .Unknown) {
            self.eat_token();
            self.eat_token(); // eat ' '
        }

        if (run) {
            // mark language for running it later
            self.run_languages.insert(lang);
        }

        var ctoken = self.peek_token();
        const code_span_start = ctoken;
        while (ctoken.token_kind != delimiter) : ({
            // while continue expression (executed on every loop as well as when a
            // continue happens)
            self.eat_token();
            ctoken = self.peek_token();
        }) {
            if (ctoken.token_kind == TokenKind.Eof) {
                Parser.report_error(
                    "ln:{}: Encountered end of file inside code span (`...`)",
                    .{code_span_start.line_nr},
                );
                return ParseError.SyntaxError;
            }
        }

        code_span.data.CodeSpan.code = self.tokenizer.bytes[code_span_start.start..self.peek_token().start];
        self.eat_token(); // eat closing ` or ``

        log.debug("ln:{}: Code span {}\n", .{ code_span_start.line_nr, code_span.data });
    }

    /// returns bool determining whether inline parsing should continue
    /// NOTE(m): no .SoftLineBreak node will be created for the end_on_newline case!
    fn parse_inline(self: *Parser, comptime end_on_newline: bool) ParseError!bool {
        const token = self.peek_token();
        switch (token.token_kind) {
            TokenKind.Newline => {
                if (end_on_newline) {
                    return false;
                } else {
                    // NOTE(m): no .SoftLineBreak node will be created for the end_on_newline case!
                    self.eat_token();
                    return true;
                }
            },
            TokenKind.Eof, TokenKind.Increase_indent, TokenKind.Decrease_indent => return false,
            TokenKind.Comment => self.eat_token(),
            TokenKind.Hard_line_break => {
                self.eat_token();
                var line_break = try self.new_node(self.get_last_block());
                line_break.data = NodeKind.HardLineBreak;
            },
            TokenKind.Asterisk, TokenKind.Underscore => {
                // check if we close the last emph block or open one
                // **fat _also cursive_**
                //                    ^ closes _
                // ** fat _also cursive** also cursive_ <- not allowed!
                // NOTE: technichally not a block in the markdown sense but since it can
                // have children as an AST node we treat it as one
                const last_block = self.get_last_block();
                const current_token_kind = self.peek_token().token_kind;
                if (last_block.data == NodeKind.Emphasis) {
                    const opener_token_kind = last_block.data.Emphasis.opener_token_kind;
                    if (last_block.data.Emphasis.opener_token_kind != current_token_kind) {
                        Parser.report_error(
                            "ln:{}: Wrong emphasis closer (expected '{}' got '{}')!\n",
                            .{ self.peek_token().line_nr, opener_token_kind, current_token_kind },
                        );
                        return ParseError.SyntaxError;
                    }

                    log.debug(
                        "Close emphasis ln:{}: token: {}\n",
                        .{ self.peek_token().line_nr, current_token_kind },
                    );
                    self.close_last_block();
                } else {
                    var emph_node = try self.new_node(self.get_last_block());
                    emph_node.data = .{
                        .Emphasis = .{ .opener_token_kind = current_token_kind },
                    };
                    log.debug(
                        "Open emphasis ln:{}: token: {} last block: {}\n",
                        .{ self.peek_token().line_nr, current_token_kind, last_block.data },
                    );
                    self.open_block(emph_node);
                }
                self.eat_token();
            },
            TokenKind.Asterisk_double, TokenKind.Underscore_double => {
                const last_block = self.get_last_block();
                const current_token_kind = self.peek_token().token_kind;
                if (last_block.data == NodeKind.StrongEmphasis) {
                    const opener_token_kind = last_block.data.StrongEmphasis.opener_token_kind;
                    if (last_block.data.StrongEmphasis.opener_token_kind != current_token_kind) {
                        Parser.report_error(
                            "ln:{}: Wrong strong emphasis closer (expected '{}' got '{}')!\n",
                            .{ self.peek_token().line_nr, opener_token_kind, current_token_kind },
                        );
                        return ParseError.SyntaxError;
                    }

                    log.debug(
                        "Close strong emphasis ln:{}: token: {}\n",
                        .{ self.peek_token().line_nr, current_token_kind },
                    );
                    self.close_last_block();
                } else {
                    var emph_node = try self.new_node(self.get_last_block());
                    emph_node.data = .{
                        .StrongEmphasis = .{ .opener_token_kind = current_token_kind },
                    };
                    log.debug(
                        "Open strong emphasis ln:{}: token: {}\n",
                        .{ self.peek_token().line_nr, current_token_kind },
                    );
                    self.open_block(emph_node);
                }
                self.eat_token();
            },
            TokenKind.Tilde_double => {
                const last_block = self.get_last_block();
                if (last_block.data == NodeKind.Strikethrough) {
                    log.debug("ln:{}: Close Strikethrough\n", .{self.peek_token().line_nr});
                    self.close_last_block();
                } else {
                    var strike_node = try self.new_node(self.get_last_block());
                    strike_node.data = .Strikethrough;
                    log.debug("ln:{}: Open strikethrough\n", .{self.peek_token().line_nr});
                    self.open_block(strike_node);
                }
                self.eat_token();
            },
            TokenKind.Caret => {
                // TODO pandoc doesn't allow spaces/newlines inside super/subscript blocks
                // but they can be backslash escaped
                // do this as well? or just make ppl escape the ^/~ instead of spaces inside?
                const last_block = self.get_last_block();
                if (last_block.data == NodeKind.Superscript) {
                    log.debug("ln:{}: Close Superscript\n", .{self.peek_token().line_nr});
                    self.close_last_block();
                } else {
                    var superscript_node = try self.new_node(self.get_last_block());
                    superscript_node.data = .Superscript;
                    log.debug("ln:{}: Open superscript\n", .{self.peek_token().line_nr});
                    self.open_block(superscript_node);
                }
                self.eat_token();
            },
            TokenKind.Tilde => {
                const last_block = self.get_last_block();
                if (last_block.data == NodeKind.Subscript) {
                    log.debug("ln:{}: Close Subscript\n", .{self.peek_token().line_nr});
                    self.close_last_block();
                } else {
                    var subscript_node = try self.new_node(self.get_last_block());
                    subscript_node.data = .Subscript;
                    log.debug("ln:{}: Open subscript\n", .{self.peek_token().line_nr});
                    self.open_block(subscript_node);
                }
                self.eat_token();
            },
            .Run_codespan => {
                try self.parse_code_span(.Backtick, true);
            },
            .Run_codespan_alt => {
                try self.parse_code_span(.Backtick_double, true);
            },
            TokenKind.Backtick, TokenKind.Backtick_double => {
                try self.parse_code_span(token.token_kind, false);
            },
            TokenKind.Dollar => {
                //  check if a digit follows immediately after and then just parse it as text
                //  so often used $xx for prices doesn't need to be escaped (how pandoc does it)
                if (self.peek_next_token().token_kind == TokenKind.Digits) {
                    try self.parse_text(token, self.get_last_block());
                    return true;
                }
                self.eat_token();

                const inline_math_start = self.peek_token();
                try self.skip_until_token(.Dollar, " inside iniline math ($...$)");

                const math_node = try self.new_node(self.get_last_block());
                math_node.data = .{ .MathInline = .{
                    .text = self.tokenizer.bytes[inline_math_start.start..self.peek_token().start],
                } };
                self.eat_token(); // eat closing $

                log.debug(
                    "ln:{}: Math span: `{s}`\n",
                    .{ inline_math_start.line_nr, math_node.data.MathInline.text },
                );
            },
            TokenKind.Open_bracket => {
                try self.parse_link();
            },
            TokenKind.Builtin_call => {
                try self.parse_builtin(token);
            },
            else => {
                try self.parse_text(token, self.get_last_block());
            },
        }
        return true;
    }

    inline fn parse_text(self: *Parser, token: *const Token, parent: *Node) ParseError!void {
        if (self.last_text_node) |continue_text| {
            // enlarge slice by directly manipulating the length (which is allowed in zig)
            // TODO backslash escaped text will result in faulty text, since the
            // backslash is included but the escaped text isn't and this as a whole ends
            // up making the text buffer too narrow
            continue_text.data.Text.text.len += token.end - token.start;
        } else {
            var text_node = try self.new_node(parent);
            text_node.data = .{
                .Text = .{ .text = self.tokenizer.bytes[token.start..token.end] },
            };
            self.last_text_node = text_node;
        }
        self.eat_token();

        // TODO @Robustness? invalidate last_text_node since Newline will
        // be consumed by caller and will most likely never reach parse_inline
        // the swallowed newline will thus not be added to the text slice
        // and following continuation texts that get added will be off by one
        // alternative is to add the newline here instead but that might not be
        // wanted all the time
        if (self.peek_token().token_kind == TokenKind.Newline) {
            self.last_text_node = null;
        }
    }

    fn parse_link(self: *Parser) ParseError!void {
        // still on [ token
        self.eat_token();

        var link_node = try self.new_node(self.get_last_block());
        link_node.data = .{
            .Link = .{
                .label = null,
                .url = null,
                .title = null,
            },
        };
        self.open_block(link_node);

        const link_text_start_token = self.peek_token();
        // TODO @CleanUp handle +-Indent
        while (try self.parse_inline(false)) {
            if (self.peek_token().token_kind == TokenKind.Close_bracket) {
                const last_block = self.get_last_block();
                if (last_block.data != NodeKind.Link) {
                    Parser.report_error("ln:{}: Unclosed {s} in Link text (first [] of a link definition)\n", .{ self.peek_token().line_nr, @tagName(last_block.data) });
                    return ParseError.SyntaxError;
                }
                break;
            }
        }
        if (self.peek_token().token_kind == TokenKind.Eof) {
            Parser.report_error(
                "ln:{}: Encountered end of file inside link text\n",
                .{link_text_start_token.line_nr},
            );
            return ParseError.SyntaxError;
        }
        const link_text_end = self.peek_token().start;
        self.eat_token(); // eat ]

        var token = self.peek_token();
        if (token.token_kind == TokenKind.Open_bracket) {
            link_node.data.Link.label = try self.parse_link_ref_label(NodeKind.Link);
        } else if (token.token_kind == TokenKind.Open_paren) {
            // start of url
            try self.parse_link_destination(); // expects to start on (
        } else {
            // use link text as link label referring to a reference definition
            link_node.data.Link.label = self.tokenizer.bytes[link_text_start_token.start..link_text_end];
        }
        self.close_last_block();

        log.debug("ln:{}: Link: {}\n", .{ link_text_start_token.line_nr, link_node.data });
    }

    fn parse_link_ref_label(self: *Parser, comptime kind: NodeKind) ParseError![]const u8 {
        // TODO compiler bug: expected token '}', found 'DocComment'
        // if function starts with a ///
        // /// expects to start on [
        // start of link label referring to a reference definition
        self.eat_token();

        const start_token = self.peek_token();
        try self.skip_until_token(.Close_bracket, " inside " ++ @tagName(kind) ++ " label brackets");
        const label_end = self.peek_token().start;
        self.eat_token(); // eat ]
        return self.tokenizer.bytes[start_token.start..label_end];
    }

    fn parse_code_block(self: *Parser) ParseError!void {
        // ArrayList doesn't accept ArenaAllocator directly so we need to
        // pass string_arena.allocator which is the proper mem.Allocator
        var string_buf = std.ArrayList(u8).init(&self.string_arena.allocator);
        var current_indent_lvl: u16 = 0;
        // TODO switch this to using spaces instead of "levels"?
        const indent = " " ** tokenizer.SPACES_PER_INDENT;
        var current_token: *Token = self.peek_token();
        var line_start = false;

        while (true) {
            if (current_token.token_kind == TokenKind.Backtick_triple) {
                self.eat_token();
                break;
            } else if (current_token.token_kind == TokenKind.Newline) {
                try string_buf.append('\n');
                line_start = true;
            } else if (current_token.token_kind == TokenKind.Increase_indent) {
                current_indent_lvl += 1;
            } else if (current_token.token_kind == TokenKind.Decrease_indent) {
                current_indent_lvl -= 1;
                if (current_indent_lvl < 0) {
                    self.report_error(
                        "ln:{}: Code block's indent decreased beyond it's starting level!",
                        .{current_token.line_nr},
                    );

                    return ParseError.SyntaxError;
                }
            } else {
                if (line_start) {
                    // indent to correct level at line start
                    var i: u32 = 0;
                    while (i < current_indent_lvl) : (i += 1) {
                        try string_buf.appendSlice(indent);
                    }
                    line_start = false;
                }

                try string_buf.appendSlice(current_token.text(self.tokenizer.bytes));
            }

            self.eat_token();
            current_token = self.peek_token();
        }

        const code_block = self.get_last_block();
        // string_buf.toOwnedSlice() -> caller owns the returned memory (remaining capacity is free'd)
        code_block.data.FencedCode.code = string_buf.toOwnedSlice();

        self.close_last_block(); // close code block
        log.debug("Code block:\n{s}", .{code_block.data.FencedCode.code});
    }

    /// when this method is called we're still on the first '('
    fn parse_link_destination(self: *Parser) ParseError!void {
        try self.require_token(
            TokenKind.Open_paren,
            ". Link destinations need to be wrapped in parentheses!",
        );
        self.eat_token(); // eat (

        var token = self.peek_token();
        const token_url_start = token;
        var ended_on_link_title = false;
        while (token.token_kind != TokenKind.Close_paren) {
            if (token.token_kind == TokenKind.Eof) {
                Parser.report_error(
                    "ln:{}: Missing closing ')' in link destination\n",
                    .{token_url_start.line_nr},
                );
                return ParseError.SyntaxError;
            } else if (token.token_kind == TokenKind.Space and
                self.peek_next_token().token_kind == TokenKind.Double_quote)
            {
                // TODO allow title to start at next line
                // start of link title
                self.eat_token();
                ended_on_link_title = true;
                break;
            }

            self.eat_token();
            token = self.peek_token();
        }

        const token_url_end = token;
        if (token_url_start.start == token_url_end.start) {
            Parser.report_error("ln:{}: Empty link destination\n", .{token_url_end.line_nr});
            return ParseError.SyntaxError;
        }

        const link_or_ref = self.get_last_block();
        log.debug(
            "ln:{}: Parse destination -> Link or ref: {s}\n",
            .{ self.peek_token().line_nr, @tagName(self.get_last_block().data) },
        );
        if (ended_on_link_title) {
            self.eat_token(); // eat "

            const link_title_start = self.peek_token().start;
            try self.skip_until_token(.Double_quote, " inside link title");
            const link_title_end = self.peek_token().start;
            self.eat_token(); // eat "

            try self.require_token(
                TokenKind.Close_paren,
                ". Link destination needs to be enclosed in parentheses!",
            );
            self.eat_token(); // eat )

            if (link_title_start == link_title_end) {
                Parser.report_error("ln:{}: Empty link title\n", .{token_url_end.line_nr});
                return ParseError.SyntaxError;
            }

            switch (link_or_ref.data) {
                // payload of this switch prong is the assigned NodeData type
                // |value| is just a copy so we need to capture the ptr to modify it
                .Link, .LinkRef => |*value| {
                    value.*.url = self.tokenizer.bytes[token_url_start.start..token_url_end.start];
                    value.*.title = self.tokenizer.bytes[link_title_start..link_title_end];
                },
                .Image => |*value| {
                    value.*.url = self.tokenizer.bytes[token_url_start.start..token_url_end.start];
                    value.*.title = self.tokenizer.bytes[link_title_start..link_title_end];
                },
                else => unreachable,
            }
        } else {
            self.eat_token(); // eat )

            switch (link_or_ref.data) {
                .Link, .LinkRef => |*value| {
                    value.*.url = self.tokenizer.bytes[token_url_start.start..token_url_end.start];
                    value.*.title = null;
                },
                .Image => |*value| {
                    value.*.url = self.tokenizer.bytes[token_url_start.start..token_url_end.start];
                    value.*.title = null;
                },
                else => unreachable,
            }
        }

        if (builtin.mode == .Debug) {
            switch (link_or_ref.data) {
                .Link, .LinkRef => |link| {
                    log.debug("Link dest:", .{});
                    if (link.label) |label| log.debug("label {s}", .{label});
                    if (link.url) |url| log.debug("url {s}", .{url});
                    if (link.title) |title| log.debug("title {s}", .{title});
                },
                .Image => |img| {
                    log.debug("Image dest:", .{});
                    if (img.label) |label| log.debug("label {s}", .{label});
                    if (img.url) |url| log.debug("url {s}", .{url});
                    if (img.title) |title| log.debug("title {s}", .{title});
                },
                else => unreachable,
            }
        }
    }

    inline fn skip_after_param(self: *Parser) !void {
        // we either need a after_pos_param state (which would mean
        // after_kw_param is needed as well) or we can skip all whitespace
        // till we hit the comma
        // TODO iterator? that erros on eof
        while (true) {
            const tok = self.peek_token();
            switch (tok.token_kind) {
                .Comma, .Close_paren => {
                    self.state = .in_pos_param; // so ',' gets treated as finisher
                    break;
                },
                .Space, .Tab => {},
                else => {
                    Parser.report_error(
                        "ln:{}: Hit '{s}' while waiting for param delimiter ','" ++
                            " or call closer ')' when parsing a builtin call!\n",
                        .{ tok.line_nr, tok.token_kind.name() },
                    );
                    return ParseError.SyntaxError;
                },
            }
            self.eat_token();
        }
    }

    fn parse_builtin(self: *Parser, start_token: *const Token) ParseError!void {
        self.eat_token(); // eat start_token
        try self.require_token(
            .Open_paren,
            ". Calling a builtin should look like: @builtin(arg, kwarg=..)\n",
        );
        self.eat_token();

        var builtin_node = try self.new_node(self.get_last_block());

        // start + 1 since the @ is included
        const keyword = self.tokenizer.bytes[start_token.start + 1 .. start_token.end];
        const mb_builtin_type = std.meta.stringToEnum(BuiltinCall, keyword);
        log.debug("Builtin type: {}", .{mb_builtin_type});
        if (mb_builtin_type) |bi_type| {
            builtin_node.data = .{ .BuiltinCall = .{ .builtin_type = bi_type } };
        } else {
            Parser.report_error("ln:{}: Unrecognized builtin: '{s}'\n", .{ start_token.line_nr, keyword });
            return ParseError.SyntaxError;
        }
        self.open_block(builtin_node);

        var current_arg = try self.new_node(builtin_node);
        current_arg.data = .PostionalArg;
        self.open_block(current_arg);

        const State = enum {
            next_pos_param,
            in_pos_param,
            // only expect kw_params after the first one
            next_kw,
            in_kw,
            after_kw,
            next_kw_param,
            in_kw_param,
        };

        var state = State.next_pos_param;
        var tok = self.peek_token();
        var last_end = tok.start; // exclusive
        // needed for switching to kwargs in the middle of in_pos_param
        // so we only need to set this in .next_pos_param and .in_pos_param
        var last_non_space = last_end; // exclusive
        var pos_params: u16 = 0;
        var kw_params: u16 = 0;
        while (tok.token_kind != .Close_paren) : ({
            tok = self.peek_token();
        }) {
            switch (state) {
                .next_pos_param => {
                    switch (tok.token_kind) {
                        .Space, .Tab, .Newline => {
                            last_end += 1;
                            self.eat_token();
                        },
                        else => {
                            state = .in_pos_param;
                            _ = try self.parse_inline(true); // eats the tok
                            last_non_space = tok.end;
                        },
                    }
                },
                .next_kw_param => {
                    switch (tok.token_kind) {
                        .Space, .Tab, .Newline => {
                            last_end += 1;
                            self.eat_token();
                        },
                        else => {
                            state = .in_kw_param;
                            _ = try self.parse_inline(true); // eats the tok
                        },
                    }
                },
                .in_pos_param => {
                    switch (tok.token_kind) {
                        .Equals => {
                            current_arg.data = .{
                                .KeywordArg = .{
                                    .keyword = self.tokenizer.bytes[last_end..last_non_space],
                                },
                            };
                            state = State.next_kw_param;
                            last_end = tok.end;

                            // delete text node that was created as the first param
                            // TODO maybe force to use double quotes?
                            // TODO this is error prone @Improve
                            //      (additionally make new_node set this to null?)
                            self.last_text_node = null;
                            current_arg.delete_direct_children(&self.node_arena.allocator);
                            self.eat_token();
                        },
                        .Comma => {
                            log.debug(
                                "ln:{}: Finished arg: {s}",
                                .{ start_token.line_nr, current_arg.data },
                            );
                            self.close_last_block();

                            state = .next_pos_param;

                            self.last_text_node = null;
                            last_end = tok.end;
                            pos_params += 1;

                            current_arg = try self.new_node(builtin_node);
                            current_arg.data = .PostionalArg;
                            self.open_block(current_arg);

                            self.eat_token();
                        },
                        .Newline => {
                            Parser.report_error(
                                "ln:{}: Newlines are not allowed inside parameter values!\n",
                                .{tok.line_nr},
                            );
                            return ParseError.SyntaxError;
                        },
                        .Space, .Tab => {
                            // treat this as a special case since we might encounter an
                            // = which would make this a kw param meaning we'd have to remember
                            // the last_non_space properly
                            _ = try self.parse_inline(true); // eats the tok
                        },
                        else => {
                            _ = try self.parse_inline(true); // eats the tok
                            last_non_space = tok.end;
                        },
                    }
                },
                .next_kw => {
                    switch (tok.token_kind) {
                        .Space, .Tab, .Newline => {
                            last_end += 1;
                            self.eat_token();
                        },
                        .Text, .Underscore => {
                            state = .in_kw;
                            // TODO is this needed? try self.parse_text(tok, current_arg);  // eats the tok
                            self.eat_token();
                        },
                        else => {
                            Parser.report_error(
                                "ln:{}: Expected keyword got {s}!\n",
                                .{ start_token.line_nr, tok.token_kind.name() },
                            );
                            return ParseError.SyntaxError;
                        },
                    }
                },
                .in_kw => {
                    switch (tok.token_kind) {
                        .Space, .Tab, .Newline => {
                            state = .after_kw;

                            current_arg.data.KeywordArg.keyword =
                                self.tokenizer.bytes[last_end..tok.start];
                            last_end = tok.end;
                            self.eat_token();
                        },
                        .Equals => {
                            state = .next_kw_param;
                            current_arg.data.KeywordArg.keyword =
                                self.tokenizer.bytes[last_end..tok.start];
                            last_end = tok.end;
                            self.eat_token();
                        },
                        .Builtin_call => return ParseError.SyntaxError,
                        else => {
                            self.eat_token();
                        },
                    }
                },
                .after_kw => {
                    switch (tok.token_kind) {
                        .Space, .Tab, .Newline => {
                            self.eat_token();
                        },
                        .Builtin_call => return ParseError.SyntaxError,
                        .Equals => {
                            state = .next_kw_param;
                            last_end = tok.end;
                            self.eat_token();
                        },
                        else => {
                            Parser.report_error(
                                "ln:{}: Expected '=' got {s}!\n",
                                .{ start_token.line_nr, tok.token_kind.name() },
                            );
                            return ParseError.SyntaxError;
                        },
                    }
                },
                .in_kw_param => {
                    switch (tok.token_kind) {
                        .Comma => {
                            log.debug(
                                "ln:{}: Finished arg: {}",
                                .{ start_token.line_nr, current_arg.data },
                            );
                            self.close_last_block();

                            state = .next_kw;
                            last_end = tok.end;
                            kw_params += 1;
                            self.last_text_node = null;

                            current_arg = try self.new_node(builtin_node);
                            self.open_block(current_arg);
                            current_arg.data = .{
                                .KeywordArg = .{
                                    .keyword = undefined,
                                },
                            };

                            self.eat_token();
                        },
                        .Newline => {
                            Parser.report_error(
                                "ln:{}: Newlines are not allowed inside parameter values!\n",
                                .{tok.line_nr},
                            );
                            return ParseError.SyntaxError;
                        },
                        else => _ = try self.parse_inline(true), // eats the tok
                    }
                },
            }
        }
        switch (state) {
            .in_kw,
            .after_kw,
            => {
                Parser.report_error(
                    "ln:{}: Encountered postional argument after keyword argument!\n",
                    .{start_token.line_nr},
                );
                return ParseError.SyntaxError;
            },
            .next_kw_param => {
                Parser.report_error(
                    "ln:{}: Missing keyword parameter value!\n",
                    .{start_token.line_nr},
                );
                return ParseError.SyntaxError;
            },
            .next_kw,
            .next_pos_param, // ignore extra comma e.g. @kw(abc, def,)
            .in_pos_param,
            .in_kw_param,
            => {
                self.last_text_node = null;
                self.close_last_block(); // arg
                std.debug.assert(self.get_last_block().data == .BuiltinCall);
                self.close_last_block(); // builtin node

                switch (state) {
                    .in_pos_param => pos_params += 1,
                    .in_kw_param => kw_params += 1,
                    else => {},
                }
                log.debug("ln:{}: LAST Finished arg: {}", .{ start_token.line_nr, current_arg.data });
            },
        }
        // TODO inline blocks now allowed as arguments, when they're used with cite builtins
        // or with nested builtins they won't be respected / or we will crash
        // @CleanUp

        self.eat_token(); // eat )

        log.debug("ln:{}: Finished builtin: {s} pos: {}, kw: {}", .{ start_token.line_nr, self.tokenizer.bytes[start_token.start..start_token.end], pos_params, kw_params });
        builtin_node.print_tree();

        const bc_info = builtin_call_info[@enumToInt(mb_builtin_type.?)];
        if (bc_info.pos_params >= 0 and pos_params != bc_info.pos_params) {
            Parser.report_error(
                "ln:{}: Expected {} positional arguments, found {} for builtin '{s}'\n",
                .{ start_token.line_nr, bc_info.pos_params, pos_params, keyword },
            );
            return ParseError.SyntaxError;
        } else if (kw_params > bc_info.kw_params) {
            Parser.report_error(
                "ln:{}: Expected a maximum of {} keyword arguments, found {} for builtin '{s}'\n",
                .{ start_token.line_nr, bc_info.kw_params, kw_params, keyword },
            );
            return ParseError.SyntaxError;
        }

        try self.execute_builtin(builtin_node, mb_builtin_type.?, .{});
    }

    fn execute_builtin(
        self: *Parser,
        builtin_node: *ast.Node,
        builtin_type: BuiltinCall,
        data: anytype,
    ) ParseError!void {
        // zig 0.9dev does not allow unused variables/parameters anymore, the intended use is
        // to "annotate" them like this (https://github.com/ziglang/zig/issues/9296)
        _ = data;

        const allocator = &self.node_arena.allocator;
        const result = bic.evaluate_builtin(allocator, builtin_node, builtin_type, .{}) catch {
            return ParseError.BuiltinCallFailed;
        };
        if (bic.builtin_call_info[@enumToInt(builtin_type)].persistent) {
            const persistent = try allocator.create(bic.BuiltinResult);
            persistent.* = result;
            builtin_node.data.BuiltinCall.result = persistent;
        }

        switch (result) {
            .cite, .textcite, .cites => {
                // store citation nodes for passing them to citeproc and replacing them
                // with actual citation nodes
                // NOTE: only store top-level citation calls (otherwise we get duplicate
                // output for .cites etc.)
                switch (self.get_last_block().data) {
                    .BuiltinCall, .PostionalArg, .KeywordArg => {},
                    else => try self.citations.append(builtin_node),
                }
            },
            .bibliography => {
                if (self.bibliography != null) {
                    Parser.report_error("Only one bibliography allowed currently!\n", .{});
                    return ParseError.SyntaxError;
                }

                self.bibliography = result.bibliography;
            },
            // TODO should these (or all builtin results?) be their own NodeData?
            .label => {
                const entry_found = try self.label_node_map.getOrPut(result.label);
                // ^ result will be a struct with a pointer to the HashMap.Entry and a bool
                // whether an existing value was found
                if (entry_found.found_existing) {
                    Parser.report_error(
                        "ln:{d}: Duplicate label '{s}'!\n",
                        .{ self.peek_token().line_nr, result.label },
                    );
                    return ParseError.SyntaxError;
                } else {
                    // actually write entry value (key was already written by getOrPut)
                    const parent = self.get_last_block();
                    std.debug.assert(parent.data != .BuiltinCall and parent.data != .PostionalArg and
                        parent.data != .KeywordArg);
                    entry_found.value_ptr.* = &parent.data;
                }
            },
            else => {},
        }
    }
};
