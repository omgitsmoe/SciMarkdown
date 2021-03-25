const std = @import("std");

// zig gets polymorphism/generics by using compile time functions that return a type
pub fn DepthFirstIterator(comptime T: type) type {
    return struct {
        const Self = @This();  // polymorphic type
        const Queue = std.TailQueue(*T);
        const QNode = Queue.Node;  // node type used in TailQueue

        allocator: *std.mem.Allocator,
        node_buf: std.ArrayList(QNode),
        q: Queue,

        pub fn init(allocator: *std.mem.Allocator, start: *T) !Self {
            var dfs = Self{
                .allocator = allocator,
                .node_buf = std.ArrayList(QNode).init(allocator),
                .q = Queue{},
            };

            const added = try dfs.node_buf.addOne();
            added.* = QNode{ .data = start };
            dfs.q.append(added);

            return dfs;
        }

        pub fn deinit(self: *Self) void {
            self.node_buf.deinit();
        }

        pub fn next(self: *Self) ?*T {
            if (self.q.len > 0) {
                const current_item = self.q.popFirst();

                // queue the children
                if (current_item.data.first_child) |first_child| {
                    var current_child = first_child;
                    self.queue_left(QNode{ .data = first_child });

                    while (current_child.next) |child| {
                        self.queue_left(QNode{ .data = child });
                        current_child = child;
                    }
                }

                return current_item.data;
            } else {
                return null;
            }
        }

        fn queue(self: *Self, node: QNode) !void {
            const new = try self.q.addOne();
            new.* = node;
            self.q.append(new);
        }

        fn queue_left(self: *Self, node: QNode) !void {
            const new = try self.q.addOne();
            new.* = node;
            self.q.prepend(new);
        }
    };
}
