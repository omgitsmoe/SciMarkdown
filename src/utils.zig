const std = @import("std");

// zig gets polymorphism/generics by using compile time functions that return a type
/// DFS Iterator that visits/emits Nodes twice, once on start and when closing/ending
/// skip_start_wo_children: skips is_end=false NodeInfo for items without children
pub fn DepthFirstIterator(
    comptime T: type,
    comptime skip_start_wo_children: bool
) type {
    return struct {
        const Self = @This();  // polymorphic type
        // need struct to be able to signal nodes starting/ending for
        // postorder traversal
        pub const NodeInfo = struct {
            data: *T,
            is_end: bool,
        };

        start: *T,
        next_item: ?NodeInfo,

        pub fn init(start: *T) Self {
            // TODO fix after this issue gets resolved:
            // Designated init of optional struct field segfaults in debug mode
            // https://github.com/ziglang/zig/issues/5573
            // .data will always be null in code below even though start can't be
            // removing the .start field will result in Segfault when creating the NodeInfo struct
            // see test3.zig
            // initializing it outside the struct succeeds
            var next_item = NodeInfo{
                    .data = start,
                    .is_end = false,
            };
            var dfs = Self{
                .start = start,
                .next_item = undefined,
                // .next_item = NodeInfo{
                //     .data = start,
                //     .is_end = false,
                // },
            };
            dfs.next_item = next_item;

            return dfs;
        }

        // adapted from: https://github.com/kivikakk/koino/blob/main/src/ast.zig by kivikakk
        /// NOTE: only a .is_end = false is emitted for the starting node (no is_end=true)!
        pub fn next(self: *Self) ?NodeInfo {
            const item = self.next_item orelse return null;

            if (!item.is_end) {
                if (item.data.first_child) |child| {
                    if (skip_start_wo_children) {
                        self.next_item = NodeInfo{
                            .data = child,
                            .is_end = if (child.first_child == null) true else false
                        };
                    } else {
                        self.next_item = NodeInfo{ .data = child, .is_end = false };
                    }
                } else {
                    // end node since it doesn't have children
                    self.next_item = NodeInfo{ .data = item.data, .is_end = true };
                }
            } else {
                if (item.data == self.start) {
                    // finish when reaching starting node
                    // TODO also emit is_end for start node here?
                    return null;
                } else if (item.data.next) |sibling| {
                    // current node has been completely traversed -> q sibling

                    // skip_start_sibling_wo_children is comptime known (comptime error if not)
                    // and Zig implicitly inlines if expressions when the condition is
                    // known at compile-time
                    // -> one of these branches will not be part of the runtime function
                    // depending on the bool passed to DepthFirstIterator
                    // cant use comptime { }
                    // since it forces the entire expression (inside {}) to be compile time
                    // (which fails on sibling.first_child etc.)
                    // so we just have to trust that this gets comptime evaluated (also called
                    // inlined in Zig) since skip_start_sibling_wo_children is comptime
                    if (skip_start_wo_children) {
                        // NOTE: checking if sibling is also an end node that doesn't have children
                        // so we don't get one is_end=true and one false version
                        self.next_item = NodeInfo{
                            .data = sibling,
                            .is_end = if (sibling.first_child == null) true else false,
                        };
                    } else {
                        self.next_item = NodeInfo{ .data = sibling, .is_end = false };
                    }
                } else if (item.data.parent) |parent| {
                    // no siblings and no children (since is_end is false) -> signal
                    // parent node has been traversed completely
                    self.next_item = NodeInfo{ .data = parent, .is_end = true };
                } else {
                    unreachable;
                }
            }

            return item;
        }
    };
}

/// intialize a union with a PayloadType that is known at comptime, but the tag and value only
/// being known at runtime
pub fn unionInitTagged(comptime U: type, tag: std.meta.Tag(U), comptime PayloadType: type, val: anytype) U {
    const uT = @typeInfo(U).Union;
    inline for (uT.fields) |union_field, enum_i| {
        // field types don't match -> otherwise @unionInit compile error
        if (union_field.field_type != PayloadType)
            continue;
        // check for active tag
        if (enum_i == @enumToInt(tag)) {
            // @compileLog("unionfield name ", union_field.name);
            // @compileLog("enum i ", enum_i, "tag ", @enumToInt(tag));
            return @unionInit(U, union_field.name, val);
        }
    }
    // without this return type might be void
    unreachable;
}

// src: https://github.com/ziglang/zig/issues/9271 by dbandstra
pub fn unionPayloadPtr(comptime T: type, union_ptr: anytype) ?*T {
    const U = @typeInfo(@TypeOf(union_ptr)).Pointer.child;
    inline for (@typeInfo(U).Union.fields) |field, i| {
        if (field.field_type != T)
            continue;
        std.debug.print("Ptrint: {d}\n", .{ @enumToInt(union_ptr.*) });
        if (@enumToInt(union_ptr.*) == i)
            return &@field(union_ptr, field.name);
    }
    return null;
}

pub fn unionSetPayload(comptime T: type, union_ptr: anytype, value: T) void {
    const U = @typeInfo(@TypeOf(union_ptr)).Pointer.child;
    inline for (@typeInfo(U).Union.fields) |field, i| {
        if (field.field_type != T)
            continue;
        if (@enumToInt(union_ptr.*) == i) {
            @field(union_ptr, field.name) = value;
            break;
        }
    } else {
        unreachable;
    }
}

/// all of the string is_.. functions are ascii only!!
pub inline fn is_alpha(char: u8) bool {
    if ((char >= 'A' and char <= 'Z') or
        (char >= 'a' and char <= 'z')) {
        return true;
    } else {
        return false;
    }
}

pub inline fn is_num(char: u8) bool {
    if (char >= '0' and char <= '9') {
        return true;
    } else {
        return false;
    }
}

pub inline fn is_alphanum(char: u8) bool {
    if (is_alpha(char) or is_num(char)) {
        return true;
    } else {
        return false;
    }
}

pub inline fn is_lowercase(char: u8) bool {
    if (char >= 'a' and char <= 'z') {
        return true;
    } else {
        return false;
    }
}

pub inline fn is_uppercase(char: u8) bool {
    if (char >= 'A' and char <= 'Z') {
        return true;
    } else {
        return false;
    }
}

pub inline fn is_end_of_line(char: u8) bool {
    if ((char == '\r') or (char == '\n')) {
        return true;
    } else {
        return false;
    }
}

pub inline fn is_space_or_tab(char: u8) bool {
    if ((char == ' ') or (char == '\t')) {
        return true;
    } else {
        return false;
    }
}

pub inline fn is_whitespace(char: u8) bool {
    if (is_space_or_tab(char) or is_end_of_line(char)) {
        return true;
    } else {
        return false;
    }
}
