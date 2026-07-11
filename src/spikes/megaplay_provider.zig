//! ROD-359 spike: drive the REAL MegaPlay provider through its vtable against the
//! live host, end to end minus mpv: the episode-1 existence probe → resolve one
//! episode of a MAL id into a StreamLink.
//!
//!   zig build spike-megaplay -- <mal_id> [ep] [sub|dub]
//!
//! With just a MAL id it stops after the probe; pass an episode number to run
//! the full resolve. Frieren ep 28: `zig build spike-megaplay -- 52991 28`.

const std = @import("std");
const zigoku = @import("zigoku");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var out_buf: [4096]u8 = undefined;
    var out_fw: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    const w = &out_fw.interface;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        try w.print("usage: zig build spike-megaplay -- <mal_id> [ep] [sub|dub]\n", .{});
        try w.flush();
        return error.MissingArg;
    }
    const mal_id = args[1];
    const ep: ?[]const u8 = if (args.len > 2) args[2] else null;
    const tt: zigoku.Translation = if (args.len > 3 and std.mem.eql(u8, args[3], "dub")) .dub else .sub;

    var megaplay = zigoku.MegaPlay.init();
    const provider = megaplay.provider();

    // No count hint here (the spike has no canonical row): a stocked show
    // answers exactly one probed label, a missing one answers zero.
    const eps = try provider.episodes(arena, io, mal_id, tt, null);
    try w.print("probe mal={s} → {s}\n", .{ mal_id, if (eps.len > 0) "stocked" else "NOT stocked" });

    if (ep) |label| {
        const link = try provider.resolve(arena, io, mal_id, .{ .raw = label }, tt, .best);
        try w.print("resolve ep {s} ({s})\n", .{ label, @tagName(tt) });
        try w.print("  m3u8    {s}\n", .{link.url});
        try w.print("  referer {s}\n", .{link.referer.?});
        try w.print("  sub     {s}\n", .{link.sub_url orelse "-"});
        try w.print("  cloaked {}\n", .{link.cloaked_segments});
    }
    try w.flush();
}
