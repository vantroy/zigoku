//! ROD-342 spike: drive the REAL AniPub provider through its vtable against the
//! live host, end to end minus mpv: search (with the MALID backfill printed) →
//! episodes → resolve one episode into a StreamLink via the megaplay extractor.
//!
//!   zig build spike-anipub -- <query> [ep] [sub|dub]
//!
//! With just a query it stops after search+episodes; pass an episode number to
//! run the full resolve. Frieren: `zig build spike-anipub -- frieren 1`.

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
        try w.print("usage: zig build spike-anipub -- <query> [ep] [sub|dub]\n", .{});
        try w.flush();
        return error.MissingArg;
    }
    const query = args[1];
    const ep: ?[]const u8 = if (args.len > 2) args[2] else null;
    const tt: zigoku.Translation = if (args.len > 3 and std.mem.eql(u8, args[3], "dub")) .dub else .sub;

    var anipub = zigoku.AniPub.init();
    const provider = anipub.provider();

    const results = try provider.search(arena, io, query, .{ .limit = 10 });
    try w.print("search \"{s}\" → {d} hit(s)\n", .{ query, results.len });
    for (results) |a| {
        try w.print("  [{s}] {s}  mal={?d} eps={?d} year={?d} status={s}\n", .{
            a.id, a.name, a.mal_id, a.total_episodes, a.year, a.status orelse "-",
        });
    }
    if (results.len == 0) {
        try w.flush();
        return;
    }

    const show = results[0];
    const eps = try provider.episodes(arena, io, show.id, tt);
    try w.print("episodes [{s}] → {d} (first {s}, last {s})\n", .{
        show.id,
        eps.len,
        if (eps.len > 0) eps[0].raw else "-",
        if (eps.len > 0) eps[eps.len - 1].raw else "-",
    });

    if (ep) |label| {
        const link = try provider.resolve(arena, io, show.id, .{ .raw = label }, tt, .best);
        try w.print("resolve ep {s} ({s})\n", .{ label, @tagName(tt) });
        try w.print("  m3u8    {s}\n", .{link.url});
        try w.print("  referer {s}\n", .{link.referer.?});
        try w.print("  cloaked {}\n", .{link.cloaked_segments});
    }
    try w.flush();
}
