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
    package_directions: InstallMethod,
    refuse_unwritable,
    /// Standalone and writable: the payload is the bindir to update into.
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
    var tag_buf: [64]u8 = undefined;
    var latest_tag: ?[]const u8 = null;
    if (updatecheck.latestFresh(arena, io, nowSecs(io))) |latest| {
        // Sanitize before it touches the terminal: a forged tag_name (compromised
        // release / broken-TLS MITM) with control bytes must not emit raw escapes.
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

/// Drive install.sh to replace the binary in place: point BINDIR at our own dir and
/// pin ZIGOKU_VERSION to the resolved tag, then download the installer to a temp file
/// and run it, streaming its progress. The installer stages + renames (see install.sh),
/// so a running binary is replaced atomically and a mid-run failure leaves the current
/// one intact. We drive install.sh rather than reimplement the fetch because it already
/// verifies the download's checksum (ROD-372).
fn performUpdate(
    io: Io,
    out: *Io.Writer,
    environ: *std.process.Environ.Map,
    bindir: []const u8,
    latest_tag: ?[]const u8,
) !void {
    try environ.put("BINDIR", bindir);
    if (latest_tag) |t| try environ.put("ZIGOKU_VERSION", t);

    // Pin the installer SCRIPT to the release tag, not just the tarball: fetching
    // install.sh from `master` would let a compromised master script ignore the
    // version pin entirely. Fall back to `master` only with no usable tag (offline
    // path) or a tag that isn't a safe git ref. Built here and passed by env, never
    // interpolated into the shell string, so a forged tag can't inject.
    const ref = if (latest_tag) |t| (if (safeRef(t)) t else "master") else "master";
    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "https://raw.githubusercontent.com/" ++ REPO ++ "/{s}/install.sh", .{ref}) catch {
        try out.print("couldn't build the installer URL\n", .{});
        return;
    };
    try environ.put("INSTALL_URL", url);

    try out.print("updating in place at {s} ...\n\n", .{bindir});
    try out.flush(); // the installer inherits stdout; flush ours first so lines don't interleave

    // Download to a temp file and RUN it, NOT `curl | sh`: a pipe reports the pipeline's
    // exit as `sh`'s (0 on empty stdin), so a failed download would read as a successful
    // update. `set -e` aborts with the fetch's real status, which we surface below.
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

/// A tag safe to splice into a raw.githubusercontent URL path as a git ref: version
/// charset only, no slash (no path traversal), no shell metacharacters. Guards the
/// installer-URL construction against a forged `tag_name`.
fn safeRef(tag: []const u8) bool {
    if (tag.len == 0 or tag.len > 64) return false;
    for (tag) |ch| switch (ch) {
        'A'...'Z', 'a'...'z', '0'...'9', '.', '+', '_', '-' => {},
        else => return false,
    };
    return true;
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

// Declared extern, NOT via `@cImport("mach-o/dyld.h")`: that header pulls in mach
// message descriptor types whose translate-c size-asserts fail to compile on macOS.
// The one symbol we need lives in libSystem (linked via libc). `[*c]u8` so the first
// call can pass null to learn the length.
extern "c" fn _NSGetExecutablePath(buf: [*c]u8, bufsize: *u32) c_int;

fn selfExePathDarwin(arena: Allocator) ![]const u8 {
    var size: u32 = 0;
    _ = _NSGetExecutablePath(null, &size); // first call: learn the required length
    const buf = try arena.alloc(u8, size);
    if (_NSGetExecutablePath(buf.ptr, &size) != 0) return error.NameTooLong;
    return std.mem.sliceTo(buf, 0); // dyld null-terminates; the path may be non-canonical (fine for dirname/access)
}

/// Which package manager, if any, owns the running binary. Exit-code-only probes:
/// a missing tool (pacman on non-Arch, brew on non-mac) fails to spawn and reads as
/// "not that manager", falling through to standalone.
fn detectMethod(arena: Allocator, io: Io, exe: []const u8) InstallMethod {
    switch (builtin.os.tag) {
        .linux => if (commandSucceeds(io, &.{ "pacman", "-Qo", exe })) return .pacman,
        .macos => {
            // `brew list zigoku` only proves a zigoku formula exists SOMEWHERE, not that
            // THIS binary is it. Confirm by comparing the running path against brew's real
            // prefix (`brew --prefix`, so a custom HOMEBREW_PREFIX is handled, which two
            // hardcoded roots would miss). If the prefix won't resolve, prefer .brew:
            // telling a user to `brew upgrade` when they needn't is harmless, but
            // self-updating a brew-managed binary out of band corrupts brew's bookkeeping.
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

/// True if `path` equals `prefix` or sits under it as a directory (so `/usr/local`
/// matches `/usr/local/bin/zigoku` but not `/usr/local-other/...`). Pure, tested.
fn hasPrefixDir(path: []const u8, prefix: []const u8) bool {
    const p = std.mem.trimEnd(u8, prefix, "/");
    if (p.len == 0 or !std.mem.startsWith(u8, path, p)) return false;
    return path.len == p.len or path[p.len] == '/';
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

/// Run `argv` and return its trimmed stdout, or null on spawn failure / nonzero exit /
/// empty output. Reads the pipe to EOF before `wait()` (the callers' commands emit one
/// short line, far under any pipe buffer, so this can't deadlock). Output lives in `arena`.
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
    // Don't close `pipe` ourselves: child.wait's cleanup closes the child's stdio
    // handles, and a manual close first makes that a double-close (BADF panic).
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

/// Copy `tag` into `buf` keeping only printable ASCII, so a forged `tag_name` can't
/// smuggle terminal escapes through the CLI's raw stdout (the TUI toast drops control
/// bytes on its own; this closes the CLI path). A legit version tag is unchanged.
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

test "hasPrefixDir: matches on a path boundary, not a bare string prefix" {
    try std.testing.expect(hasPrefixDir("/usr/local/bin/zigoku", "/usr/local"));
    try std.testing.expect(hasPrefixDir("/opt/homebrew/bin/zigoku", "/opt/homebrew"));
    try std.testing.expect(hasPrefixDir("/usr/local", "/usr/local")); // exact
    try std.testing.expect(hasPrefixDir("/usr/local/bin/zigoku", "/usr/local/")); // trailing slash tolerated
    try std.testing.expect(!hasPrefixDir("/usr/local-other/bin/zigoku", "/usr/local")); // no false prefix match
    try std.testing.expect(!hasPrefixDir("/home/u/.local/bin/zigoku", "/usr/local"));
}

test "safeRef: accepts version tags, rejects anything that could break out of a URL path" {
    try std.testing.expect(safeRef("v0.4.1"));
    try std.testing.expect(safeRef("0.10.0-rc1"));
    try std.testing.expect(!safeRef("")); // empty
    try std.testing.expect(!safeRef("v1/../../etc")); // slash → traversal
    try std.testing.expect(!safeRef("v1.0;rm -rf ~")); // shell metachars
    try std.testing.expect(!safeRef("v1.0 x")); // space
}

test "sanitizeTag: strips control bytes, leaves a clean tag intact" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("v0.5.0", sanitizeTag(&buf, "v0.5.0"));
    // A forged tag with an escape sequence keeps only the printable bytes.
    try std.testing.expectEqualStrings("v1.0[2J", sanitizeTag(&buf, "v1.0\x1b[2J"));
    try std.testing.expectEqualStrings("", sanitizeTag(&buf, "\x00\x07\x1b"));
}

test "commandOutput: captures + trims stdout, null on failure (the brew --prefix mechanism)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    // `echo` stands in for `brew --prefix`: the trailing newline must be trimmed.
    try std.testing.expectEqualStrings("/opt/homebrew", commandOutput(a, io, &.{ "echo", "/opt/homebrew" }).?);
    // Nonzero exit → null.
    try std.testing.expectEqual(@as(?[]const u8, null), commandOutput(a, io, &.{"false"}));
    // Absent binary (spawn failure) → null.
    try std.testing.expectEqual(@as(?[]const u8, null), commandOutput(a, io, &.{"zzz-no-such-command-zzz"}));
}
