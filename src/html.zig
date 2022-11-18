const std = @import("std");
const log = std.log;

const DFS = @import("utils.zig").DepthFirstIterator;

const ast = @import("ast.zig");
const Node = ast.Node;
const NodeKind = ast.NodeKind;

pub const HTMLGenerator = struct {
    allocator: *std.mem.Allocator,
    start_node: *Node,
    label_node_map: std.StringHashMap(*Node.NodeData),

    pub const Error = error{
        ReferenceLabelNotFound,
        FormatBufferTooSmall,
    };

    /// label_node_map is taken from the parser, but HTMLGenerator doesn't take ownership
    pub fn init(
        allocator: *std.mem.Allocator,
        start_node: *Node,
        label_node_map: std.StringHashMap(*Node.NodeData),
    ) HTMLGenerator {
        return HTMLGenerator{
            .allocator = allocator,
            .start_node = start_node,
            .label_node_map = label_node_map,
        };
    }

    inline fn report_error(comptime err_msg: []const u8, args: anytype) void {
        log.err(err_msg, args);
    }

    /// If out_stream is a bufferedWriter the caller is expected to call .flush()
    /// since the other out_streams don't have that method.
    // need to pass the writertype if we want an explicit error set by merging them
    pub fn write(
        self: *HTMLGenerator,
        comptime WriterType: type,
        out_stream: anytype,
    ) (Error || WriterType.Error)!void {
        var dfs = DFS(Node, true).init(self.start_node);

        try out_stream.writeAll(
            \\<html>
            \\<head>
            \\<meta charset="utf-8">
            \\<meta name="viewport" content="width=device-width, initial-scale=1.0">
            \\<script id="MathJax-script" async src="vendor/mathjax-3.1.2/tex-svg-full.js"></script>
            \\<link type="text/css" rel="stylesheet" href="html/style.css">
            \\</head>
            \\<body>
            \\<div class="content-wrapper">
        );

        var in_compact_list = false;
        while (dfs.next()) |node_info| {
            // bug in zig compiler: if a switch prong (without {}) doesn't handle an error
            // the start of the switch is reported as ignoring the error
            // std.debug.print("Node (end: {}): {}\n", .{ node_info.is_end, node_info.data.data });
            switch (node_info.data.data) {
                .Document => continue,
                .Undefined, .Import => unreachable,
                // blocks like thematic break should never get both a start and end NodeInfo
                // since they can't contain other blocks
                .ThematicBreak => try out_stream.writeAll("<hr/>\n"),
                .Heading => |heading| {
                    var hbuf: [4]u8 = undefined;
                    _ = std.fmt.bufPrint(
                        &hbuf,
                        "h{}>\n",
                        .{heading.level},
                    ) catch return Error.FormatBufferTooSmall;
                    if (node_info.is_end) {
                        try out_stream.writeAll("</");
                    } else {
                        try out_stream.writeByte('<');
                    }
                    try out_stream.writeAll(&hbuf);
                },
                .UnorderedList => |list| {
                    if (!node_info.is_end) {
                        in_compact_list = if (list.blank_lines > 0) false else true;
                        try out_stream.writeAll("<ul>\n");
                    } else {
                        try out_stream.writeAll("</ul>\n");
                        in_compact_list = HTMLGenerator.get_parents_list_compact_status(node_info.data);
                    }
                },
                .OrderedList => |list| {
                    if (!node_info.is_end) {
                        in_compact_list = if (list.blank_lines > 0) false else true;
                        if (list.start_num == 1 and list.ol_type == '1') {
                            try out_stream.writeAll("<ol>\n");
                        } else {
                            var numbuf: [4]u8 = undefined;
                            var numslice = std.fmt.bufPrint(
                                &numbuf,
                                "{}",
                                .{list.start_num},
                            ) catch return Error.FormatBufferTooSmall;
                            try out_stream.writeAll("<ol start=\"");
                            try out_stream.writeAll(numslice);
                            try out_stream.writeAll("\" type=\"");
                            try out_stream.writeByte(list.ol_type);
                            try out_stream.writeAll("\">\n");
                        }
                    } else {
                        try out_stream.writeAll("</ol>\n");
                        in_compact_list = HTMLGenerator.get_parents_list_compact_status(node_info.data);
                    }
                },
                .UnorderedListItem, .OrderedListItem => {
                    if (!node_info.is_end) {
                        try out_stream.writeAll("<li>\n");
                    } else {
                        try out_stream.writeAll("</li>\n");
                    }
                },
                .FencedCode => |code| {
                    if (!node_info.is_end) continue;

                    // no \n since the whitespace is printed verbatim in a <pre> env
                    try out_stream.writeAll("<pre><code>");
                    try out_stream.writeAll(code.code);
                    try out_stream.writeAll("</code></pre>\n");

                    if (code.stdout) |out| {
                        try out_stream.writeAll("Output:");
                        try out_stream.writeAll("<pre>\n");
                        try out_stream.writeAll(out);
                        try out_stream.writeAll("</pre>\n");
                    }
                    if (code.stderr) |err| {
                        try out_stream.writeAll("Warnings:");
                        try out_stream.writeAll("<pre>\n");
                        try out_stream.writeAll(err);
                        try out_stream.writeAll("</pre>\n");
                    }
                },
                .MathInline => |math| {
                    // \(...\) are the default MathJax inline delimiters instead of $...$
                    try out_stream.writeAll("\\(");
                    try out_stream.writeAll(math.text);
                    try out_stream.writeAll("\\)");
                },
                .MathMultiline => |math| {
                    if (!node_info.is_end) continue;
                    try out_stream.writeAll("$$");
                    try out_stream.writeAll(math.text);
                    try out_stream.writeAll("$$\n");
                },
                .BlockQuote => {
                    if (!node_info.is_end) {
                        try out_stream.writeAll("<blockquote>\n");
                    } else {
                        try out_stream.writeAll("</blockquote>\n");
                    }
                },
                .Paragraph => {
                    if (!in_compact_list) {
                        if (!node_info.is_end) {
                            try out_stream.writeAll("<p>\n");
                        } else {
                            try out_stream.writeAll("</p>\n");
                        }
                    }
                },
                .BibEntry => {
                    if (!node_info.is_end) {
                        try out_stream.writeAll("<p>\n");
                    } else {
                        try out_stream.writeAll("</p>\n");
                    }
                },
                .Emphasis => {
                    if (!node_info.is_end) {
                        try out_stream.writeAll("<em>");
                    } else {
                        try out_stream.writeAll("</em>");
                    }
                },
                .StrongEmphasis => {
                    if (!node_info.is_end) {
                        try out_stream.writeAll("<strong>");
                    } else {
                        try out_stream.writeAll("</strong>");
                    }
                },
                .Strikethrough => {
                    if (!node_info.is_end) {
                        try out_stream.writeAll("<strike>");
                    } else {
                        try out_stream.writeAll("</strike>");
                    }
                },
                .Superscript => {
                    if (!node_info.is_end) {
                        try out_stream.writeAll("<sup>");
                    } else {
                        try out_stream.writeAll("</sup>");
                    }
                },
                .Subscript => {
                    if (!node_info.is_end) {
                        try out_stream.writeAll("<sub>");
                    } else {
                        try out_stream.writeAll("</sub>");
                    }
                },
                .SmallCaps => {
                    if (!node_info.is_end) {
                        try out_stream.writeAll("<span style=\"font-variant: small-caps;\">");
                    } else {
                        try out_stream.writeAll("</span>");
                    }
                },
                .Underline => {
                    if (!node_info.is_end) {
                        try out_stream.writeAll("<u>");
                    } else {
                        try out_stream.writeAll("</u>");
                    }
                },
                .CodeSpan => |code| {
                    if (code.stdout) |out| {
                        try out_stream.writeAll(out);
                    } else {
                        try out_stream.writeAll("<code>");
                        try out_stream.writeAll(code.code);
                        try out_stream.writeAll("</code>");
                    }
                },
                .Link => |link| {
                    // TODO move this into a post pass after the frontend?
                    var link_url: []const u8 = undefined;
                    var link_title: ?[]const u8 = undefined;
                    if (link.url) |url| {
                        link_url = url;
                        link_title = link.title;
                    } else {
                        // look up reference by label; must have one if url is null
                        // returns optional ptr to entry
                        const maybe_ref = self.label_node_map.get(link.label.?);
                        if (maybe_ref) |ref| {
                            link_url = ref.LinkRef.url.?;
                            link_title = ref.LinkRef.title;
                        } else {
                            HTMLGenerator.report_error(
                                "No reference definition could be found for label '{s}'!\n",
                                .{link.label.?},
                            );
                            return Error.ReferenceLabelNotFound;
                        }
                    }

                    if (!node_info.is_end) {
                        try out_stream.writeAll("<a href=\"");
                        try out_stream.writeAll(link_url);
                        try out_stream.writeByte('"');
                        if (link_title) |title| {
                            try out_stream.writeAll("title=\"");
                            try out_stream.writeAll(title);
                            try out_stream.writeByte('"');
                        }
                        try out_stream.writeByte('>');
                    } else {
                        try out_stream.writeAll("</a>");
                    }
                },
                .Image => |img| {
                    var img_url: []const u8 = undefined;
                    var img_title: ?[]const u8 = undefined;
                    if (img.url) |url| {
                        img_url = url;
                        img_title = img.title;
                    } else {
                        // look up reference by label; must have one if url is null
                        // returns optional ptr to entry
                        const maybe_ref = self.label_node_map.get(img.label.?);
                        if (maybe_ref) |ref| {
                            img_url = ref.LinkRef.url.?;
                            img_title = ref.LinkRef.title;
                        } else {
                            HTMLGenerator.report_error(
                                "No reference definition could be found for label '{s}'!\n",
                                .{img.label.?},
                            );
                            return Error.ReferenceLabelNotFound;
                        }
                    }

                    try out_stream.writeAll("<img src=\"");
                    try out_stream.writeAll(img_url);
                    try out_stream.writeAll("\" alt=\"");
                    try out_stream.writeAll(img.alt);
                    try out_stream.writeAll("\"");
                    if (img_title) |title| {
                        try out_stream.writeAll(" title=\"");
                        try out_stream.writeAll(title);
                        try out_stream.writeAll("\"");
                    }
                    try out_stream.writeAll(" />");
                },
                .BuiltinCall => |call| {
                    if (!node_info.is_end)
                        continue;

                    switch (call.builtin_type) {
                        // TODO fix for nodes like e.g. FencedCode, Heading
                        .label => {
                            try out_stream.writeAll("<span id=\"");
                            try out_stream.writeAll(call.result.?.label);
                            try out_stream.writeAll("\"></span>");
                        },
                        .ref => {
                            const maybe_node = self.label_node_map.get(call.result.?.ref);
                            if (maybe_node) |node| {
                                try out_stream.writeAll("<a href=\"#");
                                try out_stream.writeAll(call.result.?.ref);
                                try out_stream.writeAll("\">");
                                try out_stream.writeAll(@tagName(node.*));
                                try out_stream.writeAll("</a>");
                            } else {
                                HTMLGenerator.report_error(
                                    "No corresponding label could be found for ref '{s}'!\n",
                                    .{call.result.?.ref},
                                );
                                return Error.ReferenceLabelNotFound;
                            }
                        },
                        else => {},
                    }
                },
                .HardLineBreak => try out_stream.writeAll("<br/>\n"),
                .SoftLineBreak => try out_stream.writeByte('\n'),
                .Text => |text| {
                    if (node_info.data.first_child) |fc| {
                        log.debug("Text node has child: {}\n", .{fc.data});
                    }
                    try out_stream.writeAll(text.text);
                },
                else => continue,
            }
        }

        try out_stream.writeAll("</div></body>\n</html>");
    }

    /// assumes current_list.parent is not null
    fn get_parents_list_compact_status(current_list: *Node) bool {
        // restore parent list's compact status if there is one
        return switch (current_list.parent.?.data) {
            NodeKind.OrderedListItem => blk: {
                // first parent is item, second is list itself
                break :blk current_list.parent.?.parent.?.data.OrderedList.blank_lines == 0;
            },
            NodeKind.UnorderedListItem => blk: {
                // first parent is item, second is list itself
                break :blk current_list.parent.?.parent.?.data.UnorderedList.blank_lines == 0;
            },
            // return true so paragraphs get rendered normally everywhere else
            else => false,
        };
    }
};
