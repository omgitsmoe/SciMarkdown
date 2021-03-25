const std = @import("std");

const Parser = @import("parser.zig").Parser;

pub fn main() !void {
    // gpa optimized for safety over performance; can detect leaks, double-free and use-after-free
    // takes a config struct (empty here .{})
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        // print takes a format string and a struct
        // prints automatically std.debug.print("Leak detected: {}\n", .{leaked});
    }

    const allocator = &gpa.allocator;
    // Caller must call argsFree on result
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    return mainArgs(allocator, args);
}

// errorset!return_type
// !void same as anyerror which is the global error set
pub fn mainArgs(allocator: *std.mem.Allocator, args: []const []const u8) !void {
    if (args.len <= 1) {
        std.log.info("Usage: pistis <index-filename>", .{});
        std.process.exit(1);
    }

    const root_file_name = args[1];

    var parser: Parser = try Parser.init(allocator, root_file_name);
    defer parser.deinit();
    try parser.parse();
}
