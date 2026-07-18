//! ROD-443 spike: prove the de-cloaking proxy turns a dead PNG-cloaked megaplay stream
//! into a real playable one, end to end minus the mpv window.
//!
//!   zig build spike-decloak -- <mal_id> <ep> [sub|dub]
//!
//! Resolves a live megaplay episode, starts the loopback proxy, then runs ffprobe
//! against BOTH the raw upstream master and the proxied loopback master. The raw one
//! probes as "Video: png" (the cloak); the proxied one must probe as h264 + aac. A
//! green run is the ship signal: the proxy strips the decoy header the demuxer chokes on.

const std = @import("std");
const zigoku = @import("zigoku");

fn ffprobe(arena: std.mem.Allocator, io: std.Io, url: []const u8, referer: ?[]const u8, ua: ?[]const u8, relax_ext: bool) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, "ffprobe");
    try argv.append(arena, "-v");
    try argv.append(arena, "error");
    // Only the RAW probe relaxes the extension gate, to reach the cloaked segment and
    // reveal "Video: png". The PROXIED probe runs flagless on purpose: its loopback URLs
    // end in `.ts`, so if it demuxes clean, the app needs no allowed_extensions flag.
    if (relax_ext) {
        try argv.append(arena, "-extension_picky");
        try argv.append(arena, "0");
        try argv.append(arena, "-allowed_segment_extensions");
        try argv.append(arena, "ALL");
        try argv.append(arena, "-allowed_extensions");
        try argv.append(arena, "ALL");
    }
    try argv.append(arena, "-show_entries");
    try argv.append(arena, "stream=codec_type,codec_name");
    try argv.append(arena, "-of");
    try argv.append(arena, "default=noprint_wrappers=1");
    // ffprobe carries provider headers to the CDN for the raw case; harmless for loopback.
    if (referer) |r| {
        try argv.append(arena, "-headers");
        try argv.append(arena, try std.fmt.allocPrint(arena, "Referer: {s}\r\n", .{r}));
    }
    if (ua) |u| {
        try argv.append(arena, "-user_agent");
        try argv.append(arena, u);
    }
    // ffprobe prints stream info to stderr under -v error; capture it as the report.
    try argv.append(arena, url);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var out_pipe = child.stdout.?;
    var err_pipe = child.stderr.?;
    var obuf: [4096]u8 = undefined;
    var ebuf: [4096]u8 = undefined;
    var out_reader = out_pipe.reader(io, &obuf);
    var err_reader = err_pipe.reader(io, &ebuf);
    const out = out_reader.interface.allocRemaining(arena, std.Io.Limit.limited(1 << 20)) catch "";
    const err = err_reader.interface.allocRemaining(arena, std.Io.Limit.limited(1 << 20)) catch "";
    _ = child.wait(io) catch {};
    return std.mem.concat(arena, u8, &.{ out, err });
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var out_buf: [4096]u8 = undefined;
    var out_fw: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    const w = &out_fw.interface;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        try w.print("usage: zig build spike-decloak -- <mal_id> <ep> [sub|dub]\n", .{});
        try w.flush();
        return error.MissingArg;
    }
    const mal_id = args[1];
    const ep = args[2];
    const tt: zigoku.Translation = if (args.len > 3 and std.mem.eql(u8, args[3], "dub")) .dub else .sub;

    var megaplay = zigoku.MegaPlay.init();
    const provider = megaplay.provider();
    const link = try provider.resolve(arena, io, mal_id, .{ .raw = ep }, tt, .best);
    try w.print("resolved mal={s} ep={s} ({s})\n  master  {s}\n  decloak {}\n\n", .{ mal_id, ep, @tagName(tt), link.url, link.decloak_segments });
    try w.flush();

    try w.print("── raw upstream (expect the cloak: Video: png) ──\n", .{});
    const raw_probe = try ffprobe(arena, io, link.url, link.referer, link.user_agent, true);
    try w.print("{s}\n", .{raw_probe});
    try w.flush();

    var proxy = try zigoku.proxy.Proxy.start(io, link);
    defer proxy.stop();
    const loopback = try proxy.loopbackUrl(arena, link.url);
    try w.print("── proxied via {s} (expect h264 + aac, no ext flags) ──\n", .{loopback});
    const proxied_probe = try ffprobe(arena, io, loopback, null, null, false);
    try w.print("{s}\n", .{proxied_probe});
    try w.flush();

    const decloaked = std.mem.indexOf(u8, proxied_probe, "h264") != null;
    try w.print("VERDICT (ffprobe): {s}\n", .{if (decloaked) "PASS: proxy de-cloaked to real video" else "FAIL: no h264 through the proxy"});
    try w.flush();
    if (!decloaked) std.process.exit(1);

    // Gold standard: drive REAL mpv headless (--vo/--ao=null) against the live proxy,
    // decode a few dozen frames, and confirm a clean exit. Same libavformat path as the
    // app, minus the window.
    try w.print("\n── real mpv headless (decode 60 frames) ──\n", .{});
    try w.flush();
    var child = try std.process.spawn(io, .{
        .argv = &.{ "mpv", "--no-config", "--vo=null", "--ao=null", "--frames=60", "--untimed", "--msg-level=all=error", loopback },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    const mpv_ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    try w.print("VERDICT (mpv): {s} ({any})\n", .{ if (mpv_ok) "PASS: mpv decoded frames" else "FAIL: mpv did not exit clean", term });
    try w.flush();
    if (!mpv_ok) std.process.exit(1);
}
