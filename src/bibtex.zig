const std = @import("std");
const utils = @import("utils.zig");

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

    const file = try std.fs.cwd().openFile(
        "D:\\SYNC\\coding\\pistis\\book-2020-07-28.bib", .{ .read = true });
    defer file.close();

    // there's also file.readAll that requires a pre-allocated buffer
    // TODO dynamically sized buffer
    // TODO just pass buffer and filename, loading of the file should be done elsewhere
    const contents = try file.reader().readAllAlloc(
        allocator,
        2 * 1024 * 1024,  // max_size 2MiB, returns error.StreamTooLong if file is larger
    );
    defer allocator.free(contents);

    var bp = try BibParser.init(allocator, "", contents);
    var bib = try bp.parse();
    defer bib.deinit();

}

pub const BibParser = struct {
    bib: Bibliography,
    idx: u32,
    bytes: []const u8,
    allocator: *std.mem.Allocator,

    const Error = error {
        SyntaxError,
        OutOfMemory,
        EndOfFile,
        DuplicateLabel,
    };

    pub fn init(allocator: *std.mem.Allocator, path: []const u8, bytes: []const u8) Error!BibParser {
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
        std.log.err(err_msg, args);
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
                        "Unexpected byte '{c}' expected either '@EntryType' or '%'" ++
                        " to start a line comment!\n", .{ byte });
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
                BibParser.report_error("Hit EOF while skipping whitespace!\n", .{});
                return Error.EndOfFile;
            };
        }
    }

    fn parse_entry(self: *BibParser) Error!void {
        std.debug.print("Parse entry\n", .{});
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
        std.debug.print("Lowercased type: {}\n", .{ lowercased });
        const entry_type = std.meta.stringToEnum(
            EntryType, lowercased) orelse {
                BibParser.report_error("'{}' is not a valid entry type!\n",
                                       .{ self.bytes[entry_type_start..self.idx] });
                return Error.SyntaxError;
        };
        self.allocator.free(lowercased);

        if (entry_type == .comment) {
            // NOTE: not allowing {} inside comments atm
            try self.eat_until('}');
            try self.advance_to_next_byte();
            return;
        }

        try self.advance_to_next_byte();
        const label_start = self.idx;
        try self.eat_name();
        try self.require_byte(',');
        const label = self.bytes[label_start..self.idx];

        // make sure we don't have a duplicate label!
        const entry_found = try self.bib.label_entry_map.getOrPut(label);
        // ^ result will be a struct with a pointer to the HashMap.Entry and a bool
        // whether an existing value was found
        if (entry_found.found_existing) {
            BibParser.report_error("Duplicate label '{}'!\n", .{ label });
            return Error.DuplicateLabel;
        } else {
            // actually write entry value (key was already written by getOrPut)
            entry_found.entry.*.value = Entry.init(&self.bib.field_arena.allocator, entry_type);
        }
        try self.advance_to_next_byte();

        var byte: u8 = undefined;
        while (!self.reached_eof()) {
            try self.skip_whitespace(true);
            byte = self.bytes[self.idx];
            if (byte == '}') {
                self.advance_to_next_byte() catch return;
                break;
            } else {
                try self.parse_entry_field(&entry_found.entry.value);
            }
        }

        std.debug.print("Finished entry of type '{}' with label '{}'!\n",
                        .{ entry_type, label });
    }

    /// expects to start on first byte of field name
    fn parse_entry_field(self: *BibParser, entry: *Entry) Error!void {
        const field_name_start = self.idx;
        try self.eat_name();
        const field_name_end = self.idx;

        // convert to lower-case to match with enum tagNames
        const lowercased = try std.ascii.allocLowerString(
            self.allocator, self.bytes[field_name_start..field_name_end]);
        const field_type = std.meta.stringToEnum(FieldName, lowercased) orelse .custom;
        self.allocator.free(lowercased);

        try self.skip_whitespace(true);
        try self.eat_byte('=');
        try self.skip_whitespace(true);

        self.eat_byte('{') catch {
            BibParser.report_error(
                "This implementation of a bibtex parser requires all field values to " ++
                "we wrapped in {{braces}}!\n", .{});
            return Error.SyntaxError;
        };

        // need to reform field value string since it might contain braces and other
        // escapes
        var field_value = std.ArrayList(u8).init(&self.bib.field_arena.allocator);

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
                    try field_value.appendSlice(self.bytes[added_until..self.idx]);
                    added_until = self.idx + 1;  // +1 so we don't add the {
                },
                '}' => {
                    if (braces == 0) {
                        try field_value.appendSlice(self.bytes[added_until..self.idx]);
                        break;
                    } else {
                        braces -= 1;
                        try field_value.appendSlice(self.bytes[added_until..self.idx]);
                        added_until = self.idx + 1;  // +1 so we don't add the }
                    }
                },
                '\\' => {
                    try field_value.appendSlice(self.bytes[added_until..self.idx]);
                    try self.advance_to_next_byte();
                    byte = self.peek_byte();
                    try field_value.append(byte);
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
        
        std.debug.print("On '{c}',\n{}: {}\n",
            .{ self.peek_byte(), self.bytes[field_name_start..field_name_end], field_value.items });

        // not checking if field already present
        try entry.fields.put(
            self.bytes[field_name_start..field_name_end],
            Field{
                .name = field_type,
                .value = field_value.toOwnedSlice(),
            }
        );
    }
};

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
    name_list,
    literal_list,
    key_list,
    literal_field,
    range_field,
    integer_field,
    datepart_field,
    date_field,
    verbatim_field,
    uri_field,
    separated_value_field,
    pattern_field,
    key_field,
    code_field,
};

pub const Entry = struct {
    _type: EntryType,
    // label: []const u8,
    fields: FieldMap,

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
    name: FieldName,
    value: []const u8,
    // value: FieldType,
};

pub const FieldName = enum {
    custom,  // arbitrary name to e.g. save additional info
    // special fields
    ids,
    crossref,
    fakeset,
    entryset,
    entrysubtype,
    execute,
    hyphenation,
    keywords,
    label,
    langid,
    langidopts,
    options,
    presort,
    related,
    relatedoptions,
    relatedtype,
    shorthand,
    sortshorthand,
    sortkey,
    sortname,
    sorttitle,
    sortyear,
    xref,
    // data fields
    abstract,
    addendum,
    address,
    afterword,
    annotation,
    annote,
    annotator,
    author,
    authortype,
    bookauthor,
    booksubtitle,
    booktitle,
    booktitleaddon,
    chapter,
    commentator,
    date,
    doi,
    edition,
    editor,
    editora,
    editorb,
    editorc,
    editortype,
    editoratype,
    editorbtype,
    editorctype,
    eid,
    eprint,
    eprintclass,
    eprinttype,
    eventdate,
    eventtitle,
    eventtitleaddon,
    file,
    foreword,
    gender,
    howpublished,
    indexsorttitle,
    indextitle,
    institution,
    introduction,
    isan,
    isbn,
    ismn,
    isrn,
    issn,
    issue,
    issuetitle,
    issuesubtitle,
    iswc,
    journal,
    journaltitle,
    journalsubtitle,
    language,
    library,
    location,
    bookpagination,
    mainsubtitle,
    maintitle,
    maintitleaddon,
    month,
    nameaddon,
    note,
    number,
    organization,
    origlanguage,
    origlocation,
    origpublisher,
    origtitle,
    origdate,
    pages,
    pagetotal,
    pagination,
    part,
    pdf,
    pubstate,
    reprinttitle,
    holder,
    publisher,
    school,
    series,
    shortauthor,
    shorteditor,
    shorthandintro,
    shortjournal,
    shortseries,
    shorttitle,
    subtitle,
    title,
    titleaddon,
    translator,
    @"type",
    url,
    urldate,
    venue,
    version,
    volume,
    volumes,
    year,
    // aliases
    archiveprefix,
    primaryclass,
    // custom fields
    namea,
    nameb,
    namec,
    nameatype,
    namebtype,
    namectype,
    lista,
    listb,
    listc,
    listd,
    liste,
    listf,
    usera,
    userb,
    userc,
    userd,
    usere,
    userf,
    verba,
    verbb,
    verbc,
};
