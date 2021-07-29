const std = @import("std");
const log = std.log;

const csl = @import("csl_json.zig");
const ast = @import("ast.zig");
const Parser = @import("parser.zig").Parser;

pub const BuiltinCall = enum {
    cite,
    textcite,
    cites,
    bibliography,
    sc,
    label,
    ref,
};

pub const BuiltinCallInfo = struct {
    // 0 -> varargs
    pos_params: i16,
    kw_params:  u16,
    // whether BuiltinResult should be allocated and stored persistently
    persistent: bool,
};

pub const builtin_call_info = [_]BuiltinCallInfo {
    .{ .pos_params =  1, .kw_params = 4, .persistent = true },  // cite
    .{ .pos_params =  1, .kw_params = 4, .persistent = true },  // textcite
    .{ .pos_params = -1, .kw_params = 0, .persistent = true },  // cites
    .{ .pos_params =  0, .kw_params = 0, .persistent = false },  // bibliography
    .{ .pos_params =  1, .kw_params = 0, .persistent = false },  // sc
    .{ .pos_params =  1, .kw_params = 0, .persistent = true },  // label
    .{ .pos_params =  1, .kw_params = 0, .persistent = true },  // ref
};

// TODO @CleanUp should this be a sep tag and union, since the result is optional we never
// use the tagged union properly, only the payload and tag separately
pub const BuiltinResult = union(BuiltinCall) {
    cite: csl.CitationItem,
    // citeproc doesn't propely support \textcite behaviour from biblatex where
    // the author is printed outside parens and only the year is inside:
    // @textcite(walter99) -> Walter (1999)
    // => needs to be two CitationItem with the first being author-only and the second
    // being suppress-author
    textcite: [2]csl.CitationItem,
    cites: []const csl.CitationItem,
    bibliography: *ast.Node,
    sc,
    label: []const u8,
    ref:   []const u8,
};

pub const Error = error {
    OutOfMemory,
    SyntaxError,
    ArgumentMismatch,
    InvalidArgument,
    BuiltinNotAllowed,
};

// anytype means we can pass anonymous structs like: .{ .parser = self, .. }
// checkted at compile time (aka "comptime duck-typing")
/// expects that the correct amount of positional arguments are already validated by parse_builtin
/// evaluate_builtin and derivatives are expected to clean up the argument nodes
/// so that only the builtin_node itself OR the result nodes remain!
pub fn evaluate_builtin(
    allocator: *std.mem.Allocator, 
    builtin_node: *ast.Node,
    builtin_type: BuiltinCall,
    data: anytype
) Error!BuiltinResult {
    var result: BuiltinResult = undefined;
    // NOTE: theoretically builtins using results of other arbitrary builtins are allowed
    // under the condition that the builtin can be __fully__ evaluated directly (without
    // having to e.g. wait for citeproc to process it; e.g. using @textcite as post kwarg
    // for @cite would thus not work since the post kwarg has to be sent to citeproc, but
    // the value is not known yet until citeproc is run etc..
    switch (builtin_type) {
        .cite => {
            result = .{
                .cite = try evaluate_builtin_cite(builtin_node, .cite, data),
            };
            // clean up arguments
            builtin_node.delete_children(allocator);
        },
        .textcite => {
            result = .{
                .textcite = try evaluate_builtin_textcite(builtin_node, .textcite, .{}),
            };
            // clean up arguments
            builtin_node.delete_children(allocator);
        },
        .cites => {
            // TODO @MemoryLeak this is not free'd
            var citations = std.ArrayList(csl.CitationItem).init(allocator);
            var mb_next = builtin_node.first_child;
            while (mb_next) |next| : (mb_next = next.next) {
                switch (next.first_child.?.data) {
                    .BuiltinCall => |call| {
                        switch (call.builtin_type) {
                            // .cite and .textcite nodes will have been evaluated already
                            // just use the resul ptr
                            .cite => {
                                try citations.append(call.result.?.cite);
                            },
                            .textcite => {
                                // TODO compiler stuck in an infinite loop
                                // [999/10000+] with inferred error set
                                // [4000/6000]  with explicit error set but still infinite loop
                                // const tc = try evaluate_builtin(
                                //     allocator, next.first_child.?, .textcite, .{});
                                // try citations.append(tc.textcite[0]);
                                // try citations.append(tc.textcite[1]);
                                const tc_result = call.result.?;
                                try citations.append(tc_result.textcite[0]);
                                try citations.append(tc_result.textcite[1]);
                            },
                            else => {
                                log.err(
                                    "Only calls to @cite or @textcite are allowed as arguments " ++
                                    "to builtin call '{s}'!\n",
                                    .{ @tagName(builtin_type) });
                                return Error.ArgumentMismatch;
                            },
                        }
                    },
                    else => {
                        log.err(
                            "Only calls to @cite or @textcite are allowed as arguments " ++
                            "to builtin call '{s}'!\n",
                            .{ @tagName(builtin_type) });
                        return Error.ArgumentMismatch;
                    },
                }
            }

            log.debug("Multicite:\n", .{});
            for (citations.items) |it| {
                log.debug("    {s}\n", .{ it });
            }
            log.debug("Multicite END\n", .{});

            // clean up arguments
            builtin_node.delete_children(allocator);
            result = .{
                .cites = citations.toOwnedSlice(),
            };
        },
        .bibliography => {
            var bib_node = try ast.Node.create(allocator);
            bib_node.data = .Bibliography;
            builtin_node.append_child(bib_node);

            result = .{
                .bibliography = bib_node,
            };
        },
        .sc => {
            var only_arg = builtin_node.first_child.?;
            var text_node = only_arg.first_child.?;
            text_node.detach();  // remove from only_arg
            // TODO validate arg types in a pre-pass?

            // insert parent .SmallCaps node above text_node
            var parent = try ast.Node.create(allocator);
            parent.data = .SmallCaps;
            parent.append_child(text_node);

            builtin_node.append_child(parent);
            // there are no argument nodes to clean up

            result = .sc;
        },
        .label => {
            var only_arg = builtin_node.first_child.?;
            result = .{
                .label = only_arg.first_child.?.data.Text.text,
            };
            // not neccessary/effective since we require to be called with the node
            // ArenaAllocator (and freeing allocations has no effect unless it's the
            // last allocation)
            only_arg.delete_direct_children(allocator);
            allocator.destroy(only_arg);
            builtin_node.first_child = null;
        },
        .ref => {
            var only_arg = builtin_node.first_child.?;
            result = .{
                .ref = only_arg.first_child.?.data.Text.text,
            };
            only_arg.delete_direct_children(allocator);
            allocator.destroy(only_arg);
            builtin_node.first_child = null;
        },
    }

    return result;
}

/// just here since recursive calls won't compile with the compiler being stuck in an
/// infinite loop during semantic analysis see: https://github.com/ziglang/zig/issues/4572
pub fn evaluate_builtin_textcite(
    builtin_node: *ast.Node,
    builtin_type: BuiltinCall,
    data: anytype
) Error![2]csl.CitationItem {
    _ = builtin_type;
    _ = data;
    // TODO fix kwargs on textcite since we use two separate cites to emulate a real textcite
    // the pre/post/etc get printed twice
    var cite_author_only = try evaluate_builtin_cite(builtin_node, .textcite, data);
    var cite_no_author: csl.CitationItem = cite_author_only;

    cite_author_only.@"author-only" = .{ .boolean = true };
    cite_no_author.@"suppress-author" = .{ .boolean = true };

    return [2]csl.CitationItem { cite_author_only, cite_no_author };
}

pub fn evaluate_builtin_cite(
    builtin_node: *ast.Node,
    builtin_type: BuiltinCall,
    data: anytype
) Error!csl.CitationItem {
    _ = data;
    // return BuiltinResult here as well?
    // var result: BuiltinResult = undefined;

    var citation = csl.CitationItem{
        .id = undefined,
        .prefix = null,
        .suffix = null,
        .locator = null,
        .label = null,
        .@"suppress-author" = null,
        .@"author-only" = null,
    };

    if (builtin_node.first_child) |fchild| {
        if (fchild.data != .PostionalArg) {
            log.err(
                "Builtin call '{s}' missing first postional argument 'id'!\n",
                .{ @tagName(builtin_type) });
            return Error.ArgumentMismatch;
        }
        var id = fchild.first_child.?.data.Text.text;
        if (id[0] == '-') {
            // id starting with '-' -> suppress author
            citation.@"suppress-author" = .{ .boolean = true };
            id = id[1..];
        }
        citation.id.string = id;
        log.debug("First pos arg: {s}\n", .{ fchild.first_child.?.data.Text.text });

        var mb_next = fchild.next;
        while (mb_next) |next| : (mb_next = next.next) {
            if (next.first_child == null or next.first_child.?.data != .Text) {
                log.err(
                    "Only textual arguments allowed for builtin call '{s}'!\n",
                    .{ @tagName(builtin_type) });
                log.debug("Other data: {}\n", .{ next.data });
                return Error.ArgumentMismatch;
            }

            // check that no there are no other cite calls that we depend on
            var mb_current: ?*ast.Node = next;
            while (mb_current) |current| : (mb_current = current.dfs_next()) {
                if (current.data == .BuiltinCall) {
                    switch (current.data.BuiltinCall.builtin_type) {
                        .cite, .textcite, .cites => {
                            // TODO: @Improvement include starting token in ast.Node
                            // so we can inlcude line_nr when error reporting?
                            log.err("Nested calls to cite " ++
                                    "builtins are not allowed!", .{});
                            return Error.BuiltinNotAllowed;
                        },
                        else => {},
                    }
                }
            }

            if (std.mem.eql(u8, next.data.KeywordArg.keyword, "pre")) {
                citation.prefix = next.first_child.?.data.Text.text;
            } else if (std.mem.eql(u8, next.data.KeywordArg.keyword, "post")) {
                citation.suffix = next.first_child.?.data.Text.text;
            } else if (std.mem.eql(u8, next.data.KeywordArg.keyword, "loc")) {
                citation.locator = next.first_child.?.data.Text.text;
            } else if (std.mem.eql(u8, next.data.KeywordArg.keyword, "label")) {
                const mb_loc_type = std.meta.stringToEnum(
                    csl.CitationItem.LocatorType, next.first_child.?.data.Text.text);
                if (mb_loc_type) |loc_type| {
                    citation.label = loc_type;
                } else {
                    log.err(
                        "'label={s}' is not a valid locator type! See " ++
                        "https://docs.citationstyles.org/en/stable/" ++
                        "specification.html#locators for valid locator types!\n",
                        .{ next.first_child.?.data.Text.text });
                    return Error.InvalidArgument;
                }
            } else {
                log.err(
                    "Unexpected keyword argument '{s}' for builtin call '{s}'!\n",
                    .{ next.data.KeywordArg.keyword, @tagName(builtin_type) });
                return Error.ArgumentMismatch;
            }
        }

        log.debug("After collecting kwargs:\n{}\n", .{ citation });
    } else {
        log.err(
            "Builtin call has no arguments!\n", .{});
        return Error.ArgumentMismatch;
    }

    return citation;
}
