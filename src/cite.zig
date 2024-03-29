const std = @import("std");
const log = std.log;

const utils = @import("utils.zig");
const ast = @import("ast.zig");
const NodeKind = ast.NodeKind;
const Node = ast.Node;
const TokenKind = @import("tokenizer.zig").TokenKind;
const csl = @import("csl_json.zig");
const CitationItem = csl.CitationItem;
const bib_to_csl_json = @import("bib_to_csl.zig").bib_to_csl_json;
const bibtex = @import("bibtex.zig");

const builtin = @import("builtin.zig");
const BuiltinCall = builtin.BuiltinCall;

// pub const CiteprocResult = struct {
//     citations: [][]FormattedOrLiteral,
//     // array of [id, []FormattedOrLiteral]
//     bibliography: [][2][]FormattedOrLiteral,
//     warnings: []const u8,
// };

// pub const FormattedOrLiteral = union(enum) {
//     literal: []const u8,
//     formatted: FormattedString,
// };

// pub const FormattedString = struct {
//     format: Format,
//     contents: []const []const u8,

// };

pub const Format = enum {
    // outerquotes,  // only present in rendercontext but not where json output is emitted
    italics,
    @"no-italics",
    bold,
    @"no-bold",
    underline,
    @"no-decoration",
    @"small-caps",
    @"no-small-caps",
    superscript,
    subscript,
    baseline,
    div,
};

/// will use json's memory for strings
/// caller takes ownership
pub fn nodes_from_citeproc_json(
    allocator: std.mem.Allocator,
    json: []const u8,
    cite_nodes: []*Node, // TODO NodeKind.Citation nodes in the same order as citations were passed to citeproc
) ![]*Node {
    // NOTE: either use the Parser and keep the ValueTree and generate formatted
    // strings from that directly or use json.TokenStream to generate
    // CiteprocResult from that 'manually'
    var stream = std.json.Parser.init(allocator, false);
    defer stream.deinit(); // deallocates node/values stack
    var json_tree = try stream.parse(json);
    // json_tree.arena holds allocated Arrays/ObjectMaps/Strings
    // no Strings allocated since we passed false as copy_strings
    // otherwise we could not free at the end of this proc
    defer json_tree.deinit();

    var bib_nodes = std.ArrayList(*Node).init(allocator);

    const citations = &json_tree.root.Object.getEntry("citations").?.value_ptr.*;
    std.debug.assert(citations.Array.items.len == cite_nodes.len);
    for (citations.Array.items) |citation, i| {
        try nodes_from_formatted(allocator, citation.Array.items, cite_nodes[i]);
    }

    const bibliography = &json_tree.root.Object.getEntry("bibliography").?.value_ptr.*;
    for (bibliography.Array.items) |bib_entry| {
        const entry_node = try Node.create(allocator);
        // NOTE: only passing string ids to citeproc so we can only expect string ids back
        const entry_id = try allocator.dupe(u8, bib_entry.Array.items[0].String);
        entry_node.data = .{
            .BibEntry = .{ .id = entry_id },
        };
        try bib_nodes.append(entry_node);

        try nodes_from_formatted(allocator, bib_entry.Array.items[1].Array.items, entry_node);
    }

    return bib_nodes.toOwnedSlice();
}

/// adds formatted ast.Nodes to first_parent from a Citeproc formatted string in json
fn nodes_from_formatted(
    allocator: std.mem.Allocator,
    formatted_items: []const std.json.Value,
    first_parent: *Node,
) !void {

    // TODO instead of chaning the BuiltinCall node to Citation
    // use Citation node for a single "CitationItem" in the sense of csl/citeproc
    // and store the id so we can later generate a link to the corresponding bibentry
    for (formatted_items) |formatted| {
        switch (formatted) {
            .String => |str| {
                const txt_node = try Node.create(allocator);
                // NOTE: json.Parser re-allocates strings if there is an escape token (\)
                // inside them -> dupe them (otherwise we can't free the ValueTree
                // returned from the parser)
                // (unfortunately no S.escapes is available like in the json.Parser itself
                //  to check if there are escapes)
                txt_node.data = .{
                    .Text = .{ .text = try allocator.dupe(u8, str) },
                };
                first_parent.append_child(txt_node);
            },
            .Object => |obj| {
                const format = std.meta.stringToEnum(Format, obj.get("format").?.String).?;
                var parent: *Node = undefined;
                switch (format) {
                    .italics => {
                        parent = try Node.create(allocator);
                        parent.data = .{
                            .Emphasis = .{ .opener_token_kind = TokenKind.Asterisk },
                        };
                        first_parent.append_child(parent);
                    },
                    .bold => {
                        parent = try Node.create(allocator);
                        parent.data = .{
                            .StrongEmphasis = .{ .opener_token_kind = TokenKind.Asterisk_double },
                        };
                        first_parent.append_child(parent);
                    },
                    .@"small-caps" => {
                        parent = try Node.create(allocator);
                        parent.data = .SmallCaps;
                        first_parent.append_child(parent);
                    },
                    .superscript => {
                        parent = try Node.create(allocator);
                        parent.data = .Superscript;
                        first_parent.append_child(parent);
                    },
                    .subscript => {
                        parent = try Node.create(allocator);
                        parent.data = .Subscript;
                        first_parent.append_child(parent);
                    },
                    .underline => {
                        parent = try Node.create(allocator);
                        parent.data = .Underline;
                        first_parent.append_child(parent);
                    },
                    .baseline, // TODO what is this?
                    .@"no-italics",
                    .@"no-bold",
                    .@"no-decoration",
                    .@"no-small-caps",
                    => parent = first_parent,
                    .div => unreachable,
                }

                const contents = obj.get("contents").?;
                for (contents.Array.items) |str| {
                    var txt_node = try Node.create(allocator);
                    txt_node.data = .{
                        .Text = .{ .text = try allocator.dupe(u8, str.String) },
                    };
                    parent.append_child(txt_node);
                }
            },
            else => unreachable,
        }
    }
}

/// HAS to be called with parser's node_arena.allocator (or another ArenaAllocator)
/// potential @MemoryLeak if no ArenaAllocator or sth similar is used
/// since the caller takes ownership of stdout and stderr that are
/// currently not passed TODO
pub fn run_citeproc(
    allocator: std.mem.Allocator,
    cite_nodes: []*Node,
    references: []csl.Item,
    csl_file: []const u8,
    locale: []const u8,
) ![]*Node {
    // NOTE: Try spawning the process before doing most of the work, so we can at
    // least abort on Windows, should the executable not be available
    // (on POSIX that info is delayed till we .wait() on the process, at least
    //  in zig's implementation)
    // NOTE: excecutable has to be specified without extension otherwise it tries to
    // find it as executable.exe.exe *.exe.bat etc.
    // see: https://github.com/ziglang/zig/pull/2705 and https://github.com/ziglang/zig/pull/2770
    const cmd = &[_][]const u8{
        "citeproc", "--format=json",
        "--style",  csl_file,
    };

    log.debug("Cite commands:", .{});
    for (cmd) |c| {
        log.debug("{s} ", .{c});
    }

    var runner = std.ChildProcess.init(cmd, allocator);
    runner.stdin_behavior = .Pipe;
    runner.stdout_behavior = .Pipe;
    runner.stderr_behavior = .Pipe;

    // order important otherwise stdin etc. not initialized
    try runner.spawn();

    // jgm/citeproc states that it takes either an array of Citation{} objects (json)
    // or an array of CitationItem arrays
    // but if the first option is passed it errors:
    // Error in $.citations[0]: parsing [] failed, expected Array, but encountered Object
    // .citations = &[_]Citation {
    //     .{
    //         .schema = "https://resource.citationstyles.org/schema/latest/input/json/csl-citation.json",
    //         .citationID = .{ .number = 1, },
    //         .citationItems = cites[0..],
    //     },
    // },
    var citations = std.ArrayList([]const CitationItem).init(allocator);
    defer citations.deinit();
    // TODO take ArenaAllocator as param and use child allocator here?
    var ids = std.BufSet.init(allocator);
    defer ids.deinit();

    for (cite_nodes) |cite| {
        if (cite.data.BuiltinCall.result) |result| {
            switch (result.*) {
                // same problem as below: &[1]CitationItem { single_cite }
                // for casting a single item ptr x to a slice:
                // ([]T)(*[1]T)(&x)  (using old casting syntax)
                // I guess the first cast is now implicit
                .cite => |*single_cite| try citations.append(@as(*[1]CitationItem, single_cite)),
                // NOTE: this just overwrites the previous one that was appended
                // since |two_cites| will be the values copied on the stack (which is [2]CitationItem)
                // .textcite => |two_cites| try citations.append(two_cites[0..]),
                // whereas |*two_cites| will be [2]*CitationItem
                // @Compiler TODO the documentation mention that |value| will actually
                // copy value onto the stack (and not use *const value as I assumed)
                // even though it does say that |*value| makes it a ptr
                .textcite => |*two_cites| try citations.append(two_cites[0..]),
                .cites => |cites| try citations.append(cites),
                else => unreachable,
            }

            // add used citation ids for gathering references next
            for (citations.items[citations.items.len - 1]) |citation| {
                switch (citation.id) {
                    .string => |str| try ids.insert(str),
                    .number => |num| {
                        // engough chars for a 64-bit number
                        var buf: [20]u8 = undefined;
                        const str = try std.fmt.bufPrint(buf[0..], "{}", .{num});
                        // BufSet copies the str so this is fine
                        try ids.insert(str);
                    },
                }
            }
        }
    }

    var used_refs = std.ArrayList(csl.Item).init(allocator);
    defer used_refs.deinit();
    for (references) |ref| {
        switch (ref.id) {
            .string => |str| {
                if (ids.contains(str))
                    try used_refs.append(ref);
            },
            .number => |num| {
                // engough chars for a 64-bit number
                var buf: [20]u8 = undefined;
                const str = try std.fmt.bufPrint(buf[0..], "{}", .{num});
                // BufSet copies the str so this is fine
                if (ids.contains(str))
                    try used_refs.append(ref);
            },
        }
    }

    var to_citeproc = .{
        // citations = [[CitationItem, ..], [CitationItem, ..], ..]
        .citations = citations.items,
        .references = used_refs.items,
        .lang = locale,
    };

    // write program code to stdin
    // debug try std.json.stringify(to_citeproc, .{}, std.io.getStdOut().writer());
    try std.json.stringify(to_citeproc, .{}, runner.stdin.?.writer());
    runner.stdin.?.close();
    // has to be set to null otherwise the ChildProcess tries to close it again
    // and hits unreachable code
    runner.stdin = null;

    log.debug("Done writing to stdin!\n", .{});

    // might deadlock due to https://github.com/ziglang/zig/issues/6343
    const stdout = try runner.stdout.?.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(stdout);

    log.debug("Done reading from citeproc stdout!\n", .{});
    log.debug("OUT:\n{s}\n", .{stdout});
    const stderr = try runner.stderr.?.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(stderr);
    log.debug("Done reading from citeproc stderr!\nERR:\n{s}\n", .{stderr});

    _ = try runner.wait();

    // TODO we either:
    // 1. don't allow inline nodes inside cite params
    // 2. re-parse citations, once we get them back from citeproc
    //   -> since we can't rely on citeproc/csl styles not using our inline node symbols
    //      we have to mark the parts we need to re-parse in a hacky way
    //      e.g. wrapping in sth. rare like \scm:prefix...\scm
    // 3. handle csl/citations ourselves
    // since 1. and 3. are out of the question due to too limited features and scope creep/effort
    // we need to use the hacky solution in 2.
    var res = try nodes_from_citeproc_json(allocator, stdout, cite_nodes);
    return res;
}

pub fn csl_items_from_file(
    allocator: std.mem.Allocator,
    filename: []const u8,
    write_conversion: bool,
) !csl.CSLJsonParser.Result {
    var ref_file_type = enum { bib, json, unsupported }.unsupported;
    if (std.mem.endsWith(u8, filename, ".bib")) {
        ref_file_type = .bib;
    } else if (std.mem.endsWith(u8, filename, ".json")) {
        ref_file_type = .json;
    } else {
        log.err("Only CSL-JSON and bib(la)tex are supported as bibliography file formats!", .{});
        return error.UnsupportedRefFile;
    }

    const file = blk: {
        if (std.fs.path.isAbsolute(filename)) {
            break :blk try std.fs.openFileAbsolute(filename, .{ .mode = .read_only });
        } else {
            break :blk try std.fs.cwd().openFile(filename, .{ .mode = .read_only });
        }
    };
    defer file.close();
    // 20 MiB max
    const ref_file_bytes = try file.readToEndAlloc(allocator, 20 * 1024 * 1024);
    defer allocator.free(ref_file_bytes);

    var csl_json_result: csl.CSLJsonParser.Result = undefined;
    switch (ref_file_type) {
        .bib => {
            var bibparser = bibtex.BibParser.init(allocator, filename, ref_file_bytes);
            var bib = try bibparser.parse();
            defer bib.deinit();
            var arena = std.heap.ArenaAllocator.init(allocator);
            // NOTE: we copy the strings from the Bibliography values so we can free it
            const items = try bib_to_csl_json(arena.allocator(), bib, true);
            csl_json_result = .{ .arena = arena, .items = items };

            // write file
            if (write_conversion) {
                // swap .bib with .json extension
                var converted_fn = try allocator.alloc(u8, filename.len + 1);
                @memcpy(converted_fn.ptr, filename.ptr, filename.len);
                @memcpy(converted_fn[filename.len - 3 ..].ptr, "json", 4);

                const write_file = blk: {
                    if (std.fs.path.isAbsolute(converted_fn)) {
                        // truncate: reduce file to length 0 if it exists
                        break :blk try std.fs.createFileAbsolute(
                            converted_fn,
                            .{ .read = true, .truncate = true },
                        );
                    } else {
                        break :blk try std.fs.cwd().createFile(
                            converted_fn,
                            .{ .read = true, .truncate = true },
                        );
                    }
                };
                defer write_file.close();

                try csl.write_items_json(items, write_file.writer());
            }
        },
        .json => {
            csl_json_result = try csl.read_items_json(allocator, ref_file_bytes);
        },
        else => unreachable,
    }

    return csl_json_result;
}
