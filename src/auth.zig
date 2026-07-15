//! AniList OAuth credentials (ROD-283).
//!
//! `{configDir}/auth.zon` holds the Implicit Grant bearer + identity, separate from
//! `config.zon` (ROD-85): secret is `0600` and never rides Settings round-trips.
//! Per-provider nest (`.anilist = .{…}`) for future MAL/Kitsu blocks.
//!
//! Load is total (missing/bad → `Auth{}` signed-out). `save` surfaces errors, writes `0600`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const paths = @import("paths.zig");

/// JWT ~1KB; refuse oversized files (signed-out) rather than slurp arbitrary blobs.
const max_bytes: usize = 16 * 1024;

/// AniList credentials. Empty `access_token` = signed out.
/// ~1-year JWTs, no refresh (ROD-282): `expires_at` is the whole expiry story.
pub const AniListAuth = struct {
    access_token: []const u8 = "",
    token_type: []const u8 = "Bearer",
    /// Unix seconds. 0 = unknown (e.g. hand-written file omitted it).
    expires_at: i64 = 0,
    /// Cached: MediaListCollection needs explicit userId; auth does not infer it.
    user_id: i64 = 0,
    user_name: []const u8 = "",

    /// `now_unix` injected for tests. Zero `expires_at` is not expired (prefer AniList 401
    /// over refusing an undated token).
    pub fn isExpired(self: AniListAuth, now_unix: i64) bool {
        return self.expires_at != 0 and now_unix >= self.expires_at;
    }
};

/// Deserialized auth file. `Auth{}` is always valid (no credentials).
/// Strings: static defaults or GPA-owned for process life (auth loads once; never freed).
pub const Auth = struct {
    anilist: AniListAuth = .{},

    pub fn hasAniList(self: Auth) bool {
        return self.anilist.access_token.len > 0;
    }
};

/// Total load: any failure → `Auth{}`.
pub fn load(gpa: Allocator, io: Io, path: []const u8) Auth {
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return .{};
    defer file.close(io);

    var reader = file.reader(io, &.{});
    const source = reader.interface.allocRemainingAlignedSentinel(
        gpa,
        Io.Limit.limited(max_bytes),
        .of(u8),
        0,
    ) catch return .{};
    defer gpa.free(source); // parse dupes kept strings; source is ours to drop.

    return parse(gpa, source);
}

/// Write ZON at `path`. File created owner-only `0600` atomically (bearer must never be
/// group/world-readable, even mid-write; parent dir is world-traversable). Surfaces errors.
pub fn save(io: Io, auth: Auth, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| paths.ensureDir(dir);

    var file = try std.Io.Dir.createFileAbsolute(io, path, .{ .permissions = .fromMode(0o600) });
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    try std.zon.stringify.serialize(auth, .{}, &writer.interface);
    try writer.interface.flush();
}

/// `{configDir}/auth.zon` (see `paths.configDir`).
pub fn defaultPath(arena: Allocator) ![]const u8 {
    const dir = try paths.configDir(arena);
    return std.fmt.allocPrint(arena, "{s}/auth.zon", .{dir});
}

/// Pure load half: ZON → Auth; signed-out on parse failure. Unknown fields ignored.
fn parse(gpa: Allocator, source: [:0]const u8) Auth {
    const auth = std.zon.parse.fromSliceAlloc(Auth, gpa, source, null, .{
        .ignore_unknown_fields = true,
    }) catch return .{};
    // C0 control in token (< 0x20): CR/LF trips std.http line assert (ReleaseSafe abort);
    // bare LF can inject headers. Refuse → signed-out. Real AniList JWT is base64url.
    if (hasControlBytes(auth.anilist.access_token)) return .{};
    return auth;
}

/// Any C0 control (< 0x20) that could break out of or smuggle into an HTTP header value.
fn hasControlBytes(s: []const u8) bool {
    for (s) |ch| {
        if (ch < 0x20) return true;
    }
    return false;
}

const testing = std.testing;

test "empty struct literal is signed out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = parse(arena.allocator(), ".{}");
    try testing.expect(!a.hasAniList());
    try testing.expectEqualStrings("Bearer", a.anilist.token_type);
}

test "a populated anilist block parses through" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = parse(arena.allocator(),
        \\.{ .anilist = .{
        \\    .access_token = "eyJfake.tok.en",
        \\    .expires_at = 1814703445,
        \\    .user_id = 7887529,
        \\    .user_name = "vantroy",
        \\} }
    );
    try testing.expect(a.hasAniList());
    try testing.expectEqualStrings("eyJfake.tok.en", a.anilist.access_token);
    try testing.expectEqual(@as(i64, 7887529), a.anilist.user_id);
    try testing.expectEqualStrings("vantroy", a.anilist.user_name);
}

test "malformed ZON degrades to signed out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect(!parse(arena.allocator(), "this is not zon !!!").hasAniList());
}

test "a token carrying control bytes degrades to signed out (ROD-284 hardening)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // ZON escapes become real C0 bytes; each must refuse (abort / header-injection).
    try testing.expect(!parse(a,
        \\.{ .anilist = .{ .access_token = "eyJfake\ntok" } }
    ).hasAniList());
    try testing.expect(!parse(a,
        \\.{ .anilist = .{ .access_token = "eyJfake\r\ntok" } }
    ).hasAniList());
    try testing.expect(!parse(a,
        \\.{ .anilist = .{ .access_token = "eyJfake\ttok" } }
    ).hasAniList());
    try testing.expect(parse(a,
        \\.{ .anilist = .{ .access_token = "eyJfake.tok.en" } }
    ).hasAniList());
}

test "unknown fields are ignored, not fatal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = parse(arena.allocator(),
        \\.{ .anilist = .{ .access_token = "t", .scope = "everything" }, .mal = .{} }
    );
    try testing.expect(a.hasAniList());
    try testing.expectEqualStrings("t", a.anilist.access_token);
}

test "serialized auth round-trips back through parse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const original: Auth = .{ .anilist = .{
        .access_token = "eyJheader.eyJpayload.sig",
        .token_type = "Bearer",
        .expires_at = 1814703445,
        .user_id = 7887529,
        .user_name = "vantroy",
    } };

    var aw = std.Io.Writer.Allocating.init(gpa);
    try std.zon.stringify.serialize(original, .{}, &aw.writer);
    const zon = try gpa.dupeZ(u8, aw.writer.buffered());

    const got = parse(gpa, zon);
    try testing.expectEqualStrings(original.anilist.access_token, got.anilist.access_token);
    try testing.expectEqual(original.anilist.expires_at, got.anilist.expires_at);
    try testing.expectEqual(original.anilist.user_id, got.anilist.user_id);
    try testing.expectEqualStrings(original.anilist.user_name, got.anilist.user_name);
}

test "isExpired honors the boundary and treats unknown expiry as live" {
    const tok: AniListAuth = .{ .expires_at = 1000 };
    try testing.expect(!tok.isExpired(999));
    try testing.expect(tok.isExpired(1000)); // at boundary = expired
    try testing.expect(tok.isExpired(1001));
    try testing.expect(!(AniListAuth{}).isExpired(std.math.maxInt(i64)));
}
