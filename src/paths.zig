//! Platform base-directory resolution (ROD-89): config, data, cache, runtime.
//!
//! Caller-owned `{base}/zigoku` from the passed allocator; none create the dir
//! (call `ensureDir`). `ensureDir` is io-free (raw `mkdir`) so pre-event-loop
//! callers like `Store.open` still work.
//!
//! Linux: XDG. macOS: `~/Library/...`. Windows: `error.Unsupported` (no silent scatter).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const c = @cImport({
    @cInclude("stdlib.h"); // getenv
    @cInclude("sys/stat.h"); // mkdir
});

pub const Error = error{ NoHomeDir, Unsupported, OutOfMemory };

/// config.zon home (ROD-85). Linux: `$XDG_CONFIG_HOME` → `~/.config/zigoku`.
/// macOS: `~/Library/Application Support/zigoku`.
pub fn configDir(gpa: Allocator) Error![]u8 {
    return switch (builtin.os.tag) {
        .windows => error.Unsupported,
        .macos => resolveXdg(gpa, null, env("HOME"), "Library/Application Support/zigoku"),
        else => resolveXdg(gpa, env("XDG_CONFIG_HOME"), env("HOME"), ".config/zigoku"),
    };
}

/// zigoku.db (ROD-65) + debug log (ROD-88). Linux: `$XDG_DATA_HOME` → `~/.local/share/zigoku`.
/// macOS: same Application Support path as config.
pub fn dataDir(gpa: Allocator) Error![]u8 {
    return switch (builtin.os.tag) {
        .windows => error.Unsupported,
        .macos => resolveXdg(gpa, null, env("HOME"), "Library/Application Support/zigoku"),
        else => resolveXdg(gpa, env("XDG_DATA_HOME"), env("HOME"), ".local/share/zigoku"),
    };
}

/// AniSkip skip.lua (ROD-83) + cover cache (ROD-79). Linux: `$XDG_CACHE_HOME` → `~/.cache/zigoku`.
/// macOS: `~/Library/Caches/zigoku`.
pub fn cacheDir(gpa: Allocator) Error![]u8 {
    return switch (builtin.os.tag) {
        .windows => error.Unsupported,
        .macos => resolveXdg(gpa, null, env("HOME"), "Library/Caches/zigoku"),
        else => resolveXdg(gpa, env("XDG_CACHE_HOME"), env("HOME"), ".cache/zigoku"),
    };
}

/// `$XDG_RUNTIME_DIR/zigoku`, else `/tmp/zigoku`. Never `NoHomeDir`: the mpv IPC
/// socket (ROD-80) must have a home even with no HOME env.
pub fn runtimeDir(gpa: Allocator) Error![]u8 {
    return switch (builtin.os.tag) {
        .windows => error.Unsupported,
        else => resolveRuntime(gpa, env("XDG_RUNTIME_DIR")),
    };
}

/// Display: collapse leading `$HOME/` to `~` (ROD-225 Settings). Outside HOME
/// (custom XDG on another volume, etc.) is duped verbatim. Caller always frees
/// exactly one slice, either branch.
pub fn collapseHome(gpa: Allocator, abs: []const u8) Allocator.Error![]u8 {
    return collapseHomeWith(gpa, abs, env("HOME"));
}

/// Pure `collapseHome` with `home` injected (testable without process env).
fn collapseHomeWith(gpa: Allocator, abs: []const u8, home: ?[]const u8) Allocator.Error![]u8 {
    if (home) |h| {
        // Path boundary after HOME: `/home/rod` must not swallow `/home/rodney/...`.
        if (h.len > 0 and abs.len > h.len and abs[h.len] == '/' and
            std.mem.startsWith(u8, abs, h))
        {
            return std.fmt.allocPrint(gpa, "~{s}", .{abs[h.len..]});
        }
    }
    return gpa.dupe(u8, abs);
}

/// `mkdir -p`, best-effort, no `io`. Ignores errors (EEXIST is common); real
/// failure surfaces on the later open underneath.
pub fn ensureDir(path: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len == 0 or path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;

    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            const saved = buf[i];
            buf[i] = 0;
            _ = c.mkdir(&buf, 0o755); // ignore EEXIST and friends
            buf[i] = saved;
        }
    }
}

// internals

fn env(name: [*:0]const u8) ?[]const u8 {
    return if (c.getenv(name)) |v| std.mem.span(v) else null;
}

/// Prefer non-empty `{xdg}/zigoku`, else `{home}/{home_rel}`, else `NoHomeDir`.
/// Pure (env injected) so precedence is unit-testable. macOS passes `xdg = null`.
fn resolveXdg(gpa: Allocator, xdg: ?[]const u8, home: ?[]const u8, home_rel: []const u8) Error![]u8 {
    if (xdg) |base| {
        if (base.len > 0) return std.fmt.allocPrint(gpa, "{s}/zigoku", .{base});
    }
    if (home) |h| {
        if (h.len > 0) return std.fmt.allocPrint(gpa, "{s}/{s}", .{ h, home_rel });
    }
    return error.NoHomeDir;
}

/// Runtime: XDG_RUNTIME_DIR or `/tmp/zigoku`. Never fails for want of an env var.
fn resolveRuntime(gpa: Allocator, xdg_runtime: ?[]const u8) Error![]u8 {
    if (xdg_runtime) |base| {
        if (base.len > 0) return std.fmt.allocPrint(gpa, "{s}/zigoku", .{base});
    }
    return gpa.dupe(u8, "/tmp/zigoku");
}

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "resolveXdg prefers a non-empty XDG base" {
    const got = try resolveXdg(testing.allocator, "/run/cfg", "/home/rod", ".config/zigoku");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/run/cfg/zigoku", got);
}

test "resolveXdg falls back to HOME when XDG is unset" {
    const got = try resolveXdg(testing.allocator, null, "/home/rod", ".config/zigoku");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/home/rod/.config/zigoku", got);
}

test "resolveXdg falls back to HOME when XDG is empty" {
    const got = try resolveXdg(testing.allocator, "", "/home/rod", ".local/share/zigoku");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/home/rod/.local/share/zigoku", got);
}

test "resolveXdg errors with neither XDG nor HOME" {
    try testing.expectError(error.NoHomeDir, resolveXdg(testing.allocator, null, null, ".config/zigoku"));
    try testing.expectError(error.NoHomeDir, resolveXdg(testing.allocator, "", "", ".config/zigoku"));
}

test "collapseHomeWith collapses a $HOME prefix to ~" {
    const got = try collapseHomeWith(testing.allocator, "/home/rod/.cache/zigoku/covers", "/home/rod");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("~/.cache/zigoku/covers", got);
}

test "collapseHomeWith leaves a path outside $HOME verbatim" {
    // Custom XDG on another volume must stay absolute.
    const got = try collapseHomeWith(testing.allocator, "/mnt/fast/zigoku/covers", "/home/rod");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/mnt/fast/zigoku/covers", got);
}

test "collapseHomeWith requires a path boundary after $HOME" {
    // `/home/rodney/...` must not collapse against HOME `/home/rod`.
    const got = try collapseHomeWith(testing.allocator, "/home/rodney/.cache/zigoku", "/home/rod");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/home/rodney/.cache/zigoku", got);
}

test "collapseHomeWith tolerates a null or empty HOME" {
    const a = try collapseHomeWith(testing.allocator, "/home/rod/.cache/zigoku", null);
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("/home/rod/.cache/zigoku", a);

    const b = try collapseHomeWith(testing.allocator, "/home/rod/.cache/zigoku", "");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("/home/rod/.cache/zigoku", b);
}

test "collapseHomeWith leaves a bare $HOME (no trailing slash) verbatim" {
    // Exactly HOME, no `/` after: no collapse, dupe as-is.
    const got = try collapseHomeWith(testing.allocator, "/home/rod", "/home/rod");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/home/rod", got);
}

test "resolveRuntime prefers XDG_RUNTIME_DIR" {
    const got = try resolveRuntime(testing.allocator, "/run/user/1000");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/run/user/1000/zigoku", got);
}

test "resolveRuntime falls back to /tmp" {
    const a = try resolveRuntime(testing.allocator, null);
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("/tmp/zigoku", a);

    const b = try resolveRuntime(testing.allocator, "");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("/tmp/zigoku", b);
}

test "macOS resolvers use the Apple Library conventions" {
    // Pure cores are tested above; this pins the Library literals on macOS CI
    // (ROD-149) so a green build proves the paths are right, not only that they compile.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const home = env("HOME") orelse return error.SkipZigTest;
    if (home.len == 0) return error.SkipZigTest; // empty HOME → resolveXdg errors

    const app_support = try std.fmt.allocPrint(testing.allocator, "{s}/Library/Application Support/zigoku", .{home});
    defer testing.allocator.free(app_support);
    const caches = try std.fmt.allocPrint(testing.allocator, "{s}/Library/Caches/zigoku", .{home});
    defer testing.allocator.free(caches);

    const cfg = try configDir(testing.allocator);
    defer testing.allocator.free(cfg);
    try testing.expectEqualStrings(app_support, cfg);

    const data = try dataDir(testing.allocator);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings(app_support, data);

    const cache = try cacheDir(testing.allocator);
    defer testing.allocator.free(cache);
    try testing.expectEqualStrings(caches, cache);

    // Assert both branches (XDG set vs /tmp fallback), not only the lucky one.
    const runtime = try runtimeDir(testing.allocator);
    defer testing.allocator.free(runtime);
    if (env("XDG_RUNTIME_DIR")) |xdg| {
        const expected = try std.fmt.allocPrint(testing.allocator, "{s}/zigoku", .{xdg});
        defer testing.allocator.free(expected);
        try testing.expectEqualStrings(expected, runtime);
    } else {
        try testing.expectEqualStrings("/tmp/zigoku", runtime);
    }
}

test "ensureDir tolerates empty and over-long paths" {
    ensureDir(""); // no-op, must not crash
    var huge: [std.fs.max_path_bytes + 8]u8 = undefined;
    @memset(&huge, 'a');
    ensureDir(&huge); // over-buffer, must bail cleanly
}

test "ensureDir creates a nested directory tree" {
    // io-free ensureDir: verify with libc stat, tear down with local rmdir (no unistd import).
    const libc = struct {
        extern fn rmdir(path: [*:0]const u8) c_int;
    };
    var anchor: u8 = 0;
    const root = try std.fmt.allocPrint(testing.allocator, "/tmp/zigoku-ensuredir-{x}", .{@intFromPtr(&anchor)});
    defer testing.allocator.free(root);
    const nested = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/a/b/c", .{root}, 0);
    defer testing.allocator.free(nested);

    ensureDir(nested);

    var st: c.struct_stat = undefined;
    try testing.expectEqual(@as(c_int, 0), c.stat(nested.ptr, &st));
    try testing.expect(st.st_mode & c.S_IFMT == c.S_IFDIR); // leaf is a directory

    // Teardown, deepest-first.
    for ([_][]const u8{ "/a/b/c", "/a/b", "/a", "" }) |sub| {
        const p = try std.fmt.allocPrintSentinel(testing.allocator, "{s}{s}", .{ root, sub }, 0);
        defer testing.allocator.free(p);
        _ = libc.rmdir(p.ptr);
    }
}
