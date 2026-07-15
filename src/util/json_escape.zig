//! JSON string-body escaping for GraphQL query interpolation, shared by the
//! anilist and provider clients (ROD-401). One definition so the three copies
//! cannot drift.
//!
//! GraphQL bodies here are hand-rolled (persisted-query nested escaping that
//! std.json won't reproduce), so user text spliced into them must be escaped by
//! hand. This is that escaper.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Escape `s` for inclusion inside a JSON string literal. Allocates into `arena`.
pub fn escape(arena: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(arena, "\\\""),
        '\\' => try out.appendSlice(arena, "\\\\"),
        '\n' => try out.appendSlice(arena, "\\n"),
        '\r' => try out.appendSlice(arena, "\\r"),
        '\t' => try out.appendSlice(arena, "\\t"),
        else => if (c < 0x20) {
            // RFC 8259: raw controls forbidden; `\u00XX` for c < 0x20.
            const hex = "0123456789abcdef";
            try out.appendSlice(arena, "\\u00");
            try out.append(arena, hex[(c >> 4) & 0xf]);
            try out.append(arena, hex[c & 0xf]);
        } else try out.append(arena, c),
    };
    return out.items;
}

test "escape: quotes and backslashes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("a\\\"b", try escape(a, "a\"b"));
    try std.testing.expectEqualStrings("c\\\\d", try escape(a, "c\\d"));
    try std.testing.expectEqualStrings("plain", try escape(a, "plain"));
}

test "escape: newline, tab, carriage-return, mixed, empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try std.testing.expectEqualStrings("a\\nb", try escape(a, "a\nb"));
    try std.testing.expectEqualStrings("a\\tb", try escape(a, "a\tb"));
    try std.testing.expectEqualStrings("a\\rb", try escape(a, "a\rb"));
    try std.testing.expectEqualStrings("\\\"\\\\\\n", try escape(a, "\"\\\n"));
    try std.testing.expectEqualStrings("", try escape(a, ""));
}

test "escape: unicode passthrough" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("フリーレン", try escape(a, "フリーレン"));
    try std.testing.expectEqualStrings("葬送のフリーレン", try escape(a, "葬送のフリーレン"));
}

test "escape: control characters are \\u-escaped (RFC 8259)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("\\u0000", try escape(a, "\x00"));
    try std.testing.expectEqualStrings("a\\u000bb", try escape(a, "a\x0bb"));
}
