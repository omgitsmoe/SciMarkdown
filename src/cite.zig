const std = @import("std");
const utils = @import("utils.zig");
const ast = @import("ast.zig");
const NodeKind = ast.NodeKind;
const Node = ast.Node;
const TokenKind = @import("tokenizer.zig").TokenKind;
const CitationItem = @import("csl_json.zig").CitationItem;

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
    allocator: *std.mem.Allocator,
    json: []const u8,
    cite_nodes: []*Node  // TODO NodeKind.Citation nodes in the same order as citations were passed to citeproc
) ![]*Node {
    // NOTE: either use the Parser and keep the ValueTree and generate formatted
    // strings from that directly or use json.TokenStream to generate
    // CiteprocResult from that 'manually'
    var stream = std.json.Parser.init(allocator, false);
    defer stream.deinit();  // deallocates node/values stack
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
        // std.debug.print("BIB ENTRY ID: {s}\n", .{ entry_id });
        entry_node.data = .{
            .BibEntry = .{ .id = entry_id },
        };
        try bib_nodes.append(entry_node);

        try nodes_from_formatted(
            allocator, bib_entry.Array.items[1].Array.items, entry_node);
    }

    return bib_nodes.toOwnedSlice();
}

/// adds formatted ast.Nodes to first_parent from a Citeproc formatted string in json
fn nodes_from_formatted(
    allocator: *std.mem.Allocator,
    formatted_items: []const std.json.Value,
    first_parent: *Node
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
                // std.debug.print("{} -> ", .{ format });
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
                            .StrongEmphasis = 
                                .{ .opener_token_kind = TokenKind.Asterisk_double },
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
                    .baseline,  // TODO what is this?
                    .@"no-italics", .@"no-bold",
                    .@"no-decoration", .@"no-small-caps" => parent = first_parent,
                    .div => unreachable,
                }

                const contents = obj.get("contents").?;
                for (contents.Array.items) |str| {
                    var txt_node = try Node.create(allocator);
                    txt_node.data = .{
                        .Text = .{ .text = try allocator.dupe(u8, str.String) },
                    };
                    parent.append_child(txt_node);
                    
                    // std.debug.print("{s}", .{ str });
                }
            },
            else => unreachable,
        }
        // std.debug.print("\n", .{});
    }
}

/// HAS to be called with parser's node_arena.allocator (or another ArenaAllocator)
/// potential @MemoryLeak if no ArenaAllocator or sth similar is used
/// since the caller takes ownership of stdout and stderr that are
/// currently not passed TODO
pub fn run_citeproc(allocator: *std.mem.Allocator, cite_nodes: []*Node) ![]*Node {
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
        }
    }
    var to_citeproc = .{
        // citations = [[CitationItem, ..], [CitationItem, ..], ..]
        .citations = citations.items,
        // TODO pass lang
        .lang = "de-DE",
    };

    const cmd = &[_][]const u8{
        "vendor\\citeproc.exe", "--references=bib.json",
        "--style=vendor\\apa-6th-edition.csl",
        "--format=json",
    };
    var runner = try std.ChildProcess.init(cmd, allocator);
    defer runner.deinit();
    runner.stdin_behavior = .Pipe;
    runner.stdout_behavior = .Pipe;
    runner.stderr_behavior = .Pipe;

    // order important otherwise stdin etc. not initialized
    try runner.spawn();

    try std.json.stringify(to_citeproc, .{}, runner.stdin.?.writer());
    // write program code to stdin
    runner.stdin.?.close();
    // has to be set to null otherwise the ChildProcess tries to close it again
    // and hits unreachable code
    runner.stdin = null;

    std.debug.print("Done writing to stdin!\n", .{});

    // might deadlock due to https://github.com/ziglang/zig/issues/6343
    // weirdly only WindowsTerminal seems to have a problem with it and stops
    // responding, cmd.exe works fine as does running it in a debugger
    const stdout = try runner.stdout.?.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(stdout);
    // std.debug.print("Done reading from citeproc stdout!\nOUT:\n{s}\n", .{ stdout });
    const stderr = try runner.stderr.?.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(stderr);
    std.debug.print("Done reading from citeproc stderr!\nERR:\n{s}\n", .{ stderr });

    _ = try runner.wait();

    var res = try nodes_from_citeproc_json(allocator, stdout, cite_nodes);
    return res;
}
