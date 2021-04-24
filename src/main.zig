const std = @import("std");

const Parser = @import("parser.zig").Parser;
const HTMLGenerator = @import("html.zig").HTMLGenerator;
const CodeRunner = @import("code_chunks.zig").CodeRunner;
const run_citeproc = @import("cite.zig").run_citeproc;

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

    var code_runner = try CodeRunner.init(allocator, .Python, parser.current_document);
    defer code_runner.deinit();
    try code_runner.run();

    var r_code_runner = try CodeRunner.init(allocator, .R, parser.current_document);
    defer r_code_runner.deinit();
    try r_code_runner.run();

    const bib_entries = try run_citeproc(&parser.node_arena.allocator, parser.citations.items);
    if (parser.bibliography) |bib| {
        for (bib_entries) |entry| {
            bib.append_child(entry);
        }
    }

    var html_gen = HTMLGenerator.init(allocator, parser.current_document, parser.label_ref_map);
    const html_out = try html_gen.generate();
    // std.debug.print("{}\n", .{ html_out });

    const file = try std.fs.cwd().createFile(
        "test.html",
        // truncate: reduce file to length 0 if it exists
        .{ .read = true, .truncate = true },
    );
    defer file.close();

    try file.writeAll(html_out);
}
