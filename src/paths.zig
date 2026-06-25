//! Zigoku — platform base-directory resolution (ROD-89).
//!
//! Single source of truth for *where* Zigoku keeps its files. Folds together the
//! four near-identical resolvers that grew independently — data (`store`), config
//! (`config`), cache (`aniskip`), and the runtime/socket dir (`player`) — so the
//! XDG precedence, the macOS conventions, and the Windows stance all live in one
//! place instead of being re-derived (and drifting) per subsystem.
//!
//! Every resolver returns a caller-owned `{base}/zigoku` subdirectory allocated
//! from the passed allocator. None of them create the directory — call
//! `ensureDir` for that. Dir creation is deliberately `io`-free (raw `mkdir`) so
//! resolvers that run before the event loop exists (`Store.open`) can still make
//! their directories.
//!
//! * **Linux** honors the XDG base-directory spec.
//! * **macOS** uses the Apple conventions (`~/Library/...`).
//! * **Windows** is an explicit `error.Unsupported` stub — the binary exits with
//!   a clear message rather than scattering files somewhere surprising.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const c = @cImport({
    @cInclude("stdlib.h"); // getenv
    @cInclude("sys/stat.h"); // mkdir
});

pub const Error = error{ NoHomeDir, Unsupported, OutOfMemory };

/// `$XDG_CONFIG_HOME/zigoku` → `~/.config/zigoku` (Linux);
/// `~/Library/Application Support/zigoku` (macOS). Holds `config.zon` (ROD-85).
pub fn configDir(gpa: Allocator) Error![]u8 {
    return switch (builtin.os.tag) {
        .windows => error.Unsupported,
        .macos => resolveXdg(gpa, null, env("HOME"), "Library/Application Support/zigoku"),
        else => resolveXdg(gpa, env("XDG_CONFIG_HOME"), env("HOME"), ".config/zigoku"),
    };
}

/// `$XDG_DATA_HOME/zigoku` → `~/.local/share/zigoku` (Linux);
/// `~/Library/Application Support/zigoku` (macOS). Holds `zigoku.db` (ROD-65) and
/// the debug log (ROD-88).
pub fn dataDir(gpa: Allocator) Error![]u8 {
    return switch (builtin.os.tag) {
        .windows => error.Unsupported,
        .macos => resolveXdg(gpa, null, env("HOME"), "Library/Application Support/zigoku"),
        else => resolveXdg(gpa, env("XDG_DATA_HOME"), env("HOME"), ".local/share/zigoku"),
    };
}

/// `$XDG_CACHE_HOME/zigoku` → `~/.cache/zigoku` (Linux);
/// `~/Library/Caches/zigoku` (macOS). Holds the AniSkip `skip.lua` (ROD-83) and
/// cover-art cache (ROD-79).
pub fn cacheDir(gpa: Allocator) Error![]u8 {
    return switch (builtin.os.tag) {
        .windows => error.Unsupported,
        .macos => resolveXdg(gpa, null, env("HOME"), "Library/Caches/zigoku"),
        else => resolveXdg(gpa, env("XDG_CACHE_HOME"), env("HOME"), ".cache/zigoku"),
    };
}

/// `$XDG_RUNTIME_DIR/zigoku`, falling back to `/tmp/zigoku`. Unlike the others
/// this never reports `NoHomeDir`: an ephemeral mpv IPC socket (ROD-80) always
/// has somewhere to live, even on a stripped-down session with no HOME.
pub fn runtimeDir(gpa: Allocator) Error![]u8 {
    return switch (builtin.os.tag) {
        .windows => error.Unsupported,
        else => resolveRuntime(gpa, env("XDG_RUNTIME_DIR")),
    };
}

/// Collapse a leading `$HOME/` in `abs` to `~` for display, returning a fresh
/// slice owned by `gpa`. Paths outside `$HOME` — e.g. a custom `$XDG_CACHE_HOME`
/// pointed at another volume — are duped verbatim, so the caller always frees
/// exactly one slice regardless of which branch hit. Display-only: lets the
/// Settings view (ROD-225) show the real, XDG-aware path without leaking the
/// absolute home prefix.
pub fn collapseHome(gpa: Allocator, abs: []const u8) Allocator.Error![]u8 {
    return collapseHomeWith(gpa, abs, env("HOME"));
}

/// Pure core of `collapseHome` with `home` injected, so the prefix logic is
/// unit-testable without touching process env (mirrors `resolveXdg`).
fn collapseHomeWith(gpa: Allocator, abs: []const u8, home: ?[]const u8) Allocator.Error![]u8 {
    if (home) |h| {
        // Require the `/` after HOME so `/home/rod` can't swallow a sibling
        // like `/home/rodney/...`.
        if (h.len > 0 and abs.len > h.len and abs[h.len] == '/' and
            std.mem.startsWith(u8, abs, h))
        {
            return std.fmt.allocPrint(gpa, "~{s}", .{abs[h.len..]});
        }
    }
    return gpa.dupe(u8, abs);
}

/// `mkdir -p`, best-effort. Walks `path` creating each component, ignoring every
/// error — "already exists" is the common case, and a real failure surfaces
/// later when the caller tries to open a file underneath. No `io` required.
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

// ── internals ─────────────────────────────────────────────────────────────────

/// Read an environment variable as a Zig slice, or null if unset.
fn env(name: [*:0]const u8) ?[]const u8 {
    return if (c.getenv(name)) |v| std.mem.span(v) else null;
}

/// Pure base-dir join: prefer a non-empty XDG base (`{xdg}/zigoku`), else build
/// from HOME (`{home}/{home_rel}`), else `NoHomeDir`. Extracted out of the getenv
/// shells so the precedence is unit-testable without touching process env. On
/// macOS the caller passes `xdg = null`, collapsing this to the HOME branch.
fn resolveXdg(gpa: Allocator, xdg: ?[]const u8, home: ?[]const u8, home_rel: []const u8) Error![]u8 {
    if (xdg) |base| {
        if (base.len > 0) return std.fmt.allocPrint(gpa, "{s}/zigoku", .{base});
    }
    if (home) |h| {
        if (h.len > 0) return std.fmt.allocPrint(gpa, "{s}/{s}", .{ h, home_rel });
    }
    return error.NoHomeDir;
}

/// Like `resolveXdg` but for the runtime dir: `/tmp/zigoku` is always a valid
/// last resort, so this never fails for want of an env var.
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
    // A custom $XDG_CACHE_HOME on another volume — must show the real absolute path.
    const got = try collapseHomeWith(testing.allocator, "/mnt/fast/zigoku/covers", "/home/rod");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/mnt/fast/zigoku/covers", got);
}

test "collapseHomeWith requires a path boundary after $HOME" {
    // `/home/rodney/...` must not be collapsed against HOME `/home/rod`.
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
    // Exactly HOME with nothing after it: no `/`, so no collapse — duped as-is.
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
    // The `.macos` arms are comptime-dead off Darwin, and the resolver-level
    // functions (configDir/dataDir/cacheDir) are otherwise untested — the unit
    // tests above exercise only the pure `resolveXdg`/`resolveRuntime` cores. On
    // macOS CI (ROD-149) this pins the actual Library literals so a green build
    // proves the paths are *right*, not merely that they compile.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const home = env("HOME") orelse return error.SkipZigTest;
    if (home.len == 0) return error.SkipZigTest; // empty HOME → resolveXdg errors, not our case under test

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

    // No XDG_RUNTIME_DIR on Darwin → the ephemeral socket dir lands in /tmp.
    // Assert *both* branches rather than skipping if a runner happens to set it,
    // so the XDG-wins claim is actually verified instead of assumed.
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
    // `ensureDir` is io-free, so the whole test stays io-free: build a unique
    // scratch path, verify the chain with libc `stat`, tear down with libc
    // `rmdir` (declared locally to keep `unistd.h` out of the module surface).
    const libc = struct {
        extern fn rmdir(path: [*:0]const u8) c_int;
    };
    var anchor: u8 = 0; // a stack address is unique-enough; ensureDir is idempotent anyway
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
