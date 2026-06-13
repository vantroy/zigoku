//! Zigoku — user config (ROD-85).
//!
//! One ZON file at `$XDG_CONFIG_HOME/zigoku/config.zon` (→ `~/.config/zigoku`)
//! holds the handful of knobs that used to be hardcoded: the mpv binary, the
//! sub/dub default, stream quality, resume rewind, AniSkip mode, and the image
//! protocol + chrome toggles the TUI reads.
//!
//! Loading is *total*: a missing, unreadable, or malformed file is never an
//! error — it yields the defaults below — so a corrupt config can never wedge
//! startup. `save` does surface errors; ROD-86 wires the Settings tab to mutate
//! a live `Config` and write it back on exit.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const domain = @import("domain.zig");
const c = @cImport({
    @cInclude("stdlib.h"); // getenv
});

/// A config file larger than this is almost certainly not ours — refuse it and
/// fall back to defaults rather than slurp an arbitrary blob into memory.
const max_bytes: usize = 64 * 1024;

/// The deserialized user config. Every field has a default, so a `Config{}` is
/// always valid. String fields stay as strings (not enums) so the Settings tab
/// can cycle them freely and an unrecognized value degrades to a sane default
/// at the *call site* rather than failing the whole parse — see `translationEnum`.
pub const Config = struct {
    // Bare "mpv" resolves via $PATH — matches Zigoku's pre-config behavior and
    // survives non-/usr/bin installs (brew, nix, /usr/local). Users can pin an
    // absolute path here. (Ticket suggested "/usr/bin/mpv"; PATH is safer.)
    mpv_path: []const u8 = "mpv",
    default_quality: []const u8 = "1080",
    translation: []const u8 = "sub", // "sub" | "dub"
    resume_offset_sec: u32 = 5,
    skip_mode: []const u8 = "both", // "none" | "intro" | "outro" | "both"
    image_protocol: []const u8 = "auto", // "auto" | "kitty" | "halfblock" | "off"
    cover_art: bool = true,
    kanji_chips: bool = true,

    /// Map `translation` onto the domain enum, defaulting to `.sub` for anything
    /// unrecognized. Kept here so every consumer agrees on the fallback.
    pub fn translationEnum(self: Config) domain.Translation {
        if (std.mem.eql(u8, self.translation, "dub")) return .dub;
        return .sub;
    }
};

/// Read and parse the config at `path`. Total: any failure — missing file,
/// unreadable, oversized, malformed ZON, wrong field type — yields `Config{}`.
///
/// The returned struct's string fields are either static defaults or owned by
/// `gpa`; they live for the process and are intentionally never freed (config
/// loads exactly once at startup).
pub fn load(gpa: Allocator, io: Io, path: []const u8) Config {
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

/// Serialize `config` to `path` as ZON, creating the parent directory if
/// needed. Unlike `load`, this surfaces errors — the Settings tab (ROD-86)
/// decides how to report a failed write.
pub fn save(io: Io, config: Config, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    }

    var file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    try std.zon.stringify.serialize(config, .{}, &writer.interface);
    try writer.interface.flush();
}

/// `$XDG_CONFIG_HOME/zigoku/config.zon`, falling back to `~/.config/zigoku/...`.
/// Mirrors `store.dataDir` / `aniskip.cacheDir`: every Zigoku path resolver
/// honors its XDG base dir. ROD-89 may fold these into one paths module.
pub fn defaultPath(arena: Allocator) ![]const u8 {
    const dir = try configDir(arena);
    return std.fmt.allocPrint(arena, "{s}/config.zon", .{dir});
}

fn configDir(arena: Allocator) ![]const u8 {
    if (c.getenv("XDG_CONFIG_HOME")) |x| {
        const base = std.mem.span(x);
        if (base.len > 0) return std.fmt.allocPrint(arena, "{s}/zigoku", .{base});
    }
    if (c.getenv("HOME")) |h| {
        const home = std.mem.span(h);
        if (home.len > 0) return std.fmt.allocPrint(arena, "{s}/.config/zigoku", .{home});
    }
    return error.NoHomeDir;
}

/// The pure half of `load`: ZON text → `Config`, defaults on any parse failure.
/// Unknown fields are ignored so a newer file never breaks an older binary.
fn parse(gpa: Allocator, source: [:0]const u8) Config {
    return std.zon.parse.fromSliceAlloc(Config, gpa, source, null, .{
        .ignore_unknown_fields = true,
    }) catch .{};
}

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectConfigEqual(want: Config, got: Config) !void {
    try testing.expectEqualStrings(want.mpv_path, got.mpv_path);
    try testing.expectEqualStrings(want.default_quality, got.default_quality);
    try testing.expectEqualStrings(want.translation, got.translation);
    try testing.expectEqual(want.resume_offset_sec, got.resume_offset_sec);
    try testing.expectEqualStrings(want.skip_mode, got.skip_mode);
    try testing.expectEqualStrings(want.image_protocol, got.image_protocol);
    try testing.expectEqual(want.cover_art, got.cover_art);
    try testing.expectEqual(want.kanji_chips, got.kanji_chips);
}

test "empty struct literal yields all defaults" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try expectConfigEqual(.{}, parse(arena.allocator(), ".{}"));
}

test "malformed ZON degrades to defaults" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try expectConfigEqual(.{}, parse(arena.allocator(), "this is not zon !!!"));
}

test "partial config overrides only the fields present" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = parse(arena.allocator(), ".{ .translation = \"dub\", .cover_art = false }");
    try testing.expectEqualStrings("dub", cfg.translation);
    try testing.expect(!cfg.cover_art);
    // Untouched fields keep their defaults.
    try testing.expectEqualStrings("mpv", cfg.mpv_path);
    try testing.expectEqual(@as(u32, 5), cfg.resume_offset_sec);
    try testing.expect(cfg.kanji_chips);
}

test "unknown fields are ignored, not fatal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = parse(arena.allocator(), ".{ .translation = \"dub\", .future_knob = 42 }");
    try testing.expectEqualStrings("dub", cfg.translation);
}

test "serialized config round-trips back through parse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const original: Config = .{
        .mpv_path = "/opt/mpv/bin/mpv",
        .default_quality = "720",
        .translation = "dub",
        .resume_offset_sec = 12,
        .skip_mode = "intro",
        .image_protocol = "kitty",
        .cover_art = false,
        .kanji_chips = false,
    };

    var aw = std.Io.Writer.Allocating.init(a);
    try std.zon.stringify.serialize(original, .{}, &aw.writer);
    const zon = try a.dupeZ(u8, aw.writer.buffered());

    try expectConfigEqual(original, parse(a, zon));
}

test "translationEnum maps dub, defaults everything else to sub" {
    try testing.expectEqual(.dub, (Config{ .translation = "dub" }).translationEnum());
    try testing.expectEqual(.sub, (Config{ .translation = "sub" }).translationEnum());
    try testing.expectEqual(.sub, (Config{ .translation = "garbage" }).translationEnum());
}
