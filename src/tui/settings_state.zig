//! Settings controller subsystem (ROD-161).
//!
//! Owns Settings data model + edit state: row table, cursor, text-edit buffer.
//! Cycle/toggle/edit mutate a caller-passed `*Config` in place; never reaches
//! into App or navigation.
//!
//! Keystone: owns state transitions, not App-live projections. `onKey` returns
//! `KeyResult`; App.onSettingsKey maps `.config_changed` to palette/translation
//! re-sync. Persistence rides leave/quit via `dirty` (ROD-210), not a key verdict.
//! Embed by value; no `@fieldParentPtr`. View is `view/settings.zig`.

const std = @import("std");
const vaxis = @import("vaxis");
const config_mod = @import("../config.zig");

const Config = config_mod.Config;

// ── Settings tab model (ROD-86) ─────────────────────────────────────────────
// Interactive rows only; Catalog read-only rows are rendered separately and
// skipped by navigation. provider_names (runtime) backs the provider cycle.

// Shared with view/settings.zig via app.zig re-exports (ROD-144).
pub const SettingId = enum {
    mpv_path,
    default_quality,
    translation,
    resume_offset,
    skip_mode,
    provider,
    cover_art,
    kanji_chips,
    palette,
    landing,
    title_language,
    // ── AniList Sync (ROD-286) ──
    connect,
    anilist_sync,
    // ── Updates (ROD-370) ──
    check_for_updates,
};

/// Focusable row whose Enter fires a side effect (ROD-286 connect), not a config
/// edit. `value()` returns ""; subsystem reports `.connect_requested` only.
pub const SettingKind = enum { text, cycle, toggle, action };

pub const SettingRow = struct {
    id: SettingId,
    label: []const u8,
    kind: SettingKind,
    hint: []const u8,
};

pub const settings_rows = [_]SettingRow{
    .{ .id = .mpv_path, .label = "mpv path", .kind = .text, .hint = "enter to edit" },
    .{ .id = .default_quality, .label = "default quality", .kind = .cycle, .hint = "hjkl to cycle" },
    .{ .id = .translation, .label = "translation", .kind = .cycle, .hint = "hjkl to cycle" },
    .{ .id = .resume_offset, .label = "resume offset", .kind = .cycle, .hint = "hjkl to cycle" },
    .{ .id = .skip_mode, .label = "skip mode", .kind = .cycle, .hint = "hjkl to cycle" },
    // Provider order (ROD-344). Under Catalog header in drawSettings; index stays
    // contiguous. Presets injected at startup (`provider_names`), not hardcoded.
    .{ .id = .provider, .label = "provider", .kind = .cycle, .hint = "hjkl to cycle" },
    .{ .id = .cover_art, .label = "cover art", .kind = .toggle, .hint = "space to toggle" },
    .{ .id = .kanji_chips, .label = "kanji chips", .kind = .toggle, .hint = "space to toggle" },
    .{ .id = .palette, .label = "palette", .kind = .cycle, .hint = "hjkl to cycle" },
    .{ .id = .landing, .label = "landing view", .kind = .cycle, .hint = "hjkl to cycle" },
    .{ .id = .title_language, .label = "title language", .kind = .cycle, .hint = "hjkl to cycle" },
    // AniList Sync (ROD-286): connect action + sync toggle. Account status row is
    // rendered separately (not focusable), so it is not in this table.
    .{ .id = .connect, .label = "connect", .kind = .action, .hint = "enter to connect" },
    .{ .id = .anilist_sync, .label = "sync", .kind = .toggle, .hint = "space to toggle" },
    // Updates (ROD-370): startup update-check opt-out.
    .{ .id = .check_for_updates, .label = "check", .kind = .toggle, .hint = "space to toggle" },
};

/// Interactive row count (Catalog rows excluded). Exposed for tests.
pub const settings_row_count = settings_rows.len;

comptime {
    // drawSettings group boundaries. Break the build on silent section misattribution.
    std.debug.assert(settings_rows.len == 14);
    std.debug.assert(settings_rows[4].id == .skip_mode); // last Player
    std.debug.assert(settings_rows[5].id == .provider); // Catalog (ROD-344)
    std.debug.assert(settings_rows[6].id == .cover_art); // first Interface
    std.debug.assert(settings_rows[10].id == .title_language); // last Interface (ROD-205)
    std.debug.assert(settings_rows[11].id == .connect); // first AniList Sync
    std.debug.assert(settings_rows[12].id == .anilist_sync); // last AniList Sync
    std.debug.assert(settings_rows[13].id == .check_for_updates); // Updates (ROD-370)
}

const quality_presets = [_][]const u8{ "worst", "480", "720", "1080", "best" };
const translation_presets = [_][]const u8{ "sub", "dub" };
const skip_presets = [_][]const u8{ "none", "intro", "outro", "both" };
const resume_presets = [_]u32{ 0, 3, 5, 10, 15, 30 };
const palette_presets = [_][]const u8{ "terminal_ghost", "phosphor", "nord", "tokyonight" };
// All three landing views live (ROD-229 resume-landing).
const landing_presets = [_][]const u8{ "history", "browse", "last_watched" };
// Primary show-label forms (ROD-205). No "auto": english already falls back.
const title_language_presets = [_][]const u8{ "romaji", "english", "native" };

/// Step preset list after (`dir > 0`) or before current, wrapping. Unrecognized → index 0.
/// Returns a static preset literal (safe for config string fields).
fn cyclePreset(presets: []const []const u8, current: []const u8, dir: i8) []const u8 {
    var idx: usize = 0;
    for (presets, 0..) |p, i| {
        if (std.mem.eql(u8, p, current)) {
            idx = i;
            break;
        }
    }
    const n = presets.len;
    return presets[if (dir > 0) (idx + 1) % n else (idx + n - 1) % n];
}

fn cyclePresetU32(presets: []const u32, current: u32, dir: i8) u32 {
    var idx: usize = 0;
    for (presets, 0..) |p, i| {
        if (p == current) {
            idx = i;
            break;
        }
    }
    const n = presets.len;
    return presets[if (dir > 0) (idx + 1) % n else (idx + n - 1) % n];
}

/// Cycle a cycle-kind setting. Writes only `config`; App re-derives live projections
/// on `.config_changed`. `provider_names` is the one runtime preset list.
fn cycle(config: *Config, id: SettingId, dir: i8, provider_names: []const []const u8) void {
    switch (id) {
        .default_quality => config.default_quality = cyclePreset(&quality_presets, config.default_quality, dir),
        .translation => config.translation = cyclePreset(&translation_presets, config.translation, dir),
        .skip_mode => config.skip_mode = cyclePreset(&skip_presets, config.skip_mode, dir),
        .resume_offset => config.resume_offset_sec = cyclePresetU32(&resume_presets, config.resume_offset_sec, dir),
        .palette => config.palette = cyclePreset(&palette_presets, config.palette, dir),
        .landing => config.landing = cyclePreset(&landing_presets, config.landing, dir),
        .title_language => config.title_language = cyclePreset(&title_language_presets, config.title_language, dir),
        // Provider names are vtable statics (ROD-344). Empty list (tests) leaves row inert.
        .provider => if (provider_names.len > 0) {
            config.preferred_provider = cycleProvider(provider_names, config.preferred_provider, dir);
        },
        else => {},
    }
}

/// Cycle provider preference: unset ("") then each name, wrapping.
/// Unset is a real stop: "" means follow registry leader; an explicit pin to the
/// same name does not (leader can change under a pin) (ROD-344).
fn cycleProvider(names: []const []const u8, current: []const u8, dir: i8) []const u8 {
    // Positions: 0 = unset, 1..names.len = names[pos - 1].
    const n = names.len + 1;
    var idx: usize = 0;
    for (names, 0..) |p, i| {
        if (std.mem.eql(u8, p, current)) {
            idx = i + 1;
            break;
        }
    }
    const next = if (dir > 0) (idx + 1) % n else (idx + n - 1) % n;
    return if (next == 0) "" else names[next - 1];
}

fn toggle(config: *Config, id: SettingId) void {
    switch (id) {
        .cover_art => config.cover_art = !config.cover_art,
        .kanji_chips => config.kanji_chips = !config.kanji_chips,
        .anilist_sync => config.anilist_sync_enabled = !config.anilist_sync_enabled, // ROD-286
        .check_for_updates => config.check_for_updates = !config.check_for_updates, // ROD-370
        else => {},
    }
}

/// Settings tab controller (ROD-161). Cursor + text-edit buffer; mutates caller `*Config`.
/// Never touches App, nav, palette, translation, or toasts.
pub const SettingsState = struct {
    /// Cursor over interactive rows only.
    cursor: usize = 0,
    /// Focused text field capturing printable keys.
    editing: bool = false,
    /// Live edit buffer while `editing`.
    edit_buf: [256]u8 = undefined,
    edit_len: usize = 0,
    /// Committed mpv_path home so the edit outlives the edit buffer.
    text_buf: [256]u8 = undefined,
    /// Formatted scalar values (e.g. "5s"). App-owned; vaxis holds slice until render.
    value_buf: [16]u8 = undefined,
    /// Provider row "name (default)" form (ROD-344). Separate from value_buf:
    /// value() runs once per row in one draw; shared buffer would clobber siblings.
    provider_value_buf: [48]u8 = undefined,

    /// Registry provider names in construction order, injected by run() (ROD-344).
    /// Static vtable strings; caller owns the slice for app lifetime. Empty → row inert.
    provider_names: []const []const u8 = &.{},

    /// Config mutated since enter/last save. leave/quit persists only when set (ROD-210).
    dirty: bool = false,

    /// What a settings keypress means to App. Reports change; App projects live state.
    pub const KeyResult = enum {
        /// Fall through to global key chain.
        ignored,
        /// Consumed; no App follow-up.
        consumed,
        /// Config mutated in a way App projects live (palette / translation).
        config_changed,
        /// Action row invoked (ROD-286 connect). App fires beginConnect.
        connect_requested,
    };

    /// Clean entry state. Controller calls when Settings is (re)entered.
    pub fn reset(self: *SettingsState) void {
        self.cursor = 0;
        self.editing = false;
        self.dirty = false;
    }

    /// Handle key while Settings active. While editing, delegates to editKey.
    pub fn onKey(self: *SettingsState, key: vaxis.Key, config: *Config) KeyResult {
        if (self.editing) return self.editKey(key, config);

        const row = settings_rows[self.cursor];
        if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
            if (self.cursor + 1 < settings_rows.len) self.cursor += 1;
            return .consumed;
        }
        if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
            if (self.cursor > 0) self.cursor -= 1;
            return .consumed;
        }
        if (key.matches('l', .{}) or key.matches(vaxis.Key.right, .{})) {
            if (row.kind == .cycle) {
                cycle(config, row.id, 1, self.provider_names);
                self.dirty = true;
                return .config_changed;
            }
            return .consumed;
        }
        if (key.matches('h', .{}) or key.matches(vaxis.Key.left, .{})) {
            if (row.kind == .cycle) {
                cycle(config, row.id, -1, self.provider_names);
                self.dirty = true;
                return .config_changed;
            }
            return .consumed;
        }
        if (key.matches(vaxis.Key.space, .{})) {
            if (row.kind == .toggle) {
                toggle(config, row.id);
                self.dirty = true;
            }
            // `.consumed`, not `.config_changed`: cover_art/kanji_chips have no App
            // live projection (unlike translation/palette). A new projecting toggle
            // would need `.config_changed` here.
            return .consumed;
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            if (row.kind == .text) self.beginEdit(config, row.id);
            // ROD-286: action row reports intent; do not touch App here.
            if (row.kind == .action) return .connect_requested;
            return .consumed;
        }
        // `q` falls through to global quit (ROD-210); dirty drives leave/quit write.
        return .ignored;
    }

    /// Edit mode: swallow all keys except Ctrl-C emergency quit. Esc/Enter resolve edit.
    fn editKey(self: *SettingsState, key: vaxis.Key, config: *Config) KeyResult {
        // Ctrl-C must hard-quit from anywhere, including a modal text field.
        if (key.matches('c', .{ .ctrl = true })) return .ignored;
        if (key.matches(vaxis.Key.escape, .{})) {
            self.editing = false;
            return .consumed;
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            self.commitEdit(config);
            return .consumed;
        }
        if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.edit_len > 0) self.edit_len -= 1;
            return .consumed;
        }
        if (key.text) |text| {
            for (text) |ch| {
                // Printable ASCII only (paths/presets never need control bytes).
                if (ch >= 0x20 and ch < 0x7f and self.edit_len < self.edit_buf.len) {
                    self.edit_buf[self.edit_len] = ch;
                    self.edit_len += 1;
                }
            }
        }
        return .consumed;
    }

    fn beginEdit(self: *SettingsState, config: *const Config, id: SettingId) void {
        const cur: []const u8 = switch (id) {
            .mpv_path => config.mpv_path,
            else => return,
        };
        const n = @min(cur.len, self.edit_buf.len);
        @memcpy(self.edit_buf[0..n], cur[0..n]);
        self.edit_len = n;
        self.editing = true;
    }

    /// Commit edit buffer. Empty buffer is no-op (never blank mpv argv0).
    fn commitEdit(self: *SettingsState, config: *Config) void {
        defer self.editing = false;
        const n = self.edit_len;
        if (n == 0) return;
        @memcpy(self.text_buf[0..n], self.edit_buf[0..n]);
        config.mpv_path = self.text_buf[0..n];
        self.dirty = true;
    }

    /// Display string for a setting value. Scalars format into value_buf; strings borrow config.
    pub fn value(self: *SettingsState, config: *const Config, id: SettingId) []const u8 {
        return switch (id) {
            .mpv_path => config.mpv_path,
            .default_quality => config.default_quality,
            .translation => config.translation,
            .skip_mode => config.skip_mode,
            .resume_offset => std.fmt.bufPrint(&self.value_buf, "{d}s", .{config.resume_offset_sec}) catch "?",
            // Unset shows leader + "(default)" so blank is never confused with an
            // explicit pin to the same provider (ROD-344).
            .provider => if (config.preferred_provider.len > 0)
                config.preferred_provider
            else if (self.provider_names.len > 0)
                std.fmt.bufPrint(&self.provider_value_buf, "{s} (default)", .{self.provider_names[0]}) catch self.provider_names[0]
            else
                "",
            .cover_art => if (config.cover_art) "on" else "off",
            .kanji_chips => if (config.kanji_chips) "on" else "off",
            .palette => config.palette,
            .landing => config.landing,
            .title_language => config.title_language,
            .anilist_sync => if (config.anilist_sync_enabled) "on" else "off",
            .check_for_updates => if (config.check_for_updates) "on" else "off",
            .connect => "", // action row; hint carries the affordance
        };
    }
};
