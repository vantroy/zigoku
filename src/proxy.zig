//! Localhost HLS de-cloaking reverse proxy (ROD-443).
//!
//! Some CDNs (nekostream via p16-ad-sg.ibyteimg.com) prepend a decoy image header
//! to each MPEG-TS segment: 70 junk bytes (megaplay), 252 (anineko), then the real
//! TS sync at that offset. ffmpeg content-probes byte 0, sees the fake magic, and
//! classifies the whole stream as an image, fatal. No mpv/ffmpeg flag reaches the
//! inner segment demuxer, so the bytes must be stripped before mpv sees them.
//!
//! Shape: mpv talks plaintext HTTP to `127.0.0.1:<ephemeral>/r?u=<pct upstream>`.
//! Each request fetches the upstream (TLS, referer + UA), then either:
//!   - playlist (`#EXTM3U`): rewrite every URI to another `/r?u=…` loopback ref so
//!     variants and segments route back through here (relatives joined via hls.zig).
//!   - segment: strip the prefix to the first TS-sync triple, stream the rest.
//! Content-sniffing avoids parsing STREAM-INF vs EXTINF; scanning for the sync triple
//! is provider-agnostic (any prefix length, clean-from-0 and non-TS pass through).
//!
//! Lifecycle is one playback: `play` starts the proxy when the link is flagged, points
//! mpv at the loopback master, and tears it down on mpv exit. Every hop is re-guarded
//! against SSRF (ROD-266): a hostile playlist cannot bounce the proxy at a private IP.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const domain = @import("domain.zig");
const player = @import("player.zig");
const hls = @import("providers/hls.zig");
const fetchguard = @import("util/fetchguard.zig");
const deadline = @import("util/deadline.zig");
const log = @import("log.zig");

/// TS packet size; three consecutive sync bytes at this stride mark a real stream.
const TS_PACKET = 188;
/// Prefixes are tens-to-hundreds of bytes; bound the sync search so a mid-payload
/// 0x47 coincidence can never be mistaken for the stream start.
const MAX_PREFIX_SCAN = 4096;
/// Response ceiling per upstream object. Playlists are tiny; TS segments a few MiB.
const MAX_BODY = 32 << 20;
/// Redirect hops per upstream fetch (the ibyteimg 302 is one; leave headroom).
const MAX_REDIRECTS = 5;
/// Wall-clock ceiling on one upstream fetch (redirect chain + body). std has no
/// per-socket read timeout, so without this a CDN that accepts then goes silent parks a
/// handler forever and wedges stop()/play() through the drain (ROD-443 hardening).
const FETCH_DEADLINE_S = 30;
/// Backstop on drain(): handlers are bounded by FETCH_DEADLINE_S, so anything past this
/// is a stuck thread we abandon (the OS reclaims it at exit) rather than spin on.
const DRAIN_CAP_MS = 90_000;

/// Loopback request path + query prefix. The `.ts` suffix is deliberate: it sits in
/// ffmpeg's default extension allowlist (both allowed_extensions and, on ffmpeg 8+,
/// allowed_segment_extensions), so mpv never trips the HLS extension gate on our
/// extensionless upstreams, no `allowed_extensions=ALL` flag required. `u` carries the
/// fully pct-encoded upstream URL (dots encoded too, so `.ts` is the only extension).
const PATH_PREFIX = "/r.ts?u=";

const proxy_alloc = std.heap.page_allocator;

/// Drop-in for `player.play`: transparent when the link is not cloaked, otherwise
/// wraps the launch in a de-cloaking proxy scoped to this one playback. Same signature
/// so both callers (TUI worker, CLI) swap module name only.
pub fn play(
    arena: Allocator,
    io: Io,
    mpv_path: []const u8,
    link: domain.StreamLink,
    title: []const u8,
    start_seconds: u64,
    position_callback: ?player.PositionCallback,
    skip: ?player.SkipScript,
) !void {
    if (!link.decloak_segments)
        return player.play(arena, io, mpv_path, link, title, start_seconds, position_callback, skip);

    const p = Proxy.start(io, link) catch |e| {
        // Proxy is mandatory for a cloaked link; without it mpv only ever sees PNG-headed
        // segments. Surface the start failure rather than launch a guaranteed-dead stream.
        log.err("decloak proxy failed to start: {s}", .{@errorName(e)});
        return error.ProxyStartFailed;
    };
    defer p.stop();

    // mpv fetches the loopback master; referer/UA stay on the link so the softsub CDN
    // (separate host, not proxied) still authenticates. The link's cloaked_segments flag
    // is now belt-and-suspenders: loopback URLs end in .ts, which already clears mpv's
    // extension gate, so the allowed_extensions=ALL it appends is redundant, not required.
    var relinked = link;
    relinked.url = try p.loopbackUrl(arena, link.url);
    return player.play(arena, io, mpv_path, relinked, title, start_seconds, position_callback, skip);
}

/// In-flight handler accounting so `stop` cannot free `Proxy` mid-request. Plain atomics
/// (no Io.Mutex): drained once per playback end.
const Gate = struct {
    count: std.atomic.Value(usize) = .init(0),

    fn begin(g: *Gate) void {
        _ = g.count.fetchAdd(1, .acq_rel);
    }
    fn end(g: *Gate) void {
        _ = g.count.fetchSub(1, .acq_rel);
    }
    /// Wait out in-flight handlers. Caller must have stopped new `begin`s (accept thread
    /// joined). Sleeps between checks (never a hot spin) and gives up past DRAIN_CAP_MS so
    /// a wedged handler cannot hang teardown; with FETCH_DEADLINE_S bounding each fetch,
    /// the cap is only ever reached if something below std stalls uncancellably.
    fn drain(g: *Gate, io: Io) void {
        var waited_ms: u64 = 0;
        while (g.count.load(.acquire) != 0) {
            if (waited_ms >= DRAIN_CAP_MS) {
                log.warn("proxy drain: {d} handler(s) still in flight after {d}ms, abandoning", .{ g.count.load(.acquire), waited_ms });
                return;
            }
            io.sleep(Io.Duration.fromMilliseconds(5), .awake) catch {};
            waited_ms += 5;
        }
    }
};

pub const Proxy = struct {
    io: Io,
    server: Io.net.Server,
    port: u16,
    /// Duped from the link so handler threads never alias the caller's arena.
    referer: ?[]u8,
    user_agent: ?[]u8,
    accept_thread: std.Thread,
    gate: Gate = .{},
    shutting_down: std.atomic.Value(bool) = .init(false),

    /// Bind loopback:0, learn the ephemeral port, and spin the accept loop. Heap-owned
    /// (page allocator) for a stable address across the handler threads.
    pub fn start(io: Io, link: domain.StreamLink) !*Proxy {
        const self = try proxy_alloc.create(Proxy);
        errdefer proxy_alloc.destroy(self);

        var addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(0) };
        var server = try addr.listen(io, .{ .reuse_address = true });
        errdefer server.deinit(io);

        const referer = if (link.referer) |r| try proxy_alloc.dupe(u8, r) else null;
        errdefer if (referer) |r| proxy_alloc.free(r);
        const user_agent = if (link.user_agent) |u| try proxy_alloc.dupe(u8, u) else null;
        errdefer if (user_agent) |u| proxy_alloc.free(u);

        self.* = .{
            .io = io,
            .server = server,
            .port = server.socket.address.getPort(),
            .referer = referer,
            .user_agent = user_agent,
            .accept_thread = undefined,
        };
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        return self;
    }

    /// mpv's entry URL for `upstream`, on `arena` (lives as long as the play call).
    pub fn loopbackUrl(self: *Proxy, arena: Allocator, upstream: []const u8) ![]u8 {
        return buildLoopbackUrl(arena, self.port, upstream);
    }

    /// Stop accepting, wait out in-flight handlers, then free. Safe once `start` returned.
    pub fn stop(self: *Proxy) void {
        const io = self.io;
        self.shutting_down.store(true, .release);
        // Unblock a thread parked in accept(). shutdown()-wakes-accept holds only on Linux
        // (macOS/BSD returns ENOTCONN and leaves accept blocked), so self-dial the listener
        // once, mirroring login_loopback's requestCancel: the loop re-checks shutting_down
        // right after accept returns and exits.
        self.wakeAccept();
        self.accept_thread.join();
        self.gate.drain(io);
        self.server.deinit(io);
        if (self.referer) |r| proxy_alloc.free(r);
        if (self.user_agent) |u| proxy_alloc.free(u);
        proxy_alloc.destroy(self);
    }

    /// One best-effort loopback dial to wake a blocked accept(); a refused dial means the
    /// listener is already gone. Caller must have set shutting_down first.
    fn wakeAccept(self: *Proxy) void {
        var addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(self.port) };
        const stream = addr.connect(self.io, .{ .mode = .stream }) catch return;
        stream.close(self.io);
    }

    fn acceptLoop(self: *Proxy) void {
        while (true) {
            if (self.shutting_down.load(.acquire)) return;
            const stream = self.server.accept(self.io) catch {
                if (self.shutting_down.load(.acquire)) return;
                // Transient accept error while live: back off, don't hot-spin the core
                // (fd exhaustion would otherwise feed itself).
                self.io.sleep(Io.Duration.fromMilliseconds(5), .awake) catch {};
                continue;
            };
            if (self.shutting_down.load(.acquire)) {
                // The wake dial (or a late real conn) landed during shutdown; drop it.
                stream.close(self.io);
                return;
            }
            self.gate.begin();
            const t = std.Thread.spawn(.{}, handleConn, .{ self, stream }) catch {
                self.gate.end();
                stream.close(self.io);
                continue;
            };
            t.detach();
        }
    }

    fn handleConn(self: *Proxy, stream: Io.net.Stream) void {
        defer self.gate.end();
        defer stream.close(self.io);

        var recv_buf: [16 * 1024]u8 = undefined;
        var send_buf: [16 * 1024]u8 = undefined;
        var reader = stream.reader(self.io, &recv_buf);
        var writer = stream.writer(self.io, &send_buf);
        var server = std.http.Server.init(&reader.interface, &writer.interface);

        // Keep-alive loop: mpv reuses one connection across many segment GETs.
        while (true) {
            var req = server.receiveHead() catch return;
            self.serve(&req) catch |e| {
                // A client that hangs up mid-response (mpv seeking/stopping, ffprobe with
                // enough data) surfaces as a write-class error: a normal disconnect, not a
                // fault. Only genuine upstream/serve failures are worth a receipt.
                if (!isDisconnect(e)) {
                    log.warn("proxy serve {s}: {s}", .{ req.head.target, @errorName(e) });
                    req.respond("", .{ .status = .bad_gateway, .keep_alive = false }) catch {};
                }
                return;
            };
        }
    }

    fn serve(self: *Proxy, req: *std.http.Server.Request) !void {
        var arena_state = std.heap.ArenaAllocator.init(proxy_alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const target = req.head.target;
        if (!std.mem.startsWith(u8, target, PATH_PREFIX))
            return req.respond("", .{ .status = .not_found, .keep_alive = false });

        const upstream = try percentDecode(arena, target[PATH_PREFIX.len..]);
        // Bound the whole fetch (redirect chain + body read): a hostile CDN that accepts
        // then goes silent would otherwise park this handler forever. Byte-sanitise and
        // the per-hop SSRF guard both live inside fetchUpstream (covers redirects too).
        const fetched = try deadline.withDeadline(self.io, Io.Duration.fromSeconds(FETCH_DEADLINE_S), fetchUpstream, .{ arena, self.io, upstream, self.referer, self.user_agent });

        if (isPlaylist(fetched.body)) {
            const rewritten = try rewritePlaylist(arena, fetched.body, fetched.final_url, self.port);
            return req.respond(rewritten, .{ .extra_headers = &.{
                .{ .name = "content-type", .value = "application/vnd.apple.mpegurl" },
                .{ .name = "cache-control", .value = "no-store" },
            } });
        }
        return req.respond(decloak(fetched.body), .{ .extra_headers = &.{
            .{ .name = "content-type", .value = "video/mp2t" },
            .{ .name = "cache-control", .value = "no-store" },
        } });
    }
};

/// Client-gone-away errors from writing the response: expected on every seek/stop, not faults.
fn isDisconnect(e: anyerror) bool {
    return switch (e) {
        error.WriteFailed, error.BrokenPipe, error.ConnectionResetByPeer, error.Canceled => true,
        else => false,
    };
}

const Fetched = struct { body: []u8, final_url: []const u8 };

/// Fetch `start_url` with referer/UA, following redirects by hand so every hop is
/// SSRF-guarded. Body returned on `arena`; `final_url` is the hop relatives resolve against.
fn fetchUpstream(arena: Allocator, io: Io, start_url: []const u8, referer: ?[]const u8, user_agent: ?[]const u8) !Fetched {
    var url = start_url;
    var hops: u8 = 0;
    while (true) {
        // Reject control bytes BEFORE Uri.parse: a decoded upstream or a redirect Location
        // carrying CR/LF/NUL would otherwise reach the outbound request line unescaped
        // (Uri.parse does not strip them). Runs on every hop, so redirects get it too.
        if (!urlBytesClean(url)) return error.BadUpstreamUrl;
        try fetchguard.guardFetchUrl(url);
        const uri = std.Uri.parse(url) catch return error.BadUpstreamUrl;

        var client: std.http.Client = .{ .allocator = arena, .io = io };
        defer client.deinit();

        // identity: skip content-encoding so bytes need no decompression before de-cloak.
        const headers: std.http.Client.Request.Headers = .{
            .user_agent = if (user_agent) |u| .{ .override = u } else .default,
            .accept_encoding = .{ .override = "identity" },
        };
        const extra: []const std.http.Header = if (referer) |r|
            &.{.{ .name = "referer", .value = r }}
        else
            &.{};

        var req = try client.request(.GET, uri, .{
            .redirect_behavior = .unhandled, // handle 3xx here for the per-hop guard
            .headers = headers,
            .extra_headers = extra,
        });
        defer req.deinit();
        try req.sendBodiless();

        var response = try req.receiveHead(&.{});
        const status = response.head.status;
        if (status.class() == .redirect) {
            const loc = response.head.location orelse return error.RedirectNoLocation;
            if (hops >= MAX_REDIRECTS) return error.TooManyRedirects;
            hops += 1;
            // Location may be relative; resolve against the current hop before re-guarding.
            url = try hls.joinUrl(arena, url, loc);
            continue;
        }
        if (status.class() != .success) return error.UpstreamStatus;

        // 16 KiB, not 64 B: on the hot segment path a chunked upstream would otherwise read
        // in per-chunk-header sips and throttle throughput on a body run hundreds of times
        // per episode.
        var transfer_buf: [16 * 1024]u8 = undefined;
        const body_reader = response.reader(&transfer_buf);
        const body = try body_reader.allocRemaining(arena, .limited(MAX_BODY));
        return .{ .body = body, .final_url = url };
    }
}

/// A leading `#EXTM3U` (past an optional BOM/whitespace) marks a playlist vs a segment.
/// A NUL in the head rejects it: real m3u8 is text, so a binary segment wearing an
/// `#EXTM3U` prefix (the cloak trick in reverse, to route a segment into the rewriter
/// and get it shredded) fails the sniff and falls to the de-cloak path instead.
fn isPlaylist(body: []const u8) bool {
    var b = body;
    if (b.len >= 3 and b[0] == 0xEF and b[1] == 0xBB and b[2] == 0xBF) b = b[3..];
    b = std.mem.trimStart(u8, b, " \t\r\n");
    if (!std.mem.startsWith(u8, b, "#EXTM3U")) return false;
    const head = body[0..@min(body.len, 1024)];
    return std.mem.indexOfScalar(u8, head, 0) == null;
}

/// Strip any decoy prefix to the first TS-sync triple (0x47 at i, i+188, i+376). Clean
/// streams return unchanged (match at i=0); no sync in the scan window passes through
/// (fMP4/unknown, let mpv decide) rather than corrupting a stream we do not understand.
fn decloak(body: []const u8) []const u8 {
    const stride = TS_PACKET;
    var i: usize = 0;
    const limit = @min(body.len, MAX_PREFIX_SCAN);
    while (i < limit and i + 2 * stride < body.len) : (i += 1) {
        if (body[i] == 0x47 and body[i + stride] == 0x47 and body[i + 2 * stride] == 0x47)
            return body[i..];
    }
    // No sync in the window. Legit for fMP4; otherwise a segment whose decoy prefix
    // outgrew MAX_PREFIX_SCAN, which silently un-fixes ROD-443. Log so a prefix-size shift
    // is visible instead of a mute black screen (ROD-444 is the in-app surface for this).
    if (body.len >= 2 * stride and !looksLikeFmp4(body))
        log.warn("decloak: no TS sync in first {d}B of a {d}B segment; decoy prefix may exceed the scan window", .{ limit, body.len });
    return body;
}

/// ISO-BMFF (fMP4) starts with a box whose type at offset 4 is ftyp/styp/moof. Distinguishes
/// a legitimately-not-TS segment from one whose TS sync sits past the scan window.
fn looksLikeFmp4(body: []const u8) bool {
    if (body.len < 8) return false;
    const tag = body[4..8];
    return std.mem.eql(u8, tag, "ftyp") or std.mem.eql(u8, tag, "styp") or std.mem.eql(u8, tag, "moof");
}

/// Printable ASCII only (0x21-0x7e): a URL a real CDN serves. Rejects control bytes
/// (CR/LF/NUL), spaces, and high bytes that could split the outbound request line.
fn urlBytesClean(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c < 0x21 or c > 0x7e) return false;
    return true;
}

/// Rewrite every URI in a playlist to a loopback `/r?u=…` ref so variants and segments
/// route back through the proxy. URI lines and `URI="…"` tag attributes (KEY/MEDIA/MAP)
/// are joined against `base_url` and re-pointed; comments and blanks pass through.
fn rewritePlaylist(arena: Allocator, text: []const u8, base_url: []const u8, port: u16) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |raw| {
        if (!first) try out.append(arena, '\n');
        first = false;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') {
            try out.appendSlice(arena, try rewriteTagUri(arena, line, base_url, port));
        } else {
            const abs = try hls.joinUrl(arena, base_url, line);
            try out.appendSlice(arena, try buildLoopbackUrl(arena, port, abs));
        }
    }
    return out.toOwnedSlice(arena);
}

/// Re-point a `URI="…"` attribute inside a tag line; lines without one pass through.
fn rewriteTagUri(arena: Allocator, line: []const u8, base_url: []const u8, port: u16) ![]const u8 {
    const key = "URI=\"";
    const at = std.mem.indexOf(u8, line, key) orelse return line;
    const vstart = at + key.len;
    const vend_rel = std.mem.indexOfScalar(u8, line[vstart..], '"') orelse return line;
    const vend = vstart + vend_rel;
    const abs = try hls.joinUrl(arena, base_url, line[vstart..vend]);
    const lb = try buildLoopbackUrl(arena, port, abs);
    return std.mem.concat(arena, u8, &.{ line[0..vstart], lb, line[vend..] });
}

/// `http://127.0.0.1:<port>/r.ts?u=<pct upstream>` on `arena`.
fn buildLoopbackUrl(arena: Allocator, port: u16, upstream: []const u8) ![]u8 {
    const enc = try percentEncode(arena, upstream);
    return std.fmt.allocPrint(arena, "http://127.0.0.1:{d}" ++ PATH_PREFIX ++ "{s}", .{ port, enc });
}

/// Unreserved for our purposes EXCLUDING `.`: encoding dots keeps the loopback URL's
/// only extension the synthetic `.ts` in the path, never one leaking from the query.
fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '~';
}

fn hexDigit(nibble: u8) u8 {
    return if (nibble < 10) '0' + nibble else 'A' + (nibble - 10);
}

fn unhex(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Percent-encode all but RFC 3986 unreserved bytes: the whole upstream URL (scheme,
/// host, path, query) survives intact as one `u` query value through mpv and back.
fn percentEncode(arena: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (isUnreserved(c)) {
            try out.append(arena, c);
        } else {
            try out.append(arena, '%');
            try out.append(arena, hexDigit(c >> 4));
            try out.append(arena, hexDigit(c & 0x0f));
        }
    }
    return out.toOwnedSlice(arena);
}

fn percentDecode(arena: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%') {
            if (i + 2 >= s.len) return error.BadEncoding;
            const hi = unhex(s[i + 1]) orelse return error.BadEncoding;
            const lo = unhex(s[i + 2]) orelse return error.BadEncoding;
            try out.append(arena, (hi << 4) | lo);
            i += 3;
        } else {
            try out.append(arena, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(arena);
}

// ── Tests ────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "percent round-trips the full upstream URL, encoding reserved bytes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const url = "https://cdn.nekostream.site/x/master.m3u8?token=ab.cd_ef&exp=1720000000";
    const enc = try percentEncode(a, url);
    // Reserved bytes are escaped; only alnum - _ ~ stay literal. Dots are encoded too so
    // the loopback URL's sole extension is the synthetic `.ts` in its path.
    try testing.expect(std.mem.indexOfScalar(u8, enc, ':') == null);
    try testing.expect(std.mem.indexOfScalar(u8, enc, '/') == null);
    try testing.expect(std.mem.indexOfScalar(u8, enc, '?') == null);
    try testing.expect(std.mem.indexOfScalar(u8, enc, '&') == null);
    try testing.expect(std.mem.indexOfScalar(u8, enc, '.') == null);
    try testing.expectEqualStrings(url, try percentDecode(a, enc));
}

test "percentDecode rejects a truncated or invalid escape" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectError(error.BadEncoding, percentDecode(a, "abc%"));
    try testing.expectError(error.BadEncoding, percentDecode(a, "abc%2"));
    try testing.expectError(error.BadEncoding, percentDecode(a, "abc%zz"));
    try testing.expectEqualStrings("a b", try percentDecode(a, "a%20b"));
}

test "isPlaylist: EXTM3U past BOM/whitespace is a playlist, TS bytes are not" {
    try testing.expect(isPlaylist("#EXTM3U\n#EXT-X-VERSION:3\n"));
    try testing.expect(isPlaylist("\xEF\xBB\xBF#EXTM3U\n"));
    try testing.expect(isPlaylist("  \n#EXTM3U"));
    try testing.expect(!isPlaylist("\x47\x40\x00\x10"));
    try testing.expect(!isPlaylist(""));
    try testing.expect(!isPlaylist("\x89PNG\r\n"));
}

test "decloak strips a decoy prefix to the first TS-sync triple" {
    const stride = TS_PACKET;
    // Build 3 TS packets (0x47 every 188 bytes) behind a 70-byte PNG-ish prefix.
    var buf: [70 + 3 * TS_PACKET]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @intCast(i % 251);
    buf[0] = 0x89; // definitely not 0x47 at byte 0
    buf[70] = 0x47;
    buf[70 + stride] = 0x47;
    buf[70 + 2 * stride] = 0x47;
    const out = decloak(&buf);
    try testing.expectEqual(@as(usize, 3 * TS_PACKET), out.len);
    try testing.expectEqual(@as(u8, 0x47), out[0]);

    // Megaplay 70 / anineko 252 are both covered by the same scan.
    var buf2: [252 + 3 * TS_PACKET]u8 = undefined;
    for (&buf2, 0..) |*b, i| b.* = @intCast(i % 251);
    buf2[0] = 0x89;
    buf2[252] = 0x47;
    buf2[252 + stride] = 0x47;
    buf2[252 + 2 * stride] = 0x47;
    try testing.expectEqual(@as(usize, 3 * TS_PACKET), decloak(&buf2).len);
}

test "decloak passes clean and unrecognized streams through untouched" {
    // Clean TS from byte 0 matches at i=0 → unchanged.
    var clean: [3 * TS_PACKET]u8 = undefined;
    for (&clean, 0..) |*b, i| b.* = @intCast(i % 251);
    clean[0] = 0x47;
    clean[TS_PACKET] = 0x47;
    clean[2 * TS_PACKET] = 0x47;
    try testing.expectEqual(@as(usize, clean.len), decloak(&clean).len);
    try testing.expectEqual(@as(u8, 0x47), decloak(&clean)[0]);

    // No sync triple anywhere (fMP4-ish) → pass through, do not corrupt.
    const fmp4 = "\x00\x00\x00\x18ftypmp42" ** 8;
    try testing.expectEqualStrings(fmp4, decloak(fmp4));
}

test "rewritePlaylist re-points variants, segments, and URI tags to loopback" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const base = "https://cdn.nekostream.site/hls/master.m3u8";
    const master =
        "#EXTM3U\n" ++
        "#EXT-X-MEDIA:TYPE=AUDIO,URI=\"audio/en.m3u8\"\n" ++
        "#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=842x480\n" ++
        "480/index.m3u8\n" ++
        "#EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1920x1080\n" ++
        "https://other.cdn/1080/index.m3u8\n";
    const out = try rewritePlaylist(a, master, base, 45678);

    // Comment tags without a URI stay; the EXTM3U header survives.
    try testing.expect(std.mem.startsWith(u8, out, "#EXTM3U\n"));
    // Relative variant joined to base then wrapped.
    try testing.expect(std.mem.indexOf(u8, out, "http://127.0.0.1:45678/r.ts?u=") != null);
    // The absolute variant URL is encoded (no bare https:// left in a URI line).
    try testing.expect(std.mem.indexOf(u8, out, "\nhttps://other.cdn/1080") == null);
    // The audio rendition URI attribute was rewritten in place (tag prefix preserved).
    try testing.expect(std.mem.indexOf(u8, out, "#EXT-X-MEDIA:TYPE=AUDIO,URI=\"http://127.0.0.1:45678/r.ts?u=") != null);

    // Every rewritten target decodes back to a real upstream URL.
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        const marker = "/r.ts?u=";
        const at = std.mem.indexOf(u8, line, marker) orelse continue;
        var enc = line[at + marker.len ..];
        if (std.mem.indexOfScalar(u8, enc, '"')) |q| enc = enc[0..q];
        const decoded = try percentDecode(a, enc);
        try testing.expect(std.mem.startsWith(u8, decoded, "https://"));
    }
}

test "buildLoopbackUrl encodes upstream into a decodable loopback ref" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const up = "https://cdn.example/seg/000.ts?sig=xyz";
    const lb = try buildLoopbackUrl(a, 3210, up);
    try testing.expect(std.mem.startsWith(u8, lb, "http://127.0.0.1:3210/r.ts?u="));
    // Only the synthetic path extension; no literal dot leaks from the encoded upstream.
    try testing.expect(std.mem.count(u8, lb, ".ts") == 1);
    const enc = lb["http://127.0.0.1:3210/r.ts?u=".len..];
    try testing.expectEqualStrings(up, try percentDecode(a, enc));
}

test "urlBytesClean rejects CR/LF/NUL and other non-printables that could split a request" {
    try testing.expect(urlBytesClean("https://cdn.example/x/master.m3u8?sig=ab-cd_ef.gh"));
    // Decoded bytes a hostile playlist/redirect could smuggle past Uri.parse.
    try testing.expect(!urlBytesClean("https://cdn.example/x\r\nX-Injected: evil"));
    try testing.expect(!urlBytesClean("https://cdn.example/x\ny"));
    try testing.expect(!urlBytesClean("https://cdn.example/x\x00y"));
    try testing.expect(!urlBytesClean("https://cdn.example/a b")); // space
    try testing.expect(!urlBytesClean("https://cdn.example/\x7f")); // DEL
    try testing.expect(!urlBytesClean("")); // empty is not a URL
}

test "isPlaylist rejects a binary segment wearing an EXTM3U prefix (sniff spoof)" {
    // A real playlist is text and sniffs true.
    try testing.expect(isPlaylist("#EXTM3U\n#EXT-X-VERSION:3\nseg0\n"));
    // A TS segment prefixed with the magic bytes but carrying NULs must NOT be treated as a
    // playlist (would be shredded through the rewriter); it falls to the de-cloak path.
    var spoof: [512]u8 = undefined;
    @memcpy(spoof[0..8], "#EXTM3U\n");
    for (spoof[8..], 0..) |*b, i| b.* = if (i % 7 == 0) 0x00 else 0x47;
    try testing.expect(!isPlaylist(&spoof));
}

test "decloak passes through when the sync triple sits past the scan window" {
    // Exhaust path warns by design; keep the suite output clean (no std_options logFn here).
    const prev = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev;
    // Sync at offset 5000 (> MAX_PREFIX_SCAN): returned unchanged, never a wrong-offset
    // strip. Documents the ceiling so a prefix-size regression is a known pass-through.
    const stride = TS_PACKET;
    var buf: [5000 + 3 * TS_PACKET]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @intCast(i % 251);
    buf[0] = 0x89;
    buf[5000] = 0x47;
    buf[5000 + stride] = 0x47;
    buf[5000 + 2 * stride] = 0x47;
    try testing.expectEqual(@as(usize, buf.len), decloak(&buf).len);
    try testing.expectEqual(@as(u8, 0x89), decloak(&buf)[0]);
}

test "looksLikeFmp4 distinguishes ISO-BMFF from a TS-cloak that outgrew the window" {
    try testing.expect(looksLikeFmp4("\x00\x00\x00\x18ftypmp42"));
    try testing.expect(looksLikeFmp4("\x00\x00\x00\x18styp...."));
    try testing.expect(looksLikeFmp4("\x00\x00\x00\x18moof...."));
    try testing.expect(!looksLikeFmp4("\x89PNG\r\n\x1a\n"));
    try testing.expect(!looksLikeFmp4("\x47\x40\x00")); // too short / TS
}

test "Proxy lifecycle: stop() wakes accept and drains, no hang, after a live connection" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const link: domain.StreamLink = .{ .url = "https://example.invalid/master.m3u8", .decloak_segments = true };
    var p = try Proxy.start(io, link);
    // Open then close a client: exercises accept + a handler whose receiveHead sees EOF, so
    // no upstream fetch runs (no network). stop() must self-dial to unblock accept and drain
    // to completion; a regression here surfaces as this test hanging under the CI timeout.
    var addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(p.port) };
    const client = try addr.connect(io, .{ .mode = .stream });
    client.close(io);
    p.stop();
}
