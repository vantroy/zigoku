//! ROD-341 spike: drive the REAL megaplay extractor (src/providers/megaplay.zig)
//! against the live host, end to end: embed scrape → getSources → StreamLink.
//! Prints the m3u8, the referer/UA gate, the softsub tracks and the skip stamps.
//! The curl recon lives in the ROD-340 comments; this proves the Zig module does
//! the same dance.
//!
//!   zig build spike-megaplay -- <realid> [sub|dub]
//!
//! Frieren ep1's realid is 107259 (sub data-id 13458, dub 13452).

const std = @import("std");
const zigoku = @import("zigoku");
const megaplay = zigoku.megaplay;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var out_buf: [4096]u8 = undefined;
    var out_fw: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    const w = &out_fw.interface;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        try w.print("usage: zig build spike-megaplay -- <realid> [sub|dub]\n", .{});
        try w.flush();
        return error.MissingArg;
    }
    const realid = args[1];
    const tt: zigoku.Translation = if (args.len > 2 and std.mem.eql(u8, args[2], "dub")) .dub else .sub;

    const stream = try megaplay.resolve(arena, io, realid, tt);

    try w.print("realid {s} ({s})\n", .{ realid, @tagName(tt) });
    try w.print("  m3u8    {s}\n", .{stream.link.url});
    try w.print("  referer {s}\n", .{stream.link.referer.?});
    try w.print("  ua      {s}\n", .{stream.link.user_agent.?});
    try w.print("  cloaked {}\n", .{stream.link.cloaked_segments});
    try w.print("  sub     {s}\n", .{stream.link.sub_url orelse "-"});
    for (stream.tracks) |t| {
        try w.print("  track   [{s}] {s} {s}{s}\n", .{
            t.kind orelse "?",
            t.label orelse "-",
            t.file,
            if (t.default) " (default)" else "",
        });
    }
    if (stream.intro) |s| try w.print("  intro   {d:.0}-{d:.0}s\n", .{ s.start, s.end });
    if (stream.outro) |s| try w.print("  outro   {d:.0}-{d:.0}s\n", .{ s.start, s.end });
    try w.flush();
}
