//! Zigoku — AniList OAuth credentials (ROD-283).
//!
//! One ZON file at `{configDir}/auth.zon` (→ `~/.config/zigoku/auth.zon`) holds the OAuth
//! Implicit Grant bearer token and the identity it was minted for. Kept separate from
//! `config.zon` (ROD-85) on purpose: the secret gets its own `0600` file and never rides
//! along in the config the Settings tab round-trips on every edit.
//!
//! Credentials nest per-provider (`.anilist = .{ … }`) so a future MAL/Kitsu block slots in
//! without reshaping the file.
//!
//! Loading is TOTAL, like `config.zig`: a missing, unreadable, oversized, or malformed file
//! is never an error (it yields `Auth{}`, signed out), so a corrupt token file can't wedge
//! startup. `save` surfaces errors and writes `0600`; the capture flow decides how to report
//! a failed write.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const paths = @import("paths.zig");

/// A JWT is ~1KB; a token file an order of magnitude larger isn't ours — refuse it
/// and fall back to signed-out rather than slurp an arbitrary blob into memory.
const max_bytes: usize = 16 * 1024;

/// AniList credential block. An empty `access_token` means signed out. AniList
/// mints ~1-year JWTs with **no refresh token** (ROD-282), so `expires_at` is the
/// whole expiry story — when it passes, the user re-auths from scratch.
pub const AniListAuth = struct {
    access_token: []const u8 = "",
    token_type: []const u8 = "Bearer",
    /// Unix seconds. 0 = unknown (e.g. a hand-written file that omitted it).
    expires_at: i64 = 0,
    /// The AniList user the token belongs to. Cached here because the pull query
    /// (`MediaListCollection`) needs an explicit userId — auth doesn't infer it.
    user_id: i64 = 0,
    user_name: []const u8 = "",

    /// True once the token has aged out. `now_unix` is injected for testability.
    /// A zero (unknown) `expires_at` is treated as *not* expired: we'd rather send
    /// the token and let AniList 401 than refuse one we simply can't date.
    pub fn isExpired(self: AniListAuth, now_unix: i64) bool {
        return self.expires_at != 0 and now_unix >= self.expires_at;
    }
};

/// The deserialized auth file. Every field defaults, so `Auth{}` is always valid
/// and means "no credentials". String fields are either static defaults or owned
/// by `gpa`; they live for the process and are never freed (auth loads once).
pub const Auth = struct {
    anilist: AniListAuth = .{},

    /// True when we hold a non-empty AniList token.
    pub fn hasAniList(self: Auth) bool {
        return self.anilist.access_token.len > 0;
    }
};

/// Read and parse the auth file at `path`. Total: any failure — missing file,
/// unreadable, oversized, malformed ZON, wrong field type — yields `Auth{}`.
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
    defer gpa.free(source); // parse dupes every string it keeps; source is ours to drop.

    return parse(gpa, source);
}

/// Serialize `auth` to `path` as ZON, creating the parent directory if needed.
/// The file is created **owner-only (0600) atomically** — it carries a bearer
/// token, so it must never exist group/world-readable, not even for the span of
/// the write (the parent `~/.config/zigoku` is 0755/world-traversable). Unlike
/// `load`, this surfaces errors.
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

/// The pure half of `load`: ZON text → `Auth`, signed-out on any parse failure.
/// Unknown fields are ignored so a newer file never breaks an older binary.
fn parse(gpa: Allocator, source: [:0]const u8) Auth {
    const auth = std.zon.parse.fromSliceAlloc(Auth, gpa, source, null, .{
        .ignore_unknown_fields = true,
    }) catch return .{};
    // A token carrying a C0 control byte (< 0x20) is a corrupt or hand-edited file:
    // placed in a `Bearer` header, a CR/LF trips std.http's line-terminator assert
    // (a ReleaseSafe abort), and a bare LF slips that assert and rides onto the wire
    // as a header-injection vector. Refuse it — signed-out, the same degrade as any
    // malformed file — so a corrupt token can never reach the network layer. A real
    // AniList JWT is base64url dot-separated and never contains a control byte.
    if (hasControlBytes(auth.anilist.access_token)) return .{};
    return auth;
}

/// True if `s` carries any C0 control byte (< 0x20) — the bytes (CR, LF, tab, NUL…)
/// that would break out of, or smuggle into, an HTTP header value.
fn hasControlBytes(s: []const u8) bool {
    for (s) |ch| {
        if (ch < 0x20) return true;
    }
    return false;
}

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "empty struct literal is signed out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = parse(arena.allocator(), ".{}");
    try testing.expect(!a.hasAniList());
    try testing.expectEqualStrings("Bearer", a.anilist.token_type); // default holds
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
    // A hand-corrupted auth.zon: the ZON `\n`/`\r`/`\t` escapes decode to real
    // control bytes in the token. Each must refuse to load — a Bearer header built
    // from it would abort the process (CR/LF) or inject a header (bare LF).
    try testing.expect(!parse(a,
        \\.{ .anilist = .{ .access_token = "eyJfake\ntok" } }
    ).hasAniList());
    try testing.expect(!parse(a,
        \\.{ .anilist = .{ .access_token = "eyJfake\r\ntok" } }
    ).hasAniList());
    try testing.expect(!parse(a,
        \\.{ .anilist = .{ .access_token = "eyJfake\ttok" } }
    ).hasAniList());
    // A clean JWT-shaped token is untouched by the guard.
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
    try testing.expect(!tok.isExpired(999)); // before
    try testing.expect(tok.isExpired(1000)); // exactly at expiry counts as expired
    try testing.expect(tok.isExpired(1001)); // after
    // expires_at == 0 (unknown) is never treated as expired.
    try testing.expect(!(AniListAuth{}).isExpired(std.math.maxInt(i64)));
}
