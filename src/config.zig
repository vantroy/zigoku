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
const paths = @import("paths.zig");

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
    default_quality: []const u8 = "best", // "best" | "1080" | "720" | "480" | "worst" — see domain.Quality (ROD-152)
    translation: []const u8 = "sub", // "sub" | "dub"
    resume_offset_sec: u32 = 5,
    skip_mode: []const u8 = "both", // "none" | "intro" | "outro" | "both"
    image_protocol: []const u8 = "auto", // "auto" | "kitty" | "halfblock" | "off"
    cover_art: bool = true,
    kanji_chips: bool = true,
    palette: []const u8 = "terminal_ghost", // "terminal_ghost" | "phosphor" | "nord" | "tokyonight"
    landing: []const u8 = "history", // "history" | "browse" | "last_watched" (ROD-228)
    title_language: []const u8 = "romaji", // "romaji" | "english" | "native" — primary show label (ROD-205)
    /// Max simultaneous Discover-grid cover downloads (ROD-240). The pump tops up
    /// to this many in-flight fetches each frame; covers beyond the cap wait for a
    /// slot to free. Read through `discoverCoverConcurrency`, which clamps it to a
    /// sane range so a 0 can't stall every fetch and a silly value can't spawn a
    /// thread storm.
    discover_cover_concurrency: u32 = 4,

    /// Master switch for the AniList sync side-rail (ROD-286). Off = every sync
    /// entry point no-ops: the action-triggered flush (ROD-291), the pull-on-launch
    /// (ROD-293), and the connect bootstrap (ROD-292) all check this before they arm
    /// or spawn, so a user who connected an account but wants sync paused gets a
    /// completely inert rail — no background threads, no whispers — while the token
    /// stays put. Defaults on: a fresh connect is expected to sync. The Settings
    /// "sync" toggle writes this; `hasAniList()` (a token) is orthogonal — this gates
    /// *whether* to sync, the token gates *whether we can*.
    anilist_sync_enabled: bool = true,

    /// Map `translation` onto the domain enum, defaulting to `.sub` for anything
    /// unrecognized. Kept here so every consumer agrees on the fallback.
    pub fn translationEnum(self: Config) domain.Translation {
        if (std.mem.eql(u8, self.translation, "dub")) return .dub;
        return .sub;
    }

    /// Map `landing` onto the startup-view choice, defaulting to `.history` for
    /// anything unrecognized — same degrade-at-callsite contract as
    /// `translationEnum`. `.last_watched` is a valid string today but the app
    /// folds it back to History until ROD-229 implements resume-landing; the
    /// value is reserved now so an early config never trips an older binary.
    pub fn landingEnum(self: Config) enum { browse, history, last_watched } {
        if (std.mem.eql(u8, self.landing, "browse")) return .browse;
        if (std.mem.eql(u8, self.landing, "last_watched")) return .last_watched;
        return .history;
    }

    /// Map `title_language` onto the primary-label choice (ROD-205), defaulting to
    /// `.romaji` for anything unrecognized — same degrade-at-callsite contract as
    /// `translationEnum`/`landingEnum`, so an unknown value renders romaji rather
    /// than failing. Consumers pass the result to `domain.preferredTitle`.
    pub fn titleLanguageEnum(self: Config) domain.TitleLanguage {
        if (std.mem.eql(u8, self.title_language, "english")) return .english;
        if (std.mem.eql(u8, self.title_language, "native")) return .native;
        return .romaji;
    }

    /// Lower / upper bound for `discover_cover_concurrency`. 1 keeps fetches making
    /// forward progress (0 would stall the grid forever); 16 caps the worst-case
    /// thread fan-out — the visible+prefetch set bounds it far lower in practice, so
    /// this is only a guard against a hand-edited config asking for hundreds.
    pub const discover_cover_concurrency_min: u32 = 1;
    pub const discover_cover_concurrency_max: u32 = 16;

    /// `discover_cover_concurrency` clamped to `[min, max]` (ROD-240). Every
    /// consumer reads through this so the bound is enforced in exactly one place —
    /// the raw field stays whatever the file said (round-trips unchanged on save).
    pub fn discoverCoverConcurrency(self: Config) u32 {
        return std.math.clamp(
            self.discover_cover_concurrency,
            discover_cover_concurrency_min,
            discover_cover_concurrency_max,
        );
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
    if (std.fs.path.dirname(path)) |dir| paths.ensureDir(dir);

    var file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    try std.zon.stringify.serialize(config, .{}, &writer.interface);
    try writer.interface.flush();
}

/// `{configDir}/config.zon` (see `paths.configDir`).
pub fn defaultPath(arena: Allocator) ![]const u8 {
    const dir = try paths.configDir(arena);
    return std.fmt.allocPrint(arena, "{s}/config.zon", .{dir});
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
    try testing.expectEqualStrings(want.palette, got.palette);
    try testing.expectEqualStrings(want.landing, got.landing);
    try testing.expectEqualStrings(want.title_language, got.title_language);
    try testing.expectEqual(want.discover_cover_concurrency, got.discover_cover_concurrency);
    try testing.expectEqual(want.anilist_sync_enabled, got.anilist_sync_enabled);
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
        .palette = "nord",
        .landing = "browse",
        .title_language = "english",
        .discover_cover_concurrency = 8,
        .anilist_sync_enabled = false,
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
    try testing.expectEqual(.history, (Config{}).landingEnum()); // default
}

test "titleLanguageEnum maps english and native, defaults everything else to romaji (ROD-205)" {
    try testing.expectEqual(.english, (Config{ .title_language = "english" }).titleLanguageEnum());
    try testing.expectEqual(.native, (Config{ .title_language = "native" }).titleLanguageEnum());
    try testing.expectEqual(.romaji, (Config{ .title_language = "romaji" }).titleLanguageEnum());
    try testing.expectEqual(.romaji, (Config{ .title_language = "garbage" }).titleLanguageEnum());
    try testing.expectEqual(.romaji, (Config{}).titleLanguageEnum()); // default
}

test "anilist_sync_enabled defaults on, round-trips a paused value (ROD-286)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Default: sync armed for a freshly-connected account.
    try testing.expect((Config{}).anilist_sync_enabled);
    // A user who paused sync must survive a reload as paused, not silently re-armed.
    try testing.expect(!parse(arena.allocator(), ".{ .anilist_sync_enabled = false }").anilist_sync_enabled);
}

test "discoverCoverConcurrency clamps to [min, max], default passes through" {
    try testing.expectEqual(@as(u32, 4), (Config{}).discoverCoverConcurrency()); // default
    try testing.expectEqual(@as(u32, 6), (Config{ .discover_cover_concurrency = 6 }).discoverCoverConcurrency());
    // 0 would stall every fetch — floored to the minimum.
    try testing.expectEqual(Config.discover_cover_concurrency_min, (Config{ .discover_cover_concurrency = 0 }).discoverCoverConcurrency());
    // A hand-edited absurd value is capped, not honoured.
    try testing.expectEqual(Config.discover_cover_concurrency_max, (Config{ .discover_cover_concurrency = 9999 }).discoverCoverConcurrency());
}
