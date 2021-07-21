const std = @import("std");
const log = std.log;
const builtin = @import("builtin");

const Parser = @import("parser.zig").Parser;
const HTMLGenerator = @import("html.zig").HTMLGenerator;
const CodeRunner = @import("code_chunks.zig").CodeRunner;
const cite = @import("cite.zig");
const run_citeproc = cite.run_citeproc;
const csl = @import("csl_json.zig");
const ast = @import("ast.zig");

const clap = @import("zig-clap");

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
    // const allocator = std.heap.page_allocator;

    // We can use `parseParam` to parse a string to a `Param(Help)`
    @setEvalBranchQuota(2000);
    const params = comptime [_]clap.Param(clap.Help){
        clap.parseParam("-h, --help                       Display this help and exit.") catch unreachable,
        clap.parseParam("-o, --out <FILENAME>             Output filename.") catch unreachable,
        clap.parseParam("-r, --references <FILENAME>      Path to references file (BibLaTeX or CSL-JSON).") catch unreachable,
        clap.parseParam("-s, --citation-style <FILENAME>  Path to CSL file.") catch unreachable,
        clap.parseParam("-l, --locale <LOCALE>  Specify locale as BCP 47 language tag.") catch unreachable,
        clap.parseParam("--write-bib-conversion           Whether to write out the converted .bib file as CSL-JSON") catch unreachable,
        // clap.parseParam(
        //     "-s, --string <STR>...  An option parameter which can be specified multiple times.") catch unreachable,
        clap.parseParam("<IN-FILE>") catch unreachable,
    };

    // Initalize our diagnostics, which can be used for reporting useful errors.
    // This is optional. You can also pass `.{}` to `clap.parse` if you don't
    // care about the extra information `Diagnostics` provides.
    var diag = clap.Diagnostic{};

    // TODO use parseEx since using clap.parse directly is bugged even though
    // it's just a thin wrapper https://github.com/Hejsil/zig-clap/issues/43
    // somehow the cause of the issue is parseEx reusing OsIterator's allocator
    // var args = clap.parse(clap.Help, &params, .{ .diagnostic = &diag, .allocator = allocator }) catch |err| {
    //     // Report useful error and exit
    //     diag.report(std.io.getStdErr().writer(), err) catch {};
    //     return err;
    // };
    // defer args.deinit();

    // We then initialize an argument iterator. We will use the OsIterator as it nicely
    // wraps iterating over arguments the most efficient way on each os.
    var iter = try clap.args.OsIterator.init(allocator);
    defer iter.deinit();

    var args = clap.parseEx(clap.Help, &params, &iter, .{
        .allocator = allocator,
        .diagnostic = &diag,
    }) catch |err| {
        // Report useful error and exit
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer args.deinit();

    if (args.flag("--help") or args.positionals().len != 1) {
        const writer = std.io.getStdErr().writer();
        if (builtin.os.tag == .windows) {
            try writer.writeAll("Usage: scimd.exe ");
        } else {
            try writer.writeAll("Usage: scimd ");
        }

        try clap.usage(writer, &params);
        try writer.writeByte('\n');
        try clap.help(writer, &params);

        std.process.exit(1);
    }

    const pos_args = args.positionals();
    const in_file = pos_args[0];
    log.debug("In file: {s}\n", .{in_file});

    var out_filename: []const u8 = undefined;
    if (args.option("--out")) |out| {
        log.debug("Out direct: {s}\n", .{out});
        out_filename = out;
    } else {
        const base = std.fs.path.basename(in_file);
        const ext = std.fs.path.extension(base);
        const new_ext = ".html";
        // will be leaked but we need it till the end anyway
        const out_buf = try allocator.alloc(u8, base.len - ext.len + new_ext.len);
        std.mem.copy(u8, out_buf, base[0 .. base.len - ext.len]);
        std.mem.copy(u8, out_buf[base.len - ext.len ..], new_ext);

        out_filename = out_buf;
    }

    log.debug("Out file: {s}\n", .{out_filename});

    var ref_file: ?[]const u8 = null;
    if (args.option("--references")) |ref_fn| {
        ref_file = ref_fn;
    }
    var csl_file: ?[]const u8 = null;
    if (args.option("--citation-style")) |csl_fn| {
        csl_file = csl_fn;
    }
    var csl_locale: ?[]const u8 = null;
    if (args.option("--locale")) |csl_loc| {
        csl_locale = csl_loc;
    }

    var parser: Parser = try Parser.init(allocator, in_file);
    defer parser.deinit();
    try parser.parse();

    // execute code for found languages
    var run_lang_iter = parser.run_languages.iterator();
    var runners = std.ArrayList(CodeRunner).init(allocator);
    defer runners.deinit();
    while (run_lang_iter.next()) |lang| {
        var code_runner = try runners.addOne();
        code_runner.* = try CodeRunner.init(allocator, lang, parser.current_document);
        // TODO still go for checking if the exe is available manually?
        // unfortunately not possible to switch on error sets yet:
        // https://github.com/ziglang/zig/issues/2473
        code_runner.run() catch |err| {
            log.err("Running {s} code chunks with executable '{s}' failed with error: {s}\n",
                    .{ @tagName(lang), "TODO", @errorName(err) });
        };
    }
    defer {
        for (runners.items) |*runner| {
            runner.deinit();
        }
    }

    if (parser.citations.items.len > 0 and (ref_file != null or csl_file != null)) {
        if (ref_file != null and csl_file != null and csl_locale != null) {
            const write_conversion = args.flag("--write-bib-conversion");
            const csl_json_result = try cite.csl_items_from_file(allocator, ref_file.?, write_conversion);
            defer csl_json_result.arena.deinit();

            const bib_entries = run_citeproc(
                &parser.node_arena.allocator, parser.citations.items, csl_json_result.items,
                csl_file.?, csl_locale.?) catch |err| blk: {
                    log.err("Running citeproc failed with error: {s}\n", .{ @errorName(err) });
                    log.err("Citation processing was aborted!", .{});

                    break :blk &[_]*ast.Node{};
            };
            if (parser.bibliography) |bib| {
                for (bib_entries) |entry| {
                    bib.append_child(entry);
                }
            }
        } else {
            log.warn(
                "Both a references file (BibLaTeX or CSL-JSON) as well as CSL file " ++
                "and a locale is needed to process citations!", .{});
        }
    }

    var html_gen = HTMLGenerator.init(allocator, parser.current_document, parser.label_node_map);

    var file: std.fs.File = undefined;
    if (std.fs.path.isAbsolute(out_filename)) {
        file = try std.fs.createFileAbsolute(
            out_filename,
            .{ .read = true, .truncate = true },
        );
    } else {
        file = try std.fs.cwd().createFile(
            out_filename,
            // truncate: reduce file to length 0 if it exists
            .{ .read = true, .truncate = true },
        );
    }
    defer file.close();

    var out = std.io.bufferedWriter(file.writer());
    try html_gen.write(@TypeOf(out), out.writer());
    try out.flush();
}
