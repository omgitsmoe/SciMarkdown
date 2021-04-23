const std = @import("std");
const utils = @import("utils.zig");
const is_space_or_tab = utils.is_space_or_tab;
const is_num = utils.is_num;
const is_end_of_line = utils. is_end_of_line;

pub const TAB_TO_SPACES = 4;
pub const SPACES_PER_INDENT = 4;

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
    Comma,
    Colon,
    Colon_open_bracket,
    Equals,
    Bar,
    Caret,
    // TODO rename tokens to their function if they only have one single functionality?
    Dollar,
    Dollar_double,

    Exclamation_open_bracket,  // ![

    Open_paren,
    Close_paren,
    Open_bracket,
    Close_bracket,
    Close_bracket_colon, // ]:
    // open_brace,
    // close_brace,
    Open_angle_bracket,
    Close_angle_bracket,

    Double_quote,
    Double_quote_triple,
    Single_quote,
    Backtick,
    Backtick_double,
    Backtick_triple,

    Backslash,

    Space,
    Tab,
    Newline,
    Increase_indent,
    Decrease_indent,
    Hard_line_break,  // \ in front of a line break

    Comment,  // //

    Digits,

    Text,

    Builtin_call,

    Eof,

    pub inline fn name(self: TokenKind) []const u8 {
        return switch (self) {
            .Invalid => "(invalid)",

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
            .Comma => ",",
            .Colon => ":",
            .Colon_open_bracket => ":[",
            .Bar => "|",
            .Equals => "=",
            .Caret => "^",
            .Dollar => "$",
            .Dollar_double => "$$",

            .Exclamation_open_bracket => "![",  // ![

            .Open_paren => "(",
            .Close_paren => ")",
            .Open_bracket => "[",
            .Close_bracket => "]",
            .Close_bracket_colon => "]:",
            // open_brace,
            // close_brace,
            .Open_angle_bracket => "<",
            .Close_angle_bracket => ">",

            .Double_quote => "\"",
            .Double_quote_triple => "\"\"\"",
            .Single_quote => "'",
            .Backtick => "`",
            .Backtick_triple => "``",
            .Backtick_double => "```",

            .Backslash => "\\",

            .Space => " ",
            .Tab => "\\t",
            .Newline => "\\n",

            .Increase_indent => "(increase_indent)",
            .Decrease_indent => "(decrease_indent)",
            .Hard_line_break => "(hard_line_break)",
            .Comment => "(comment)",
            .Digits => "(digits)",
            .Text => "(text)",

            .Builtin_call => "(@keyword)",

            .Eof => "(EOF)",
        };
    }

    pub inline fn ends_line(self: TokenKind) bool {
        return switch (self) {
            .Eof, .Newline => true,
            else => false,
        };
    }
};

pub const Token = struct {
    token_kind: TokenKind,
    start: u32,
    // exclusive end offset so we can use start..end when slicing
    end: u32,
    column: u16,
    line_nr: u32,

    pub inline fn len(self: *const Token) u32 {
        return self.end - self.start;
    }

    /// get string content from token
    /// bytes: md file text content
    pub inline fn text(self: *Token, bytes: []const u8) []const u8 {
        // make sure we don't call this on sth. that is not 'printable'
        std.debug.assert(switch (self.token_kind) {
            .Decrease_indent, .Eof => false,
            else => true });

        return switch (self.token_kind) {
            .Tab => " " ** TAB_TO_SPACES,
            .Increase_indent => " " ** SPACES_PER_INDENT,
            .Newline => "\n",
            .Text, .Digits, .Comment => bytes[self.start..self.end],
            else => return self.token_kind.name(),
        };
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
    indent_idx: u8,
    new_indent_idx: u8,
    indent_stack: [50]i16,

    pub const Error = error {
        UnmachtingDedent,
        BlankLineContainsWhiteSpace,
        SuddenEndOfFile,
    };

    pub fn init(allocator: *std.mem.Allocator, filename: []const u8) !Tokenizer {
        // TODO skip BOM if present
        const file = try std.fs.cwd().openFile(filename, .{ .read = true });
        defer file.close();

        // there's also file.readAll that requires a pre-allocated buffer
        // TODO dynamically sized buffer
        // TODO just pass buffer and filename, loading of the file should be done elsewhere
        const contents = try file.reader().readAllAlloc(
            allocator,
            20 * 1024 * 1024,  // max_size 2MiB, returns error.StreamTooLong if file is larger
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
            .indent_idx = 0,
            .new_indent_idx = 0,
            .indent_stack = undefined,
        };
        tokenizer.indent_stack[0] = 0;

        return tokenizer;
    }

    pub fn deinit(self: *Tokenizer) void {
        self.allocator.free(self.bytes);
    }

    inline fn advance_to_next_byte(self: *Tokenizer) void {
        if (self.index + 1 < self.bytes.len) {
            self.index += 1;
            self.current_byte = self.bytes[self.index];
        } else {
            // advance index beyond bytes length here as well?
            self.current_byte = null;
        }
    }

    /// caller has to make sure advancing the index doesn't go beyond bytes' length
    inline fn prechecked_advance_to_next_byte(self: *Tokenizer) void {
        self.index += 1;
        self.current_byte = self.bytes[self.index];
    }

    inline fn peek_next_byte(self: *Tokenizer) ?u8 {
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

    inline fn report_error(comptime err_msg: []const u8, args: anytype) void {
        std.log.err(err_msg, args);
    }

    pub fn get_token(self: *Tokenizer) Error!Token {
        var tok = Token{
            .token_kind = TokenKind.Invalid,
            .start = self.index,
            .end = self.index + 1,
            .column = @intCast(u16, self.index - self.last_line_end_idx),
            .line_nr = self.line_count, 
        };

        // we already advanced to the first non-whitespace byte but we still
        // need to emit indentation change tokens
        if (self.indent_idx < self.new_indent_idx) {
            tok.token_kind = TokenKind.Increase_indent;
            const ind_delta = self.indent_stack[self.indent_idx + 1] - self.indent_stack[self.indent_idx];
            self.indent_idx += 1;
            tok.column = @intCast(u16, self.indent_stack[self.indent_idx]);
            tok.start = self.last_line_end_idx + tok.column;
            tok.end = tok.start + @intCast(u16, ind_delta);
            return tok;
        } else if (self.indent_idx > self.new_indent_idx) {
            tok.token_kind = TokenKind.Decrease_indent;
            const ind_delta = self.indent_stack[self.indent_idx - 1] - self.indent_stack[self.indent_idx];
            self.indent_idx -= 1;
            tok.column = @intCast(u16, self.indent_stack[self.indent_idx]);
            tok.start = self.last_line_end_idx + tok.column;
            // -% -> wrapping subtraction
            tok.end = @intCast(u32, @intCast(i64, tok.start) - ind_delta);
            return tok;
        }

        if (self.current_byte) |char| {
            if (char == '\r') {
                if (self.peek_next_byte() != @as(u8, '\n')) {
                    // MacOS classic uses just \r as line break
                    // -> replace \r with \n
                    self.current_byte = @as(u8, '\n');
                    return self.get_token();
                } else {
                    // ignore \r on DOS (\r\n line break)
                    self.advance_to_next_byte();
                    return self.get_token();
                }
            }

            tok.token_kind = switch (char) {
                '\n' => blk: {
                    // since line/col info is only needed on error we only store the
                    // line number and compute the col on demand
                    self.line_count += 1;
                    self.last_line_end_idx = self.index;

                    var indent_spaces: i16 = 0;
                    while (self.peek_next_byte()) |next_byte| : (self.prechecked_advance_to_next_byte()) {
                        switch (next_byte) {
                            ' ' => indent_spaces += 1,
                            '\t' => indent_spaces += TAB_TO_SPACES,
                            else => break,
                        }
                    }

                    // only change indent_status if it's not a blank line
                    // NOTE: got rid of this since a blank line between blockquotes would
                    // swallow the +Indent -Indent
                    // make blank lines containing whitespace an error instead
                    // (similar to e.g. PEP8 W293 in python, but more extreme)
                    // TODO is this too obnoxious?
                    if (self.peek_next_byte()) |next_byte| {  // need this due to compiler bug involving optionals
                        if (indent_spaces > 0 and
                                (next_byte == @as(u8, '\n') or next_byte == @as(u8, '\r'))) {
                            Tokenizer.report_error(
                                "ln:{}: Blank line contains whitespace!\n",
                                .{ self.line_count });  // not tok.line_nr since its the next line
                            return Error.BlankLineContainsWhiteSpace;

                        }
                    }
                    
                    // dont emit any token for change in indentation level here since we first
                    // need the newline token
                    // check if amount of spaces changed changed
                    // TODO keep this v?
                    // (beyond a threshold of >1 space only when INCREASING indent)
                    const indent_delta: i16 = indent_spaces - self.indent_stack[self.indent_idx];
                    if (indent_delta > 1) {
                        self.new_indent_idx = self.indent_idx + 1;
                        self.indent_stack[self.new_indent_idx] = indent_spaces;
                    } else if (indent_delta < 0) {
                        var new_indent_idx = self.indent_idx;
                        while (self.indent_stack[new_indent_idx] != indent_spaces) : (
                            new_indent_idx -= 1) {
                            if (new_indent_idx == 0) {
                                Tokenizer.report_error(
                                    "ln:{}: No indentation level matches the last indent!\n",
                                    .{ self.line_count });  // not tok.line_nr since its the next line
                                return Error.UnmachtingDedent;
                            }
                        }
                        self.new_indent_idx = new_indent_idx;
                    }

                    break :blk TokenKind.Newline;
                },

                ' ' => .Space,

                '0'...'9' => blk: {
                    while (self.peek_next_byte()) |next_byte| : (self.prechecked_advance_to_next_byte()) {
                        if (!is_num(next_byte)) {
                            break;
                        }
                    }

                    break :blk .Digits;
                },

                '#' => .Hash,
                '*' => blk: {
                    if (self.peek_next_byte() == @intCast(u8, '*')) {
                        self.prechecked_advance_to_next_byte();
                        break :blk TokenKind.Asterisk_double;
                    } else {
                        break :blk TokenKind.Asterisk;
                    }
                },
                '_' => blk: {
                    if (self.peek_next_byte() == @intCast(u8, '_')) {
                        self.prechecked_advance_to_next_byte();
                        break :blk TokenKind.Underscore_double;
                    } else {
                        break :blk TokenKind.Underscore;
                    }
                },
                '~' => blk: {
                    if (self.peek_next_byte() == @intCast(u8, '~')) {
                        self.prechecked_advance_to_next_byte();
                        break :blk TokenKind.Tilde_double;
                    } else {
                        break :blk TokenKind.Tilde;
                    }
                },
                '-' => .Dash,
                '+' => .Plus,

                '.' => .Period,
                ',' => .Comma,
                ':' => blk: {
                    if (self.peek_next_byte() == @intCast(u8, '[')) {
                        self.prechecked_advance_to_next_byte();
                        break :blk TokenKind.Colon_open_bracket;
                    } else {
                        break :blk TokenKind.Colon;
                    }
                },
                '|' => .Bar,
                '^' => .Caret,
                '=' => .Equals,
                '$' => blk: {
                    if (self.peek_next_byte() == @as(u8, '$')) {
                        self.prechecked_advance_to_next_byte();
                        break :blk TokenKind.Dollar_double;
                    } else {
                        break :blk TokenKind.Dollar;
                    }
                },
                '!' => blk: {
                    if (self.peek_next_byte() == @as(u8, '[')) {
                        self.prechecked_advance_to_next_byte();
                        break :blk TokenKind.Exclamation_open_bracket;
                    } else {
                        break :blk TokenKind.Text;
                    }
                },

                '(' => .Open_paren,
                ')' => .Close_paren,
                '[' => .Open_bracket,
                ']' => blk: {
                    if (self.peek_next_byte() == @intCast(u8, ':')) {
                        self.prechecked_advance_to_next_byte();
                        break :blk TokenKind.Close_bracket_colon;
                    } else {
                        break :blk TokenKind.Close_bracket;
                    }
                },
                '<' => .Open_angle_bracket,
                '>' => .Close_angle_bracket,

                '"' => blk: {
                    if (self.peek_next_byte() == @as(u8, '"')) {
                        self.prechecked_advance_to_next_byte();
                        if (self.peek_next_byte() == @as(u8, '"')) {
                            self.prechecked_advance_to_next_byte();
                            break :blk TokenKind.Double_quote_triple;
                        } else {
                            break :blk TokenKind.Text;
                        }
                    } else {
                        break :blk TokenKind.Double_quote;
                    }
                },
                '\'' => .Single_quote,
                '`' => blk: {
                    if (self.peek_next_byte() == @intCast(u8, '`')) {
                        self.prechecked_advance_to_next_byte();
                        if (self.peek_next_byte() == @intCast(u8, '`')) {
                            self.prechecked_advance_to_next_byte();
                            break :blk TokenKind.Backtick_triple;
                        } else {
                            break :blk TokenKind.Backtick_double;
                        }
                    } else {
                        break :blk TokenKind.Backtick;
                    }
                },

                '%' => blk: {
                    // type of '%' is apparently comptime_int so we need to cast it to u8 to
                    // be able to compare it
                    if (self.peek_next_byte() == @intCast(u8, '%')) {
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
                        break :blk TokenKind.Text;
                    }

                },

                '\\' => blk: {
                    // \ escapes following byte
                    // currently only emits one single Text token for a single byte only

                    // below triggers zig compiler bug: https://github.com/ziglang/zig/issues/6059
                    // if (self.current_byte == @intCast(u8, '\r') or
                    //         self.current_byte == @intCast(u8, '\n')) {
                    // make sure we don't consume the line break so we still hit the
                    // correct switch prong next call

                    // backslash followed by \n (or \r but that is handled before the switch)
                    // is a hard line break
                    // NOTE: make sure we don't actually consume the \n
                    if (self.peek_next_byte()) |next_byte| {
                        if (next_byte == @as(u8, '\n') or next_byte == @as(u8, '\r')) {
                            break :blk TokenKind.Hard_line_break;
                        }
                    }

                    self.advance_to_next_byte();
                    tok.start = self.index;
                    break :blk TokenKind.Text;

                },

                '@' => blk: {
                    if (self.peek_next_byte()) |next_byte| {
                        self.prechecked_advance_to_next_byte();
                        if (!utils.is_lowercase(next_byte)) {
                            break :blk TokenKind.Text;
                        }
                    } else {
                        break :blk TokenKind.Text;
                    }
                    // haven't hit eof but we're still on '@'
                    self.prechecked_advance_to_next_byte();

                    while (self.peek_next_byte()) |next_byte| : (self.prechecked_advance_to_next_byte()) {
                        switch (next_byte) {
                            'a'...'z', 'A'...'Z', '0'...'9', '_' => continue,
                            else => break,
                        }
                    } else {
                        // else -> break not hit
                        Tokenizer.report_error(
                            "ln:{}: Hit unexpected EOF while parsing builtin keyword (@keyword(...))\n",
                            .{ self.line_count });
                        return Error.SuddenEndOfFile;
                    }

                    break :blk TokenKind.Builtin_call;
                },

                // assuming text (no keywords currently)
                else => blk: {
                    // consume everything that's not an inline style
                    while (self.peek_next_byte()) |next_byte| : (self.prechecked_advance_to_next_byte()) {
                        switch (next_byte) {
                            ' ', '\t', '\r', '\n', '_', '*', '/', '\\', '`', '.',
                            '<', '[', ']', ')', '"', '~', '^', '$', '=' , ',', '@' => break,
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
