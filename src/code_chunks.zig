const std = @import("std");
const ast = @import("ast.zig");
const DFS = @import("utils.zig").DepthFirstIterator;

pub const Language = enum {
    Unknown,
    Python,
    R,
    Julia,
    C,
    Cpp,

    pub inline fn match(language_name: []const u8) Language {
        var result: Language = undefined;
        if (language_name.len > 0) {
            var name_buf: [25]u8 = undefined;
            std.mem.copy(u8, name_buf[0..], language_name);
            const name = name_buf[0..language_name.len];
            // convert name to all lowercase
            for (name) |*byte| {
                byte.* = std.ascii.toLower(byte.*);
            }

            if (name.len == 1) {
                if (name[0] == 'r') {
                    result = .R;
                } else if (name[0] == 'c') {
                    result = .C;
                }
            } else if (std.mem.eql(u8, name, "python") or std.mem.eql(u8, name, "py")) {
                result = .Python;
            } else if (std.mem.eql(u8, name, "jl") or std.mem.eql(u8, name, "julia")) {
                result = .Julia;
            } else if (std.mem.eql(u8, name, "c++") or std.mem.eql(u8, name, "cpp")) {
                // TODO cpp compiler version
                result = .Cpp;
            } else {
                result = .Unknown;
            }
        } else {
            result = .Unknown;
        }

        return result;
    }
};

const python_helper = @embedFile("./lang_helpers/python.py");
const r_helper = @embedFile("./lang_helpers/R.r");

pub const CodeRunner = struct {
    code_datas: std.ArrayList(*ast.Node.CodeData),
    lang: Language,
    merged_code: std.ArrayList(u8),
    runner: *std.ChildProcess,
    out_buf: std.heap.ArenaAllocator,

    pub fn init(allocator: *std.mem.Allocator, language: Language, root_node: *ast.Node) !CodeRunner {
        var code_runner = CodeRunner{
            .code_datas = std.ArrayList(*ast.Node.CodeData).init(allocator),
            .lang = language,
            .merged_code = std.ArrayList(u8).init(allocator),
            .runner = undefined,
            .out_buf = std.heap.ArenaAllocator.init(allocator),
        };

        try code_runner.gather_code_blocks(root_node);
        return code_runner;
    }

    pub fn deinit(self: *CodeRunner) void {
        self.code_datas.deinit();
        self.merged_code.deinit();
        self.out_buf.deinit();
    }

    fn gather_code_blocks(self: *CodeRunner, root_node: *ast.Node) !void {
        var dfs = DFS(ast.Node, true).init(root_node);

        switch(self.lang) {
            .Python => try self.merged_code.appendSlice(python_helper),
            .R => try self.merged_code.appendSlice(r_helper),
            else => {},
        }

        // TODO make self.lang comptime so these switches won't be at runtime
        // or as comptime proc argument
        const lang = self.lang;
        while (dfs.next()) |node_info| {
            if (!node_info.is_end)
                continue;

            switch (node_info.data.data) {
                .FencedCode, .CodeSpan => |*data| {
                    if (data.language == lang and data.run) {
                        try self.code_datas.append(data);

                        try self.merged_code.appendSlice(data.code);
                        switch (self.lang) {
                            .Python => try self.merged_code.appendSlice(
                                "\n\nsys.stdout.real_flush()\nsys.stderr.real_flush()\n\n"),
                            .R => {
                                // using sink(connection) to divert stdout or stderr output
                                // to the passed connection
                                //
                                // sink() or sink(file = NULL) ends the last diversion
                                // (there is a diversion stack) of the specified type
                                // but calling sink twice for our stdout+err diversions warns
                                // about there not being a sink to remove
                                // can't reset the stdout_buf vector (functional language YAY)
                                // and re-assigning errors since there's a binding to out_tcon
                                // -> close and then re-open connection
                                // the connection needs to be close before sending the buf contents
                                // to stdout otherwise some content might not be written to the
                                // buf yet, since it only flushes once a \n is reached
                                try self.merged_code.appendSlice(
                                    \\
                                    \\sink()
                                    \\sink(type="message")
                                    \\close(out_tcon)
                                    \\close(err_tcon)
                                    \\write_to_con_with_length(stdout_buf, stdout())
                                    \\write_to_con_with_length(stderr_buf, stderr())
                                    \\stdout_buf <- vector("character")
                                    \\stderr_buf <- vector("character")
                                    \\out_tcon <- textConnection('stdout_buf', 'wr', local = TRUE)
                                    \\err_tcon <- textConnection('stderr_buf', 'wr', local = TRUE)
                                    \\sink(out_tcon)
                                    \\sink(err_tcon, type="message")
                                    \\
                                );
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        switch(self.lang) {
            .Python => try self.merged_code.appendSlice("sys.exit(0)"),
            .R => {
                // close textconnections
                try self.merged_code.appendSlice(
                    \\
                    \\sink()
                    \\sink(type="message")
                    \\close(err_tcon)
                    \\close(out_tcon)
                );
            },
            else => {},
        }

        std.debug.print(
            "Lang: {s} Code generated: \n{s}\n---\n", .{ @tagName(self.lang), self.merged_code.items });
    }

    pub fn run(self: *CodeRunner) !void {
        const allocator = &self.out_buf.allocator;
        const cmd = switch (self.lang) {
            .Python => &[_][]const u8{"python"},
            .R => &[_][]const u8{"D:\\Programs\\R-4.0.2\\bin\\R.exe", "--save", "--quiet", "--no-echo"},
            else => return,
        };
        self.runner = try std.ChildProcess.init(cmd, allocator);
        self.runner.stdin_behavior = .Pipe;
        self.runner.stdout_behavior = .Pipe;
        self.runner.stderr_behavior = .Pipe;

        // order important otherwise stdin etc. not initialized
        try self.runner.spawn();

        // write program code to stdin
        try self.runner.stdin.?.writer().writeAll(self.merged_code.items);
        self.runner.stdin.?.close();
        // has to be set to null otherwise the ChildProcess tries to close it again
        // and hits unreachable code
        self.runner.stdin = null;

        std.debug.print("Done writing to stdin!\n", .{});

        // might deadlock due to https://github.com/ziglang/zig/issues/6343
        // weirdly only WindowsTerminal seems to have a problem with it and stops
        // responding, cmd.exe works fine as does running it in a debugger
        const stdout = try self.runner.stdout.?.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
        errdefer allocator.free(stdout);
        std.debug.print("Done reading from stdout!\n", .{});
        const stderr = try self.runner.stderr.?.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
        errdefer allocator.free(stderr);
        std.debug.print("Done reading from stderr!\n", .{});

        _ = try self.runner.wait();
        std.debug.print("Done waiting on child!\n", .{});

        switch (self.lang) {
            .R => {
                self.assign_output_to_nodes_text(stdout, false);
                self.assign_output_to_nodes_text(stderr, true);
            },
            else => {
                self.assign_output_to_nodes_bin(stdout, false);
                self.assign_output_to_nodes_bin(stderr, true);
            },
        }
    }


    fn assign_output_to_nodes_bin(self: *CodeRunner, bytes: []const u8, comptime is_err: bool) void {
        var i: u32 = 0;
        var code_chunk: u16 = 0;
        while (i < bytes.len) {
            // first 4 bytes that contain chunk out length
            // const chunk_out_len = std.mem.readIntNative(u32, @ptrCast(*const [4]u8, &stdout[i]));
            // const chunk_out_len = std.mem.bytesToValue(u32, @ptrCast(*const [4]u8, &stdout[i]));
            // bytes slice has alignemnt of 1, casting to *u32 means changing alignment to 4
            // but only higher aligments coerce to lower ones so we have to use an alignCast
            // (which has a safety check in debug builds)
            // below errors out with "incorrect alignment" (unsure) since the []u8 is 1-aligned
            // and u32 is 4-aligned
            // const chunk_out_len = @ptrCast(*const u32, @alignCast(@alignOf(u32), &stdout[i])).*;
            // just specify that the *u32 is 1-aligned
            const chunk_out_len = @ptrCast(*align(1)const u32, &bytes[i]).*;
            var chunk_out: ?[]const u8 = null;
            if (chunk_out_len > 0) {
                chunk_out = bytes[i+4..i+4+chunk_out_len];
                std.debug.print("\nOUT:\n'''{s}'''\n----------\n", .{ chunk_out });
            }
            i += 4 + chunk_out_len;

            if (!is_err) {
                self.code_datas.items[code_chunk].stdout = chunk_out;
            } else {
                self.code_datas.items[code_chunk].stderr = chunk_out;
            }
            code_chunk += 1;
        }
    }

    fn assign_output_to_nodes_text(self: *CodeRunner, bytes: []const u8, comptime is_err: bool) void {
        var i: u32 = 0;
        var code_chunk: u16 = 0;
        while (i < bytes.len) {
            // chunk out length as text followed by ';'
            var text_len_start = i;
            while (bytes[i] != ';') : ( i += 1 ) {}
            var text_len_end = i;
            i += 1;  // skip ;
            const chunk_out_len = std.fmt.parseUnsigned(
                u32, bytes[text_len_start..text_len_end], 10) catch unreachable;

            var chunk_out: ?[]const u8 = null;
            if (chunk_out_len > 0) {
                chunk_out = bytes[i..i + chunk_out_len];
                std.debug.print("\nOUT:\n'''{s}'''\n----------\n", .{ chunk_out });
            }
            i += chunk_out_len;

            if (!is_err) {
                self.code_datas.items[code_chunk].stdout = chunk_out;
            } else {
                self.code_datas.items[code_chunk].stderr = chunk_out;
            }
            code_chunk += 1;

        }
    }
};
