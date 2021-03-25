const std = @import("std");

// zig gets polymorphism/generics by using compile time functions that return a type
pub fn DepthFirstIterator(comptime T: type) type {
    return struct {
        const Self = @This();  // polymorphic type
        const Queue = std.TailQueue(T);
        const QNode = Queue.Node;  // node type used in TailQueue

        // can't use an ArrayList with this since the ptrs get invalidated on resize
        node_buf: std.heap.ArenaAllocator,
        q: Queue,

        pub fn init(allocator: *std.mem.Allocator, start: T) !Self {
            var dfs = Self{
                .node_buf = std.heap.ArenaAllocator.init(allocator),
                .q = Queue{},
            };

            const added = try dfs.node_buf.allocator.create(QNode);
            added.* = QNode{ .data = start };
            dfs.q.prepend(added);

            return dfs;
        }

        pub fn deinit(self: *Self) void {
            self.node_buf.deinit();
        }

        pub fn next(self: *Self) !?T {
            if (self.q.len > 0) {
                // we can use .? (short for "orelse unreachable") since we checked that q has items
                const current_item = self.q.popFirst().?;

                // queue the children
                if (current_item.data.first_child) |first_child| {
                    var current_child = first_child;
                    // in order to preserve the child order we have to use TailQueue.insertAfter
                    // the last queued child for every child beyond the first
                    var last_queued = try self.queue_left(QNode{ .data = first_child });

                    while (current_child.next) |child| {
                        last_queued = try self.queue_after(last_queued, QNode{ .data = child });
                        current_child = child;
                    }
                }

                return current_item.data;
            } else {
                return null;
            }
        }

        fn queue(self: *Self, node: QNode) !*QNode {
            // TODO look up in stdlib how ArenaAllocator is used (storing allocator separate?)
            const new = try self.node_buf.allocator.create(QNode);
            new.* = node;
            self.q.append(new);
            return new;
        }

        fn queue_after(self: *Self, after: *QNode, node: QNode) !*QNode {
            const new = try self.node_buf.allocator.create(QNode);
            new.* = node;
            self.q.insertAfter(after, new);
            return new;
        }

        fn queue_left(self: *Self, node: QNode) !*QNode {
            const new = try self.node_buf.allocator.create(QNode);
            new.* = node;
            self.q.prepend(new);
            return new;
        }
    };
}
