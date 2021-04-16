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

    var bp = try BibParser.init(allocator, "", contents);
    var bib = try bp.parse();
    defer bib.deinit();

}

pub const BibParser = struct {
    bib: Bibliography,
    idx: u32,
    bytes: []const u8,

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

    inline fn next(self: *BibParser) ?u8 {
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
            &self.bib.field_arena.allocator, self.bytes[entry_type_start..self.idx]);
        std.debug.print("Lowercased type: {}\n", .{ lowercased });
        const entry_type = std.meta.stringToEnum(
            EntryType, lowercased) orelse {
                return Error.SyntaxError;
        };
        self.bib.field_arena.allocator.free(lowercased);

        try self.advance_to_next_byte();
        const label_start = self.idx;
        try self.eat_until(',');
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
                // TODO
                self.idx += 1; // try self.parse_entry_field();
            }
        }

        std.debug.print("Finished entry of type '{}' with label '{}'!\n",
                        .{ entry_type, label });
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
    tags: FieldMap,

    pub fn init(allocator: *std.mem.Allocator, _type: EntryType) Entry {
        return Entry{
            ._type = _type,
            .tags = FieldMap.init(allocator),
        };
    }

    pub fn deinit(self: *Entry) void {
        self.tags.deinit();
    }
};

/// not handling @STRING, @PREAMBLE since they're not mentioned in the
/// biblatex manual (only on the bibtex.org/format)
/// handling @COMMENT
pub const EntryType = enum {
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
    masterthesis,  // special case of thesis, as type tag
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
    value: FieldType,
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
