const std = @import("std");

// zig gets polymorphism/generics by using compile time functions that return a type
pub fn DepthFirstIterator(comptime T: type) type {
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
        pub fn next(self: *Self) ?NodeInfo {
            const item = self.next_item orelse return null;

            if (!item.is_end) {
                if (item.data.first_child) |child| {
                    self.next_item = NodeInfo{ .data = child, .is_end = false };
                } else {
                    // end node since it doesn't have children
                    self.next_item = NodeInfo{ .data = item.data, .is_end = true };
                }
            } else {
                if (item.data == self.start) {
                    // finish when reaching starting node
                    return null;
                } else if (item.data.next) |sibling| {
                    // current node has been completely traversed -> q sibling
                    // NOTE: checking if sibling is also an end node that doesn't have children
                    // so we don't get one is_end=true and one false version
                    // TODO @Robustness is this a good idea?
                    self.next_item = NodeInfo{
                        .data = sibling,
                        .is_end = if (sibling.first_child == null) true else false,
                    };
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
