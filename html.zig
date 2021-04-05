const std = @import("std");

const DFS = @import("utils.zig").DepthFirstIterator;

const ast = @import("ast.zig");
const Node = ast.Node;
const NodeKind = ast.NodeKind;

pub const HTMLGenerator = struct {
    allocator: *std.mem.Allocator,
    html_buf: std.ArrayList(u8),
    start_node: *Node,
    label_ref_map: std.StringHashMap(*Node.LinkData),

    pub const Error = error {
        OutOfMemory,
        ReferenceLabelNotFound,
        FormatBufferTooSmall,
    };

    /// label_ref_map is taken from the parser, but HTMLGenerator doesn't take ownership
    pub fn init(
        allocator: *std.mem.Allocator,
        start_node: *Node,
        label_ref_map: std.StringHashMap(*Node.LinkData)
    ) !HTMLGenerator {
        return HTMLGenerator{
            .allocator = allocator,
            .html_buf = std.ArrayList(u8).init(allocator),
            .start_node = start_node,
            .label_ref_map = label_ref_map,
        };
    }

    inline fn report_error(comptime err_msg: []const u8, args: anytype) void {
        std.log.err(err_msg, args);
    }

    pub fn generate(self: *HTMLGenerator) Error![]const u8 {
        var dfs = DFS(Node, true).init(self.start_node);

        try self.html_buf.appendSlice(
            \\<html>
            \\<head>
            \\<meta charset="utf-8">
            \\<meta name="viewport" content="width=device-width, initial-scale=1.0">
            \\</head>
            \\<body>
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
                .ThematicBreak => try self.html_buf.appendSlice("<hr/>\n"),
                .Heading => |heading| {
                    var hbuf: [4]u8 = undefined;
                    _ = std.fmt.bufPrint(&hbuf, "h{}>\n", .{ heading.level })
                        catch return Error.FormatBufferTooSmall;
                    if (node_info.is_end) {
                        try self.html_buf.appendSlice("</");
                    } else {
                        try self.html_buf.append('<');
                    }
                    try self.html_buf.appendSlice(&hbuf);
                },
                .UnorderedList => |list| {
                    if (!node_info.is_end) {
                        in_compact_list = if (list.blank_lines > 0) false else true;
                        try self.html_buf.appendSlice("<ul>\n");
                    } else {
                        try self.html_buf.appendSlice("</ul>\n");
                        in_compact_list = HTMLGenerator.get_parents_list_compact_status(node_info.data);
                    }
                },
                .OrderedList => |list| {
                    if (!node_info.is_end) {
                        in_compact_list = if (list.blank_lines > 0) false else true;
                        try self.html_buf.appendSlice("<ol>\n");
                    } else {
                        try self.html_buf.appendSlice("</ol>\n");
                        in_compact_list = HTMLGenerator.get_parents_list_compact_status(node_info.data);
                    }
                },
                .UnorderedListItem, .OrderedListItem => {
                    if (!node_info.is_end) {
                        try self.html_buf.appendSlice("<li>\n");
                    } else {
                        try self.html_buf.appendSlice("</li>\n");
                    }
                },
                .FencedCode => |code| {
                    try self.html_buf.appendSlice("<pre><code>\n");
                    try self.html_buf.appendSlice(code.code);
                    try self.html_buf.appendSlice("</code></pre>\n");
                },
                .BlockQuote => {
                    if (!node_info.is_end) {
                        try self.html_buf.appendSlice("<blockquote>\n");
                    } else {
                        try self.html_buf.appendSlice("</blockquote>\n");
                    }
                },
                .Paragraph => {
                    if (!in_compact_list) {
                        if (!node_info.is_end) {
                            try self.html_buf.appendSlice("<p>\n");
                        } else {
                            try self.html_buf.appendSlice("</p>\n");
                        }
                    }
                },
                .Emphasis => {
                    if (!node_info.is_end) {
                        try self.html_buf.appendSlice("<em>");
                    } else {
                        try self.html_buf.appendSlice("</em>");
                    }
                },
                .StrongEmphasis => {
                    if (!node_info.is_end) {
                        try self.html_buf.appendSlice("<strong>");
                    } else {
                        try self.html_buf.appendSlice("</strong>");
                    }
                },
                .Strikethrough => {
                    if (!node_info.is_end) {
                        try self.html_buf.appendSlice("<strike>");
                    } else {
                        try self.html_buf.appendSlice("</strike>");
                    }
                },
                .Superscript => {
                    if (!node_info.is_end) {
                        try self.html_buf.appendSlice("<sup>");
                    } else {
                        try self.html_buf.appendSlice("</sup>");
                    }
                },
                .Subscript => {
                    if (!node_info.is_end) {
                        try self.html_buf.appendSlice("<sub>");
                    } else {
                        try self.html_buf.appendSlice("</sub>");
                    }
                },
                .CodeSpan => |code| {
                    try self.html_buf.appendSlice("<code>");
                    try self.html_buf.appendSlice(code.text);
                    try self.html_buf.appendSlice("</code>");
                },
                .Link => |link| {
                    var link_url: []const u8 = undefined;
                    var link_title: ?[]const u8 = undefined;
                    if (link.url) |url| {
                        link_url = url;
                        link_title = link.title;
                    } else {
                        // look up reference by label; must have one if url is null
                        // returns optional ptr to entry
                        const maybe_ref = self.label_ref_map.get(link.label.?);
                        if (maybe_ref) |ref| {
                            link_url = ref.url.?;
                            link_title = ref.title;
                        } else {
                            HTMLGenerator.report_error(
                                "No reference definition could be found for label '{}'!\n",
                                .{ link.label.? });
                            return Error.ReferenceLabelNotFound;
                        }
                    }

                    if (!node_info.is_end) {
                        try self.html_buf.appendSlice("<a href=\"");
                        try self.html_buf.appendSlice(link_url);
                        try self.html_buf.append('"');
                        if (link_title) |title| {
                            try self.html_buf.appendSlice("title=\"");
                            try self.html_buf.appendSlice(title);
                            try self.html_buf.append('"');
                        }
                        try self.html_buf.append('>');
                    } else {
                        try self.html_buf.appendSlice("</a>");
                    }
                },
                .Image => |img| {
                    if (img.url) |url| {
                        // TODO resolve references
                        try self.html_buf.appendSlice("<img src=\"");
                        try self.html_buf.appendSlice(url);
                        try self.html_buf.appendSlice("\" alt=\"");
                        try self.html_buf.appendSlice(img.alt);
                        try self.html_buf.appendSlice("\"");
                        if (img.title) |title| {
                            try self.html_buf.appendSlice(" title=\"");
                            try self.html_buf.appendSlice(title);
                            try self.html_buf.appendSlice("\"");
                        }
                        try self.html_buf.appendSlice(" />");
                    }
                },
                .HardLineBreak => try self.html_buf.appendSlice("<br/>\n"),
                .Text => |text| {
                    if (node_info.data.first_child) |fc| {
                        std.debug.print("Text node has child: {}\n", .{ fc.data });
                    }
                    try self.html_buf.appendSlice(text.text);
                    try self.html_buf.append('\n');
                },
                else => continue,
            }
        }

        try self.html_buf.appendSlice("</body>\n</html>");
        return self.html_buf.toOwnedSlice();
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
