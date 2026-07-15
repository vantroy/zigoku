//! `zigoku update` (ROD-371): decide how to update from install method + writability.
//!
//! Package ownership before writability: a package-managed binary in a root-owned
//! dir must not report "needs root" when the answer is "use your package manager".
//! Download/atomic swap is ROD-372.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const updatecheck = @import("updatecheck.zig");
const semver = @import("util/semver.zig");

const REPO = "vantroy/zigoku";

pub const InstallMethod = enum { pacman, brew, standalone };

/// Policy product of `decide` (testable without spawn/fs).
pub const Action = union(enum) {
    package_directions: InstallMethod,
    refuse_unwritable,
    /// Standalone + writable: bindir to update into.
    self_update: []const u8,
};

/// Package manager wins over writability; standalone self-updates only if writable.
pub fn decide(method: InstallMethod, bindir: []const u8, dir_writable: bool) Action {
    return switch (method) {
        .pacman, .brew => .{ .package_directions = method },
        .standalone => if (dir_writable) .{ .self_update = bindir } else .refuse_unwritable,
    };
}

/// Entry point. Expected conditions (offline, packaged, root-owned) are outcomes, not errors.
pub fn run(
    arena: Allocator,
    io: Io,
    out: *Io.Writer,
    current_version: []const u8,
    environ: *std.process.Environ.Map,
) !void {
    const exe = selfExePath(arena, io) catch {
        try out.print(
            \\couldn't locate the running zigoku binary.
            \\update by hand from https://github.com/{s}/releases
            \\
        , .{REPO});
        return;
    };
    const bindir = std.fs.path.dirname(exe) orelse exe;

    // Fresh check (not 6h cache). Offline still continues by install method.
    // Keep tag so the installer pins the compared release.
    var tag_buf: [64]u8 = undefined;
    var latest_tag: ?[]const u8 = null;
    if (updatecheck.latestFresh(arena, io, nowSecs(io))) |latest| {
        // Sanitize: forged tag_name must not emit terminal escapes.
        const clean = sanitizeTag(&tag_buf, latest);
        if (!semver.isNewer(clean, current_version)) {
            try out.print("zigoku v{s} is already the latest release.\n", .{current_version});
            return;
        }
        latest_tag = clean;
        try out.print("update available: v{s} -> {s}\n\n", .{ current_version, clean });
    } else {
        try out.print("couldn't reach GitHub to check the latest release; continuing anyway.\n\n", .{});
    }

    const method = detectMethod(arena, io, exe);
    switch (decide(method, bindir, dirWritable(io, bindir))) {
        .package_directions => |m| try printPackageDirections(out, m),
        .refuse_unwritable => try printRefusal(out, bindir),
        .self_update => |dir| try performUpdate(io, out, environ, dir, latest_tag),
    }
}

/// Drive install.sh in place: BINDIR + ZIGOKU_VERSION; stages + renames (checksum via install.sh, ROD-372).
fn performUpdate(
    io: Io,
    out: *Io.Writer,
    environ: *std.process.Environ.Map,
    bindir: []const u8,
    latest_tag: ?[]const u8,
) !void {
    try environ.put("BINDIR", bindir);
    if (latest_tag) |t| try environ.put("ZIGOKU_VERSION", t);

    // Pin install.sh to the release tag (not master) so a compromised master cannot
    // ignore the version pin. Env only, never shell-interpolated.
    const ref = if (latest_tag) |t| (if (safeRef(t)) t else "master") else "master";
    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "https://raw.githubusercontent.com/" ++ REPO ++ "/{s}/install.sh", .{ref}) catch {
        try out.print("couldn't build the installer URL\n", .{});
        return;
    };
    try environ.put("INSTALL_URL", url);

    try out.print("updating in place at {s} ...\n\n", .{bindir});
    try out.flush();

    // Download then run: `curl | sh` reports sh's exit (0 on empty stdin), hiding fetch failure.
    const cmd =
        \\set -e
        \\f=$(mktemp)
        \\trap 'rm -f "$f"' EXIT
        \\if command -v curl >/dev/null 2>&1; then curl -fsSL "$INSTALL_URL" -o "$f"; else wget -qO "$f" "$INSTALL_URL"; fi
        \\sh "$f"
    ;

    var child = std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", cmd },
        .environ_map = environ,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |e| {
        try out.print("couldn't launch the installer: {s}\n", .{@errorName(e)});
        return;
    };
    const term = child.wait(io) catch |e| {
        try out.print("installer did not complete: {s}\n", .{@errorName(e)});
        return;
    };
    switch (term) {
        .exited => |code| if (code == 0)
            try out.print("\nupdated. restart zigoku to run the new version.\n", .{})
        else
            try out.print("\nupdate failed (installer exited {d}); your existing binary is untouched.\n", .{code}),
        else => try out.print("\nupdate interrupted; your existing binary is untouched.\n", .{}),
    }
}

/// Safe git ref for raw.githubusercontent URL path (no slash/shell metachars).
fn safeRef(tag: []const u8) bool {
    if (tag.len == 0 or tag.len > 64) return false;
    for (tag) |ch| switch (ch) {
        'A'...'Z', 'a'...'z', '0'...'9', '.', '+', '_', '-' => {},
        else => return false,
    };
    return true;
}

fn selfExePath(arena: Allocator, io: Io) ![]const u8 {
    switch (builtin.os.tag) {
        .linux => {
            const buf = try arena.alloc(u8, std.fs.max_path_bytes);
            const n = try std.Io.Dir.readLinkAbsolute(io, "/proc/self/exe", buf);
            return buf[0..n];
        },
        .macos => return selfExePathDarwin(arena),
        else => return error.UnsupportedOs,
    }
}

// extern not @cImport: mach-o/dyld.h translate-c size-asserts fail on macOS.
extern "c" fn _NSGetExecutablePath(buf: [*c]u8, bufsize: *u32) c_int;

fn selfExePathDarwin(arena: Allocator) ![]const u8 {
    var size: u32 = 0;
    _ = _NSGetExecutablePath(null, &size);
    const buf = try arena.alloc(u8, size);
    if (_NSGetExecutablePath(buf.ptr, &size) != 0) return error.NameTooLong;
    return std.mem.sliceTo(buf, 0);
}

/// Package manager ownership. Missing tool → fall through to standalone.
fn detectMethod(arena: Allocator, io: Io, exe: []const u8) InstallMethod {
    switch (builtin.os.tag) {
        .linux => if (commandSucceeds(io, &.{ "pacman", "-Qo", exe })) return .pacman,
        .macos => {
            // `brew list zigoku` proves formula exists, not that THIS binary is it.
            // Compare path to `brew --prefix`. Unresolvable prefix → prefer .brew
            // (harmless advice vs corrupting brew bookkeeping with a self-update).
            if (commandSucceeds(io, &.{ "brew", "list", "zigoku" })) {
                if (commandOutput(arena, io, &.{ "brew", "--prefix" })) |prefix|
                    return if (hasPrefixDir(exe, prefix)) .brew else .standalone;
                return .brew;
            }
        },
        else => {},
    }
    return .standalone;
}

/// True if `path` equals `prefix` or is under it as a directory boundary.
fn hasPrefixDir(path: []const u8, prefix: []const u8) bool {
    const p = std.mem.trimEnd(u8, prefix, "/");
    if (p.len == 0 or !std.mem.startsWith(u8, path, p)) return false;
    return path.len == p.len or path[p.len] == '/';
}

fn commandSucceeds(io: Io, argv: []const []const u8) bool {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = child.wait(io) catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Trimmed stdout or null. Read pipe to EOF before wait (short output; no deadlock).
fn commandOutput(arena: Allocator, io: Io, argv: []const []const u8) ?[]const u8 {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;
    var pipe = child.stdout orelse {
        _ = child.wait(io) catch {};
        return null;
    };
    // Don't close pipe: child.wait closes stdio; manual close first = double-close BADF.
    var rbuf: [512]u8 = undefined;
    var reader = pipe.reader(io, &rbuf);
    const data = reader.interface.allocRemaining(arena, Io.Limit.limited(4096)) catch {
        _ = child.wait(io) catch {};
        return null;
    };
    const term = child.wait(io) catch return null;
    const ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) return null;
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

/// Relative path unresolvable here → not writable (refusal safer than false go-ahead).
fn dirWritable(io: Io, dir: []const u8) bool {
    if (!std.fs.path.isAbsolute(dir)) return false;
    std.Io.Dir.accessAbsolute(io, dir, .{ .write = true }) catch return false;
    return true;
}

fn printPackageDirections(out: *Io.Writer, method: InstallMethod) !void {
    switch (method) {
        .pacman => try out.print(
            \\zigoku was installed via the AUR. Update it with your AUR helper:
            \\  yay -S zigoku
            \\  # or: paru -S zigoku
            \\
        , .{}),
        .brew => try out.print(
            \\zigoku was installed via Homebrew. Update it with:
            \\  brew upgrade zigoku
            \\
        , .{}),
        .standalone => unreachable,
    }
}

fn printRefusal(out: *Io.Writer, bindir: []const u8) !void {
    try out.print(
        \\zigoku lives in {s}, which needs elevated permissions to write.
        \\Refusing to self-update a root-owned install. Either:
        \\  - re-run the installer with sudo, or
        \\  - reinstall to a writable dir via BINDIR, e.g.:
        \\      curl -fsS https://raw.githubusercontent.com/{s}/master/install.sh | BINDIR=$HOME/.local/bin sh
        \\
    , .{ bindir, REPO });
}

fn nowSecs(io: Io) i64 {
    const ts = std.Io.Clock.real.now(io);
    return @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_s));
}

/// Printable ASCII only: forged tag_name cannot smuggle terminal escapes through CLI stdout.
fn sanitizeTag(buf: []u8, tag: []const u8) []const u8 {
    var n: usize = 0;
    for (tag) |ch| {
        if (n == buf.len) break;
        if (ch >= 0x20 and ch < 0x7f) {
            buf[n] = ch;
            n += 1;
        }
    }
    return buf[0..n];
}

// ── Tests ──────────────────────────────────────────────────────────────────────

test "decide: a package manager owns the update regardless of writability" {
    try std.testing.expectEqual(InstallMethod.pacman, decide(.pacman, "/usr/bin", false).package_directions);
    try std.testing.expectEqual(InstallMethod.pacman, decide(.pacman, "/usr/bin", true).package_directions);
    try std.testing.expectEqual(InstallMethod.brew, decide(.brew, "/usr/local/bin", false).package_directions);
    try std.testing.expectEqual(InstallMethod.brew, decide(.brew, "/opt/homebrew/bin", true).package_directions);
}

test "decide: standalone self-updates only when its dir is writable" {
    try std.testing.expectEqualStrings("/home/u/.local/bin", decide(.standalone, "/home/u/.local/bin", true).self_update);
    try std.testing.expect(decide(.standalone, "/usr/local/bin", false) == .refuse_unwritable);
}

test "dirWritable: true for a writable temp dir, false for a missing or relative path" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.GetCwdFailed;
    const abs = try std.fmt.allocPrint(std.testing.allocator, "{s}/.zig-cache/tmp/{s}", .{ std.mem.sliceTo(&cwd_buf, 0), tmp.sub_path });
    defer std.testing.allocator.free(abs);

    try std.testing.expect(dirWritable(io, abs));
    try std.testing.expect(!dirWritable(io, "/definitely/not/a/real/dir/zzz"));
    try std.testing.expect(!dirWritable(io, "relative/path"));
}

test "hasPrefixDir: matches on a path boundary, not a bare string prefix" {
    try std.testing.expect(hasPrefixDir("/usr/local/bin/zigoku", "/usr/local"));
    try std.testing.expect(hasPrefixDir("/opt/homebrew/bin/zigoku", "/opt/homebrew"));
    try std.testing.expect(hasPrefixDir("/usr/local", "/usr/local"));
    try std.testing.expect(hasPrefixDir("/usr/local/bin/zigoku", "/usr/local/"));
    try std.testing.expect(!hasPrefixDir("/usr/local-other/bin/zigoku", "/usr/local"));
    try std.testing.expect(!hasPrefixDir("/home/u/.local/bin/zigoku", "/usr/local"));
}

test "safeRef: accepts version tags, rejects anything that could break out of a URL path" {
    try std.testing.expect(safeRef("v0.4.1"));
    try std.testing.expect(safeRef("0.10.0-rc1"));
    try std.testing.expect(!safeRef(""));
    try std.testing.expect(!safeRef("v1/../../etc"));
    try std.testing.expect(!safeRef("v1.0;rm -rf ~"));
    try std.testing.expect(!safeRef("v1.0 x"));
}

test "sanitizeTag: strips control bytes, leaves a clean tag intact" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("v0.5.0", sanitizeTag(&buf, "v0.5.0"));
    try std.testing.expectEqualStrings("v1.0[2J", sanitizeTag(&buf, "v1.0\x1b[2J"));
    try std.testing.expectEqualStrings("", sanitizeTag(&buf, "\x00\x07\x1b"));
}

test "commandOutput: captures + trims stdout, null on failure (the brew --prefix mechanism)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    try std.testing.expectEqualStrings("/opt/homebrew", commandOutput(a, io, &.{ "echo", "/opt/homebrew" }).?);
    try std.testing.expectEqual(@as(?[]const u8, null), commandOutput(a, io, &.{"false"}));
    try std.testing.expectEqual(@as(?[]const u8, null), commandOutput(a, io, &.{"zzz-no-such-command-zzz"}));
}
