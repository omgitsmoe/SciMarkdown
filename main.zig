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

    var parser: Parser = try Parser.init(allocator, "test.md");
    try parser.parse();
}

const Parser = struct {
    allocator: *std.mem.Allocator,
    node_arena: std.heap.ArenaAllocator,

    tokenizer: Tokenizer,
    token_buf: std.ArrayList(Token),
    current_token: Token,

    current_document: *Node,
    last_node: *Node,
    tk_index: usize,
    indent: i32,

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
            .current_token = Token{
                .token_kind = TokenKind.Invalid,
                .text = ""[0..],
                .pos = .{
                    .line = 0,
                    .col = 0,
                },
            },

            .current_document = undefined,
            .last_node = undefined, 
            .tk_index = 0,
            .indent = 0,
        };

        var current_document = try parser.node_arena.allocator.create(Node);
        current_document.* = .{
            .parent = null,
            .next = null,
            .first_child = null,
            .last_child = null,
            .data = .Document,
        };
        parser.last_node = parser.current_document;

        return parser;
    }

    pub fn deinit(self: *Parser) void {
        self.node_arena.deinit();
        self.tokenizer.deinit();
        self.token_buf.deinit();
    }

    pub fn parse(self: *Parser) !void {
        while (self.current_token.token_kind != TokenKind.Eof) {
            try self.parse_block();
        }
    }

    fn get_token(self: *Parser) !Token {
        const current_token = self.tokenizer.get_token();
        self.current_token = current_token;
        // std.debug.print("{}\n", .{ current_token });
        try self.token_buf.append(current_token);
        return current_token;
    }

    fn require_token(self: *Parser, token_kind: TokenKind, err_msg: []const u8) !bool {
        if (try self.get_token().token_kind != token_kind) {
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
        const num_spaces = self.advance_to_first_nonspace();
        const indent_delta = self.indent - @intCast(i32, num_spaces);

        if (indent_delta >= 4) {
            // code block
        } else {
            switch (self.current_token.token_kind) {
                TokenKind.Hash => {
                    // atx heading
                    // 1-6 unescaped # followed by ' ' or end-of-line
                    // optional closing # that don't have to match the number of opening #
                    var heading_lvl: i16 = 1;
                    while (((try self.get_token()).token_kind) == TokenKind.Hash) {
                        heading_lvl += 1;
                    }

                    if (heading_lvl > 6 or
                        (self.current_token.token_kind != TokenKind.Space and
                         self.current_token.token_kind != TokenKind.Newline)) {
                        // self.parse_paragraph()
                    } else {
                        // TODO close_open_block
                        var new_node: *Node = try self.node_arena.allocator.create(Node);
                        new_node.data = .{
                            .Heading = .{ .level = heading_lvl, .setext_heading = false },
                        };
                        self.last_node.append_child(new_node);
                    }
                },

                TokenKind.Asterisk, TokenKind.Dash, TokenKind.Plus, TokenKind.Underscore => {
                    // maybe thematic break: the same 3 or more *, - or _ followed by optional spaces
                    // bullet list/list item
                },

                TokenKind.Digits => {
                    // maybe ordered list
                    // 1-9 digits (0-9) ending in a '.' or ')'
                    const next_token = try self.get_token();
                    if (next_token.token_kind == TokenKind.Period or
                            next_token.token_kind == TokenKind.Close_paren) {
                        if (self.current_token.text.len > 9) {
                            std.debug.print(
                                "CommonMark ordered list items only allow 9 digits!", .{});
                            return ParseError.ExceededOrderedListDigits;
                        }
                    }
                },

                TokenKind.Close_angle_bracket => {
                    // maybe block quote
                    // 0-3 spaces + '>' with an optional following ' '
                },

                else => {
                },
            }
        }
    }
};

const NodeKind = enum {
    // special
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
        Document,
        Import,

        // block
        // leaf blocks
        ThematicBreak,

        Heading: struct { level: i16, setext_heading: bool },

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

    pub fn append_child(self: *Node, child: *Node) void {
        std.debug.assert(child.parent == null);

        if (self.first_child) {
            self.last_child.next = child;
            self.last_child = child;
        } else {
            self.first_child = child;
            self.last_child = child;
        }

        child.parent = self;
    }
};
