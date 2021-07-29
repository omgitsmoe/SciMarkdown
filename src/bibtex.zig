// names all say bibtex but this is a biblatex parser
const std = @import("std");
const utils = @import("utils.zig");
const expect = std.testing.expect;
const log = std.log;

pub const BibParser = struct {
    bib: Bibliography,
    idx: u32,
    bytes: []const u8,
    allocator: *std.mem.Allocator,

    pub const Error = error {
        SyntaxError,
        OutOfMemory,
        EndOfFile,
        DuplicateLabel,
    };

    pub fn init(allocator: *std.mem.Allocator, path: []const u8, bytes: []const u8) BibParser {
        var parser = BibParser{
            .bib = Bibliography{
                .path = path,
                .label_entry_map = std.StringHashMap(Entry).init(allocator),
                .field_arena = std.heap.ArenaAllocator.init(allocator),
            },
            .idx = 0,
            .bytes = bytes,
            .allocator = allocator,
        };
        return parser;
    }

    inline fn report_error(comptime err_msg: []const u8, args: anytype) void {
        log.err(err_msg, args);
    }

    // zig stdlib's reader also returns EndOfStream err instead of returning null
    // prob since ?u8 is actually u9 (1 extra bit for maybe bool)
    // but !u8 returns a union with a value: u8 field and a tag field
    // which is 0 (none) if there is no error otherwise it's the error code e.g. EndOfFile(51)
    // so this would require even more space? (all irrelevant anyway since it will fit in a
    // register, but I just wanna know how it works)
    inline fn advance_to_next_byte(self: *BibParser) Error!void {
        if (self.idx + 1 < self.bytes.len) {
            self.idx += 1;
        } else {
            return Error.EndOfFile;
        }
    }

    inline fn peek_byte(self: *BibParser) u8 {
        // current position must be in bounds since we should've hit Error.EndOfFile otherwise
        return self.bytes[self.idx];
    }

    inline fn eat_until(self: *BibParser, end: u8) Error!void {
        while (self.peek_byte() != end) {
            self.advance_to_next_byte() catch {
                BibParser.report_error("Reached EOF while waiting for '{c}'!\n", .{ end });
                return Error.EndOfFile;
            };
        }
    }

    fn eat_name(self: *BibParser) Error!void {
        var byte = self.peek_byte();
        while (true) {
            switch (byte) {
                // this is what btparse defines as name, but are that many special chars allowed?
                // biber disallows " # ' ( ) , = { } %
                'a'...'z', 'A'...'Z', '0'...'9',
                '!', '$', '*', '+', '-', '.', '/', ':',
                ';', '<', '>', '?', '[', ']', '^', '_', '`', '|' => {},
                else => break,
            }
            self.advance_to_next_byte() catch {
                BibParser.report_error("Reached EOF while consuming name!\n", .{});
                return Error.EndOfFile;
            };
            byte = self.peek_byte();
        }
    }

    /// does not advance the idx
    inline fn require_byte(self: *BibParser, byte: u8) Error!void {
        if (self.peek_byte() != byte) {
            BibParser.report_error("Expected '{c}' got '{c}'!\n", .{ byte, self.peek_byte() });
            return Error.SyntaxError;
        }
    }

    inline fn eat_byte(self: *BibParser, byte: u8) Error!void {
        try self.require_byte(byte);
        try self.advance_to_next_byte();
    }

    fn next(self: *BibParser) ?u8 {
        if (self.idx + 1 < self.bytes.len) {
            self.idx += 1;
            var byte = self.bytes[self.idx];
            return byte;
        } else {
            return null;
        }
    }

    inline fn reached_eof(self: *BibParser) bool {
        if (self.idx >= self.bytes.len) {
            return true;
        } else {
            return false;
        }
    }

    /// caller owns memory of return Bibliography
    pub fn parse(self: *BibParser) Error!Bibliography {
        // clean up on error so we don't leak on unsuccessful parses
        errdefer {
            self.bib.deinit();
        }

        while (self.idx < self.bytes.len) {
            var byte = self.peek_byte();
            if (utils.is_whitespace(byte)) {
                self.idx += 1;
                continue;
            }
            switch (byte) {
                '@' => {
                    self.idx += 1;
                    try self.parse_entry();
                },
                '%' => {
                    // line-comment, used by jabref to state encoding
                    self.idx += 1;
                    self.skip_line();
                },
                else => {
                    BibParser.report_error(
                        "Unexpected byte '{c}' expected either '@' followed by a valid " ++
                        " entry type or '%' to start a line comment!\n", .{ byte });
                    return Error.SyntaxError;
                },
            }
        }

        return self.bib;
    }

    fn skip_line(self: *BibParser) void {
        var byte: u8 = undefined;
        while (self.idx < self.bytes.len) : (self.idx += 1) {
            byte = self.bytes[self.idx];
            if (byte == '\r') {
                // macos classic line ending is just \r
                self.idx += 1;
                if (self.idx < self.bytes.len and self.bytes[self.idx] == '\n') {
                    self.idx += 1;
                }
                break;
            } else if (byte == '\n') {
                // unix line-ending
                self.idx += 1;
                break;
            }
        }
    }

    fn skip_whitespace(self: *BibParser, comptime eof_is_error: bool) Error!void {
        while (utils.is_whitespace(self.peek_byte())) {
            self.advance_to_next_byte() catch {
                if (eof_is_error) {
                    BibParser.report_error("Hit EOF while skipping whitespace!\n", .{});
                    return Error.EndOfFile;
                } else {
                    return;
                }
            };
        }
    }

    fn parse_entry(self: *BibParser) Error!void {
        const entry_type_start = self.idx;
        while (self.peek_byte() != '{') {
            self.advance_to_next_byte() catch {
                BibParser.report_error("Reached EOF while parsing entry type name!\n", .{});
                return Error.SyntaxError;
            };
        }
        // convert to lower-case to match with enum tagNames
        const lowercased = try std.ascii.allocLowerString(
            self.allocator, self.bytes[entry_type_start..self.idx]);
        const entry_type = std.meta.stringToEnum(
            EntryType, lowercased) orelse {
                BibParser.report_error("'{s}' is not a valid entry type!\n",
                                       .{ self.bytes[entry_type_start..self.idx] });
                return Error.SyntaxError;
        };
        self.allocator.free(lowercased);

        if (entry_type == .comment) {
            // NOTE: not allowing {} inside comments atm
            try self.eat_until('}');
            // TODO @Improve
            self.advance_to_next_byte() catch {
                // advance_to_next_byte errors since we're at the last byte before EOF
                // but we know the current one is '{' so we advance it manually
                // so the main loop in parse can exit properly
                self.idx += 1;
                return;
            };
            return;
        }

        try self.advance_to_next_byte();
        const label_start = self.idx;
        // TODO allow unicode labels?
        try self.eat_name();
        try self.require_byte(',');
        const label = self.bytes[label_start..self.idx];

        // make sure we don't have a duplicate label!
        var entry_found = try self.bib.label_entry_map.getOrPut(label);
        // ^ result will be a struct with a pointer to the HashMap.Entry and a bool
        // whether an existing value was found
        if (entry_found.found_existing) {
            BibParser.report_error("Duplicate label '{s}'!\n", .{ label });
            return Error.DuplicateLabel;
        } else {
            // actually write entry value (key was already written by getOrPut)
            entry_found.value_ptr.* = Entry.init(&self.bib.field_arena.allocator, entry_type);
        }
        try self.advance_to_next_byte();

        var byte: u8 = undefined;
        while (!self.reached_eof()) {
            try self.skip_whitespace(true);
            byte = self.bytes[self.idx];
            if (byte == '}') {
                self.advance_to_next_byte() catch {
                    self.idx += 1;
                    return;
                };
                break;
            } else {
                // NOTE: label_entry_map can't be modified while the function below is
                // still running otherwise the entry ptr might? get invalidated
                try self.parse_entry_field(entry_found.value_ptr);
            }
        }
    }

    /// expects to start on first byte of field name
    fn parse_entry_field(self: *BibParser, entry: *Entry) Error!void {
        const field_name_start = self.idx;
        try self.eat_name();
        const field_name_end = self.idx;

        // convert to lower-case to match with enum tagNames
        const lowercased = try std.ascii.allocLowerString(
            self.allocator, self.bytes[field_name_start..field_name_end]);
        const field_name = std.meta.stringToEnum(FieldName, lowercased) orelse .custom;
        self.allocator.free(lowercased);

        try self.skip_whitespace(true);
        try self.eat_byte('=');
        try self.skip_whitespace(true);

        // TODO worth to handle field values that are not wrapped in {} and those
        // that are wrapped in "" and thus can be concatenated using '#'?
        self.eat_byte('{') catch {
            BibParser.report_error(
                "This implementation of a bibtex parser requires all field values to " ++
                "be wrapped in {{braces}}!\n", .{});
            return Error.SyntaxError;
        };

        // need to reform field value string since it might contain braces and other
        // escapes
        var field_value_str = std.ArrayList(u8).init(&self.bib.field_arena.allocator);

        var braces: u32 = 0;
        // TODO foreign/special char escapes e.g. \'{o} for ó etc.
        // currently just discards the braces
        // TODO process into name lists etc.
        // TODO {} protect from case-mangling etc.
        var byte = self.peek_byte();
        var added_until = self.idx;  // exclusive
        while (true) {
            switch (byte) {
                '{' => {
                    braces += 1;
                    try field_value_str.appendSlice(self.bytes[added_until..self.idx]);
                    added_until = self.idx + 1;  // +1 so we don't add the {
                },
                '}' => {
                    if (braces == 0) {
                        try field_value_str.appendSlice(self.bytes[added_until..self.idx]);
                        break;
                    } else {
                        braces -= 1;
                        try field_value_str.appendSlice(self.bytes[added_until..self.idx]);
                        added_until = self.idx + 1;  // +1 so we don't add the }
                    }
                },
                '\\' => {
                    try field_value_str.appendSlice(self.bytes[added_until..self.idx]);
                    try self.advance_to_next_byte();
                    byte = self.peek_byte();
                    try field_value_str.append(byte);
                    added_until = self.idx + 1;
                },
                else => {},
            }
            try self.advance_to_next_byte();
            byte = self.peek_byte();
        }
        try self.eat_byte('}');

        // , is technichally optional
        if (self.peek_byte() == ',') {
            try self.advance_to_next_byte();
        }
        
        // std.debug.print("Field -> {s}: {s}\n",
        //     .{ self.bytes[field_name_start..field_name_end], field_value_str.items });

        const field_type = field_name.get_field_type();
        // payload will be undefined after from_field_tag
        var field_value = FieldType.from_field_tag(field_type);
        switch (field_value) {
            .name_list, .literal_list, .key_list => |*value| {
                // NOTE: the split list still uses the memory of field_value_str
                // so we can't free it
                value.*.values = try BibParser.split_list(
                    &self.bib.field_arena.allocator, field_value_str.toOwnedSlice());
            },
            .literal_field, .range_field, .integer_field, .datepart_field, .date_field,
            .verbatim_field, .uri_field, .separated_value_field, .pattern_field,
            .key_field, .code_field, .special_field, => |*value| {
                value.*.value = field_value_str.toOwnedSlice();
            },
        }

        // not checking if field already present -> gets overwritten
        try entry.fields.put(
            self.bytes[field_name_start..field_name_end],
            Field{
                .name = field_name,
                .data = field_value,
            }
        );
    }

    inline fn split_list(allocator: *std.mem.Allocator, bytes: []const u8) Error![]const []const u8 {
        // NOTE: not checking keys of key lists
        // NOTE: leaving names of name lists as-is and parsing them on demand
        // with ListField.parse_name
        var split_items = std.ArrayList([]const u8).init(allocator);
        var split_iter = std.mem.split(bytes, " and ");
        while (split_iter.next()) |item| {
            try split_items.append(item);
        }

        return split_items.toOwnedSlice();
    }
};

test "split list" {
    const alloc = std.testing.allocator;
    var res = try BibParser.split_list(alloc, "A and B and C and others");
    var expected = [_][]const u8 { "A", "B", "C", "others" };
    for (res) |it, i| {
        try expect(std.mem.eql(u8, it, expected[i]));
    }
    // otherwise testing allocator complains about memory leak
    alloc.free(res);

    res = try BibParser.split_list(alloc, "Hand and von Band, Jr., Test and Stand de Ipsum and others");
    expected = [_][]const u8 { "Hand", "von Band, Jr., Test", "Stand de Ipsum", "others" };
    for (res) |it, i| {
        try expect(std.mem.eql(u8, it, expected[i]));
    }
    alloc.free(res);
}

test "bibparser" {
    const alloc = std.testing.allocator;
    const bibtxt =
        \\% Encoding: UTF-8
        \\@Article{Seidel2015,
        \\author    = {{Dominik} {Seidel} and {Nils Hoffmann} and Martin Ehbrecht and Julia Juchheim and Christian Ammer},
        \\title     = {{How} neighborhood affects tree diameter increment},
        \\journal   = {Forest Ecology and Management},
        \\year      = {2015},
        \\volume    = {336},
        \\pages     = {119--128},
        \\month     = {jan},
        \\doi       = {10.1016/j.foreco.2014.10.020},
        \\file      = {:../Lit/Seidel et al. 2015_as downloaded.pdf:PDF},
        \\publisher = {Elsevier {BV}},
        \\}
        \\@Comment{jabref-meta: databaseType:bibtex;}
    ;

    var bp = BibParser.init(alloc, "/home/test/path", bibtxt);
    var bib = try bp.parse();
    defer bib.deinit();

    try expect(std.mem.eql(u8, bib.path, "/home/test/path"));

    var entry = bib.label_entry_map.get("Seidel2015").?;
    try expect(entry._type == .article);

    const author = entry.fields.get("author").?;
    const author_expected = [_][]const u8 {
        "Dominik Seidel", "Nils Hoffmann", "Martin Ehbrecht", "Julia Juchheim", "Christian Ammer"
    };
    for (author.data.name_list.values) |it, i| {
        try expect(std.mem.eql(u8, it, author_expected[i]));
    }

    var field = entry.fields.get("title").?;
    try expect(std.mem.eql(
            u8, field.data.literal_field.value, "How neighborhood affects tree diameter increment"));

    field = entry.fields.get("journal").?;
    try expect(std.mem.eql(
            u8, field.data.literal_field.value, "Forest Ecology and Management"));

    field = entry.fields.get("year").?;
    try expect(std.mem.eql(
            u8, field.data.literal_field.value, "2015"));

    field = entry.fields.get("volume").?;
    try expect(std.mem.eql(
            u8, field.data.integer_field.value, "336"));

    field = entry.fields.get("pages").?;
    try expect(std.mem.eql(
            u8, field.data.range_field.value, "119--128"));

    field = entry.fields.get("month").?;
    try expect(std.mem.eql(
            u8, field.data.literal_field.value, "jan"));

    field = entry.fields.get("doi").?;
    try expect(std.mem.eql(
            u8, field.data.verbatim_field.value, "10.1016/j.foreco.2014.10.020"));

    field = entry.fields.get("publisher").?;
    try expect(field.data.literal_list.values.len == 1);
    try expect(std.mem.eql(u8, field.data.literal_list.values[0], "Elsevier BV"));
}

test "bibparser no leak on err" {
    const alloc = std.testing.allocator;
    const bibtxt =
        \\% Encoding: UTF-8
        \\@Article{Seidel2015,
    ;

    var bp = BibParser.init(alloc, "/home/test/path", bibtxt);
    var bib = bp.parse();
    try std.testing.expectError(BibParser.Error.EndOfFile, bib);
}

pub const FieldMap = std.StringHashMap(Field);
pub const Bibliography = struct {
    path: []const u8,
    label_entry_map: std.StringHashMap(Entry),
    field_arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Bibliography) void {
        self.label_entry_map.deinit();
        self.field_arena.deinit();
    }
};

// could use std.meta.TagPayloadType to get payload type from tag on a tagged union
pub const FieldTypeTT = std.meta.TagType(FieldType);
pub const FieldType = union(enum) {
    // lists
    // all lists can be shortened with 'and others'
    // in case of name_list it will then always print et al. in the bibliography
    name_list:    ListField,
    literal_list: ListField,
    key_list:     ListField,
    // fields
    literal_field:  SingleField,
    range_field:    SingleField,
    integer_field:  SingleField,
    datepart_field: SingleField,
    date_field:     SingleField,
    verbatim_field: SingleField,
    uri_field:      SingleField,
    separated_value_field: SingleField,
    pattern_field:  SingleField,
    key_field:      SingleField,
    code_field:     SingleField,
    special_field:  SingleField,

    /// returns union with correct tag activated based on it's tag type
    /// NOTE: the payload type will be undefined!
    pub fn from_field_tag(tag: FieldTypeTT) FieldType {
        return switch (tag) {
            .name_list =>       FieldType{ .name_list = undefined },
            .literal_list =>    FieldType{ .literal_list = undefined },
            .key_list =>        FieldType{ .key_list = undefined },
            .literal_field =>   FieldType{ .literal_field = undefined },
            .range_field =>     FieldType{ .range_field = undefined },
            .integer_field =>   FieldType{ .integer_field = undefined },
            .datepart_field =>  FieldType{ .datepart_field = undefined },
            .date_field =>      FieldType{ .date_field = undefined },
            .verbatim_field =>  FieldType{ .verbatim_field = undefined },
            .uri_field =>       FieldType{ .uri_field = undefined },
            .separated_value_field => FieldType{ .separated_value_field = undefined },
            .pattern_field =>   FieldType{ .pattern_field = undefined },
            .key_field =>       FieldType{ .key_field = undefined },
            .code_field =>      FieldType{ .code_field = undefined },
            .special_field =>   FieldType{ .special_field = undefined },
        };
    }
};
pub const ListField = struct {
    values: []const []const u8,

    pub const Name = struct {
        last: ?[]const u8 = null,
        first: ?[]const u8 = null,
        prefix: ?[]const u8 = null,
        suffix: ?[]const u8 = null,

        const unkown_format_err = "Name has unkown format{s}!\n" ++
                                  "Formats are:\n" ++
                                  "First von Last\n" ++
                                  "von Last, First\n" ++
                                  "von Last, Jr, First\n";
    };

    const NameState = enum {
        first,
        prefix,
        suffix,
        last,
    };

    /// doesn't recognize lowercase unicode codepoints which is need for identifying
    /// the prefix part of the Name
    pub fn parse_name(name: []const u8) BibParser.Error!Name {
        // 4 name components:
        // Family name (also known as 'last' part)
        // Given name (also known as 'first' part)
        // Name prefix (also known as 'von' part)
        // Name suffix (also known as 'Jr' part)
        // the name can be typed in one of 3 forms:
        // "First von Last"
        // "von Last, First"
        // "von Last, Jr, First"

        var commas: u8 = 0;
        for (name) |c| {
            if (c == ',') {
                commas += 1;
            }
        }
        switch (commas) {
            0 => return parse_name_simple(name),
            1, 2 => return parse_name_with_commas(name, commas),
            // technichally this should remove the extra commas >2
            else => return parse_name_with_commas(name, commas),
        }

        return result;
    }

    fn parse_name_simple(name: []const u8) BibParser.Error!Name {
        // words split by whitespace
        // up to first lowercase word is 'first'
        // all following lowercase words are 'prefix'
        // first uppercase word starts 'last'
        // no suffix part
        var result = Name{};
        var state = NameState.first;
        var i: u16 = 0;
        var last_end: u16 = 0; // exclusive
        var last_word_start: u16 = 0; // inclusive
        var prev_whitespace = false;
        while (i < name.len) : ( i += 1 ) {
            if (utils.is_whitespace(name[i])) {
                prev_whitespace = true;
                // to skip initial whitespace
                if (i == last_end) {
                    last_end += 1;
                }
            } else if (prev_whitespace) {
                switch (name[i]) {
                    'a'...'z' => {
                        switch (state) {
                            .first => {
                                state = .prefix;
                                // -1 to not include last space
                                result.first = name[last_end..i-1];
                                last_end = i;
                            },
                            else => {}
                        }
                    },
                    'A'...'Z' => {
                        switch (state) {
                            .prefix => {
                                state = .last;
                                // -1 to not include last space
                                result.prefix = name[last_end..i-1];
                                last_end = i;
                            },
                            else => {},
                        }
                    },
                    else => {},
                }
                prev_whitespace = false;
                last_word_start = i;
            }
        }
        // no words starting with a lowercase letter -> no prefix
        // btparse then just treats the whole string as first
        // but biblatex seems to interpret First Last correctly
        if (state == .first) {
            if (last_word_start != 0) {
                result.first = name[0..last_word_start - 1];
                result.last = name[last_word_start..];
            } else {
                result.last = name[0..];
            }
        } else {
            result.last = name[last_end..];
        }

        return result;
    }

    fn parse_name_with_commas(name: []const u8, num_commas: u8) BibParser.Error!Name {
        var result = Name{};
        var state = NameState.prefix;
        var last_end: u16 = 0; // exclusive
        var i: u16 = 0;
        var prev_whitespace = false;
        while (i < name.len) : ( i += 1) {
            if (utils.is_whitespace(name[i])) {
                prev_whitespace = true;
                // to skip initial whitespace
                if (i == last_end) {
                    last_end += 1;
                }
            } else if (prev_whitespace) {
                switch (name[i]) {
                    // 'a'...'z' => {
                    // },
                    'A'...'Z' => {
                        if (state == .prefix) {
                            state = .last;
                            if (last_end != i) {
                                result.prefix = name[last_end..i-1];
                                last_end = i;
                            }
                        }
                    },
                    else => {},
                }
                prev_whitespace = false;
            }
            switch (name[i]) {
                ',' => {
                    switch (state) {
                        .last, .prefix => {
                            // prefix:
                            // only lowercase words so far but comma would now start first/suffix
                            // treat everything up to here as last
                            state = if (num_commas < 2) .first else .suffix;
                            result.last = name[last_end..i];
                            last_end = i + 1;  // skip ,
                        },
                        .suffix => {
                            state = .first;
                            result.suffix = name[last_end..i];
                            last_end = i + 1;  // skip ,
                        },
                        else => {},
                    }
                },
                else => {}
            }
        }
        result.first = name[last_end..];

        return result;
    }
};
pub const SingleField = struct {
    value: []const u8,
};

inline fn is_single_field_type(field_type: FieldTypeTT) void {
    return switch (field_type) {
        .name_list, .literal_list, .key_list => false,
        else => true,
    };
}

test "parse name simple" {
    var res = try ListField.parse_name("First von Last");
    try expect(std.mem.eql(u8, res.first.?, "First"));
    try expect(std.mem.eql(u8, res.prefix.?, "von"));
    try expect(std.mem.eql(u8, res.last.?, "Last"));
    try expect(res.suffix == null);

    res = try ListField.parse_name("First Last");
    try expect(std.mem.eql(u8, res.first.?, "First"));
    try expect(res.prefix == null);
    try expect(std.mem.eql(u8, res.last.?, "Last"));
    try expect(res.suffix == null);

    // currently not stripping whitespace in the First Last case
    res = try ListField.parse_name("First    Last  ");
    try expect(std.mem.eql(u8, res.first.?, "First   "));
    try expect(res.prefix == null);
    try expect(std.mem.eql(u8, res.last.?, "Last  "));
    try expect(res.suffix == null);

    res = try ListField.parse_name("Last-Last");
    try expect(res.first == null);
    try expect(res.prefix == null);
    try expect(std.mem.eql(u8, res.last.?, "Last-Last"));
    try expect(res.suffix == null);

    res = try ListField.parse_name("First J. Other von da of Last Last");
    try expect(std.mem.eql(u8, res.first.?, "First J. Other"));
    try expect(std.mem.eql(u8, res.prefix.?, "von da of"));
    try expect(std.mem.eql(u8, res.last.?, "Last Last"));
    try expect(res.suffix == null);

    // only skipping initial whitespace for now
    // TODO?
    res = try ListField.parse_name("    First von Last");
    try expect(std.mem.eql(u8, res.first.?, "First"));
    try expect(std.mem.eql(u8, res.prefix.?, "von"));
    try expect(std.mem.eql(u8, res.last.?, "Last"));
    try expect(res.suffix == null);
}

test "parse name commas" {
    var res = try ListField.parse_name("von Last, First");
    try expect(std.mem.eql(u8, res.first.?, "First"));
    try expect(std.mem.eql(u8, res.prefix.?, "von"));
    try expect(std.mem.eql(u8, res.last.?, "Last"));
    try expect(res.suffix == null);

    res = try ListField.parse_name("von de of Last Last, First Other");
    try expect(std.mem.eql(u8, res.first.?, "First Other"));
    try expect(std.mem.eql(u8, res.prefix.?, "von de of"));
    try expect(std.mem.eql(u8, res.last.?, "Last Last"));
    try expect(res.suffix == null);

    // 2 commas
    res = try ListField.parse_name("von Last, Jr., First");
    try expect(std.mem.eql(u8, res.first.?, "First"));
    try expect(std.mem.eql(u8, res.prefix.?, "von"));
    try expect(std.mem.eql(u8, res.last.?, "Last"));
    try expect(std.mem.eql(u8, res.suffix.?, "Jr."));

    res = try ListField.parse_name("   von de of Last Last, Jr. Sr., First Other");
    try expect(std.mem.eql(u8, res.first.?, "First Other"));
    try expect(std.mem.eql(u8, res.prefix.?, "von de of"));
    try expect(std.mem.eql(u8, res.last.?, "Last Last"));
    try expect(std.mem.eql(u8, res.suffix.?, "Jr. Sr."));
}

pub const Entry = struct {
    _type: EntryType,
    // label: []const u8,
    fields: FieldMap,

    /// FieldMap should be initialized with Bibliography.field_arena.allocator
    /// so we don't have to deinit
    pub fn init(allocator: *std.mem.Allocator, _type: EntryType) Entry {
        return Entry{
            ._type = _type,
            .fields = FieldMap.init(allocator),
        };
    }

    pub fn deinit(self: *Entry) void {
        self.fields.deinit();
    }
};

/// not handling @STRING, @PREAMBLE since they're not mentioned in the
/// biblatex manual (only on the bibtex.org/format)
/// handling @COMMENT
pub const EntryType = enum {
    // comment not actually an entry type -> content is ignored
    comment,

    article,
    book,
    mvbook,
    inbook,
    bookinbook,
    suppbook,
    booklet,
    collection,
    mvcollection,
    incollection,
    suppcollection,
    dataset,
    manual,
    misc,
    online,
    patent,
    periodical,
    suppperiodical,
    proceedings,
    mvproceedings,
    inproceedings,
    reference,
    mvreference,
    inreference,
    report,
    set,
    software,
    thesis,
    unpublished,
    xdata,
    // ?custom[a-f]

    // aliases
    conference,  // -> inproceedings
    electronic,  // -> online
    mastersthesis,  // special case of thesis, as type tag
    phdthesis,  // special case of thesis, as type tag
    techreport,  // -> report, as type tag
    www,  // -> online

    // non-standard types -> treated as misc
    artwork,
    audio,
    bibnote,
    commentary,
    image,
    jurisdiction,
    legislation,
    legal,
    letter,
    movie,
    music,
    performance,
    review,
    standard,
    video,
};

pub const Field = struct {
    // currently not storing str for custom FieldName here, use the key from FieldMap
    name: FieldName,
    data: FieldType,
};

pub const FieldName = enum {
    // NOTE: IMPORTANT don't change the order of these since it requires to also change
    // the switch in get_field_type below
    // literal_field START
    custom,  // arbitrary name to e.g. save additional info
    abstract,
    addendum,
    annotation,
    booksubtitle,
    booktitle,
    booktitleaddon,
    chapter,
    edition,  // can be integer or literal
    eid,
    entrysubtype,
    eprintclass,
    eprinttype,
    eventtitle,
    eventtitleaddon,
    howpublished,
    indextitle,
    isan,
    isbn,
    ismn,
    isrn,
    issn,
    issue,
    issuetitle,
    issuesubtitle,
    issuetitleaddon,
    iswc,
    journaltitle,
    journalsubtitle,
    journaltitleaddon,
    label,
    library,
    mainsubtitle,
    maintitle,
    maintitleaddon,
    month,
    nameaddon,
    note,
    number,
    origtitle,
    pagetotal,
    part,
    reprinttitle,
    series,
    shorthand,
    shorthandintro,
    shortjournal,
    shortseries,
    shorttitle,
    subtitle,
    title,
    titleaddon,
    venue,
    version,
    year,
    usera,
    userb,
    userc,
    userd,
    usere,
    userf,
    verba,
    verbb,
    verbc,
    annote,   // alias for annotation
    archiveprefix,  // alias -> eprinttype
    journal,   // alias -> journaltitle
    key,  // aliast -> sortkey
    primaryclass,  // alias -> eprintclass
    // literal_field END
    //
    // name_list START
    afterword,
    annotator,
    author,
    bookauthor,
    commentator,
    editor,
    editora,
    editorb,
    editorc,
    foreword,
    holder,
    introduction,
    shortauthor,
    shorteditor,
    translator,
    namea,
    nameb,
    namec,
    // name_list END
    //
    // key_field START
    authortype,
    bookpagination,
    editortype,
    editoratype,
    editorbtype,
    editorctype,
    pagination,
    @"type",
    nameatype,
    namebtype,
    namectype,
    // key_field END
    //
    // date_field START
    date,
    eventdate,
    origdate,
    urldate,
    // date_field END
    //
    // verbatim_field START
    doi,
    eprint,
    file,
    pdf,   // alias -> file
    // verbatim_field END
    //
    // literal_list START
    institution,
    location,
    organization,
    origlocation,
    origpublisher,
    publisher,
    pubstate,
    lista,
    listb,
    listc,
    listd,
    liste,
    listf,
    address,  // alias for location
    school,   // alias -> institution
    // literal_list END
    //
    // key_list START
    language,
    origlanguage,
    // key_list END
    //
    // range_field START
    pages,
    // range_field END
    //
    // uri_field START
    url,
    // uri_field END
    //
    // integer_field START
    volume,
    volumes,
    // integer_field END
    //
    // special fields START
    ids,
    crossref,
    fakeset,
    gender,
    entryset,
    execute,
    hyphenation,
    indexsorttitle,
    keywords,
    langid,
    langidopts,
    options,
    presort,
    related,
    relatedoptions,
    relatedtype,
    sortshorthand,
    sortkey,
    sortname,
    sorttitle,
    sortyear,
    xref,
    // special fields END

    pub fn get_field_type(self: FieldName) FieldTypeTT {
        // ... is not allowed with enums, so cast it to it's underlying int tag type
        return switch (@enumToInt(self)) {
            @enumToInt(FieldName.custom) ... @enumToInt(FieldName.primaryclass) => .literal_field,
            @enumToInt(FieldName.afterword) ... @enumToInt(FieldName.namec) => .name_list,
            @enumToInt(FieldName.authortype) ... @enumToInt(FieldName.namectype) => .key_field,
            @enumToInt(FieldName.date) ... @enumToInt(FieldName.urldate) => .date_field, 
            @enumToInt(FieldName.doi) ... @enumToInt(FieldName.pdf) => .verbatim_field,
            @enumToInt(FieldName.institution) ... @enumToInt(FieldName.school) => .literal_list,
            @enumToInt(FieldName.language), @enumToInt(FieldName.origlanguage) => .key_list,
            @enumToInt(FieldName.pages) => .range_field,
            @enumToInt(FieldName.url) => .uri_field,
            @enumToInt(FieldName.volume), @enumToInt(FieldName.volumes) => .integer_field,
            @enumToInt(FieldName.ids) ... @enumToInt(FieldName.xref) => .special_field,
            else => unreachable,
        };
    }
};
