const std = @import("std");
const log = std.log;

const tokenizer = @import("tokenizer.zig");
const TokenKind = tokenizer.TokenKind;

const Language = @import("code_chunks.zig").Language;

const builtin = @import("builtin.zig");
const DFS = @import("utils.zig").DepthFirstIterator;

const expect = std.testing.expect;

// meta.TagType gets union's enum tag type (by using @typeInfo(T).tag_type)
pub const NodeKind = std.meta.TagType(Node.NodeData);
pub const Node = struct {
    parent: ?*Node,

    next: ?*Node,
    first_child: ?*Node,
    last_child: ?*Node,

    // since a tagged union coerces to their tag type we don't need a
    // separate kind field
    data: NodeData,

    pub const LinkData = struct { label: ?[]const u8, url: ?[]const u8, title: ?[]const u8};
    pub const EmphData = struct { opener_token_kind: TokenKind };
    pub const ListData = struct { blank_lines: u32, start_num: u16 = 1, ol_type: u8 };
    pub const CodeData = struct { language: Language, code: []const u8, run: bool,
                                  stdout: ?[]const u8 = null, stderr: ?[]const u8 = null };
    /// indent: column that list item startes need to have in order to continue the list
    ///         1. test
    ///           - sublist
    ///           ^ this is the indent of the sublist
    pub const ListItemData = struct { list_item_starter: TokenKind, indent: u16, ol_type: u8 };
    pub const CitationData = struct { id: []const u8 };

    // tagged union
    pub const NodeData = union(enum) {
        // special
        Undefined,
        Document,
        Import,

        BuiltinCall: struct { builtin_type: builtin.BuiltinCall, result: ?*builtin.BuiltinResult = null },
        PostionalArg,
        KeywordArg: struct { keyword: []const u8 },

        // block
        // leaf blocks
        ThematicBreak,

        Heading: struct { level: u8 },

        FencedCode: CodeData,
        MathMultiline: struct { text: []const u8 },

        LinkRef: LinkData,

        // inline in CommonMark - leaf block here
        // TODO just store the pointer here and the ImageData just in the same arena
        // oterwise the union is getting way too big
        Image: struct { alt: []const u8, label: ?[]const u8, url: ?[]const u8, title: ?[]const u8 },

        // TODO add id to generate link to bibentry
        Citation: CitationData,
        Bibliography,
        BibEntry: CitationData,

        Paragraph,
        BlankLine, // ?

        // container blocks
        BlockQuote,

        UnorderedList: ListData,
        UnorderedListItem: ListItemData,

        OrderedList: ListData,
        OrderedListItem: ListItemData,
        
        // ?
        Table,
        TableRow,

        // inline
        CodeSpan: CodeData,
        MathInline: struct { text: []const u8 },
        Emphasis: EmphData,
        StrongEmphasis: EmphData,
        Strikethrough,
        Superscript,
        Subscript,
        // TODO add syntax
        SmallCaps,
        // TODO add syntax?
        Underline,
        Link: LinkData,
        // add SoftLineBreak ? are basically ignored and are represented by single \n
        HardLineBreak,
        Text: struct { text: []const u8 },
    };

    pub inline fn create(allocator: *std.mem.Allocator) !*Node {
        var new_node = try allocator.create(Node);
        new_node.* = .{
            .parent = null,
            .next = null,
            .first_child = null,
            .last_child = null,
            .data = .Undefined,
        };
        return new_node;
    }

    pub fn append_child(self: *Node, child: *Node) void {
        std.debug.assert(child.parent == null);

        if (self.first_child != null) {
            // .? equals "orelse unreachable" so we crash when last_child is null
            self.last_child.?.next = child;
            self.last_child = child;
        } else {
            self.first_child = child;
            self.last_child = child;
        }

        child.parent = self;
    }

    /// allocator has to be the allocator that node and it's direct children were
    /// allocated with
    /// Node's child must not have children of their own, otherwise there will be a leak
    pub fn delete_direct_children(self: *Node, allocator: *std.mem.Allocator) void {
        var mb_next = self.first_child;
        while (mb_next) |next| {
            mb_next = next.next;
            std.debug.assert(next.first_child == null);
            allocator.destroy(next);
        }
        self.first_child = null;
        self.last_child = null;
    }

    /// allocator has to be the one that node and it's direct children were allocated with
    pub fn delete_children(self: *Node, allocator: *std.mem.Allocator) void {
        var dfs = DFS(Node, true).init(self);

        while (dfs.next()) |node_info| {
            if (!node_info.is_end)
                continue;
            log.debug("Deleting end {}\n", .{ node_info.data.data });
            allocator.destroy(node_info.data);
        }

        // !IMPORTANT! mark self as having no children
        self.first_child = null;
        self.last_child = null;
    }

    /// detaches itself from parent
    pub fn detach(self: *Node) void {
        if (self.parent) |parent| {
            parent.remove_child(self);
        }
    }

    /// assumes that x is a child of self
    /// does not deallocate x
    pub fn remove_child(self: *Node, x: *Node) void {
        if (self.first_child == x) {
            if (self.last_child == x) {
                // x is the only child
                self.first_child = null;
                self.last_child = null;
            } else {
                self.first_child = x.next;
            }
            x.parent = null;
            x.next = null;
            return;
        }

        // find node which is followed by x
        var prev_child = self.first_child.?;
        while (prev_child.next != x) {
            prev_child = prev_child.next.?;
        }

        if (self.last_child == x) {
            self.last_child = prev_child;
            prev_child.next = null;
        } else {
            prev_child.next = x.next;
        }

        x.next = null;
        x.parent = null;
    }

    pub fn print_direct_children(self: *Node) void {
        var mb_next = self.first_child;
        while (mb_next) |next| {
            std.debug.print("Child: {}\n", .{ next.data });
            mb_next = next.next;
        }
    }
};

test "node remove_child first_child of 3" {
    const alloc = std.testing.allocator;

    var parent = try Node.create(alloc);
    defer alloc.destroy(parent);
    var child1 = try Node.create(alloc);
    defer alloc.destroy(child1);
    var child2 = try Node.create(alloc);
    defer alloc.destroy(child2);
    var child3 = try Node.create(alloc);
    defer alloc.destroy(child3);

    parent.append_child(child1);
    parent.append_child(child2);
    parent.append_child(child3);

    parent.remove_child(child1);
    try expect(parent.first_child == child2);
    try expect(parent.last_child  == child3);

    try expect(child2.next == child3);
    try expect(child1.next == null);
    try expect(child1.parent == null);
    try expect(child3.next == null);
}

test "node remove_child middle_child of 3" {
    const alloc = std.testing.allocator;

    var parent = try Node.create(alloc);
    defer alloc.destroy(parent);
    var child1 = try Node.create(alloc);
    defer alloc.destroy(child1);
    var child2 = try Node.create(alloc);
    defer alloc.destroy(child2);
    var child3 = try Node.create(alloc);
    defer alloc.destroy(child3);

    parent.append_child(child1);
    parent.append_child(child2);
    parent.append_child(child3);

    parent.remove_child(child2);
    try expect(parent.first_child == child1);
    try expect(parent.last_child  == child3);

    try expect(child2.next == null);
    try expect(child2.parent == null);

    try expect(child1.next == child3);
    try expect(child3.next == null);
}

test "node remove_child last_child of 3" {
    const alloc = std.testing.allocator;

    var parent = try Node.create(alloc);
    defer alloc.destroy(parent);
    var child1 = try Node.create(alloc);
    defer alloc.destroy(child1);
    var child2 = try Node.create(alloc);
    defer alloc.destroy(child2);
    var child3 = try Node.create(alloc);
    defer alloc.destroy(child3);

    parent.append_child(child1);
    parent.append_child(child2);
    parent.append_child(child3);

    parent.remove_child(child3);
    try expect(parent.first_child == child1);
    try expect(parent.last_child  == child2);

    try expect(child1.next == child2);
    try expect(child2.next == null);

    try expect(child3.next == null);
    try expect(child3.parent == null);
}

test "node remove_child only_child" {
    const alloc = std.testing.allocator;

    var parent = try Node.create(alloc);
    defer alloc.destroy(parent);
    var child1 = try Node.create(alloc);
    defer alloc.destroy(child1);

    parent.append_child(child1);

    parent.remove_child(child1);
    try expect(parent.first_child == null);
    try expect(parent.last_child  == null);

    try expect(child1.next == null);
    try expect(child1.parent == null);
}

pub inline fn is_container_block(self: NodeKind) bool {
    return switch (self) {
        .Document, .BlockQuote, .UnorderedList, .UnorderedListItem, .OrderedList, .OrderedListItem => true,
        else => false,
    };
}

pub inline fn is_leaf_block(self: NodeKind) bool {
    return switch (self) {
        .ThematicBreak, .Heading, .FencedCode, .LinkRef, .Paragraph,
        .BlankLine, .Image, .MathMultiline => true,
        else => false,
    };
}

pub inline fn is_inline(self: NodeKind) bool {
    return switch (self) {
        .CodeSpan, .Emphasis, .StrongEmphasis, .Strikethrough, .Link,
        .HardLineBreak, .Text, .Superscript, .Subscript, .MathInline => true,
        else => false,
    };
}

pub inline fn can_hold(self: NodeKind, other: NodeKind) bool {
    if (is_container_block(self)) {
        return true;
    } else if (other == .PostionalArg or other == .KeywordArg) {
        if (self == .BuiltinCall) {
            return true;
        } else {
            return false;
        }
    } else {
        return if (is_inline(other)) true else false;
    }
}

pub inline fn children_allowed(self: NodeKind) bool {
    return switch (self) {
        .Undefined, .CodeSpan, .ThematicBreak, .LinkRef,
        .BlankLine, .HardLineBreak, .Text, .MathInline => false,
        else => true,
    };
}

pub inline fn is_block(self: NodeKind) bool {
    return is_container_block(self) or is_leaf_block(self);
}
