const std = @import("std");
const log = std.log;

const DFS = @import("utils.zig").DepthFirstIterator;

const ast = @import("ast.zig");
const Node = ast.Node;
const NodeKind = ast.NodeKind;

usingnamespace @import("c.zig");


fn error_handler(error_no: HPDF_STATUS, detail_no: HPDF_STATUS, user_data: ?*c_void) callconv(.C) void {
    // zig 0.9.0dev now doesn't allow unused variables, so you the intended use for functions
    // of a specific type is to "annotate" unused parameters like so: _ = user_data;
    _ = user_data;
    log.err("error number: {x}, detail number: {x}", .{ @as(c_uint, error_no), @as(c_uint, detail_no) });
}

pub const PDFGenerator = struct {
    allocator: *std.mem.Allocator,
    start_node: *Node,
    label_node_map: std.StringHashMap(*Node.NodeData),

    pub const Error = error {
        ReferenceLabelNotFound,
        FormatBufferTooSmall,
        PDFError,
        OutOfMemory,
    };

    /// label_node_map is taken from the parser, but PDFGenerator doesn't take ownership
    pub fn init(
        allocator: *std.mem.Allocator,
        start_node: *Node,
        label_node_map: std.StringHashMap(*Node.NodeData)
    ) @This() {
        return @This(){
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
        self: *@This(),
        comptime WriterType: type,
        out_stream: anytype
    ) (Error || WriterType.Error)!void {
        _ = out_stream;
        var dfs = DFS(Node, true).init(self.start_node);

        const pdf = HPDF_New(error_handler, null);
        if (pdf == null) return Error.PDFError;
        defer { _ = HPDF_Free (pdf); }

        // all of these return HPDF_STATUS
        _ = HPDF_SetCompressionMode(pdf, HPDF_COMP_NONE);
        const font = HPDF_GetFont(pdf, "Helvetica", null);
        var page = HPDF_AddPage(pdf);

        _ = HPDF_Page_SetFontAndSize (page, font, 24);
        const page_title = "SciMarkdown Test";
        const tw = HPDF_Page_TextWidth(page, page_title);
        _ = HPDF_Page_BeginText (page);
        _ = HPDF_Page_TextOut (page, (HPDF_Page_GetWidth(page) - tw) / 2,
                    HPDF_Page_GetHeight (page) - 50, page_title);
        _ = HPDF_Page_EndText (page);

        var curr_text_x: f32 = 0;
        var curr_text_y: f32 = HPDF_Page_GetHeight(page);
        var open_text = false;
        var in_compact_list = false;
        _ = in_compact_list; // TODO remove
        while (dfs.next()) |node_info| {
            // bug in zig compiler: if a switch prong (without {}) doesn't handle an error
            // the start of the switch is reported as ignoring the error
            // std.debug.print("Node (end: {}): {}\n", .{ node_info.is_end, node_info.data.data });
            switch (node_info.data.data) {
                .Document => continue,
                .Undefined, .Import => unreachable,
        //         // blocks like thematic break should never get both a start and end NodeInfo
        //         // since they can't contain other blocks
        //         .ThematicBreak => try out_stream.writeAll("<hr/>\n"),
        //         .Heading => |heading| {
        //             var hbuf: [4]u8 = undefined;
        //             _ = std.fmt.bufPrint(&hbuf, "h{}>\n", .{ heading.level })
        //                 catch return Error.FormatBufferTooSmall;
        //             if (node_info.is_end) {
        //                 try out_stream.writeAll("</");
        //             } else {
        //                 try out_stream.writeByte('<');
        //             }
        //             try out_stream.writeAll(&hbuf);
        //         },
        //         .UnorderedList => |list| {
        //             if (!node_info.is_end) {
        //                 in_compact_list = if (list.blank_lines > 0) false else true;
        //                 try out_stream.writeAll("<ul>\n");
        //             } else {
        //                 try out_stream.writeAll("</ul>\n");
        //                 in_compact_list = HTMLGenerator.get_parents_list_compact_status(node_info.data);
        //             }
        //         },
        //         .OrderedList => |list| {
        //             if (!node_info.is_end) {
        //                 in_compact_list = if (list.blank_lines > 0) false else true;
        //                 if (list.start_num == 1 and list.ol_type == '1') {
        //                     try out_stream.writeAll("<ol>\n");
        //                 } else {
        //                     var numbuf: [4]u8 = undefined;
        //                     var numslice = std.fmt.bufPrint(&numbuf, "{}", .{ list.start_num })
        //                         catch return Error.FormatBufferTooSmall;
        //                     try out_stream.writeAll("<ol start=\"");
        //                     try out_stream.writeAll(numslice);
        //                     try out_stream.writeAll("\" type=\"");
        //                     try out_stream.writeByte(list.ol_type);
        //                     try out_stream.writeAll("\">\n");
        //                 }
        //             } else {
        //                 try out_stream.writeAll("</ol>\n");
        //                 in_compact_list = HTMLGenerator.get_parents_list_compact_status(node_info.data);
        //             }
        //         },
        //         .UnorderedListItem, .OrderedListItem => {
        //             if (!node_info.is_end) {
        //                 try out_stream.writeAll("<li>\n");
        //             } else {
        //                 try out_stream.writeAll("</li>\n");
        //             }
        //         },
        //         .FencedCode => |code| {
        //             if (!node_info.is_end) continue;

        //             // no \n since the whitespace is printed verbatim in a <pre> env
        //             try out_stream.writeAll("<pre><code>");
        //             try out_stream.writeAll(code.code);
        //             try out_stream.writeAll("</code></pre>\n");

        //             if (code.stdout) |out| {
        //                 try out_stream.writeAll("Output:");
        //                 try out_stream.writeAll("<pre>\n");
        //                 try out_stream.writeAll(out);
        //                 try out_stream.writeAll("</pre>\n");
        //             }
        //             if (code.stderr) |err| {
        //                 try out_stream.writeAll("Warnings:");
        //                 try out_stream.writeAll("<pre>\n");
        //                 try out_stream.writeAll(err);
        //                 try out_stream.writeAll("</pre>\n");
        //             }
        //         },
        //         .MathInline => |math| {
        //             // \(...\) are the default MathJax inline delimiters instead of $...$
        //             try out_stream.writeAll("\\(");
        //             try out_stream.writeAll(math.text);
        //             try out_stream.writeAll("\\)");
        //         },
        //         .MathMultiline => |math| {
        //             if (!node_info.is_end) continue;
        //             try out_stream.writeAll("$$");
        //             try out_stream.writeAll(math.text);
        //             try out_stream.writeAll("$$\n");
        //         },
        //         .BlockQuote => {
        //             if (!node_info.is_end) {
        //                 try out_stream.writeAll("<blockquote>\n");
        //             } else {
        //                 try out_stream.writeAll("</blockquote>\n");
        //             }
        //         },
        //         .Paragraph => {
        //             if (!in_compact_list) {
        //                 if (!node_info.is_end) {
        //                     try out_stream.writeAll("<p>\n");
        //                 } else {
        //                     try out_stream.writeAll("</p>\n");
        //                 }
        //             }
        //         },
        //         .BibEntry => {
        //             if (!node_info.is_end) {
        //                 try out_stream.writeAll("<p>\n");
        //             } else {
        //                 try out_stream.writeAll("</p>\n");
        //             }
        //         },
        //         .Emphasis => {
        //             if (!node_info.is_end) {
        //                 try out_stream.writeAll("<em>");
        //             } else {
        //                 try out_stream.writeAll("</em>");
        //             }
        //         },
        //         .StrongEmphasis => {
        //             if (!node_info.is_end) {
        //                 try out_stream.writeAll("<strong>");
        //             } else {
        //                 try out_stream.writeAll("</strong>");
        //             }
        //         },
        //         .Strikethrough => {
        //             if (!node_info.is_end) {
        //                 try out_stream.writeAll("<strike>");
        //             } else {
        //                 try out_stream.writeAll("</strike>");
        //             }
        //         },
        //         .Superscript => {
        //             if (!node_info.is_end) {
        //                 try out_stream.writeAll("<sup>");
        //             } else {
        //                 try out_stream.writeAll("</sup>");
        //             }
        //         },
        //         .Subscript => {
        //             if (!node_info.is_end) {
        //                 try out_stream.writeAll("<sub>");
        //             } else {
        //                 try out_stream.writeAll("</sub>");
        //             }
        //         },
        //         .SmallCaps => {
        //             if (!node_info.is_end) {
        //                 try out_stream.writeAll("<span style=\"font-variant: small-caps;\">");
        //             } else {
        //                 try out_stream.writeAll("</span>");
        //             }
        //         },
        //         .Underline => {
        //             if (!node_info.is_end) {
        //                 try out_stream.writeAll("<u>");
        //             } else {
        //                 try out_stream.writeAll("</u>");
        //             }
        //         },
        //         .CodeSpan => |code| {
        //             if (code.stdout) |out| {
        //                 try out_stream.writeAll(out);
        //             } else {
        //                 try out_stream.writeAll("<code>");
        //                 try out_stream.writeAll(code.code);
        //                 try out_stream.writeAll("</code>");
        //             }
        //         },
        //         .Link => |link| {
        //             // TODO move this into a post pass after the frontend?
        //             var link_url: []const u8 = undefined;
        //             var link_title: ?[]const u8 = undefined;
        //             if (link.url) |url| {
        //                 link_url = url;
        //                 link_title = link.title;
        //             } else {
        //                 // look up reference by label; must have one if url is null
        //                 // returns optional ptr to entry
        //                 const maybe_ref = self.label_node_map.get(link.label.?);
        //                 if (maybe_ref) |ref| {
        //                     link_url = ref.LinkRef.url.?;
        //                     link_title = ref.LinkRef.title;
        //                 } else {
        //                     HTMLGenerator.report_error(
        //                         "No reference definition could be found for label '{s}'!\n",
        //                         .{ link.label.? });
        //                     return Error.ReferenceLabelNotFound;
        //                 }
        //             }

        //             if (!node_info.is_end) {
        //                 try out_stream.writeAll("<a href=\"");
        //                 try out_stream.writeAll(link_url);
        //                 try out_stream.writeByte('"');
        //                 if (link_title) |title| {
        //                     try out_stream.writeAll("title=\"");
        //                     try out_stream.writeAll(title);
        //                     try out_stream.writeByte('"');
        //                 }
        //                 try out_stream.writeByte('>');
        //             } else {
        //                 try out_stream.writeAll("</a>");
        //             }
        //         },
        //         .Image => |img| {
        //             var img_url: []const u8 = undefined;
        //             var img_title: ?[]const u8 = undefined;
        //             if (img.url) |url| {
        //                 img_url = url;
        //                 img_title = img.title;
        //             } else {
        //                 // look up reference by label; must have one if url is null
        //                 // returns optional ptr to entry
        //                 const maybe_ref = self.label_node_map.get(img.label.?);
        //                 if (maybe_ref) |ref| {
        //                     img_url = ref.LinkRef.url.?;
        //                     img_title = ref.LinkRef.title;
        //                 } else {
        //                     HTMLGenerator.report_error(
        //                         "No reference definition could be found for label '{s}'!\n",
        //                         .{ img.label.? });
        //                     return Error.ReferenceLabelNotFound;
        //                 }
        //             }

        //             try out_stream.writeAll("<img src=\"");
        //             try out_stream.writeAll(img_url);
        //             try out_stream.writeAll("\" alt=\"");
        //             try out_stream.writeAll(img.alt);
        //             try out_stream.writeAll("\"");
        //             if (img_title) |title| {
        //                 try out_stream.writeAll(" title=\"");
        //                 try out_stream.writeAll(title);
        //                 try out_stream.writeAll("\"");
        //             }
        //             try out_stream.writeAll(" />");
        //         },
        //         .BuiltinCall => |call| {
        //             if (!node_info.is_end)
        //                 continue;

        //             switch (call.builtin_type) {
        //                 // TODO fix for nodes like e.g. FencedCode, Heading
        //                 .label => {
        //                     try out_stream.writeAll("<span id=\"");
        //                     try out_stream.writeAll(call.result.?.label);
        //                     try out_stream.writeAll("\"></span>");
        //                 },
        //                 .ref => {
        //                     const maybe_node = self.label_node_map.get(call.result.?.ref);
        //                     if (maybe_node) |node| {
        //                         try out_stream.writeAll("<a href=\"#");
        //                         try out_stream.writeAll(call.result.?.ref);
        //                         try out_stream.writeAll("\">");
        //                         try out_stream.writeAll(@tagName(node.*));
        //                         try out_stream.writeAll("</a>");
        //                     } else {
        //                         HTMLGenerator.report_error(
        //                             "No corresponding label could be found for ref '{s}'!\n",
        //                             .{ call.result.?.ref });
        //                         return Error.ReferenceLabelNotFound;
        //                     }
        //                 },
        //                 else => {},
        //             }
        //         },
        //         .HardLineBreak => try out_stream.writeAll("<br/>\n"),
        //         .SoftLineBreak => try out_stream.writeByte('\n'),
                .Text => |text| {
                    if (node_info.data.first_child) |fc| {
                        log.debug("Text node has child: {}\n", .{ fc.data });
                    }

                    _ = HPDF_Page_SetFontAndSize (page, font, 12);
                    // not in text mode
                    var first = false;
                    if (!open_text) {
                        _ = HPDF_Page_BeginText (page);
                        open_text = true;
                        first = true;
                    }

                    const page_width = HPDF_Page_GetWidth(page);
                    // HPDF_Page_TextWidth @Library is bugged returning max? width for a single space
                    // const space_width = HPDF_Page_TextWidth(page, " ");
                    const space_width = HPDF_Page_TextWidth(page, "M");
                    // const line_height = @intToFloat(f32, HPDF_Font_GetCapHeight(font)) * 1.2;
                    // set the dy that will be used as offset from the current to the next line
                    const line_height = space_width * 2;
                    _ = HPDF_Page_SetTextLeading(page, line_height);
                    // this spacing is applied to ' ' in the text, but it's in multiples of the
                    // normal spacing
                    // _ = HPDF_Page_SetWordSpace(page, space_width);

                    var buf: [500]u8 = undefined;
                    var alloc = std.heap.FixedBufferAllocator.init(&buf);
                    var text_cstr = try std.cstr.addNullByte(&alloc.allocator, text.text);

                    var bytes_written: u8 = 0;
                    const len_bytes = text.text.len;
                    while (bytes_written < len_bytes) {
                        // how many bytes can we fit into width(2nd param) when not breaking up words (3rd)
                        const sliced = text_cstr[bytes_written..];
                        const num_bytes = HPDF_Page_MeasureText(
                            // @Compiler passing a slice directly into a foreign c function
                            // triggers compiler bug (replace sliced with text_cstr[bytes_written..])
                            page, sliced, page_width - curr_text_x,
                            HPDF_TRUE, null);
                        if (num_bytes == 0) {
                            // moving to next line does not modify the x coordinate
                            // _ = HPDF_Page_MoveToNextLine(page);
                            _ = HPDF_Page_MoveTextPos(page, -curr_text_x, -line_height);
                            const nl_point = HPDF_Page_GetCurrentTextPos(page);
                            curr_text_x = nl_point.x;
                            curr_text_y = nl_point.y;
                            continue;
                        }
                        // _ = HPDF_Page_TextOut (page, (HPDF_Page_GetWidth(page) - tw) / 2,
                        //             HPDF_Page_GetHeight (page) - 50, page_title);
                        // truncate text
                        const abs_idx = bytes_written + num_bytes;
                        text_cstr[abs_idx] = 0;
                        if (first) {
                            // use TextOut for our first call so we can pass absolute curr_text_* coords
                            // TODO
                            _ = HPDF_Page_TextOut(page, curr_text_x, curr_text_y, sliced);
                            first = false;
                        } else {
                            _ = HPDF_Page_ShowText(page, sliced);
                        }
                        // restore u8 that was overwritten with null byte
                        if (abs_idx < len_bytes)
                            text_cstr[abs_idx] = text.text[abs_idx];

                        // std.debug.print("Left: {d}, Fitted: {d}\n", .{ bytes_left, num_bytes });
                        bytes_written += @intCast(u8, num_bytes);

                        const point = HPDF_Page_GetCurrentTextPos(page);
                        std.debug.print("X Offset {d}, Y Offset {d}\n", .{ @bitOffsetOf(HPDF_Point, "x"), @bitOffsetOf(HPDF_Point, "y") });
                        std.debug.print("Point {any} X {d} Y {d}\n", .{ point, point.x, point.y });
                        curr_text_x = point.x;
                        curr_text_y = point.y;

                        if (curr_text_x >= page_width - space_width) {
                            _ = HPDF_Page_MoveTextPos(page, -curr_text_x, -line_height);
                            const nl_point = HPDF_Page_GetCurrentTextPos(page);
                            curr_text_x = nl_point.x;
                            curr_text_y = nl_point.y;
                        } else {
                            // add space @Robustness this might overflow the page
                            _ = HPDF_Page_MoveTextPos(page, space_width, 0);
                        }
                    }
                    // try out_stream.writeAll(text.text);
                },
                else => continue,
            }
        }

        if (open_text)
            _ = HPDF_Page_EndText (page);

        // try out_stream.writeAll("</div></body>\n</html>");
        _ = HPDF_SaveToFile (pdf, "test.pdf");
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
