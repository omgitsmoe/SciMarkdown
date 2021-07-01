const std = @import("std");
const mem = std.mem;
const utils = @import("utils.zig");
const expect = std.testing.expect;
const log = std.log;

pub const Item = struct {
    // required: type, id; no additional properties
    @"type": ItemType,  // string -> enum
    id: OrdinaryVar,
    optionals: PropertyMap,

    pub fn init(alloactor: *std.mem.Allocator, _type: ItemType, id: OrdinaryVar) Item {
        return Item{
            .@"type" = _type,
            .id = id,
            .optionals = PropertyMap.init(alloactor),
        };
    }

    pub fn jsonStringify(
        value: @This(),
        options: std.json.StringifyOptions,
        out_stream: anytype,
    ) !void {
        try out_stream.writeByte('{');

        inline for (@typeInfo(@This()).Struct.fields) |Field, field_i| {
            comptime {
                if (std.mem.eql(u8, Field.name, "optionals")) {
                    continue;
                }
            }

            if (field_i != 0)
                try out_stream.writeByte(',');

            try std.json.stringify(Field.name, options, out_stream);
            try out_stream.writeByte(':');
            try std.json.stringify(@field(value, Field.name), options, out_stream);
        }

        if (value.optionals.count() > 0) {
            try out_stream.writeByte(',');
            var iter = value.optionals.iterator();
            var i: u32 = 0;
            while (iter.next()) |entry| : (i += 1) {
                if (i > 0) try out_stream.writeByte(',');
                try std.json.stringify(entry.key_ptr, options, out_stream);
                try out_stream.writeByte(':');
                try std.json.stringify(entry.value_ptr, options, out_stream);
            }
        }
        try out_stream.writeByte('}');
    }
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
    classic,
    dataset,
    document,
    entry,
    @"entry-dictionary",
    @"entry-encyclopedia",
    event,
    figure,
    graphic,
    hearing,
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
    performance,
    periodical,
    personal_communication,
    post,
    @"post-weblog",
    regulation,
    report,
    review,
    @"review-book",
    software,
    song,
    speech,
    standard,
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
    // NOTE: std.json.stringify fails to stringify ObjectMap even though that's what's being used to
    // parse objects in the json parser?
    // custom: std.json.ObjectMap,
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

// TODO make these smaller they're huge
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
    // https://www.loc.gov/standards/datetime/
    edtf: []const u8,
    date: Date,

    pub const Date = struct {
        // 1-2 of 1-3 items [2][3]OrdinaryVar
        @"date-parts": ?[][]OrdinaryVar = null,
        season: ?OrdinaryVar = null,
        circa: ?BoolLike = null,
        literal: ?[]const u8 = null,
        raw: ?[]const u8 = null,
        edtf: ?[]const u8 = null,

        pub fn jsonStringify(
            value: @This(),
            options: std.json.StringifyOptions,
            out_stream: anytype,
        ) !void {
            try out_stream.writeByte('{');

            // iterate over struct fields
            inline for (@typeInfo(@This()).Struct.fields) |Field, field_i| {
                if (field_i != 0)
                    try out_stream.writeByte(',');

                try std.json.stringify(Field.name, options, out_stream);
                try out_stream.writeByte(':');
                try std.json.stringify(@field(value, Field.name), options, out_stream);
            }
            try out_stream.writeByte('}');
        }
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

// TODO @Speed
// makes more sense to store this as a map internally, even though the schema states
// it is an array of Items
// pub const CSLJsonMap = std.StringHashMap(Item);

pub fn write_items_json(allocator: *std.mem.Allocator, items: []Item, out_stream: anytype) !void {
    try out_stream.writeByte('[');
    const len = items.len;
    for (items) |item, i| {
        try out_stream.writeAll("{\"type\": ");
        try std.json.stringify(item.@"type", .{}, out_stream);
        try out_stream.writeAll(", ");
        try out_stream.writeAll("\"id\": ");
        try std.json.stringify(item.id, .{}, out_stream);

        var props_iter = item.optionals.iterator();
        // const props_num = item.optionals.count();
        while (props_iter.next()) |prop_entry| {
            try out_stream.writeAll(", ");
            try out_stream.writeAll("\"");
            try out_stream.writeAll(prop_entry.key_ptr.*);
            try out_stream.writeAll("\": ");
            try std.json.stringify(prop_entry.value_ptr, .{}, out_stream);
        }
        try out_stream.writeByte('}');
        if (i != len - 1)
            try out_stream.writeByte(',');
    }
    try out_stream.writeByte(']');
}

pub fn read_items_json(allocator: *std.mem.Allocator, input: []const u8) !CSLJsonParser.Result {
    var parser = CSLJsonParser.init(allocator, input);
    return parser.parse();
}

// TODO write csl json test
test "read csl json" {
    const allocator = std.testing.allocator;
    const csljson =
        \\[{"type": "article-journal", "id": "Ismail2007",
        \\"author": [{"family":"Ismail","given":"R",
        \\"dropping-particle":null,"non-dropping-particle":null,"suffix":null,
        \\"comma-suffix":null,"static-ordering":null,"literal":null,"parse-names":null},
        \\{"family":"Mutanga","given":"O","parse-names":null}],
        \\"issued": {"date-parts":[["2007"]],"season":null,"circa":null,
        \\"literal":null,"raw":null,"edtf":null}, "number": "1",
        \\"title": "Forest health and vitality: the detection and monitoring of Pinus patula trees infected by Sirex noctilio using digital multispectral imagery",
        \\"DOI": "10.2989/shfj.2007.69.1.5.167", "volume": 69, "page": "39--47",
        \\"publisher": "Informa UK Limited", "container-title": "Southern Hemisphere Forestry Journal"}]
    ;

    const parse_result = try read_items_json(allocator, csljson[0..]);
    defer parse_result.arena.deinit();
    const items = parse_result.items;

    try expect(items.len == 1);
    const it = items[0];
    try expect(it.@"type" == .@"article-journal");
    try expect(it.id == .string);
    try expect(mem.eql(u8, it.id.string, "Ismail2007"));

    const authors = it.optionals.get("author").?.author;
    try expect(authors.len == 2);
    try expect(mem.eql(u8, authors[0].family.?, "Ismail"));
    try expect(mem.eql(u8, authors[0].given.?, "R"));
    try expect(authors[0].@"dropping-particle" == null);
    try expect(authors[0].@"non-dropping-particle" == null);
    try expect(authors[0].suffix == null);
    try expect(authors[0].@"comma-suffix" == null);
    try expect(authors[0].@"static-ordering" == null);
    try expect(authors[0].literal == null);
    try expect(authors[0].@"parse-names" == null);

    const issued = it.optionals.get("issued").?.issued.date.@"date-parts".?;
    try expect(issued.len == 1);
    try expect(issued[0].len == 1);
    try expect(mem.eql(u8, issued[0][0].string, "2007"));

    const number = it.optionals.get("number").?.number;
    try expect(mem.eql(u8, number.string, "1"));

    const title = it.optionals.get("title").?.title;
    try expect(mem.eql(u8, title, "Forest health and vitality: the detection and monitoring of Pinus patula trees infected by Sirex noctilio using digital multispectral imagery"));

    const doi = it.optionals.get("DOI").?.DOI;
    try expect(mem.eql(u8, doi, "10.2989/shfj.2007.69.1.5.167"));

    const volume = it.optionals.get("volume").?.volume;
    try expect(volume.number == 69);

    const page = it.optionals.get("page").?.page;
    try expect(mem.eql(u8, page.string, "39--47"));

    const publisher = it.optionals.get("publisher").?.publisher;
    try expect(mem.eql(u8, publisher, "Informa UK Limited"));

    const container_title = it.optionals.get("container-title").?.@"container-title";
    try expect(mem.eql(u8, container_title, "Southern Hemisphere Forestry Journal"));
}

pub const CSLJsonParser = struct {
    stream: std.json.TokenStream,
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Item),
    state: State,
    current: u32,
    input: []const u8,

    const State = enum {
        begin,
        items_start,
        item_begin,
        item_end,
        expect_id,
        expect_type,
        after_field_value,
        end,
    };

    pub const Error = error {
        UnexpectedToken,
        ParserFinished,
        ParserNotFinished,
        UnknownItemType,
        UnknownProperty,
    };

    pub const Result = struct {
        arena: std.heap.ArenaAllocator,
        items: []Item,
    };

    pub fn init(allocator: *std.mem.Allocator, input: []const u8) CSLJsonParser {
        var parser = CSLJsonParser{
            .stream = std.json.TokenStream.init(input),
            .arena = std.heap.ArenaAllocator.init(allocator),
            .items = undefined,
            .current = undefined,
            .input = input,
            .state = .begin,
        };
        return parser;
    }

    pub fn parse(self: *@This()) !Result {
        // NOTE: can't be initialized in init since the address of the arena.allocator
        // will change
        self.items = std.ArrayList(Item).init(&self.arena.allocator);

        while (try self.stream.next()) |token| {
            try self.feed(token);
        }

        switch (self.state) {
            .end => return Result{ .arena = self.arena, .items = self.items.toOwnedSlice() },
            else => return Error.ParserNotFinished,
        }
    }

    fn feed(self: *@This(), token: std.json.Token) !void {
        // []NameVar (only arr)
        // []const u8
        // []const []const u8 (only categories)
        // DateVar
        // OrdinaryVar
        switch (self.state) {
            .begin => {
                switch (token) {
                    .ArrayBegin => self.state = .items_start,
                    else => return Error.UnexpectedToken,
                }
            },
            .items_start, .item_end => {
                switch (token) {
                    .ObjectBegin => {
                        self.state = .item_begin;
                        const item: *Item = try self.items.addOne();
                        // init PropertyMap
                        item.optionals = PropertyMap.init(&self.arena.allocator);
                        self.current = @intCast(u32, self.items.items.len) - 1;
                    },
                    .ArrayEnd => self.state = .end,
                    else => return Error.UnexpectedToken,
                }
            },
            .item_begin, .after_field_value => {
                switch (token) {
                    .String => |str| {
                        // assume that the field name doesn't contain escapes
                        const current_field = str.slice(self.input, self.stream.i - 1);
                        if (mem.eql(u8, "id", current_field)) {
                            self.state = .expect_id;
                        } else if (mem.eql(u8, "type", current_field)) {
                            self.state = .expect_type;
                        } else {
                            // we have to call this here directly otherwise (if we wait to be
                            // fed the token) the tokenstream will have advanced beyond the start
                            // of the obj/value already
                            try self.parse_property(current_field);
                            self.state = .after_field_value;
                        }
                    },
                    .ObjectEnd => self.state = .item_end,
                    else => return Error.UnexpectedToken,
                }
            },
            .expect_id => {
                switch (token) {
                    .String => |str| {
                        const slice = str.slice(self.input, self.stream.i - 1);
                        self.items.items[self.current].id = .{ .string = try self.copy_string(str, slice) };
                    },
                    .Number => |num| {
                        if (!num.is_integer) {
                            return Error.UnexpectedToken;
                        }
                        const slice = num.slice(self.input, self.stream.i - 1);
                        const parsed = std.fmt.parseInt(i32, slice, 10) catch return Error.UnexpectedToken;
                        self.items.items[self.current].id = .{ .number = parsed };
                    },
                    else => return Error.UnexpectedToken,
                }

                self.state = .after_field_value;
            },
            .expect_type => {
                switch (token) {
                    .String => |str| {
                        const slice = str.slice(self.input, self.stream.i - 1);
                        const mb_item_type = std.meta.stringToEnum(ItemType, slice);
                        if (mb_item_type) |item_type| {
                            self.items.items[self.current].@"type" = item_type;
                        } else {
                            log.err("Unknown CSL-JSON item type: {s}\n", .{ slice });
                            return Error.UnknownItemType;
                        }
                        self.state = .after_field_value;
                    },
                    else => return Error.UnexpectedToken,
                }
            },
            .end => return Error.ParserFinished,
        }
    }

    // copies the string from a json string token wihout backslashes
    fn copy_string(
        self: *@This(),
        str: std.meta.TagPayload(std.json.Token, .String),
        slice: []const u8
    ) ![]const u8 {

        if (str.escapes == .Some) {
            var strbuf = try std.ArrayList(u8).initCapacity(
                    self.items.allocator, str.decodedLength());

            var escaped = false;
            for (slice) |b| {
                if (escaped) {
                    escaped = false;
                } else if (b == '\\') {
                    escaped = true;
                }
                strbuf.appendAssumeCapacity(b);
            }

            return strbuf.toOwnedSlice();
        } else {
            return mem.dupe(self.items.allocator, u8, slice);
        }
    }

    fn parse_property(self: *@This(), prop_name: []const u8) !void {
        // json.parse for Propery needs alot of comptime backward branches
        @setEvalBranchQuota(3000);
        // let json.parse handle parsing the Propery tagged union
        // NOTE: we have to use stringToEnum and then switch on the tag
        // and call json.parse to parse the proper type directly
        // since json.parse will just parse the first matching union type
        // so e.g. citation-key and language will always end up as citation-key
        const prop_kind = std.meta.stringToEnum(
            std.meta.Tag(Property), prop_name) orelse return Error.UnknownProperty;

        // @Compiler / @stdlib meta.TagPayload and @unionInit only work with comptime
        // known values, would be really practical if there were runtime variants
        // of these for getting the payload of a tag at runtime and the initializing
        // the union with the active tag and payload at runtime as well
        // TODO?
        // const PayloadType = std.meta.TagPayload(Property, prop_kind);
        // const payload = std.json.parse(
        //     PayloadType, &self.stream,
        //     .{ .allocator = self.items.allocator,
        //        .allow_trailing_data = true }
        // ) catch |err| {
        //     log.err("Could not parse property for field: {s} due to err {s}\n",
        //             .{ prop_name, err });
        //     return Error.UnknownProperty;
        // };
        // std.debug.print("putting {s}\n", .{ @tagName(prop_kind) });
        // try props.put(current_field, @unionInit(Property, @tagName(prop_kind), payload));

        // @Compiler type has to be comptime known and there is no runtime type information???
        var prop: Property = undefined;
        // switch on tag so we know which payload type we have to parse then set prop using
        // json.parse's result
        switch (prop_kind) {
            .@"citation-key", .language, .journalAbbreviation, .shortTitle,
            .abstract, .annote, .archive, .archive_collection, .archive_location,
            .@"archive-place", .authority, .@"call-number",
            .@"citation-label", .@"collection-title", .@"container-title",
            .@"container-title-short", .dimensions, .division, .DOI,
            // Deprecated - use '@"event-title' instead. Will be removed in 1.1
            // event: []const u8,
            .@"event-title", .@"event-place", .genre, .ISBN, .ISSN, .jurisdiction,
            .keyword, .medium, .note, .@"original-publisher", .@"original-publisher-place",
            .@"original-title", .@"part-title", .PMCID, .PMID, .publisher, .@"publisher-place",
            .references, .@"reviewed-genre", .@"reviewed-title", .scale, .section, .source,
            .status, .title, .@"title-short", .URL, .version, .@"volume-title",
            .@"volume-title-short", .@"year-suffix",
            => {
                // []const u8,
                const payload = std.json.parse(
                    []const u8, &self.stream,
                    .{ .allocator = self.items.allocator,
                       .allow_trailing_data = true }
                ) catch |err| {
                    log.err("Could not parse property for field: {s} due to err {s}\n",
                            .{ prop_name, err });
                    return Error.UnknownProperty;
                };
                prop = utils.unionInitTagged(Property, prop_kind, []const u8, payload);
            },

            .categories => {
                // []const []const u8,
                const payload = std.json.parse(
                    []const []const u8, &self.stream,
                    .{ .allocator = self.items.allocator,
                       .allow_trailing_data = true }
                ) catch |err| {
                    log.err("Could not parse property for field: {s} due to err {s}\n",
                            .{ prop_name, err });
                    return Error.UnknownProperty;
                };
                prop = utils.unionInitTagged(Property, prop_kind, []const []const u8, payload);
            },

            .author, .chair, .@"collection-editor", .compiler, .composer,
            .@"container-author", .contributor, .curator, .director,
            .editor, .@"editorial-director", .@"executive-producer", .guest,
            .host, .interviewer, .illustrator, .narrator, .organizer,
            .@"original-author", .performer, .producer, .recipient,
            .@"reviewed-author", .@"script-writer", .@"series-creator", .translator
            => {
                // []NameVar
                const payload = std.json.parse(
                    []NameVar, &self.stream,
                    .{ .allocator = self.items.allocator,
                       .allow_trailing_data = true }
                ) catch |err| {
                    log.err("Could not parse property for field: {s} due to err {s}\n",
                            .{ prop_name, err });
                    return Error.UnknownProperty;
                };
                prop = utils.unionInitTagged(Property, prop_kind, []NameVar, payload);
            },

            .accessed, .@"available-date", .@"event-date", .issued,
            .@"original-date", .submitted
            => {
                // DateVar
                const payload = std.json.parse(
                    DateVar, &self.stream,
                    .{ .allocator = self.items.allocator,
                       .allow_trailing_data = true }
                ) catch |err| {
                    log.err("Could not parse property for field: {s} due to err {s}\n",
                            .{ prop_name, err });
                    return Error.UnknownProperty;
                };
                prop = utils.unionInitTagged(Property, prop_kind, DateVar, payload);
            },


            .@"chapter-number", .@"citation-number", .@"collection-number", .edition,
            .@"first-reference-note-number", .issue, .locator, .number,
            .@"number-of-pages", .@"number-of-volumes", .page, .@"page-first",
            .part, .printing, .supplement, .volume,
            => {
                // OrdinaryVar
                const payload = std.json.parse(
                    OrdinaryVar, &self.stream,
                    .{ .allocator = self.items.allocator,
                       .allow_trailing_data = true }
                ) catch |err| {
                    log.err("Could not parse property for field: {s} due to err {s}\n",
                            .{ prop_name, err });
                    return Error.UnknownProperty;
                };
                prop = utils.unionInitTagged(Property, prop_kind, OrdinaryVar, payload);
            },
        }

        // NOTE: important to take the address here otherwise we copy the
        // PropertyMap and the state gets reset when exiting this function
        var props = &self.items.items[self.current].optionals;
        // add to PropertyMap
        try props.put(prop_name, prop);
    }
};
