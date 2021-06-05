const std = @import("std");
const utils = @import("utils.zig");
const expect = std.testing.expect;

const bibtex = @import("bibtex.zig");
const csl = @import("csl_json.zig");

pub const Error = error {
    NoMatchingItemType,
    NoMatchingField,
};

pub fn bib_to_csl_json(
    allocator: *std.mem.Allocator,
    bib: bibtex.Bibliography,
    comptime copy_strings: bool
) ![]csl.Item {
    var items = std.ArrayList(csl.Item).init(allocator);

    var bib_iter = bib.label_entry_map.iterator();
    while (bib_iter.next()) |map_entry| {
        const id = map_entry.key;
        const entry = &map_entry.value;
        var csl_type = bib_entry_to_csl_item(entry._type) catch continue;

        // std.debug.print("Bib type: {} CSL type: {}\n", .{ entry._type, csl_type });

        var item = csl.Item{
            .@"type" = csl_type,
            .id = .{
                .string = try maybe_copy_string(allocator, copy_strings, id) },
            .optionals = csl.PropertyMap.init(allocator),
        };

        var fields_iter = entry.fields.iterator();
        while (fields_iter.next()) |field_entry| {
            const field_name = field_entry.value.name;
            if (field_name == .custom) continue;
            set_bib_field_on_csl(
                allocator, field_name, field_entry.value.data,
                &item.optionals, copy_strings) catch continue;
            // std.debug.print("Bib field: {} CSL field: {}\n", .{ field_name, csl_property });
        }

        try items.append(item);
    }

    return items.toOwnedSlice();
}

// TODO proper tests
test "bib to csl" {
    const alloc = std.testing.allocator;
    const file = try std.fs.cwd().openFile("book-2020-07-28.bib", .{ .read = true });
    defer file.close();

    const contents = try file.reader().readAllAlloc(
        alloc,
        2 * 1024 * 1024,  // max_size 2MiB, returns error.StreamTooLong if file is larger
    );
    defer alloc.free(contents);

    var bibparser = bibtex.BibParser.init(alloc, "book-2020-07-28.bib", contents);
    var bib = try bibparser.parse();
    defer bib.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var csl_json = try bib_to_csl_json(&arena.allocator, bib, false);

    const write_file = try std.fs.cwd().createFile(
        "bib.json",
        // truncate: reduce file to length 0 if it exists
        .{ .read = true, .truncate = true },
    );
    defer write_file.close();

    try csl.write_items_json(alloc, csl_json, write_file.writer());
}

pub fn bib_entry_to_csl_item(entry_type: bibtex.EntryType) !csl.ItemType {
    return switch (entry_type) {
        // ?custom[a-f]
        .comment,
        .set,
        .xdata,
        .bibnote,
        => return Error.NoMatchingItemType,

        .article,
        .periodical,
        .suppperiodical,
        => .@"article-journal",

        .misc,
        .commentary,
        => .article,

        .book, .mvbook, .bookinbook, .booklet,
        .collection, .mvcollection,
        .proceedings, .mvproceedings,
        .reference, .mvreference,
        => .book,

        .incollection,
        .suppcollection,
        .inbook,
        .suppbook,
        => .chapter,

        .dataset,
        => .dataset,

        .online,
        .electronic,  // -> online
        .www,  // -> online
        => .webpage,

        .patent,
        => .patent,

        .inproceedings,
        .conference,  // -> inproceedings
        => .@"paper-conference",

        .inreference,
        => .entry,

        .report,
        .techreport,  // -> report, as type tag
        => .report,

        .software,
        => .software,

        .thesis,
        .mastersthesis,  // special case of thesis, as type tag
        .phdthesis,  // special case of thesis, as type tag
        => .thesis,

        .unpublished,
        => .manuscript,

        .artwork,
        => .graphic,

        .audio,
        => .song,

        .image,
        => .figure,

        .jurisdiction,
        => .legal_case,

        .legislation,
        => .legislation,

        .legal,
        => .treaty,

        .letter,
        => .personal_communication,

        .movie,
        .video,
        => .motion_picture,

        .music,
        => .musical_score,

        .review,
        => .review,

        // TODO unsure
        .manual,
        => .document,

        .performance,
        => .performance,

        .standard,
        => .standard,
    };
}

inline fn set_issued(
    allocator: *std.mem.Allocator,
    field_name: bibtex.FieldName,
    field_data: bibtex.FieldType,
    item_props: *csl.PropertyMap,
    comptime date_part_idx: usize,
    comptime copy_strings: bool,
) !?csl.Property {
    if (date_part_idx > 2) {
        @compileError("date_part_idx can only range from 0-2 (0: year, 1: month, 2: day)!");
    }

    var mb_target = item_props.get("issued");
    if (mb_target) |target| {
        switch (target.issued) {
            // don't overwrite target's date union if it has an incompatible version
            .edtf => {},
            .date => |*value| {
                if (value.raw == null and value.literal == null and value.edtf == null) {
                    const parts = value.@"date-parts".?;
                    if (parts.items.len == 1 and parts.items[0].items.len >= date_part_idx + 1) {
                        parts.items[0].items[date_part_idx] = .{
                            .string = try maybe_copy_string(
                                        allocator, copy_strings, field_data.literal_field.value),
                        };
                    }
                }
            },
        }
        return null;
    } else {
        var date_parts = try allocator.create(csl.DateVar.DateParts);
        date_parts.* = csl.DateVar.DateParts.init(allocator);
        try date_parts.append(std.ArrayList(?csl.OrdinaryVar).init(allocator));

        if (date_part_idx == 1) {
            // append null for year if we're setting month
            try date_parts.items[0].append(null);
        }
        try date_parts.items[0].append(csl.OrdinaryVar{
            .string = try maybe_copy_string(
                        allocator, copy_strings, field_data.literal_field.value)
        });
        return csl.Property{
            .issued = .{
                .date = .{ .@"date-parts" = date_parts }
            }
        };
    }
}

pub fn set_bib_field_on_csl(
    allocator: *std.mem.Allocator,
    field_name: bibtex.FieldName,
    field_data: bibtex.FieldType,
    item_props: *csl.PropertyMap,
    comptime copy_strings: bool,
) !void {
    var csl_prop: csl.Property = undefined;
    switch (field_name) {
        .custom,  // arbitrary name to e.g. save additional info
        => return Error.NoMatchingField,

        .abstract,
        => csl_prop = .{ .abstract = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), },

        // .addendum,

        .annotation,
        .annote,   // alias for annotation
        => csl_prop = .{ .annote = try maybe_copy_string(
                    allocator, copy_strings, field_data.literal_field.value), },

        .booksubtitle,
        .booktitle,
        .booktitleaddon,
        => csl_prop = .{ .@"container-title" = try maybe_copy_string(
                    allocator, copy_strings, field_data.literal_field.value), },

        .chapter,
        => csl_prop = .{ .@"chapter-number" = .{
                .string = try maybe_copy_string(
                    allocator, copy_strings, field_data.literal_field.value), } },

        .edition,
        => csl_prop = .{ .edition = .{
                .string = try maybe_copy_string(
                    allocator, copy_strings, field_data.literal_field.value), } },

        // TODO on .eid: should start with 'e', pages -> replace '--' with '-'
        .eid,
        => csl_prop = .{ .page = .{
                .string = try maybe_copy_string(
                    allocator, copy_strings, field_data.literal_field.value), } },

        .entrysubtype,  // citation-js also has 'type' as target?
        => csl_prop = .{ .genre = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), },

        // .eprintclass,

        .eprinttype,
        => csl_prop = .{ .PMID = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), },

        .eventtitle,
        => csl_prop = .{ .@"event-title" = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), },

        // .eventtitleaddon,

        // TODO only on manuscript when there's no publisher, organization, institution
        .howpublished,
        => csl_prop = .{ .publisher = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), },

        // .indextitle,

        // TODO when not patent
        .isan, .ismn, .isrn, .iswc,
        => csl_prop = .{ .number = .{
                .string = try maybe_copy_string(
                    allocator, copy_strings, field_data.literal_field.value), } },

        .isbn,
        => csl_prop = .{ .ISBN = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), },

        .issn,
        => csl_prop = .{ .ISSN = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), },

        // .issue,

        .issuetitle, .issuesubtitle, .issuetitleaddon,
        => csl_prop = .{ .@"volume-title" = try maybe_copy_string(
                    allocator, copy_strings, field_data.literal_field.value), },

        // TODO citation-js has target: article, article-newspaper, etc.
        .journaltitle, .journalsubtitle, .journaltitleaddon,
        .journal,   // alias -> journaltitle
        => csl_prop = .{ .@"container-title" = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), },

        // .label,
        .library,
        => csl_prop = .{ .@"call-number" = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), },

        .mainsubtitle, .maintitle, .maintitleaddon,
        => csl_prop = .{ .@"container-title" = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), },

        // .nameaddon,
        .note,
        => csl_prop = .{ .note = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), },

        .number,
        => csl_prop = .{ .number = .{
                .string = try maybe_copy_string(
                    allocator, copy_strings, field_data.literal_field.value), } },

        .origtitle,
        => csl_prop = .{ .@"original-title" = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), },

        .pagetotal,
        => csl_prop = .{ .@"number-of-pages" = .{
                .string = try maybe_copy_string(
                    allocator, copy_strings, field_data.literal_field.value), } },

        .part,
        => csl_prop = .{ .part = .{ .string = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), } },

        // .reprinttitle,
        .series,
        => csl_prop = .{ .@"collection-title" = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), },

        // .shorthand,
        // .shorthandintro,

        .shortjournal,
        .shortseries,
        .shorttitle,
        => csl_prop = .{ .@"container-title-short" = try maybe_copy_string(
                    allocator, copy_strings, field_data.literal_field.value), },

        .title,
        .titleaddon,
        .subtitle,
        => csl_prop = .{ .title = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), },

        .venue,
        => csl_prop = .{ .@"event-place" = try maybe_copy_string(
                    allocator, copy_strings, field_data.literal_field.value), },

        .version,
        => csl_prop = .{ .version = try maybe_copy_string(
                    allocator, copy_strings, field_data.literal_field.value), },

        .month,
        => csl_prop = (try set_issued(allocator, field_name, field_data, item_props, 1, copy_strings))
            orelse return,

        .year,
        => csl_prop = (try set_issued(allocator, field_name, field_data, item_props, 0, copy_strings))
            orelse return,

        .usera, .userb, .userc, .userd, .usere, .userf,
        .verba, .verbb, .verbc,
        .lista, .listb, .listc, .listd, .liste, .listf,
        => return Error.NoMatchingField,  // TODO custom fields

        .archiveprefix,  // alias -> eprinttype
        => csl_prop = .{
            .PMID = try maybe_copy_string(allocator, copy_strings, field_data.literal_field.value), },

        // .primaryclass,  // alias -> eprintclass

        // afterword,
        // annotator,
        .author,
        => csl_prop = try bib_field_extract_name_list(allocator, .author, field_data, copy_strings),

        .bookauthor,
        => csl_prop = try bib_field_extract_name_list(
            allocator, .@"container-author", field_data, copy_strings),

        // commentator,
        .editor,
        .editora, .editorb, .editorc,
        => csl_prop = try bib_field_extract_name_list(allocator, .editor, field_data, copy_strings),

        // foreword,
        // holder,
        // introduction,
        // shortauthor,
        // shorteditor,

        .translator,
        => csl_prop = try bib_field_extract_name_list(allocator, .translator, field_data, copy_strings),

        // namea,
        // nameb,
        // namec,
        //
        // key_field START
        // authortype,
        // TODO unsure v
        .bookpagination,
        => csl_prop = .{
            .section = try maybe_copy_string(allocator, copy_strings, field_data.key_field.value), },

        // TODO can be used to assign editor[a-c] to compiler, organizer, ...
        // editortype,
        // editoratype,
        // editorbtype,
        // editorctype,
        //
        // pagination,
        // .@"type",
        // => .genre,

        // nameatype,
        // namebtype,
        // namectype,
        // key_field END
        //
        // NOTE: treats bib(la)tex date fields as edtf strings
        // these should prob be fine as edtf string, but the format needs to be
        // YYYY-MM-DDTHH:MM:SS, see https://www.loc.gov/standards/datetime/
        // raw field of date is now supposed to be treated like edtf
        // (see https://discourse.citationstyles.org/t/raw-dates-vs-date-parts/1533/11)
        // literal is used to inlcude additional descriptions in the date
        .date,
        => csl_prop = .{ .issued = .{
                .edtf = try maybe_copy_string(
                    allocator, copy_strings, field_data.date_field.value), } },

        .eventdate,
        => csl_prop = .{ .@"event-date" = .{
                .edtf = try maybe_copy_string(
                    allocator, copy_strings, field_data.date_field.value), } },

        .origdate,
        => csl_prop = .{ .@"original-date" = .{
                    .edtf = try maybe_copy_string(
                        allocator, copy_strings, field_data.date_field.value), } },

        .urldate,
        => csl_prop = .{ .accessed = .{
                .edtf = try maybe_copy_string(
                    allocator, copy_strings, field_data.date_field.value), } },

        //
        .doi,
        => csl_prop = .{ .DOI = try maybe_copy_string(
                allocator, copy_strings, field_data.verbatim_field.value), },

        .eprint,
        => csl_prop = .{ .PMID = try maybe_copy_string(
                allocator, copy_strings, field_data.verbatim_field.value), },

        // TODO custom
        // file,
        // pdf,   // alias -> file
        .institution,
        .school,   // alias -> institution
        => csl_prop = bib_field_extract_list(allocator, .publisher, .literal_list, field_data, copy_strings),

        // TODO 'jurisdiction' when type patent
        .location,
        .address,  // alias for location
        => csl_prop = bib_field_extract_list(
            allocator, .@"publisher-place", .literal_list, field_data, copy_strings),

        .organization,
        => csl_prop = bib_field_extract_list(allocator, .publisher, .literal_list, field_data, copy_strings),

        .origlocation,
        => csl_prop = bib_field_extract_list(
            allocator, .@"original-publisher-place", .literal_list, field_data, copy_strings),

        .origpublisher,
        => csl_prop = bib_field_extract_list(
            allocator, .@"original-publisher", .literal_list, field_data, copy_strings),

        .publisher,
        => csl_prop = bib_field_extract_list(allocator, .publisher, .literal_list, field_data, copy_strings),

        .pubstate,
        => csl_prop = bib_field_extract_list(allocator, .status, .literal_list, field_data, copy_strings),

        .language,
        => csl_prop = bib_field_extract_list(allocator, .language, .key_list, field_data, copy_strings),

        // origlanguage,
        .pages,
        => csl_prop = .{ .page = .{
                .string = try maybe_copy_string(
                    allocator, copy_strings, field_data.range_field.value), } },

        .url,
        => csl_prop = .{ .URL = try maybe_copy_string(allocator, copy_strings, field_data.uri_field.value), },

        .volume,
        => csl_prop = .{ .volume = .{ 
                .string = try maybe_copy_string(
                    allocator, copy_strings, field_data.integer_field.value), }, },

        .volumes,
        => csl_prop = .{ .@"number-of-volumes" = .{
                    .string = try maybe_copy_string(
                        allocator, copy_strings, field_data.integer_field.value),
            }
        },

        // special fields START
        // .ids, .crossref, .fakeset, .gender, .entryset, .execute,
        // .hyphenation, .indexsorttitle, .keywords, .langid, .langidopts,
        // .options, .presort, .related, .relatedoptions, .relatedtype,
        // .sortshorthand, .sortkey, .sortname, .sorttitle, .sortyear, .xref,
        // .key,  // aliast -> sortkey
        // => return Error.NoMatchingField,
        // special fields END

        else => return Error.NoMatchingField,
    }

    // NOTE: currently overwriting on duplicate
    try item_props.put(@tagName(csl_prop), csl_prop);
}

inline fn bib_field_extract_name_list(
    allocator: *std.mem.Allocator,
    comptime active_tag: std.meta.TagType(csl.Property),
    field_data: bibtex.FieldType,
    comptime copy_strings: bool,
) !csl.Property {
    var names = std.ArrayList(csl.NameVar).init(allocator);
    for (field_data.name_list.values) |name_literal| {
        var bt_name = try bibtex.ListField.parse_name(name_literal);
        try names.append(.{
            .family = if (bt_name.last) |last|
                try maybe_copy_string(allocator, copy_strings, last) else null,
            .given = if (bt_name.first) |first|
                try maybe_copy_string(allocator, copy_strings, first) else null,
            .@"non-dropping-particle" =
                if (bt_name.prefix) |prefix|
                    try maybe_copy_string(allocator, copy_strings, prefix) else null,
            .suffix = if (bt_name.suffix) |suffix|
                try maybe_copy_string(allocator, copy_strings, suffix) else null,
        });
    }

    // builtin that makes union init with a comptime known field/tag name possible
    return @unionInit(csl.Property, @tagName(active_tag), names.toOwnedSlice());
}

inline fn bib_field_extract_list(
    allocator: *std.mem.Allocator,
    comptime active_tag: std.meta.TagType(csl.Property),
    comptime active_field_tag: bibtex.FieldTypeTT,
    field_data: bibtex.FieldType,
    comptime copy_strings: bool,
) csl.Property {
    // @field performs a field access base on a comptime-known string
    var list: []const []const u8 = @field(field_data, @tagName(active_field_tag)).values;

    // NOTE: this only works since we know that our bibtex parser doesn't re-allocate
    // the single list items but just creates slices into the bibtex file content
    var result: []const u8 = &[_]u8 {};  // empty string
    if (list.len > 0) {
        const first = list[0];
        const last = list[list.len - 1];
        result.ptr = first.ptr;
        result.len = @ptrToInt(last.ptr) - @ptrToInt(result.ptr) + last.len;
    }
    if (copy_strings)
        result = try maybe_copy_string(allocator, result, true);

    // builtin that makes union init with a comptime known field/tag name possible
    return @unionInit(csl.Property, @tagName(active_tag), result);
}

inline fn maybe_copy_string(
    allocator: *std.mem.Allocator,
    comptime copy_strings: bool,
    string: []const u8
) ![]const u8 {
    // dupe copies passed in slice to new memory that the caller then owns
    if (copy_strings) {
        return try std.mem.Allocator.dupe(allocator, u8, id);
    } else {
        return string;
    }
}
