//! `zigoku update` (ROD-371): the decision layer for self-update. Resolves the
//! running binary, works out how it was installed, then either points a packaged
//! user at their package manager, refuses when the binary sits in a dir we can't
//! write, or (standalone and writable) proceeds with the in-place update.
//!
//! Detection precedence is deliberate: a package-managed binary lives in a
//! root-owned dir (/usr/bin for the AUR, /usr/local/bin for Intel Homebrew), so
//! checking writability first would wrongly report "needs root" when the right
//! answer is "use your package manager". Package ownership is decided BEFORE
//! writability. The actual download and atomic swap is ROD-372.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const updatecheck = @import("updatecheck.zig");
const semver = @import("util/semver.zig");

const REPO = "vantroy/zigoku";

/// How the running binary got onto the machine.
pub const InstallMethod = enum { pacman, brew, standalone };

/// What `zigoku update` should do once it knows the install method and whether the
/// binary's dir is writable. Pure product of `decide`, so the policy is tested
/// without spawning a process or touching the filesystem.
pub const Action = union(enum) {
    /// Packaged: tell the user to update through their package manager.
    package_directions: InstallMethod,
    /// Standalone but the binary's dir isn't writable by us: refuse.
    refuse_unwritable,
    /// Standalone and writable: proceed with the self-update into this dir.
    self_update: []const u8,
};

/// The policy in one place: a package manager owns the update over any writability
/// question (see the module note); a standalone install self-updates only when we
/// can actually write its directory.
pub fn decide(method: InstallMethod, bindir: []const u8, dir_writable: bool) Action {
    return switch (method) {
        .pacman, .brew => .{ .package_directions = method },
        .standalone => if (dir_writable) .{ .self_update = bindir } else .refuse_unwritable,
    };
}

/// `zigoku update` entry point. Best-effort and chatty: it prints what it finds and
/// what it decides, then acts. Never returns an error for an expected condition
/// (offline, packaged, root-owned); those are outcomes, not failures. `environ`
/// is the process environment, forwarded (with BINDIR/ZIGOKU_VERSION added) to the
/// installer the self-update path spawns.
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

    // Explicit command → a fresh check, not the ambient 6h cache. Distinguish
    // "already current" (stop) from "couldn't reach GitHub" (press on: the user
    // asked to update, and we can still route them by install method). Keep the
    // tag to pin the installer's download to exactly the release we compared against.
    var latest_tag: ?[]const u8 = null;
    if (updatecheck.latestFresh(arena, io, nowSecs(io))) |latest| {
        if (!semver.isNewer(latest, current_version)) {
            try out.print("zigoku v{s} is already the latest release.\n", .{current_version});
            return;
        }
        latest_tag = latest;
        try out.print("update available: v{s} -> {s}\n\n", .{ current_version, latest });
    } else {
        try out.print("couldn't reach GitHub to confirm the latest release; continuing anyway.\n\n", .{});
    }

    const method = detectMethod(io, exe);
    switch (decide(method, bindir, dirWritable(io, bindir))) {
        .package_directions => |m| try printPackageDirections(out, m),
        .refuse_unwritable => try printRefusal(out, bindir),
        .self_update => |dir| try performUpdate(io, out, environ, dir, latest_tag),
    }
}

/// Drive install.sh to replace the binary in place: point BINDIR at our own dir and
/// pin ZIGOKU_VERSION to the tag we resolved, then run the installer and stream its
/// progress. The installer stages + renames (see install.sh), so a running binary is
/// replaced atomically and a mid-run failure leaves the current one intact. The
/// installer already verifies the download's checksum, which is why we drive it
/// rather than reimplement the fetch here (ROD-372).
fn performUpdate(
    io: Io,
    out: *Io.Writer,
    environ: *std.process.Environ.Map,
    bindir: []const u8,
    latest_tag: ?[]const u8,
) !void {
    try environ.put("BINDIR", bindir);
    if (latest_tag) |t| try environ.put("ZIGOKU_VERSION", t);

    try out.print("updating in place at {s} ...\n\n", .{bindir});
    try out.flush(); // the installer inherits stdout; flush ours first so lines don't interleave

    // Fetch install.sh with whichever downloader is present (mirrors install.sh's own
    // curl-or-wget probe), then pipe it to sh. BINDIR/ZIGOKU_VERSION reach the piped
    // shell through the inherited environment.
    const cmd = "if command -v curl >/dev/null 2>&1; then curl -fsSL https://raw.githubusercontent.com/" ++ REPO ++
        "/master/install.sh; else wget -qO- https://raw.githubusercontent.com/" ++ REPO ++
        "/master/install.sh; fi | sh";

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
            try out.print("\ninstaller exited with status {d}; your existing binary is untouched.\n", .{code}),
        else => try out.print("\ninstaller was interrupted; your existing binary is untouched.\n", .{}),
    }
}

/// Absolute path of the running binary. Linux reads `/proc/self/exe`; macOS asks
/// dyld. Any other target has no supported resolver.
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

const darwin = if (builtin.os.tag == .macos) @cImport(@cInclude("mach-o/dyld.h")) else void;

fn selfExePathDarwin(arena: Allocator) ![]const u8 {
    var size: u32 = 0;
    _ = darwin._NSGetExecutablePath(null, &size); // first call: learn the required length
    const buf = try arena.alloc(u8, size);
    if (darwin._NSGetExecutablePath(buf.ptr, &size) != 0) return error.NameTooLong;
    return std.mem.sliceTo(buf, 0); // dyld null-terminates; the path may be non-canonical (fine for dirname/access)
}

/// Which package manager, if any, owns the running binary. Exit-code-only probes:
/// a missing tool (pacman on non-Arch, brew on non-mac) fails to spawn and reads as
/// "not that manager", falling through to standalone.
fn detectMethod(io: Io, exe: []const u8) InstallMethod {
    switch (builtin.os.tag) {
        .linux => if (commandSucceeds(io, &.{ "pacman", "-Qo", exe })) return .pacman,
        .macos => if (commandSucceeds(io, &.{ "brew", "list", "zigoku" })) return .brew,
        else => {},
    }
    return .standalone;
}

/// True iff `argv` spawns and exits 0. A spawn failure (tool absent) or any nonzero
/// / signalled exit is false. stdio is discarded: we want the exit code, not output.
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

/// Whether we can write into `dir` (so an in-place swap is possible). A relative
/// path can't be resolved here, so it reads as not-writable (conservative: a refusal
/// is safer than a false "go ahead").
fn dirWritable(io: Io, dir: []const u8) bool {
    if (!std.fs.path.isAbsolute(dir)) return false;
    std.Io.Dir.accessAbsolute(io, dir, .{ .write = true }) catch return false;
    return true;
}

fn printPackageDirections(out: *Io.Writer, method: InstallMethod) !void {
    switch (method) {
        .pacman => try out.print(
            \\zigoku was installed from the AUR. Update it with your AUR helper:
            \\  yay -S zigoku
            \\  # or: paru -S zigoku
            \\
        , .{}),
        .brew => try out.print(
            \\zigoku was installed with Homebrew. Update it with:
            \\  brew upgrade zigoku
            \\
        , .{}),
        .standalone => unreachable, // decide() never routes standalone here
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

/// Wall-clock seconds since the epoch. Local mirror of the ms helper in workers so
/// this module needn't reach into the Store just for the clock.
fn nowSecs(io: Io) i64 {
    const ts = std.Io.Clock.real.now(io);
    return @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_s));
}

// ── Tests ──────────────────────────────────────────────────────────────────────

test "decide: a package manager owns the update regardless of writability" {
    // The precedence guard: even a writable packaged dir routes to the package manager.
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
    // Absolute path to the tmpDir, built the same way store.zig's tests do (its
    // handle is relative to .zig-cache/tmp), so accessAbsolute's absolute-path
    // contract holds.
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.GetCwdFailed;
    const abs = try std.fmt.allocPrint(std.testing.allocator, "{s}/.zig-cache/tmp/{s}", .{ std.mem.sliceTo(&cwd_buf, 0), tmp.sub_path });
    defer std.testing.allocator.free(abs);

    try std.testing.expect(dirWritable(io, abs));
    try std.testing.expect(!dirWritable(io, "/definitely/not/a/real/dir/zzz"));
    try std.testing.expect(!dirWritable(io, "relative/path")); // unresolvable → conservative false
}
