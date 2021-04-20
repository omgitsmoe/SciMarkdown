const std = @import("std");

const tokenizer = @import("tokenizer.zig");
const TokenKind = tokenizer.TokenKind;

const Language = @import("code_chunks.zig").Language;

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
    pub const ListData = struct { blank_lines: u32 };
    pub const CodeData = struct { language: Language, code: []const u8,
                                  stdout: ?[]const u8 = null, stderr: ?[]const u8 = null };
    /// indent: column that list item startes need to have in order to continue the list
    ///         1. test
    ///           - sublist
    ///           ^ this is the indent of the sublist
    pub const ListItemData = struct { list_item_starter: TokenKind, indent: u16 };
    // tagged union
    pub const NodeData = union(enum) {
        // special
        Undefined,
        Document,
        Import,

        BuiltinCall,
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

        Citation,
        Bibliography,
        BibEntry: struct { id: []const u8 },

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
        CodeSpan: struct { text: []const u8 },
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
    /// Node's child must not have children of their own, otherwise they will be a leak
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

    pub fn print_direct_children(self: *Node) void {
        var mb_next = self.first_child;
        while (mb_next) |next| {
            std.debug.print("Child: {}\n", .{ next.data });
            mb_next = next.next;
        }
    }
};

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
        .Undefined, .CodeSpan, .ThematicBreak, .FencedCode, .LinkRef,
        .BlankLine, .HardLineBreak, .Text, .MathInline => false,
        else => true,
    };
}

pub inline fn is_block(self: NodeKind) bool {
    return is_container_block(self) or is_leaf_block(self);
}
