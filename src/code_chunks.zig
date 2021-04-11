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

        // const path = try fs.realpathAlloc(code_datas.allocator, "./lang_helpers");
        // defer code_datas.allocator.free(path);

        switch(self.lang) {
            .Python => try self.merged_code.appendSlice(python_helper),
            else => {},
        }

        const lang = self.lang;
        while (dfs.next()) |node_info| {
            if (!node_info.is_end)
                continue;

            switch (node_info.data.data) {
                .FencedCode => |*data| {
                    if (data.language == lang) {
                        try self.code_datas.append(data);

                        try self.merged_code.appendSlice(data.code);
                        switch (self.lang) {
                            .Python => try self.merged_code.appendSlice(
                                "\n\nsys.stdout.real_flush()\nsys.stderr.real_flush()\n\n"),
                            else => {},
                        }
                    }
                },
                // .CodeSpan => {
                // },
                else => {},
            }
        }

        switch(self.lang) {
            .Python => try self.merged_code.appendSlice("sys.exit(0)"),
            else => {},
        }

        std.debug.print("Lang: {} Code generated: \n{}\n---\n", .{ @tagName(self.lang), self.merged_code.items });
    }

    pub fn run(self: *CodeRunner) !void {
        // caller owns result.stdout and result.stderr memory
        // can't write to stdin this way
        // const result = try std.ChildProcess.exec(.{
        //     .allocator = self.code_datas.allocator,
        //     .argv = &[_][]const u8{ "python" },
        //     .max_output_bytes = 1_000_000,
        // });
        const allocator = &self.out_buf.allocator;
        self.runner = try std.ChildProcess.init(
            &[_][]const u8{"python"}, allocator);
        self.runner.stdin_behavior = .Pipe;
        self.runner.stdout_behavior = .Pipe;
        self.runner.stderr_behavior = .Pipe;

        // order important otherwise stdin etc. not initialized
        try self.runner.spawn();

        // write program code to stdin
        // TODO close stdin or sth?; as it is right now we lock on waiting for the python interpreter
        try self.runner.stdin.?.writer().writeAll(self.merged_code.items);
        self.runner.stdin.?.close();
        self.runner.stdin = null;
        // doesn't work try self.runner.stdin.?.writer().writeByte(0);
        // closing stdin also doesn't work since the ChildProcess tries closing it later which
        // causes an error
        // self.runner.stdin.?.close();

        const stdout = try self.runner.stdout.?.reader().readAllAlloc(allocator, 50 * 1024);
        errdefer allocator.free(stdout);
        const stderr = try self.runner.stderr.?.reader().readAllAlloc(allocator, 50 * 1024);
        errdefer allocator.free(stderr);

        _ = try self.runner.wait();

        // skip first 4 bytes that contain chunk out length
        std.debug.print("\nOUT:\n{}----------\n", .{ stdout[4..] });
        std.debug.print("\nERR:\n{}----------\n", .{ stderr });
    }
};
