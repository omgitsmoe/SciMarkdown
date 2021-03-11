const std = @import("std");

const TAB_TO_SPACES = 4;

pub const TokenKind = enum {
    Invalid,

    Hash,
    Asterisk,
    Underscore,
    Tilde,
    Dash,
    Plus,
    Period,
    Colon,
    Bar,

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

    // slash,
    Backslash,

    Space,
    Tab,
    Newline,

    Digits,

    Eof,

    Text,
};

// TODO check that these match the enumb above at comptime
// Like ComptimeStringbut optimized for small sets of disparate string keys
// pub const TokenStrings = std.ComptimeStringMap(TokenKind, .{
//     .{ "#", .hash },
//     .{ "*", .asterisk },
//     .{ "_", .underscore },
//     .{ "~", .tilde },
//     .{ "-", .dash },
//     .{ "\n", .newline },
// });

pub const Token = struct {
    token_kind: TokenKind,
    text: []const u8,

    pos: TokenPos,
    const TokenPos = struct {
        line: u32,
        // currently in bytes, multi-byte code points not handled
        col:  u32,
    };
};

pub const Tokenizer = struct {
    allocator: *std.mem.Allocator,
    // can't have const filename inside struct unless declaring new global type
    // after looking at zig stdlib that statement might not be true?
    filename: []const u8,
    bytes: []const u8,
    index: usize,
    // commented out since id have to set this when using peek_next_byte too
    current_byte: ?u8,

    line_count: usize,
    last_line_end_idx: usize,

    pub fn init(allocator: *std.mem.Allocator, filename: []const u8) !Tokenizer {
        const file = try std.fs.cwd().openFile(filename, .{ .read = true });
        defer file.close();

        // there's also file.readAll that requires a pre-allocated buffer
        const contents = try file.reader().readAllAlloc(
            allocator,
            2 * 1024 * 1024,  // max_size 2MiB, returns error.StreamTooLong if file is larger
        );

        // need to initialize explicitly or leave it undefined
        // no zero init since it doesn't adhere to the language's principles
        // due to zero initialization "not being meaningfull"
        // (but there is std.meta.zeroes)
        var tokenizer = Tokenizer{
            .allocator = allocator,
            .filename = filename,
            .bytes = contents,
            .index = 0,
            .current_byte = contents[0],
            .line_count = 1,
            .last_line_end_idx = 0,
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
        var token = Token{
            .token_kind = .Invalid,
            .text = undefined,
            .pos  = .{
                .line = @intCast(u32, self.line_count), 
                .col  =
                    @intCast(
                        u32,
                        self.index - self.last_line_end_idx + @boolToInt((self.last_line_end_idx == 0)))
            },
        };

        if (self.current_byte) |char| {
            // ignore \r
            if (char == '\r') {
                self.advance_to_next_byte();
                return self.get_token();
            }

            const token_start: usize = self.index;

            // switch on known tokens else assume text
            token.token_kind = get_token_kind(char);
            switch (token.token_kind) {
                .Newline => {
                    // since line/col info is only needed on error i could also compute
                    // these later by saving the index and counting the new lines
                    self.last_line_end_idx = self.index;
                    self.line_count += 1;
                    // empty string slice
                    token.text = ""[0..];
                },
                .Text => {
                    while (self.peek_next_byte()) |next_char| : (self.index += 1) {
                        if (get_token_kind(next_char) != .Text) {
                            // self.index points to last char belonging to text token
                            break;
                        }
                    }
                    token.text = self.bytes[token_start..self.index + 1];
                },
                .Digits => {
                    while (self.peek_next_byte()) |next_byte| : (self.index += 1) {
                        if (!is_num(next_byte)) {
                            break;
                        }
                    }
                    token.text = self.bytes[token_start..self.index + 1];
                },
                // since we switch on an enum we have to provid an else since the
                // switch is supposed to be exhaustive
                else => {
                    token.text = self.bytes[self.index..self.index + 1];
                },
            }
            // OLD
            // label block as blk so we can 'return' an expression from it
            // using break :label_name expression;
            // else => blk: {
            //     break :blk .text;
            // },
            self.advance_to_next_byte();
        } else {
            token.token_kind = .Eof;
            // empty string slice
            token.text = ""[0..];
        }

        return token;
    }
};

fn get_token_kind(char: u8) TokenKind {
    return switch (char) {
        '\n' => .Newline, 

        ' ' => .Space,

        '0'...'9' => .Digits,

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

        // '/' => .Slash,
        '\\' => .Backslash,

        // TODO extract this switch statement into a function and while we keep
        // getting .text (or .space) token kinds we keep on adding them to our token's
        // .text (only exception would be a .space after a newline)
        //
        // assuming text (no keywords currently)
        else => .Text,
    };
}

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
