const std = @import("std");
const utils = @import("utils.zig");
const expect = std.testing.expect;

pub const Item = struct {
    // required: type, id; no additional properties
    @"type": ItemType,  // string -> enum
    id: OrdinaryVar,
    optionals: PropertyMap,
};
pub const PropertyMap = std.StringHashMap(Property);

pub const ItemType = enum {
    article,
    @"article-journal",
    @"article-magazine",
    @"article-newspaper",
    bill,
    book,
    broadcast,
    chapter,
    dateset,
    entry,
    @"entry-dictionary",
    @"entry-encyclopedia",
    figure,
    graphic,
    interview,
    legal_case,
    legislation,
    manuscript,
    map,
    motion_picture,
    musical_score,
    pamphlet,
    @"paper-conference",
    patent,
    personal_communication,
    post,
    @"post-weblog",
    report,
    review,
    @"review-book",
    song,
    speech,
    thesis,
    treaty,
    webpage,

    // provide jsonStringify method so std's json writer knows how to format the enum
    // or any custom type (uses comptime duck-typing by checking if a custom type
    // has the jsonStringify method; std.meta.trait.hasFn("jsonStringify"))
    pub fn jsonStringify(
        value: ItemType,
        options: std.json.StringifyOptions,
        out_stream: anytype,
    ) !void {
        try std.json.stringify(@tagName(value), options, out_stream);
    }
};

pub const Property = union(enum) {
    @"citation-key": []const u8,
    categories: []const []const u8,
    language: []const u8,
    journalAbbreviation: []const u8,
    shortTitle: []const u8,

    author: []NameVar,
    chair: []NameVar,
    @"collection-editor": []NameVar,
    compiler: []NameVar,
    composer: []NameVar,
    @"container-author": []NameVar,
    contributor: []NameVar,
    curator: []NameVar,
    director: []NameVar,
    editor: []NameVar,
    @"editorial-director": []NameVar,
    @"executive-producer": []NameVar,
    guest: []NameVar,
    host: []NameVar,
    interviewer: []NameVar,
    illustrator: []NameVar,
    narrator: []NameVar,
    organizer: []NameVar,
    @"original-author": []NameVar,
    performer: []NameVar,
    producer: []NameVar,
    recipient: []NameVar,
    @"reviewed-author": []NameVar,
    @"script-writer": []NameVar,
    @"series-creator": []NameVar,
    translator: []NameVar,

    accessed: DateVar,
    @"available-date": DateVar,
    @"event-date": DateVar,
    issued: DateVar,
    @"original-date": DateVar,
    submitted: DateVar,

    abstract: []const u8,
    annote: []const u8,
    archive: []const u8,
    archive_collection: []const u8,
    archive_location: []const u8,
    @"archive-place": []const u8,
    authority: []const u8,
    @"call-number": []const u8,
    @"chapter-number": OrdinaryVar,
    @"citation-number": OrdinaryVar,
    @"citation-label": []const u8,
    @"collection-number": OrdinaryVar,
    @"collection-title": []const u8,
    @"container-title": []const u8,
    @"container-title-short": []const u8,
    dimensions: []const u8,
    division: []const u8,
    DOI: []const u8,
    edition: OrdinaryVar,
    // Deprecated - use '@"event-title' instead. Will be removed in 1.1
    // event: []const u8,
    @"event-title": []const u8,
    @"event-place": []const u8,
    @"first-reference-note-number": OrdinaryVar,
    genre: []const u8,
    ISBN: []const u8,
    ISSN: []const u8,
    issue: OrdinaryVar,
    jurisdiction: []const u8,
    keyword: []const u8,
    locator: OrdinaryVar,
    medium: []const u8,
    note: []const u8,
    number: OrdinaryVar,
    @"number-of-pages": OrdinaryVar,
    @"number-of-volumes": OrdinaryVar,
    @"original-publisher": []const u8,
    @"original-publisher-place": []const u8,
    @"original-title": []const u8,
    page: OrdinaryVar,
    @"page-first": OrdinaryVar,
    part: OrdinaryVar,
    @"part-title": []const u8,
    PMCID: []const u8,
    PMID: []const u8,
    printing: OrdinaryVar,
    publisher: []const u8,
    @"publisher-place": []const u8,
    references: []const u8,
    @"reviewed-genre": []const u8,
    @"reviewed-title": []const u8,
    scale: []const u8,
    section: []const u8,
    source: []const u8,
    status: []const u8,
    supplement: OrdinaryVar,
    title: []const u8,
    @"title-short": []const u8,
    URL: []const u8,
    version: []const u8,
    volume: OrdinaryVar,
    @"volume-title": []const u8,
    @"volume-title-short": []const u8,
    @"year-suffix": []const u8,
    // TODO custom; 'js object' with arbitrary @"key-value pairs for storing additional information
    // we currently don't need this information
    custom,
};

pub const OrdinaryVar = union(enum) {
    string: []const u8,
    // float also allowed here or just ints?
    number: i32,
};

pub const BoolLike = union(enum) {
    string: []const u8,
    number: i32,
    boolean: bool,
};

pub const NameVar = struct {
    family: ?[]const u8 = null,
    given: ?[]const u8 = null,
    @"dropping-particle": ?[]const u8 = null,
    @"non-dropping-particle": ?[]const u8 = null,
    suffix: ?[]const u8 = null,
    @"comma-suffix": ?BoolLike = null,
    @"static-ordering": ?BoolLike = null,
    literal: ?[]const u8 = null,
    @"parse-names": ?BoolLike = null,

};

pub const DateVar = union(enum) {
    // Extended Date/Time Format (EDTF) string
    edtf: []const u8,
    date: Date,

    pub const Date = struct {
        // 1-2 of 1-3 items [2][3]OrdinaryVar
        @"date-parts": [][]OrdinaryVar,
        season: OrdinaryVar,
        circa: BoolLike,
        literal: []const u8,
        raw: []const u8,
        edtf: []const u8,
    };
};

pub const Citation = struct {
    // schema: "https://resource.citationstyles.org/schema/latest/input/json/csl-citation.json" 
    schema: []const u8,
    citationID: OrdinaryVar,
    citationItems: ?[]CitationItem = null,
    properties: ?struct { noteIndex: i32 } = null,
};

pub const CitationItem = struct {
    id: OrdinaryVar,
    // TODO un-comment when Item can get properly stringified
    // itemData: ?[]Item = null,
    prefix: ?[]const u8 = null,
    suffix: ?[]const u8 = null,
    locator: ?[]const u8 = null,
    label: ?LocatorType = null,
    @"suppress-author": ?BoolLike = null,
    @"author-only": ?BoolLike = null,
    uris: ?[]const []const u8 = null,
    
    pub const LocatorType = enum {
        act,
        appendix,
        @"article-locator",
        book,
        canon,
        chapter,
        column,
        elocation,
        equation,
        figure,
        folio,
        issue,
        line,
        note,
        opus,
        page,
        paragraph,
        part,
        rule,
        scene,
        section,
        @"sub-verbo",
        supplement,
        table,
        timestamp,
        @"title-locator",
        verse,
        version,
        volume,

        pub fn jsonStringify(
            value: LocatorType,
            options: std.json.StringifyOptions,
            out_stream: anytype,
        ) !void {
            try std.json.stringify(@tagName(value), options, out_stream);
        }
    };
};
