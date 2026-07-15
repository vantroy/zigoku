//! User config (ROD-85): `$XDG_CONFIG_HOME/zigoku/config.zon`.
//!
//! Load is total: missing/corrupt → defaults (cannot wedge startup). `save` surfaces errors.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const domain = @import("domain.zig");
const paths = @import("paths.zig");

/// Refuse oversized blobs; fall back to defaults.
const max_bytes: usize = 64 * 1024;

/// Every field defaults. Strings stay strings so Settings can cycle freely;
/// unrecognized values degrade at the call site (see translationEnum).
pub const Config = struct {
    // Bare "mpv" via $PATH (brew/nix/local). Absolute path ok.
    mpv_path: []const u8 = "mpv",
    default_quality: []const u8 = "best", // domain.Quality (ROD-152)
    translation: []const u8 = "sub",
    resume_offset_sec: u32 = 5,
    skip_mode: []const u8 = "both", // none|intro|outro|both
    image_protocol: []const u8 = "auto",
    cover_art: bool = true,
    kanji_chips: bool = true,
    palette: []const u8 = "terminal_ghost",
    landing: []const u8 = "history", // history|browse|last_watched (ROD-228)
    title_language: []const u8 = "romaji", // romaji|english|native (ROD-205)
    /// Max simultaneous Discover cover downloads (ROD-240). Read via discoverCoverConcurrency.
    discover_cover_concurrency: u32 = 4,
    /// Provider that leads resolve walks; "" = registry construction order (ROD-344).
    preferred_provider: []const u8 = "",
    /// AniList sync master switch (ROD-286). Off = inert rail; token stays put.
    anilist_sync_enabled: bool = true,
    /// Startup GitHub update check (ROD-370). Hard opt-out for offline/privacy/CI.
    check_for_updates: bool = true,

    pub fn translationEnum(self: Config) domain.Translation {
        if (std.mem.eql(u8, self.translation, "dub")) return .dub;
        return .sub;
    }

    /// last_watched reserved (ROD-229); app folds to History until implemented.
    pub fn landingEnum(self: Config) enum { browse, history, last_watched } {
        if (std.mem.eql(u8, self.landing, "browse")) return .browse;
        if (std.mem.eql(u8, self.landing, "last_watched")) return .last_watched;
        return .history;
    }

    pub fn titleLanguageEnum(self: Config) domain.TitleLanguage {
        if (std.mem.eql(u8, self.title_language, "english")) return .english;
        if (std.mem.eql(u8, self.title_language, "native")) return .native;
        return .romaji;
    }

    // min 1: 0 would stall the grid forever. max 16: worst-case fan-out guard, not a target (visible+prefetch bounds it far lower).
    pub const discover_cover_concurrency_min: u32 = 1;
    pub const discover_cover_concurrency_max: u32 = 16;

    /// Clamped concurrency (ROD-240), enforced in exactly one place. Raw field round-trips unchanged on save.
    pub fn discoverCoverConcurrency(self: Config) u32 {
        return std.math.clamp(
            self.discover_cover_concurrency,
            discover_cover_concurrency_min,
            discover_cover_concurrency_max,
        );
    }
};

/// Total: any failure yields Config{}. String fields static or gpa-owned for process life.
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
    defer gpa.free(source);

    return parse(gpa, source);
}

/// Surfaces errors (Settings decides how to report).
pub fn save(io: Io, config: Config, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| paths.ensureDir(dir);

    var file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    try std.zon.stringify.serialize(config, .{}, &writer.interface);
    try writer.interface.flush();
}

pub fn defaultPath(arena: Allocator) ![]const u8 {
    const dir = try paths.configDir(arena);
    return std.fmt.allocPrint(arena, "{s}/config.zon", .{dir});
}

/// Unknown fields ignored so a newer file never breaks an older binary.
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
    try testing.expectEqualStrings(want.palette, got.palette);
    try testing.expectEqualStrings(want.landing, got.landing);
    try testing.expectEqualStrings(want.title_language, got.title_language);
    try testing.expectEqual(want.discover_cover_concurrency, got.discover_cover_concurrency);
    try testing.expectEqualStrings(want.preferred_provider, got.preferred_provider);
    try testing.expectEqual(want.anilist_sync_enabled, got.anilist_sync_enabled);
    try testing.expectEqual(want.check_for_updates, got.check_for_updates);
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
        .palette = "nord",
        .landing = "browse",
        .title_language = "english",
        .discover_cover_concurrency = 8,
        .preferred_provider = "megaplay",
        .anilist_sync_enabled = false,
        .check_for_updates = false,
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

test "landingEnum maps browse and last_watched, defaults everything else to history" {
    try testing.expectEqual(.browse, (Config{ .landing = "browse" }).landingEnum());
    try testing.expectEqual(.last_watched, (Config{ .landing = "last_watched" }).landingEnum());
    try testing.expectEqual(.history, (Config{ .landing = "history" }).landingEnum());
    try testing.expectEqual(.history, (Config{ .landing = "garbage" }).landingEnum());
    try testing.expectEqual(.history, (Config{}).landingEnum());
}

test "titleLanguageEnum maps english and native, defaults everything else to romaji (ROD-205)" {
    try testing.expectEqual(.english, (Config{ .title_language = "english" }).titleLanguageEnum());
    try testing.expectEqual(.native, (Config{ .title_language = "native" }).titleLanguageEnum());
    try testing.expectEqual(.romaji, (Config{ .title_language = "romaji" }).titleLanguageEnum());
    try testing.expectEqual(.romaji, (Config{ .title_language = "garbage" }).titleLanguageEnum());
    try testing.expectEqual(.romaji, (Config{}).titleLanguageEnum());
}

test "preferred_provider defaults empty, round-trips a set value (ROD-344)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("", (Config{}).preferred_provider);
    try testing.expectEqualStrings(
        "megaplay",
        parse(arena.allocator(), ".{ .preferred_provider = \"megaplay\" }").preferred_provider,
    );
}

test "anilist_sync_enabled defaults on, round-trips a paused value (ROD-286)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect((Config{}).anilist_sync_enabled);
    try testing.expect(!parse(arena.allocator(), ".{ .anilist_sync_enabled = false }").anilist_sync_enabled);
}

test "discoverCoverConcurrency clamps to [min, max], default passes through" {
    try testing.expectEqual(@as(u32, 4), (Config{}).discoverCoverConcurrency());
    try testing.expectEqual(@as(u32, 6), (Config{ .discover_cover_concurrency = 6 }).discoverCoverConcurrency());
    try testing.expectEqual(Config.discover_cover_concurrency_min, (Config{ .discover_cover_concurrency = 0 }).discoverCoverConcurrency());
    try testing.expectEqual(Config.discover_cover_concurrency_max, (Config{ .discover_cover_concurrency = 9999 }).discoverCoverConcurrency());
}
