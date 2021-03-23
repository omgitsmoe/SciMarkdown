const std = @import("std");

const tok = @import("tokenizer.zig");
const Tokenizer = tok.Tokenizer;
const Token = tok.Token;
const TokenKind = tok.TokenKind;

pub fn main() !void {
    // gpa optimized for safety over performance; can detect leaks, double-free and use-after-free
    // takes a config struct (empty here .{})
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        // print takes a format string and a struct
        // prints automatically std.debug.print("Leak detected: {}\n", .{leaked});
    }

    const allocator = &gpa.allocator;
    // Caller must call argsFree on result
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    return mainArgs(allocator, args);
}

// errorset!return_type
// !void same as anyerror which is the global error set
pub fn mainArgs(allocator: *std.mem.Allocator, args: []const []const u8) !void {
    if (args.len <= 1) {
        std.log.info("Usage: pistis <index-filename>", .{});
        std.process.exit(1);
    }

    const root_file_name = args[1];

    var parser: Parser = try Parser.init(allocator, root_file_name);
    defer parser.deinit();
    try parser.parse();
}

const Parser = struct {
    allocator: *std.mem.Allocator,
    node_arena: std.heap.ArenaAllocator,
    string_arena: std.heap.ArenaAllocator,

    tokenizer: Tokenizer,
    // NOTE: ArrayList: pointers to items are __invalid__ after resizing operations!!
    // so it doesn't make sense to keep a ptr to the current token
    token_buf: std.ArrayList(Token),
    tk_index: u32,

    current_document: *Node,
    last_node: *Node,
    // first open_block is always current_document
    open_blocks: [50]*Node,
    open_block_idx: u8,

    const ParseError = error {
        SyntaxError,
        ExceededOrderedListDigits,
    };

    pub fn init(allocator: *std.mem.Allocator, filename: []const u8) !Parser {
        var parser = Parser{
            .allocator = allocator,
            .node_arena = std.heap.ArenaAllocator.init(allocator),
            .string_arena = std.heap.ArenaAllocator.init(allocator),

            .tokenizer = try Tokenizer.init(allocator, filename),
            // TODO allocate a capacity for tokens with ensureCapacity based on filesize
            .token_buf = std.ArrayList(Token).init(allocator),
            .tk_index = 0,

            .current_document = undefined,
            .last_node = undefined,
            .open_blocks = undefined,
            .open_block_idx = 0,
        };

        // manually get the first token
        try parser.token_buf.append(parser.tokenizer.get_token());

        // create() returns ptr to undefined memory
        var current_document = try Node.create(allocator);
        current_document.data = .Document;
        parser.current_document = current_document;
        parser.last_node = current_document;
        parser.open_blocks[0] = current_document;

        return parser;
    }

    pub fn deinit(self: *Parser) void {
        // free code string buffers from .FencedCode nodes
        self.string_arena.deinit();
        self.node_arena.deinit();
        self.tokenizer.deinit();
        self.token_buf.deinit();
    }

    inline fn new_node(self: *Parser, parent: *Node) !*Node {
        const node = try Node.create(&self.node_arena.allocator);
        parent.append_child(node);
        self.last_node = node;
        return node;
    }

    inline fn open_block(self: *Parser, block: *Node) void {
        self.open_block_idx += 1;
        self.open_blocks[self.open_block_idx] = block;
    }

    /// does no bounds checking
    inline fn get_last_block(self: *Parser) *Node {
        return self.open_blocks[self.open_block_idx];
    }

    inline fn close_last_block(self: *Parser) void {
        std.debug.assert(self.open_block_idx > 0);
        self.open_block_idx -= 1;
    }

    pub fn parse(self: *Parser) !void {
        // tokenize the whole file first so we can use ptrs that don't get invalidated
        // due to resizing; maybe also faster for successful compiles since
        // better cache friendlyness?
        var token: Token = undefined;
        token.token_kind = TokenKind.Invalid;
        while (token.token_kind != TokenKind.Eof) {
            token = self.tokenizer.get_token();
            try self.token_buf.append(token);
        }

        while (self.peek_token().token_kind != TokenKind.Eof) {
            try self.parse_block();
        }
    }

    /// does no bounds checking beyond which is integrated with zig up to ReleaseSafe mode
    /// assumes caller doesn't call peek_next_token after receiving TokenKind.Eof
    inline fn eat_token(self: *Parser) void {
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

    inline fn require_token(self: *Parser, comptime token_kind: TokenKind,
                            comptime expl_msg: []const u8) ParseError!void {
        const token = self.peek_token();
        if (token.token_kind != token_kind) {
            Parser.report_error("ln:{}: Expected token '{}' found '{}'" ++ expl_msg ++ "\n",
                                .{ token.line_nr, token_kind.name(), token.token_kind.name() });
            return ParseError.SyntaxError;
        }
    }
    
    inline fn report_error(comptime err_msg: []const u8, args: anytype) void {
        std.log.err(err_msg, args);
    }

    fn parse_block(self: *Parser) !void {
        switch (self.peek_token().token_kind) {
            TokenKind.Comment => {
                self.eat_token();
                self.eat_token();  // eat \n
            },
            TokenKind.Newline => {
                // close block on blank line otherwise ignore
                // blank lines are ignored
                // two \n (blank line) end a paragraph

                // self.current_document is always open_blocks[0]
                if (self.open_block_idx > 0) {
                    std.debug.print("Close block ln {}\n", .{ self.peek_token().line_nr });
                    self.close_last_block();
                }

                self.eat_token();
            },

            TokenKind.Hash => {
                // atx heading
                // 1-6 unescaped # followed by ' ' or end-of-line
                // not doing: optional closing # that don't have to match the number of opening #

                var heading_lvl: i16 = 1;
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
                        " escacpe the first '#' with a '\\'", .{ tok_after_hashes.line_nr });
                    return ParseError.SyntaxError;
                } else {
                    // TODO close_open_block
                    self.eat_token();  // eat space

                    // could be multiple text or other kinds of tokens that should be
                    // interpreted as text
                    // TODO => this should be replaced by parse inline
                    // TODO open block
                    const heading_name_start = self.peek_token().start;
                    // TODO make sure we account for sudden Eof everywhere
                    while (self.peek_token().token_kind != TokenKind.Newline and
                            self. peek_token().token_kind != TokenKind.Eof) {
                        self.eat_token();
                    }
                    const heading_name_end = self.peek_token().start;
                    if (heading_name_start == heading_name_end) {
                        Parser.report_error("ln:{}: Empty heading name!", .{ self.peek_token().line_nr });
                        return ParseError.SyntaxError;
                    }

                    var heading_node: *Node = try self.new_node(self.current_document);
                    heading_node.data = .{
                        .Heading = .{ .level = heading_lvl,
                                      .text = self.tokenizer.bytes[heading_name_start..heading_name_end] },
                    };

                    std.debug.print(
                        "Heading: level {} text: '{}'\n",
                        .{ heading_node.data.Heading.level, heading_node.data.Heading.text });
                }
            },

            TokenKind.Dash, TokenKind.Plus => {
                // maybe thematic break: the same 3 or more *, - or _ followed by optional spaces
                // bullet list/list item
                // remove _ and * from being able to start a thematic break/unordered list
                // so we don't have to backtrack if parsing doesn't succeed when it was just
                // being used as emphasis
                const start_token_kind = self.peek_token().token_kind;
                self.eat_token();

                const next_token = self.peek_token();
                if (next_token.token_kind == TokenKind.Space) {
                    // TODO unordered list (can be started while in a container block)
                } else if (start_token_kind != TokenKind.Plus and
                           next_token.token_kind == TokenKind.Dash and
                           self.peek_next_token().token_kind == TokenKind.Dash) {
                    self.eat_token();

                    // thematic break
                    var token_kind = self.peek_token().token_kind;
                    while (token_kind == TokenKind.Dash or
                            token_kind == TokenKind.Comment or
                            token_kind == TokenKind.Space) {
                        self.eat_token();
                        token_kind = self.peek_token().token_kind;
                    }

                    // CommonMark allows optional spaces after a thematic break - we don't!
                    // so the line the thematic break is in has to end in a newline right
                    // after the thematic break (---)
                    if (self.peek_token().token_kind != TokenKind.Newline) {
                        // \\ starts a zig multiline string-literal that goes until the end
                        // of the line, \n is only added if the next line starts with a \\
                        // alternatively you could use ++ at the end of the line to concat
                        // the arrays
                        // recognizes --- of table sep as invalid thematic break
                        // -> always require table rows to start with |
                        std.log.err("Line {}: " ++
                                    "A line with a thematic break (consisting of at least 3 '-'" ++
                                    " can only contain whitespace, comments or the " ++
                                    "character that started the break and has to end in a new line!\n",
                                    .{ self.peek_token().line_nr });
                        return ParseError.SyntaxError;
                    } else {
                        var thematic_break = try self.new_node(self.get_last_block());
                        thematic_break.data = .ThematicBreak;
                        std.debug.print("Found valid thematic break! starting with: '{}'\n",
                                        .{start_token_kind});
                    }
                } else {
                    // error here otherwise we'd have to backtrack - how often do you
                    // really want to start a paragraph with *-+_ without wanting
                    // a thematic break / list?
                    // still on 2nd #/-/_
                    Parser.report_error(
                        "ln:{}: Characters '-' and '+' that start a new paragraph need to " ++
                        "either be part of an unordered list ('- Text') or a thematic break " ++
                        "(at least three '-')!\n", .{ self.peek_token().line_nr });
                    return ParseError.SyntaxError;
                }
            },

            TokenKind.Digits => {
                // maybe ordered list
                // 1-9 digits (0-9) ending in a '.' or ')'
                // TODO can't be in a paragraph
                self.eat_token();
                const next_token_kind = self.peek_token().token_kind;
                if (next_token_kind == TokenKind.Period or
                        next_token_kind == TokenKind.Close_paren) {
                    self.eat_token();

                    try self.require_token(TokenKind.Space, " after list item starter!");
                    self.eat_token();

                    var list_node = try self.new_node(self.get_last_block());
                    list_node.data = .OrderedList;
                    // TODO can only be opened inside another container block
                    self.open_block(list_node);

                    // TODO parse_list_item; move this into it v
                    // limit doesn't make sense, since number isn't used for numbering the
                    // ordered list; even though this should belong into the list item parse fn
                    // if (current_token.len() > 9) {
                    //     std.debug.print(
                    //         "CommonMark ordered list items only allow 9 digits!", .{});
                    //     return ParseError.ExceededOrderedListDigits;
                    // }
                    // const item_text = try self.require_token(TokenKind.Text
                    // var list_item = try self.new_node();
                    // list_item.data = .OrderedListItem;
                    // list_node.append_child(list_item);
                } else {
                    // TODO parse_paragraph
                }
            },

            TokenKind.Backtick_triple => {
                self.eat_token();
                    
                // language name or newline
                const lang_name_start = self.peek_token().start;
                while (self.peek_token().token_kind != TokenKind.Newline) {
                    self.eat_token();
                }
                const lang_name_end = self.peek_token().start;
                self.eat_token();

                var code_node = try self.new_node(self.get_last_block());
                code_node.data = .{
                    .FencedCode = .{
                        .language_name =
                            if (lang_name_start != lang_name_end)
                                self.tokenizer.bytes[lang_name_start..lang_name_end]
                            else "",
                        .code = undefined,
                    },
                };
                self.open_block(code_node);

                std.debug.print("Found code block ln{}: lang_name {}\n",
                    .{ self.peek_token().line_nr, code_node.data.FencedCode.language_name });

                try self.parse_code_block();
            },

            TokenKind.Colon_open_bracket => {
                // link reference definition
                if (self.open_block_idx > 0) {
                    Parser.report_error(
                        "ln:{}: References must be defined at the document level!\n",
                        .{ self.peek_token() });
                    return ParseError.SyntaxError;
                }
                self.eat_token();

                var token = self.peek_token();
                const ref_name_start = token.start;
                // CommonMark allows one \n inside a reference label
                // don't allow any for now!
                while (token.token_kind != TokenKind.Close_bracket_colon and
                        token.token_kind != TokenKind.Newline and
                        token.token_kind != TokenKind.Eof) {
                    self.eat_token();
                    token = self.peek_token();
                }
                const ref_name_end = self.peek_token().start;

                if (token.token_kind != TokenKind.Close_bracket_colon) {
                    Parser.report_error("ln:{}: Missing closing ']:' from reference label!\n",
                                        .{ self.peek_token().line_nr });
                    return ParseError.SyntaxError;
                }
                self.eat_token();

                if (ref_name_start == ref_name_end) {
                    Parser.report_error("ln:{}: Empty reference label!\n", .{ self.peek_token().line_nr });
                    return ParseError.SyntaxError;
                }
                std.debug.print(
                    "ln:{}: Ref with label: '{}'\n",
                    .{ self.peek_token().line_nr, self.tokenizer.bytes[ref_name_start..ref_name_end] });

                try self.require_token(
                    TokenKind.Space,
                    ". A space is required between reference label and reference content!");
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

                try self.parse_link_destination();
            },

            // TokenKind.Close_angle_bracket => {
            //     // maybe block quote
            //     // 0-3 spaces + '>' with an optional following ' '
            //     // can contain other blocks: headings, code blocks etc.
            // },

            else => {
                // std.debug.print("Else branch ln {}\n", .{ self.peek_token().line_nr });
                // self.eat_token();

                // var token_kind = self.peek_token().token_kind;
                // while (token_kind != TokenKind.Newline and token_kind != TokenKind.Eof) {
                //     // std.debug.print("Ate token {} ln {}\n", .{ token_kind, self.peek_token().line_nr });
                //     self.eat_token();
                //     token_kind = self.peek_token().token_kind;
                // }
                // // will end on newline token -> need to advance one more
                // self.eat_token();
                try self.parse_paragraph();
                // will end on newline token -> need to advance one more
                self.eat_token();
            },
        }
    }

    fn parse_paragraph(self: *Parser) !void {
        var paragraph = try self.new_node(self.get_last_block());
        paragraph.data = NodeKind.Paragraph;
        self.open_block(paragraph);
        while (true) {
            if(self.peek_token().token_kind == TokenKind.Newline) {
                self.eat_token();
                if (self.peek_token().token_kind == TokenKind.Newline) {
                    break;
                }
            }
            try self.parse_inline();
            // std.debug.print("Tok: {} NExt {}\n", .{ self.peek_token().token_kind, self.peek_next_token().token_kind });
        }
        self.eat_token();  // eat 2nd \n

        std.debug.print("Last block: {}\n", .{ self.get_last_block().data });
        if (self.get_last_block().data != NodeKind.Paragraph) {
            Parser.report_error(
                "ln:{}: There was at least one unclosed inline element of type '{}'\n",
                .{ self.peek_token().line_nr, @tagName(self.get_last_block().data) });
            return ParseError.SyntaxError;
        }
        self.close_last_block();
    }

    fn parse_inline(self: *Parser) !void {
        var token = self.peek_token();
        switch (token.token_kind) {
            TokenKind.Newline, TokenKind.Eof => return,
            TokenKind.Hard_line_break => {
                self.eat_token();
                // TODO last_node is not correct
                var line_break = try self.new_node(self.last_node);
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
                            .{ self.peek_token().line_nr, opener_token_kind, current_token_kind });
                        return ParseError.SyntaxError;
                    }

                    std.debug.print("Close emphasis ln:{}: token: {}\n",
                                    .{ self.peek_token().line_nr, current_token_kind });
                    self.close_last_block();
                } else {
                    var emph_node = try self.new_node(self.last_node);
                    emph_node.data = .{
                        .Emphasis = .{ .opener_token_kind = current_token_kind },
                    };
                    std.debug.print("Open emphasis ln:{}: token: {} last block: {}\n",
                                    .{ self.peek_token().line_nr, current_token_kind, last_block.data });
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
                            .{ self.peek_token().line_nr, opener_token_kind, current_token_kind });
                        return ParseError.SyntaxError;
                    }

                    std.debug.print("Close strong emphasis ln:{}: token: {}\n",
                                    .{ self.peek_token().line_nr, current_token_kind });
                    self.close_last_block();
                } else {
                    var emph_node = try self.new_node(self.last_node);
                    emph_node.data = .{
                        .StrongEmphasis = .{ .opener_token_kind = current_token_kind },
                    };
                    std.debug.print("Open strong emphasis ln:{}: token: {}\n",
                                    .{ self.peek_token().line_nr, current_token_kind });
                    self.open_block(emph_node);
                }
                self.eat_token();
            },
            else => { self.eat_token(); },
        }
    }

    fn parse_code_block(self: *Parser) !void {
        const starting_lvl = self.tokenizer.indent_lvl;
        // ArrayList doesn't accept ArenaAllocator directly so we need to
        // pass string_arena.allocator which is the proper mem.Allocator
        var string_buf = std.ArrayList(u8).init(&self.string_arena.allocator);
        var current_indent_lvl: u8 = 0;
        const indent = " " ** tok.SPACES_PER_INDENT;
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
                        .{ current_token.line_nr });

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

                switch (current_token.token_kind) {
                    TokenKind.Text, TokenKind.Comment => 
                        try string_buf.appendSlice(
                            self.tokenizer.bytes[current_token.start..current_token.end]),
                    else => try string_buf.appendSlice(current_token.token_kind.name()),
                }
            }

            self.eat_token();
            current_token = self.peek_token();
        }

        const code_block = self.get_last_block();
        // string_buf.toOwnedSlice() -> caller owns the returned memory (remaining capacity is free'd)
        code_block.data.FencedCode.code = string_buf.toOwnedSlice();

        self.close_last_block();  // close code block
        std.debug.print("Code block:\n{s}", .{ code_block.data.FencedCode.code });
    }

    /// when this method is called we're still on the first '('
    fn parse_link_destination(self: *Parser) !void {
        try self.require_token(TokenKind.Open_paren, ". Link destinations need to be wrapped in parentheses!");
        self.eat_token();  // eat (

        var token = self.peek_token();
        const token_url_start = token;
        var ended_on_link_title = false;
        while (token.token_kind != TokenKind.Close_paren) {
            if (token.token_kind == TokenKind.Eof) {
                Parser.report_error("ln:{}: Missing closing ')' in link destination\n",
                                    .{ token_url_start.line_nr });
                return ParseError.SyntaxError;
            } else if (token.token_kind == TokenKind.Space and
                       self.peek_next_token().token_kind == TokenKind.Double_quote) {
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
            Parser.report_error("ln:{}: Empty link destination\n",
                                .{ token_url_end.line_nr });
            return ParseError.SyntaxError;
        }

        const link_or_ref = self.last_node;
        if (ended_on_link_title) {
            self.eat_token();  // eat "
            token = self.peek_token();
            const link_title_start = token;

            while (token.token_kind != TokenKind.Double_quote) {
                if (token.token_kind == TokenKind.Eof) {
                    Parser.report_error("ln:{}: Missing closing '\"' in link title\n",
                                        .{ link_title_start.line_nr });
                    return ParseError.SyntaxError;
                }

                self.eat_token();
                token = self.peek_token();
            }
            const link_title_end = token;
            self.eat_token();  // eat "

            try self.require_token(TokenKind.Close_paren,
                                   ". Link destination needs to be enclosed in parentheses!");
            
            if (link_title_start.start == link_title_end.start) {
                Parser.report_error("ln:{}: Empty link title\n",
                                    .{ token_url_end.line_nr });
                return ParseError.SyntaxError;
            }

            switch (link_or_ref.data) {
                // payload of this switch prong is the assigned NodeData type
                // |value| is just a copy so we need to capture the ptr to modify it
                .Link, .LinkRef => |*value| {
                    value.*.url = self.tokenizer.bytes[token_url_start.start..token_url_end.start];
                    value.*.title = self.tokenizer.bytes[link_title_start.start..link_title_end.start];
                },
                else => unreachable,
            }
        } else {
            self.eat_token();  // eat )

            switch (link_or_ref.data) {
                .Link, .LinkRef => |*value| {
                    value.*.url = self.tokenizer.bytes[token_url_start.start..token_url_end.start];
                    value.*.title = null;
                },
                else => unreachable,
            }
        }

        std.debug.print("Link dest: {}\n", .{ link_or_ref.data });
    }
};

// meta.TagType gets union's enum tag type (by using @typeInfo(T).tag_type)
const NodeKind = std.meta.TagType(Node.NodeData);
const Node = struct {
    parent: ?*Node,

    next: ?*Node,
    first_child: ?*Node,
    last_child: ?*Node,

    // since a tagged union coerces to their tag type we don't need a
    // separate kind field
    data: NodeData,

    const LinkData = struct { label: []const u8, url: []const u8, title: ?[]const u8 };
    const EmphData = struct { opener_token_kind: TokenKind };
    // tagged union
    const NodeData = union(enum) {
        // special
        Undefined,
        Document,
        Import,

        // block
        // leaf blocks
        ThematicBreak,

        Heading: struct { level: i16, text: []const u8 },

        // TODO free code buffer
        FencedCode: struct { language_name: []const u8, code: []const u8 },

        LinkRef: LinkData,

        Image,  // inline in CommonMark - leaf block here

        Paragraph,
        BlankLine, // ?

        // container blocks
        BlockQuote,

        UnorderedList,
        UnorderedListItem,

        OrderedList,
        OrderedListItem,
        
        // ?
        Table,
        TableRow,

        // inline
        CodeSpan,
        Emphasis: EmphData,
        StrongEmphasis: EmphData,
        Link: LinkData,
        Autolink,
        // add SoftLineBreak ? are basically ignored and are represented by single \n
        HardLineBreak,
        Text,
    };

    pub inline fn create(allocator: *std.mem.Allocator) !*Node {
        var new_node = try allocator.create(Node);
        new_node.* = .{
            .parent = null,
            .next = null,
            .first_child = null,
            .last_child = null,
            .data = .Undefined,
        };
        return new_node;
    }

    pub fn append_child(self: *Node, child: *Node) void {
        std.debug.assert(child.parent == null);

        if (self.first_child != null) {
            // .? equals "orelse unreachable" so we crash when last_child is null
            self.last_child.?.next = child;
            self.last_child = child;
        } else {
            self.first_child = child;
            self.last_child = child;
        }

        child.parent = self;
    }

    pub inline fn is_container_block(self: *Node) bool {
        return switch (self.data) {
            .BlockQuote, .BulletList, .BulletListItem, .OrderedList, .OrderedListItem => true,
            else => false,
        };
    }

    pub inline fn is_leaf_block(self: *Node) bool {
        return switch (self.data) {
            .ThematicBreak, .Heading, .FencedCode, .LinkRef, .Paragraph, .BlankLine, .Image => true,
            else => false,
        };
    }

    pub inline fn is_block(self: *Node) bool {
        return is_container_block(self) or is_leaf_block(self);
    }
};

// zig gets polymorphism/generics by using compile time functions that return a type
pub fn DepthFirstIterator(comptime T: type) type {
    return struct {
        const Self = @This();  // polymorphic type
        const Queue = std.TailQueue(*T);
        const QNode = Queue.Node;  // node type used in TailQueue

        allocator: *std.mem.Allocator,
        node_buf: std.ArrayList(QNode),
        q: Queue,

        pub fn init(allocator: *std.mem.Allocator, start: *T) !Self {
            var dfs = Self{
                .allocator = allocator,
                .node_buf = std.ArrayList(QNode).init(allocator),
                .q = Queue{},
            };

            const added = try dfs.node_buf.addOne();
            added.* = QNode{ .data = start };
            dfs.q.append(added);

            return dfs;
        }

        pub fn deinit(self: *Self) void {
            self.node_buf.deinit();
        }

        pub fn next(self: *Self) ?*T {
            if (self.q.len > 0) {
                const current_item = self.q.popFirst();

                // queue the children
                if (current_item.data.first_child) |first_child| {
                    var current_child = first_child;
                    self.queue_left(QNode{ .data = first_child });

                    while (current_child.next) |child| {
                        self.queue_left(QNode{ .data = child });
                        current_child = child;
                    }
                }

                return current_item.data;
            } else {
                return null;
            }
        }

        fn queue(self: *Self, node: QNode) !void {
            const new = try self.q.addOne();
            new.* = node;
            self.q.append(new);
        }

        fn queue_left(self: *Self, node: QNode) !void {
            const new = try self.q.addOne();
            new.* = node;
            self.q.prepend(new);
        }
    };
}
