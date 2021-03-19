const std = @import("std");

pub const TAB_TO_SPACES = 2;
pub const SPACES_PER_INDENT = 2;

pub const TokenKind = enum {
    Invalid,

    Hash,
    Asterisk,
    Underscore,
    Asterisk_double,
    Underscore_double,
    Tilde,
    Tilde_double,  // ~~
    Dash,
    Plus,
    Period,
    Colon,
    Bar,

    Exclamation_open_bracket,  // ![

    Open_paren,
    Close_paren,
    Open_bracket,
    Close_bracket,
    // open_brace,
    // close_brace,
    Open_angle_bracket,
    Close_angle_bracket,

    Double_quote,
    Single_quote,
    Backtick,
    Backtick_triple,

    Slash,
    Backslash,

    Space,
    Tab,
    Newline,
    Increase_indent,
    Decrease_indent,

    Comment,  // //

    Digits,

    Eof,

    Text,

    pub inline fn str(self: TokenKind) []const u8 {
        return switch (self) {
            .Hash => "#",
            .Asterisk => "*",
            .Underscore => "_",
            .Asterisk_double => "**",
            .Underscore_double => "__",
            .Tilde => "~",
            .Tilde_double => "~~",  // ~~
            .Dash => "-",
            .Plus => "+",
            .Period => ".",
            .Colon => ":",
            .Bar => "|",

            .Exclamation_open_bracket => "![",  // ![

            .Open_paren => "(",
            .Close_paren => ")",
            .Open_bracket => "[",
            .Close_bracket => "]",
            // open_brace,
            // close_brace,
            .Open_angle_bracket => "<",
            .Close_angle_bracket => ">",

            .Double_quote => "\"",
            .Single_quote => "'",
            .Backtick => "`",
            .Backtick_triple => "```",

            .Slash => "/",
            .Backslash => "\\",

            .Space => " ",
            .Newline => "\n",
            // TODO error here?
            else => "",
        };
    }
};

pub const Token = struct {
    token_kind: TokenKind,
    start: u32,
    // exclusive end offset so we can use start..end when slicing
    end: u32,
    line_nr: u32,

    pub inline fn len(self: *const Token) u32 {
        return self.end - self.start;
    }
};

pub const Tokenizer = struct {
    allocator: *std.mem.Allocator,
    // can't have const filename inside struct unless declaring new global type
    // after looking at zig stdlib that statement might not be true?
    filename: []const u8,
    bytes: []const u8,
    // we don't really need usize just use u32; supporting >4GiB md files would be bananas
    index: u32,
    // commented out since id have to set this when using peek_next_byte too
    // NOTE: zig needs 1 extra bit for optional non-pointer values to check if
    // it has a payload/is non-null
    current_byte: ?u8,

    line_count: u32,
    last_line_end_idx: u32,
    indent_lvl: u8,
    new_indent_lvl: u8,

    pub fn init(allocator: *std.mem.Allocator, filename: []const u8) !Tokenizer {
        // TODO skip BOM if present
        const file = try std.fs.cwd().openFile(filename, .{ .read = true });
        defer file.close();

        // there's also file.readAll that requires a pre-allocated buffer
        const contents = try file.reader().readAllAlloc(
            allocator,
            2 * 1024 * 1024,  // max_size 2MiB, returns error.StreamTooLong if file is larger
        );

        // need to initialize explicitly or leave it undefined
        // no zero init since it doesn't adhere to the language's principles
        // due to zero initialization "not being meaningful"
        // (but there is std.meta.zeroes)
        var tokenizer = Tokenizer{
            .allocator = allocator,
            .filename = filename,
            .bytes = contents,
            .index = 0,
            .current_byte = contents[0],
            .line_count = 1,
            .last_line_end_idx = 0,
            .indent_lvl = 0,
            .new_indent_lvl = 0,
        };

        return tokenizer;
    }

    pub fn deinit(self: *Tokenizer) void {
        self.allocator.free(self.bytes);
    }

    fn advance_to_next_byte(self: *Tokenizer) void {
        if (self.index + 1 < self.bytes.len) {
            self.index += 1;
            self.current_byte = self.bytes[self.index];
        } else {
            // advance index beyond bytes length here as well?
            self.current_byte = null;
        }
    }

    /// caller has to make sure advancing the index doesn't go beyond bytes' length
    fn prechecked_advance_to_next_byte(self: *Tokenizer) void {
        self.index += 1;
        self.current_byte = self.bytes[self.index];
    }

    fn peek_next_byte(self: *Tokenizer) ?u8 {
        if (self.index + 1 < self.bytes.len) {
            return self.bytes[self.index + 1];
        } else {
            return null;
        }
    }

    fn eat_spaces_or_tabs(self: *Tokenizer) void {
        while (self.peek_next_byte()) |char| : (self.index += 1) {
            if (!is_space_or_tab(char)) {
                // self.index will point to last space/tab char so self.next_byte
                // returns the first non-whitespace byte or newline
                break;
            }
        }
    }

    pub fn get_token(self: *Tokenizer) Token {
        var tok = Token{
            .token_kind = TokenKind.Invalid,
            .start = self.index,
            .end = self.index + 1,
            .line_nr = self.line_count, 
        };

        // we already advanced to the first non-whitespace byte but we still
        // need to emit indentation change tokens
        if (self.indent_lvl < self.new_indent_lvl) {
            self.indent_lvl += 1;
            tok.token_kind = TokenKind.Increase_indent;
            return tok;
        } else if (self.indent_lvl > self.new_indent_lvl) {
            self.indent_lvl -= 1;
            tok.token_kind = TokenKind.Decrease_indent;
            return tok;
        }

        if (self.current_byte) |char| {
            // ignore \r
            if (char == '\r') {
                self.advance_to_next_byte();
                return self.get_token();
            }

            tok.token_kind = switch (char) {
                '\n' => blk: {
                    // since line/col info is only needed on error we only store the
                    // line number and compute the col on demand
                    // TODO delete last_line_end_idx
                    self.last_line_end_idx = self.index;
                    self.line_count += 1;

                    var indent_spaces: i32 = 0;
                    while (self.peek_next_byte()) |next_byte| : (self.index += 1) {
                        switch (next_byte) {
                            ' ' => indent_spaces += 1,
                            '\t' => indent_spaces += TAB_TO_SPACES,
                            else => break,
                        }
                    }

                    // dont emit any token for change in indentation level here since we first
                    // need the newline token
                    const new_indent_lvl: u8 = @intCast(u8, @divTrunc(indent_spaces, SPACES_PER_INDENT)); 
                    if (new_indent_lvl > self.indent_lvl) {
                        self.new_indent_lvl = new_indent_lvl;
                    } else if (new_indent_lvl < self.indent_lvl) {
                        self.new_indent_lvl = new_indent_lvl;
                    }

                    break :blk TokenKind.Newline;
                },

                ' ' => .Space,

                '0'...'9' => blk: {
                    while (self.peek_next_byte()) |next_byte| : (self.index += 1) {
                        if (!is_num(next_byte)) {
                            break;
                        }
                    }

                    break :blk .Digits;
                },

                '#' => .Hash,
                '*' => .Asterisk,
                '_' => .Underscore,
                '~' => .Tilde,
                '-' => .Dash,
                '+' => .Plus,

                '.' => .Period,
                ':' => .Colon,
                '|' => .Bar,

                '(' => .Open_paren,
                ')' => .Close_paren,
                '[' => .Open_bracket,
                ']' => .Close_bracket,
                '<' => .Open_angle_bracket,
                '>' => .Close_angle_bracket,

                '"' => .Double_quote,
                '\'' => .Single_quote,
                '`' => blk: {
                    if (self.peek_next_byte() == @intCast(u8, '`')) {
                        self.prechecked_advance_to_next_byte();
                        self.advance_to_next_byte();
                        if (self.current_byte == @intCast(u8, '`')) {
                            break :blk TokenKind.Backtick_triple;
                        } else {
                            // TODO backtrack here or what other solutions are there?
                            // currently just emitting a short .Text token for just the
                            // two backticks atm
                            break :blk TokenKind.Text;
                        }
                    } else {
                        break :blk TokenKind.Backtick;
                    }
                },

                '/' => blk: {
                    // type of '/' is apparently comptime_int so we need to cast it to the optional's
                    // child value so we can compar them
                    if (self.peek_next_byte() == @intCast(u8, '/')) {
                        self.prechecked_advance_to_next_byte();

                        // commented out till end of line
                        while (self.peek_next_byte()) |commented_byte| : (self.index += 1) {
                            if (is_end_of_line(commented_byte)) {
                                break;
                            }
                        }

                        // need to use the enum name here otherwise type inference breaks somehow
                        break :blk TokenKind.Comment;
                    } else {
                        break :blk TokenKind.Slash;
                    }
                },
                '\\' => blk: {
                    // \ escapes following byte
                    // currently only emits one single Text token for a single byte only
                    self.advance_to_next_byte();
                    tok.start = self.index;
                    break :blk .Text;
                },

                // assuming text (no keywords currently)
                else => blk: {
                    // consume everything that's not an inline style
                    while (self.peek_next_byte()) |next_byte| : (self.index += 1) {
                        switch (next_byte) {
                            '\r', '\n', '_', '*', '/', '\\', '`', '<', '[' => break,
                            else => {},
                        }
                    }

                    break :blk .Text;
                },
            };

            tok.end = self.index + 1;
        } else {
            tok.token_kind = .Eof;
        }

        self.advance_to_next_byte();
        return tok;
    }
};

pub inline fn is_alpha(char: u8) bool {
    if ((char >= 'A' and char <= 'Z') or
        (char >= 'a' and char <= 'z')) {
        return true;
    } else {
        return false;
    }
}

pub inline fn is_num(char: u8) bool {
    if (char >= '0' and char <= '9') {
        return true;
    } else {
        return false;
    }
}

pub inline fn is_alphanum(char: u8) bool {
    if (is_alpha(char) or is_num(char)) {
        return true;
    } else {
        return false;
    }
}

pub inline fn is_end_of_line(char: u8) bool {
    if ((char == '\r') or (char == '\n')) {
        return true;
    } else {
        return false;
    }
}

pub inline fn is_space_or_tab(char: u8) bool {
    if ((char == ' ') or (char == '\t')) {
        return true;
    } else {
        return false;
    }
}

pub inline fn is_whitespace(char: u8) bool {
    if (is_space_or_tab(char) or is_end_of_line(char)) {
        return true;
    } else {
        return false;
    }
}
