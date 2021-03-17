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
    const args = try std.process.argsAlloc(allocator);
    defer allocator.free(args);

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

    // rather than parse char by char
    // split tokenizing/parsing up into parsing the lines/paragraphs
    // and inline tokens etc.
    // since a lot of tokens only have an 'effect' if they start the line as the first
    // non-whitepsace token

    var parser: Parser = try Parser.init(allocator, root_file_name);
    try parser.parse();
}

const Parser = struct {
    allocator: *std.mem.Allocator,
    node_arena: std.heap.ArenaAllocator,

    tokenizer: Tokenizer,
    // NOTE: ArrayList: pointers to items are __invalid__ after resizing operations!!
    // so it doesn't make sense to keep a ptr to the current token
    token_buf: std.ArrayList(Token),
    tk_index: u32,

    current_document: *Node,
    last_node: *Node,
    indent: i32,
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

            .tokenizer = try Tokenizer.init(allocator, filename),
            // TODO allocate a capacity for tokens with ensureCapacity based on filesize
            .token_buf = std.ArrayList(Token).init(allocator),
            .tk_index = 0,

            .current_document = undefined,
            .last_node = undefined, 
            .indent = 0,
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

        return parser;
    }

    pub fn deinit(self: *Parser) void {
        self.node_arena.deinit();
        self.tokenizer.deinit();
        self.token_buf.deinit();
    }

    pub fn parse(self: *Parser) !void {
        while (self.peek_token().token_kind != TokenKind.Eof) {
            try self.parse_block();
            // const ctok = try self.get_token();
            // std.debug.print("'{}': {}\n", .{ self.tokenizer.bytes[ctok.start..ctok.end], ctok });
        }
    }

    /// NOTE: ptr will be invalid after self.token_buf gets resized!
    inline fn get_token(self: *Parser) !void {
        try self.token_buf.append(self.tokenizer.get_token());
    }

    inline fn eat_token(self: *Parser) !void {
        // order important
        self.tk_index += 1;
        try self.get_token();
    }

    /// NOTE: ptr will be invalid after self.token_buf gets resized!
    inline fn peek_token(self: *Parser) *Token {
        // std.debug.print("{}\n", .{ current_token });
        return &self.token_buf.items[self.tk_index];
    }

    /// NOTE: ptr will be invalid after self.token_buf gets resized!
    fn peek_next_token(self: *Parser) !*Token {
        const next_token_idx = self.tk_index + 1;
        if (next_token_idx >= self.token_buf.items.len) {
            try self.get_token();
        }

        return &self.token_buf.items[next_token_idx];
    }

    // TODO remove err_msg?
    inline fn require_token(self: *Parser, token_kind: TokenKind, err_msg: []const u8) bool {
        if (self.peek_token().token_kind != token_kind) {
            std.debug.print("ERROR - {}", .{ err_msg });
            return false;
        } else {
            return true;
        }
    }

    fn advance_to_first_nonspace(self: *Parser) u32 {
        var num_spaces: u32 = 0;
        return blk: while ((try self.get_token()).token_kind == TokenKind.Space) {
            num_spaces += 1;
            break :blk num_spaces;
        };
    }

    fn parse_block(self: *Parser) !void {
        switch (self.peek_token().token_kind) {
            // TokenKind.Increase_indent => {
            //     // code block if not in another block?
            // },
            TokenKind.Newline => {
                // close block
                std.debug.print("Close block ln {}\n", .{ self.peek_token().line_nr });
                try self.eat_token();
            },

            TokenKind.Hash => {
                // atx heading
                // 1-6 unescaped # followed by ' ' or end-of-line
                // not doing: optional closing # that don't have to match the number of opening #

                var heading_lvl: i16 = 1;
                try self.eat_token();
                while (self.peek_token().token_kind == TokenKind.Hash) {
                    heading_lvl += 1;
                    try self.eat_token();
                }

                // TODO !IMPORTANT! can't store references to tokens since they get invalidated
                // as soon as we get a new one, so either:
                // 1) tokenize the whole file into a dynamic buffer and then iterate over that
                //    using indices
                // 2) make sure our syntax only requires one token look-ahead so we don't
                //    even have to store them in a buffer
                // 3) store token handles/indices and use that to look them up in our dynamic buffer
                //    (never storing pointers)
                const tok_after_hashes = self.peek_token();
                if (heading_lvl > 6 or
                    (tok_after_hashes.token_kind != TokenKind.Space and
                     tok_after_hashes.token_kind != TokenKind.Newline)) {
                    // self.parse_paragraph() or error?
                } else {
                    // TODO close_open_block
                    try self.eat_token();  // eat space

                    var new_node: *Node = try Node.create(&self.node_arena.allocator);
                    if (!self.require_token(TokenKind.Text, "Expected heading name!\n")) {
                        return ParseError.SyntaxError;
                    }
                    // TODO could be multiple text or other kinds of tokens that should be
                    // interpreted as text
                    const text_tok = self.peek_token();
                    new_node.data = .{
                        .Heading = .{ .level = heading_lvl, .setext_heading = false,
                                      .text = self.tokenizer.bytes[text_tok.start..text_tok.end] },
                    };
                    try self.eat_token(); // eat text token

                    if (!self.require_token(TokenKind.Newline, "Expected end of line!\n")) {
                        return ParseError.SyntaxError;
                    }
                    std.debug.print(
                        "Heading: level {} text: '{}'\n",
                        .{ new_node.data.Heading.level, new_node.data.Heading.text });
                    self.last_node.append_child(new_node);
                }
            },

            TokenKind.Asterisk, TokenKind.Dash, TokenKind.Plus, TokenKind.Underscore => {
                // maybe thematic break: the same 3 or more *, - or _ followed by optional spaces
                // bullet list/list item
                const start_token_kind = self.peek_token().token_kind;
                try self.eat_token();

                const next_token = self.peek_token();
                if (start_token_kind != TokenKind.Underscore and
                    next_token.token_kind == TokenKind.Space) {
                    // TODO can only be started while not in a block
                    // unordered list
                } else if (start_token_kind != TokenKind.Plus and
                           next_token.token_kind == start_token_kind) {

                    if ((try self.peek_next_token()).token_kind == start_token_kind) {
                        try self.eat_token();

                        // thematic break
                        while (self.peek_token().token_kind == start_token_kind) {
                            try self.eat_token();
                        }

                        // CommonMark allows optional spaces after a thematic break - we don't!
                        // so the line the thematic break is in has to end in a newline right
                        // after the thematic break (-, *, _)
                        if (self.peek_token().token_kind != TokenKind.Newline) {
                            // \\ starts a zig multiline string-literal that goes until the end
                            // of the line, \n is only added if the next line starts with a \\
                            // alternatively you could use ++ at the end of the line to concat
                            // the arrays
                            // TODO recognizes --- of table sep as invalid thematic break
                            std.log.err("Line {}: " ++
                                        "A line with a thematic break (consisting of at least 3 " ++
                                        "*, _, or -) can only contain the character that started " ++
                                        "the break and has to end in a new line!\n" ,
                                        .{ self.peek_token().line_nr });
                            return ParseError.SyntaxError;
                        } else {
                            var thematic_break = try Node.create(&self.node_arena.allocator);
                            thematic_break.data = .ThematicBreak;
                            self.current_document.append_child(thematic_break);
                            std.debug.print("Found valid thematic break! starting with: '{}'\n",
                                            .{start_token_kind});
                        }
                    } else {
                        // TODO parse_paragraph or error?
                        // still on 2nd #/-/_
                    }
                }
            },

            TokenKind.Digits => {
                // maybe ordered list
                // 1-9 digits (0-9) ending in a '.' or ')'
                // TODO can't be in a paragraph
                try self.eat_token();
                const next_token_kind = self.peek_token().token_kind;
                if (next_token_kind == TokenKind.Period or
                        next_token_kind == TokenKind.Close_paren) {
                    try self.eat_token();

                    if (!self.require_token(TokenKind.Space, "Expected ' ' after list item starter!\n"))
                    {
                        return ParseError.SyntaxError;
                    }

                    var list_node = try Node.create(&self.node_arena.allocator);
                    list_node.data = .OrderedList;
                    self.current_document.append_child(list_node);

                    // TODO parse_list_item; move this into it v
                    // limit doesn't make sense, since number isn't used for numbering the
                    // ordered list; even though this should belong into the list item parse fn
                    // if (current_token.len() > 9) {
                    //     std.debug.print(
                    //         "CommonMark ordered list items only allow 9 digits!", .{});
                    //     return ParseError.ExceededOrderedListDigits;
                    // }
                    // const item_text = try self.require_token(TokenKind.Text
                    // var list_item = try Node.create(&self.node_arena.allocator);
                    // list_item.data = .OrderedListItem;
                    // list_node.append_child(list_item);
                } else {
                    // TODO parse_paragraph
                }
            },

            // TokenKind.Close_angle_bracket => {
            //     // maybe block quote
            //     // 0-3 spaces + '>' with an optional following ' '
            // },

            else => {
                std.debug.print("Else branch ln {}\n", .{ self.peek_token().line_nr });
                try self.eat_token();

                var token_kind = self.peek_token().token_kind;
                while (token_kind != TokenKind.Newline and token_kind != TokenKind.Eof) {
                    std.debug.print("Ate token {} ln {}\n", .{ token_kind, self.peek_token().line_nr });
                    try self.eat_token();
                    token_kind = self.peek_token().token_kind;
                }
                // will end on newline token -> need to advance one more
                try self.eat_token();
            },
        }
    }
};

const NodeKind = enum {
    // special
    Undefined,
    Document,
    Import,

    // block
    // leaf blocks
    ThematicBreak,

    Heading,

    IndentedCode,
    FencedCode,

    HtmlBlock,

    LinkRef,

    Paragraph,
    BlankLine, // ?

    // container blocks
    BlockQuote,

    BulletList,
    BulletListItem,

    OrderedList,
    OrderedListItem,
    
    // ?
    Table,
    TableRow,

    // inline
    Text,
    Link,
    Image,  // inline apparently
};

const Node = struct {
    parent: ?*Node,

    next: ?*Node,
    first_child: ?*Node,
    last_child: ?*Node,

    // since a tagged union coerces to their tag type we don't need a
    // separate kind field
    data: NodeData,

    // tagged union
    const NodeData = union(NodeKind) {
        // special
        Undefined,
        Document,
        Import,

        // block
        // leaf blocks
        ThematicBreak,

        Heading: struct { level: i16, setext_heading: bool, text: []const u8 },

        IndentedCode,
        FencedCode,

        HtmlBlock,

        LinkRef,

        Paragraph,
        BlankLine, // ?

        // container blocks
        BlockQuote,

        BulletList,
        BulletListItem,

        OrderedList,
        OrderedListItem,
        
        // ?
        Table,
        TableRow,

        // inline
        Text,
        Link,
        Image,  // inline apparently
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
};
