const std = @import("std");

const csl = @import("csl_json.zig");
const ast = @import("ast.zig");

pub const BuiltinCall = enum {
    cite = 0,
    textcite,
    cites,
};

pub const BuiltinCallInfo = struct {
    // 0 -> varargs
    pos_params: u32,
    kw_params:  u32,
};

pub const builtin_call_info = [_]BuiltinCallInfo {
    .{ .pos_params = 1, .kw_params = 4 },  // cite
    .{ .pos_params = 1, .kw_params = 4 },  // textcite
    .{ .pos_params = 0, .kw_params = 0 },  // cites
};

pub const BuiltinResult = union(BuiltinCall) {
    cite: csl.CitationItem,
    // citeproc doesn't propely support \textcite behaviour from biblatex where
    // the author is printed outside parens and only the year is inside:
    // @textcite(walter99) -> Walter (1999)
    // => needs to be two CitationItem with the first being author-only and the second
    // being suppress-author
    textcite: [2]csl.CitationItem,
    cites: []const csl.CitationItem,
};

pub const Error = error {
    OutOfMemory,
    SyntaxError,
    ArgumentMismatch,
    InvalidArgument,
};

// anytype means we can pass anonymous structs like: .{ .parser = self, .. }
// checkted at compile time (aka "comptime duck-typing")
/// expects that the correct amount of positional arguments are already validated by parse_builtin
pub fn evaluate_builtin(
    allocator: *std.mem.Allocator,
    builtin_node: *ast.Node,
    builtin_type: BuiltinCall,
    data: anytype
) !BuiltinResult {
    var result: BuiltinResult = undefined;
    switch (builtin_type) {
        .cite => {
            result = .{
                .cite = try evaluate_builtin_cite(builtin_node, builtin_type, data),
            };
        },
        .textcite => {
            var cite_author_only = try evaluate_builtin_cite(builtin_node, builtin_type, data);
            var cite_no_author: csl.CitationItem = cite_author_only;

            cite_author_only.@"author-only" = .{ .boolean = true };
            cite_no_author.@"suppress-author" = .{ .boolean = true };

            result = .{
                .textcite = [2]csl.CitationItem { cite_author_only, cite_no_author },
            };
        },
        .cites => {
            // TODO @Leak this is not free'd
            var citations = std.ArrayList(csl.CitationItem).init(allocator);
            var mb_next = builtin_node.first_child;
            while (mb_next) |next| : (mb_next = next.next) {
                switch (next.first_child.?.data) {
                    .BuiltinCall => |call| {
                        switch (call.builtin_type) {
                            .cite => {
                                try citations.append(
                                    try evaluate_builtin_cite(next.first_child.?, .cite, .{}));
                            },
                            .textcite => {
                                // const tc = try evaluate_builtin(
                                //     allocator, next.first_child.?, call.builtin_type, .{});
                                // try citations.append(tc.textcite[0]);
                                // try citations.append(tc.textcite[1]);
                            },
                            else => {
                                std.log.err(
                                    "Only calls to @cite or @textcite are allowed as arguments " ++
                                    "to builtin call '{}'!\n",
                                    .{ @tagName(builtin_type) });
                                return Error.ArgumentMismatch;
                            },
                        }
                    },
                    else => {
                        std.log.err(
                            "Only calls to @cite or @textcite are allowed as arguments " ++
                            "to builtin call '{}'!\n",
                            .{ @tagName(builtin_type) });
                        return Error.ArgumentMismatch;
                    },
                }
            }

            std.debug.print("Multicite:\n", .{});
            for (citations.items) |it| {
                std.debug.print("    {}\n", .{ it });
            }
            std.debug.print("Multicite END\n", .{});

            result = .{
                .cites = citations.toOwnedSlice(),
            };
        },
    }

    return result;
}

pub fn evaluate_builtin_cite(builtin_node: *ast.Node, builtin_type: BuiltinCall, data: anytype) !csl.CitationItem {
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
            std.log.err(
                "Builtin call '{}' missing first postional argument 'id'!\n",
                .{ @tagName(builtin_type) });
            return Error.ArgumentMismatch;
        }
        citation.id.string = fchild.first_child.?.data.Text.text;
        std.debug.print("First pos arg: {}\n", .{ citation.id });

        var mb_next = fchild.next;
        while (mb_next) |next| : (mb_next = next.next) {
            if (next.first_child == null or next.first_child.?.data != .Text) {
                std.log.err(
                    "Only textual arguments allowed for builtin call '{}'!\n",
                    .{ @tagName(builtin_type) });
                std.debug.print("Other data: {}\n", .{ next.data });
                return Error.ArgumentMismatch;
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
                    std.log.err(
                        "'label={}' is not a valid locator type! See " ++
                        "https://docs.citationstyles.org/en/stable/" ++
                        "specification.html#locators for valid locator types!\n",
                        .{ next.first_child.?.data.Text.text });
                    return Error.InvalidArgument;
                }
            } else {
                std.log.err(
                    "Unexpected keyword argument '{}' for builtin call '{}'!\n",
                    .{ next.data.KeywordArg.keyword, @tagName(builtin_type) });
                return Error.ArgumentMismatch;
            }
        }

        std.debug.print("After collecting kwargs:\n{}\n", .{ citation });
    } else {
        std.log.err(
            "Builtin call has no arguments!\n", .{});
        return Error.ArgumentMismatch;
    }

    return citation;
}
