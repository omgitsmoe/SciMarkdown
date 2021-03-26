const std = @import("std");

const tokenizer = @import("tokenizer.zig");
const TokenKind = tokenizer.TokenKind;

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

    const LinkData = struct { label: ?[]const u8, url: ?[]const u8, title: ?[]const u8 };
    const EmphData = struct { opener_token_kind: TokenKind };
    // tagged union
    const NodeData = union(enum) {
        // special
        Undefined,
        Document,
        Import,

        // block
        // leaf blocks
        ThematicBreak,

        Heading: struct { level: u8 },

        FencedCode: struct { language_name: []const u8, code: []const u8 },

        LinkRef: LinkData,

        Image,  // inline in CommonMark - leaf block here

        Paragraph,
        BlankLine, // ?

        // container blocks
        BlockQuote,

        UnorderedList,
        UnorderedListItem,

        OrderedList,
        OrderedListItem,
        
        // ?
        Table,
        TableRow,

        // inline
        CodeSpan: struct { text: []const u8 },
        Emphasis: EmphData,
        StrongEmphasis: EmphData,
        Strikethrough,
        Link: LinkData,
        Autolink,
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

    pub inline fn is_container_block(self: *Node) bool {
        return switch (self.data) {
            .BlockQuote, .BulletList, .BulletListItem, .OrderedList, .OrderedListItem => true,
            else => false,
        };
    }

    pub inline fn is_leaf_block(self: *Node) bool {
        return switch (self.data) {
            .ThematicBreak, .Heading, .FencedCode, .LinkRef, .Paragraph, .BlankLine, .Image => true,
            else => false,
        };
    }

    pub inline fn children_allowed(self: *Node) bool {
        return switch (self.data) {
            .Undefined, .CodeSpan, .ThematicBreak, .FencedCode, .LinkRef,
            .BlankLine, .Image, .Autolink, .HardLineBreak, .Text => false,
            else => true,
        };
    }

    pub inline fn is_block(self: *Node) bool {
        return is_container_block(self) or is_leaf_block(self);
    }
};
