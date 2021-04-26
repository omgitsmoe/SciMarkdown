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
            var csl_property = bib_field_to_csl(
                allocator, field_name, field_entry.value.data, copy_strings) catch continue;
            // std.debug.print("Bib field: {} CSL field: {}\n", .{ field_name, csl_property });

            // NOTE: currently overwriting on duplicate
            try item.optionals.put(@tagName(csl_property), csl_property);
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

pub fn bib_field_to_csl(
    allocator: *std.mem.Allocator,
    field_name: bibtex.FieldName,
    field_data: bibtex.FieldType,
    comptime copy_strings: bool,
) !csl.Property {
    return switch (field_name) {
        .custom,  // arbitrary name to e.g. save additional info
        => return Error.NoMatchingField,

        .abstract,
        => .{ .abstract = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), },

        // .addendum,

        .annotation,
        .annote,   // alias for annotation
        => .{ .annote = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), },

        .booksubtitle,
        .booktitle,
        .booktitleaddon,
        => .{ .@"container-title" = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), },

        .chapter,
        => .{ .@"chapter-number" = .{
                .string = try maybe_copy_string(
                    allocator, copy_strings, field_data.literal_field.value), } },

        .edition,
        => .{ .edition = .{
                .string = try maybe_copy_string(
                    allocator, copy_strings, field_data.literal_field.value), } },

        // TODO on .eid: should start with 'e', pages -> replace '--' with '-'
        .eid,
        => .{ .page = .{
                .string = try maybe_copy_string(
                    allocator, copy_strings, field_data.literal_field.value), } },

        .entrysubtype,  // citation-js also has 'type' as target?
        => .{ .genre = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), },

        // .eprintclass,

        .eprinttype,
        => .{ .PMID = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), },

        .eventtitle,
        => .{ .@"event-title" = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), },

        // .eventtitleaddon,

        // TODO only on manuscript when there's no publisher, organization, institution
        .howpublished,
        => .{ .publisher = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), },

        // .indextitle,

        // TODO when not patent
        .isan, .ismn, .isrn, .iswc,
        => .{ .number = .{
                .string = try maybe_copy_string(
                    allocator, copy_strings, field_data.literal_field.value), } },

        .isbn,
        => .{ .ISBN = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), },

        .issn,
        => .{ .ISSN = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), },

        // .issue,

        .issuetitle, .issuesubtitle, .issuetitleaddon,
        => .{ .@"volume-title" = try maybe_copy_string(
                    allocator, copy_strings, field_data.literal_field.value), },

        // TODO citation-js has target: article, article-newspaper, etc.
        .journaltitle, .journalsubtitle, .journaltitleaddon,
        .journal,   // alias -> journaltitle
        => .{ .@"container-title" = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), },

        // .label,
        .library,
        => .{ .@"call-number" = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), },

        .mainsubtitle, .maintitle, .maintitleaddon,
        => .{ .@"container-title" = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), },

        .month,
        => .{ .issued = .{
                .edtf = try maybe_copy_string(
                    allocator, copy_strings, field_data.literal_field.value), } },

        // .nameaddon,
        .note,
        => .{ .note = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), },

        .number,
        => .{ .number = .{
                .string = try maybe_copy_string(
                    allocator, copy_strings, field_data.literal_field.value), } },

        .origtitle,
        => .{ .@"original-title" = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), },

        .pagetotal,
        => .{ .@"number-of-pages" = .{
                .string = try maybe_copy_string(
                    allocator, copy_strings, field_data.literal_field.value), } },

        .part,
        => .{ .part = .{ .string = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), } },

        // .reprinttitle,
        .series,
        => .{ .@"collection-title" = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), },

        // .shorthand,
        // .shorthandintro,

        .shortjournal,
        .shortseries,
        .shorttitle,
        => .{ .@"container-title-short" = try maybe_copy_string(
                    allocator, copy_strings, field_data.literal_field.value), },

        .title,
        .titleaddon,
        .subtitle,
        => .{ .title = try maybe_copy_string(
                allocator, copy_strings, field_data.literal_field.value), },

        .venue,
        => .{ .@"event-place" = try maybe_copy_string(
                    allocator, copy_strings, field_data.literal_field.value), },

        .version,
        => .{ .version = try maybe_copy_string(
                    allocator, copy_strings, field_data.literal_field.value), },

        // TODO fill out proper date part and check that we don't overwrite previous
        .year,
        => .{ .issued = .{
                .edtf = try maybe_copy_string(
                    allocator, copy_strings, field_data.literal_field.value), } },

        .usera, .userb, .userc, .userd, .usere, .userf,
        .verba, .verbb, .verbc,
        .lista, .listb, .listc, .listd, .liste, .listf,
        => return Error.NoMatchingField,  // TODO custom fields

        .archiveprefix,  // alias -> eprinttype
        => .{ .PMID = try maybe_copy_string(allocator, copy_strings, field_data.literal_field.value), },

        // .primaryclass,  // alias -> eprintclass

        // afterword,
        // annotator,
        .author,
        => try bib_field_extract_name_list(allocator, .author, field_data),

        .bookauthor,
        => try bib_field_extract_name_list(allocator, .@"container-author", field_data),

        // commentator,
        .editor,
        .editora, .editorb, .editorc,
        => try bib_field_extract_name_list(allocator, .editor, field_data),

        // foreword,
        // holder,
        // introduction,
        // shortauthor,
        // shorteditor,

        .translator,
        => try bib_field_extract_name_list(allocator, .translator, field_data),

        // namea,
        // nameb,
        // namec,
        //
        // key_field START
        // authortype,
        // TODO unsure v
        .bookpagination,
        => .{ .section = try maybe_copy_string(allocator, copy_strings, field_data.key_field.value), },

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
        // TODO proper date conversion
        .date,
        => .{ .issued = .{
                .edtf = try maybe_copy_string(
                    allocator, copy_strings, field_data.date_field.value), } },

        .eventdate,
        => .{ .@"event-date" = .{
                .edtf = try maybe_copy_string(
                    allocator, copy_strings, field_data.date_field.value), } },

        .origdate,
        => .{ .@"original-date" = .{
                    .edtf = try maybe_copy_string(
                        allocator, copy_strings, field_data.date_field.value), } },

        .urldate,
        => .{ .accessed = .{
                .edtf = try maybe_copy_string(
                    allocator, copy_strings, field_data.date_field.value), } },

        //
        .doi,
        => .{ .DOI = try maybe_copy_string(allocator, copy_strings, field_data.verbatim_field.value), },

        .eprint,
        => .{ .PMID = try maybe_copy_string(allocator, copy_strings, field_data.verbatim_field.value), },

        // TODO custom
        // file,
        // pdf,   // alias -> file
        .institution,
        .school,   // alias -> institution
        => bib_field_extract_list(allocator, .publisher, .literal_list, field_data),

        // TODO 'jurisdiction' when type patent
        .location,
        .address,  // alias for location
        => bib_field_extract_list(allocator, .@"publisher-place", .literal_list, field_data),

        .organization,
        => bib_field_extract_list(allocator, .publisher, .literal_list, field_data),

        .origlocation,
        => bib_field_extract_list(allocator, .@"original-publisher-place", .literal_list, field_data),

        .origpublisher,
        => bib_field_extract_list(allocator, .@"original-publisher", .literal_list, field_data),

        .publisher,
        => bib_field_extract_list(allocator, .publisher, .literal_list, field_data),

        .pubstate,
        => bib_field_extract_list(allocator, .status, .literal_list, field_data),

        .language,
        => bib_field_extract_list(allocator, .language, .key_list, field_data),

        // origlanguage,
        .pages,
        => .{ .page = .{
                .string = try maybe_copy_string(
                    allocator, copy_strings, field_data.range_field.value), } },

        .url,
        => .{ .URL = try maybe_copy_string(allocator, copy_strings, field_data.uri_field.value), },

        .volume,
        => .{ .volume = .{ 
                .string = try maybe_copy_string(
                    allocator, copy_strings, field_data.integer_field.value), }, },

        .volumes,
        => .{ .@"number-of-volumes" = .{
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
    };
}

inline fn bib_field_extract_name_list(
    allocator: *std.mem.Allocator,
    comptime active_tag: @TagType(csl.Property),
    field_data: bibtex.FieldType
) !csl.Property {
    var names = std.ArrayList(csl.NameVar).init(allocator);
    for (field_data.name_list.values) |name_literal| {
        var bt_name = try bibtex.ListField.parse_name(name_literal);
        try names.append(.{
            .family = bt_name.last,
            .given = bt_name.first,
            .@"non-dropping-particle" = bt_name.prefix,
            .suffix = bt_name.suffix,
        });
    }

    // builtin that makes union init with a comptime known field/tag name possible
    return @unionInit(csl.Property, @tagName(active_tag), names.toOwnedSlice());
}

inline fn bib_field_extract_list(
    allocator: *std.mem.Allocator,
    comptime active_tag: @TagType(csl.Property),
    comptime active_field_tag: bibtex.FieldTypeTT,
    field_data: bibtex.FieldType
) csl.Property {
    // @field performs a field access base on a comptime-known string
    var list: []const []const u8 = @field(field_data, @tagName(active_field_tag)).values;

    var result: []const u8 = &[_]u8 {};  // empty string
    if (list.len > 0) {
        const first = list[0];
        const last = list[list.len - 1];
        result.ptr = first.ptr;
        result.len = @ptrToInt(last.ptr) - @ptrToInt(result.ptr) + last.len;
    }

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
