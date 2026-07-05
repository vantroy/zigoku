//! ROD-283 (2b) spike — std.http.Server loopback listener for the OAuth redirect.
//!
//! De-risks the Zig 0.16 `std.Io.net` + `std.http.Server` surface before wiring
//! the real capture, and prototypes the fragment-relay the Implicit Grant forces:
//! the token comes back in the URL *fragment* (`#access_token=…`), which a browser
//! never sends to a server — so a bare loopback listener sees nothing. The fix is
//! a two-hop dance across two requests:
//!
//!   GET /            → serve an HTML+JS page that reads `location.hash` and
//!                      re-navigates to `/callback?<hash>` (now a query string)
//!   GET /callback?…  → the listener reads `access_token` & `state` from the QUERY
//!
//! Test:
//!   zig build spike-loopback            # then, in another shell:
//!   curl 'http://127.0.0.1:8765/callback?access_token=abc&state=xyz'
//!   # or open  http://127.0.0.1:8765/#access_token=abc&state=xyz  in a browser
//!
//! Throwaway — the real listener lands in ROD-283 (2b), feeding the captured query
//! string straight into `login.completeLogin` and checking `state` for CSRF.

const std = @import("std");
const net = std.Io.net;
const http = std.http;

const RELAY_PAGE =
    \\<!doctype html><meta charset="utf-8"><title>Zigoku sign-in</title>
    \\<body style="font:16px system-ui;padding:2rem">
    \\<p>Finishing sign-in… you can close this tab in a moment.</p>
    \\<script>
    \\  // The OAuth token arrives in the URL fragment (#…), which browsers never
    \\  // send to a server. Relay it to the loopback listener as a query string.
    \\  location.replace("/callback?" + location.hash.substring(1));
    \\</script></body>
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const port: u16 = if (args.len > 1) (std.fmt.parseInt(u16, args[1], 10) catch 8765) else 8765;

    var out_buf: [4096]u8 = undefined;
    var out_fw: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_fw.interface;

    var addr: net.IpAddress = .{ .ip4 = .loopback(port) };
    var server = addr.listen(io, .{ .reuse_address = true }) catch |err| {
        try out.print("✗ listen on 127.0.0.1:{d} failed: {s}\n", .{ port, @errorName(err) });
        try out.flush();
        return err;
    };
    defer server.deinit(io);

    try out.print("listening on http://127.0.0.1:{d}/  (Ctrl-C to quit)\n", .{port});
    try out.print("  browser: http://127.0.0.1:{d}/#access_token=abc&state=xyz\n", .{port});
    try out.print("  curl:    curl 'http://127.0.0.1:{d}/callback?access_token=abc&state=xyz'\n\n", .{port});
    try out.flush();

    while (true) {
        var stream = server.accept(io) catch |err| {
            try out.print("accept failed: {s}\n", .{@errorName(err)});
            try out.flush();
            return;
        };
        defer stream.close(io);

        var recv_buf: [8192]u8 = undefined;
        var send_buf: [8192]u8 = undefined;
        var conn_reader = stream.reader(io, &recv_buf);
        var conn_writer = stream.writer(io, &send_buf);
        var http_server: http.Server = .init(&conn_reader.interface, &conn_writer.interface);

        var request = http_server.receiveHead() catch |err| {
            try out.print("receiveHead failed: {s}\n", .{@errorName(err)});
            try out.flush();
            continue;
        };
        const target = request.head.target;
        try out.print("→ {s} {s}\n", .{ @tagName(request.head.method), target });
        try out.flush();

        if (std.mem.startsWith(u8, target, "/callback")) {
            const query = if (std.mem.indexOfScalar(u8, target, '?')) |i| target[i + 1 ..] else "";
            const token = queryParam(query, "access_token") orelse "(missing)";
            const state = queryParam(query, "state") orelse "(missing)";
            try out.print("  ✓ captured  access_token={s}  state={s}\n", .{ token, state });
            try out.flush();
            try request.respond("Signed in. You can close this tab.", .{
                .keep_alive = false,
                .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
            });
            try out.print("done — got the callback, exiting.\n", .{});
            try out.flush();
            return;
        }

        // Any other path (the browser's first landing) → serve the relay page.
        try request.respond(RELAY_PAGE, .{
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
        });
    }
}

/// Read `key`'s value out of a `k=v&k=v` query string, or null if absent.
/// (No percent-decoding — a JWT and a hex nonce are already URL-safe.)
fn queryParam(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}
