//! Zigoku — Settings controller subsystem (ROD-161).
//!
//! Owns the Settings tab's data model + edit state: the row table, the cursor over the
//! interactive rows, and the in-progress text-edit buffer. Cycle/toggle/edit mutate the
//! caller's `Config` in place through an explicitly-passed `*Config`; this struct never
//! reaches back into App or navigation state.
//!
//! Keystone: the subsystem owns its state transitions but never the PROJECTIONS of those
//! transitions onto App-live state. `onKey` returns a `KeyResult` verdict; the controller
//! (App.onSettingsKey) maps `.config_changed` to a palette/translation re-sync, so this
//! struct stays free of `App`, `palette`, `translation`, toasts, and the view/pane writes.
//! Persistence rides leave/quit, not a key verdict (ROD-210): a `dirty` flag tells the
//! controller whether `App.leaveSettings` owes a write. Embed by value; no `@fieldParentPtr`.
//!
//! The view (`view/settings.zig`) renders this; the data model
//! (`SettingId`/`SettingRow`/`settings_rows`) is re-exported from app.zig.

const std = @import("std");
const vaxis = @import("vaxis");
const config_mod = @import("../config.zig");

const Config = config_mod.Config;

// ── Settings tab model (ROD-86) ─────────────────────────────────────────────
//
// The Settings tab edits the caller's `Config` (ROD-85) in place. Only the
// *interactive* rows live in this table — Catalog's two read-only rows are
// rendered separately and skipped by navigation. Cycle/toggle write scalar or
// preset-literal fields (always safe — presets are static literals); the one
// editable text field (mpv_path) commits into `SettingsState.text_buf`.

// pub (SettingId/SettingKind/SettingRow/settings_rows): the settings data model
// is shared between the handlers here and the render pass in view/settings.zig
// (ROD-144), reached via app.zig's re-exports.
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
    // ── AniList Sync section (ROD-286) ──
    connect,
    anilist_sync,
    // ── Updates section (ROD-370) ──
    check_for_updates,
};

/// `action` (ROD-286): a focusable row whose Enter fires a side effect rather than
/// editing a config value — the connect row kicks off the OAuth flow. It has no stored
/// value (`value()` returns ""), and the controller, not the subsystem, runs the effect
/// (the subsystem reports `.connect_requested`; it never reaches into App).
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
    // Provider order preference (ROD-344). Rendered under the Catalog header
    // (see drawSettings), not Player, but the index stays contiguous so the
    // cursor walks top-to-bottom. Its presets are the registry's provider
    // names, injected at startup (`provider_names`), never hardcoded here.
    .{ .id = .provider, .label = "provider", .kind = .cycle, .hint = "hjkl to cycle" },
    .{ .id = .cover_art, .label = "cover art", .kind = .toggle, .hint = "space to toggle" },
    .{ .id = .kanji_chips, .label = "kanji chips", .kind = .toggle, .hint = "space to toggle" },
    .{ .id = .palette, .label = "palette", .kind = .cycle, .hint = "hjkl to cycle" },
    .{ .id = .landing, .label = "landing view", .kind = .cycle, .hint = "hjkl to cycle" },
    .{ .id = .title_language, .label = "title language", .kind = .cycle, .hint = "hjkl to cycle" },
    // AniList Sync (ROD-286): a connect *action* (Enter → OAuth flow) and the sync
    // master-switch *toggle*. The section's read-only "account" status row is rendered
    // separately (like Catalog) and is not focusable, so it isn't in this table.
    .{ .id = .connect, .label = "connect", .kind = .action, .hint = "enter to connect" },
    .{ .id = .anilist_sync, .label = "sync", .kind = .toggle, .hint = "space to toggle" },
    // Updates (ROD-370): the startup update-check opt-out. Its own section since it's
    // app behavior, not display or an AniList concern.
    .{ .id = .check_for_updates, .label = "check", .kind = .toggle, .hint = "space to toggle" },
};

/// Number of interactive (focusable) settings rows — the Catalog rows are not
/// in `settings_rows` and are skipped by navigation. Exposed for tests.
pub const settings_row_count = settings_rows.len;

comptime {
    // `drawSettings` splits this table 0..5 = Player, 5 = Catalog's provider row,
    // 6..11 = Interface, 11..13 = AniList Sync, 13..end = Updates. Pin the boundaries
    // so inserting/removing a row can't silently misattribute it to the wrong group
    // header: this breaks the build instead.
    std.debug.assert(settings_rows.len == 14);
    std.debug.assert(settings_rows[4].id == .skip_mode); // last Player row
    std.debug.assert(settings_rows[5].id == .provider); // the Catalog row (ROD-344)
    std.debug.assert(settings_rows[6].id == .cover_art); // first Interface row
    std.debug.assert(settings_rows[10].id == .title_language); // last Interface row (ROD-205)
    std.debug.assert(settings_rows[11].id == .connect); // first AniList Sync row
    std.debug.assert(settings_rows[12].id == .anilist_sync); // last AniList Sync row
    std.debug.assert(settings_rows[13].id == .check_for_updates); // the Updates row (ROD-370)
}

const quality_presets = [_][]const u8{ "worst", "480", "720", "1080", "best" };
const translation_presets = [_][]const u8{ "sub", "dub" };
const skip_presets = [_][]const u8{ "none", "intro", "outro", "both" };
const resume_presets = [_]u32{ 0, 3, 5, 10, 15, 30 };
const palette_presets = [_][]const u8{ "terminal_ghost", "phosphor", "nord", "tokyonight" };
// All three landing views are live now: ROD-229 implemented resume-landing, so
// "last_watched" rejoins the cycle (it was held back in ROD-228 only because it
// would have silently folded to History).
const landing_presets = [_][]const u8{ "history", "browse", "last_watched" };
// Primary show-label forms (ROD-205). No "auto": `english` already resolves as
// English-preferred-with-fallback, so a fourth value would just alias it.
const title_language_presets = [_][]const u8{ "romaji", "english", "native" };

/// Step through a preset list to the value after (`dir > 0`) or before the
/// current one, wrapping. An unrecognized current value starts from index 0.
/// Returns a static preset literal — safe to assign into a config string field.
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

/// Step a cycle-kind setting to its next/previous preset. Writes only `config`;
/// the controller re-derives any App-live projection (palette/translation) from
/// the new config value — see `SettingsState.onKey` returning `.config_changed`.
/// `provider_names` backs the one runtime preset list (the provider row); every
/// other list is a static table above.
fn cycle(config: *Config, id: SettingId, dir: i8, provider_names: []const []const u8) void {
    switch (id) {
        .default_quality => config.default_quality = cyclePreset(&quality_presets, config.default_quality, dir),
        .translation => config.translation = cyclePreset(&translation_presets, config.translation, dir),
        .skip_mode => config.skip_mode = cyclePreset(&skip_presets, config.skip_mode, dir),
        .resume_offset => config.resume_offset_sec = cyclePresetU32(&resume_presets, config.resume_offset_sec, dir),
        .palette => config.palette = cyclePreset(&palette_presets, config.palette, dir),
        .landing => config.landing = cyclePreset(&landing_presets, config.landing, dir),
        .title_language => config.title_language = cyclePreset(&title_language_presets, config.title_language, dir),
        // Provider names are `name()` vtable statics, so assigning one into the
        // config string field is as safe as the preset literals (ROD-344). An
        // un-injected list (unit tests) makes the row inert rather than a mod-0.
        .provider => if (provider_names.len > 0) {
            config.preferred_provider = cycleProvider(provider_names, config.preferred_provider, dir);
        },
        else => {},
    }
}

/// Cycle the provider preference through unset ("") then each provider name,
/// wrapping. Unset is a REAL stop, not a display quirk: "" means "follow the
/// registry's construction leader", which an explicit pin to the same name
/// does not (the leader can change under a pin; the review flagged the
/// one-way door). An unrecognized current value re-enters the wheel at unset.
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
        .anilist_sync => config.anilist_sync_enabled = !config.anilist_sync_enabled, // ROD-286 master switch
        .check_for_updates => config.check_for_updates = !config.check_for_updates, // ROD-370
        else => {},
    }
}

/// The Settings tab controller (ROD-161). Owns the row cursor and the text-edit
/// buffer, and applies cycle/toggle/edit mutations to a caller-supplied
/// `*Config`. It never touches App, navigation, palette, translation, or
/// toasts: `onKey` reports a `KeyResult` and the controller projects it.
pub const SettingsState = struct {
    /// Cursor over the *interactive* rows only (the two Catalog rows are
    /// non-interactive and skipped by navigation).
    cursor: usize = 0,
    /// Whether the focused text field is in edit mode (captures printable keys).
    editing: bool = false,
    /// Live edit buffer while `editing`; seeded from the field's value.
    edit_buf: [256]u8 = undefined,
    edit_len: usize = 0,
    /// Committed home for an edited mpv_path. `config.mpv_path` is re-pointed
    /// here on confirm, so the edited value outlives the edit buffer without
    /// touching the original literal/arena slice.
    text_buf: [256]u8 = undefined,
    /// Scratch for a formatted settings value (e.g. "5s"). Owned here, not a
    /// draw-local stack buffer, because vaxis keeps the printed slice by
    /// reference until render — a stack buffer would dangle.
    value_buf: [16]u8 = undefined,
    /// Scratch for the provider row's "name (default)" form (ROD-344). Its own
    /// buffer, NOT value_buf: value() runs once per row within a single draw
    /// pass, so two rows sharing one buffer would clobber each other's slice
    /// before vx.render() reads them.
    provider_value_buf: [48]u8 = undefined,

    /// The registry's provider names in construction order, injected once by
    /// `run()` (ROD-344). The preset list for the provider row: the settings
    /// subsystem never sees the Registry itself, only this projection. Names
    /// are static vtable strings; the slice is owned by the caller for the
    /// app's lifetime. Empty (the default) leaves the row inert, which is the
    /// state unit tests construct.
    provider_names: []const []const u8 = &.{},

    /// Whether an edit has mutated `config` since the tab was entered or last
    /// saved. The controller persists on leave/quit only when this is set
    /// (ROD-210), so tabbing through Settings unchanged neither rewrites the
    /// config file nor toasts.
    dirty: bool = false,

    /// What a settings keypress means to the controller. Keeps the subsystem
    /// free of App-live projections: it reports *what changed*, the controller
    /// decides how that lands on palette/translation/nav state.
    pub const KeyResult = enum {
        /// Not a settings key — fall through to the global key chain.
        ignored,
        /// Consumed; no App-level follow-up needed.
        consumed,
        /// Consumed and `config` mutated in a way App projects live (palette /
        /// translation). Controller re-syncs those from config.
        config_changed,
        /// Consumed: an `.action` row was invoked (ROD-286 — the connect row). The
        /// subsystem can't run the effect (it never reaches into App/loop/io), so it
        /// reports the intent and the controller (`onSettingsKey`) fires `beginConnect`.
        connect_requested,
    };

    /// Reset to a clean entry state (top row, not editing). Called by the
    /// controller when the Settings tab is (re)entered, so a stray cursor or
    /// half-finished edit from a prior visit never bleeds in.
    pub fn reset(self: *SettingsState) void {
        self.cursor = 0;
        self.editing = false;
        self.dirty = false;
    }

    /// Handle a key while the Settings tab is active. Returns a `KeyResult` the
    /// controller projects onto App state. While editing, delegates to
    /// `editKey` (which swallows everything but Ctrl-C).
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
            // `.consumed`, not `.config_changed`: the toggle fields (cover_art,
            // kanji_chips) have no App-live projection — nothing mirrors them the
            // way `translation`/`palette` mirror their cycle fields, so no
            // re-sync is owed. A *new* toggle that does project would need
            // `.config_changed` here instead.
            return .consumed;
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            if (row.kind == .text) self.beginEdit(config, row.id);
            // ROD-286: Enter on an action row (only `.connect` today) asks the
            // controller to run the side effect. Report intent; don't touch App here.
            if (row.kind == .action) return .connect_requested;
            return .consumed;
        }
        // `q` is no longer a settings verdict (ROD-210): it falls through to the
        // global key chain, which quits. Persistence moved to leave/quit (see
        // App.leaveSettings); the `dirty` flag set above drives whether it writes.
        return .ignored;
    }

    /// Key handling while a text field is being edited. Swallows every key —
    /// except the Ctrl-C emergency quit — so a stray F-key can't switch views
    /// mid-edit; only Esc/Enter resolve the edit itself.
    fn editKey(self: *SettingsState, key: vaxis.Key, config: *Config) KeyResult {
        // Ctrl-C must hard-quit from anywhere, including a modal text field.
        if (key.matches('c', .{ .ctrl = true })) return .ignored;
        if (key.matches(vaxis.Key.escape, .{})) {
            self.editing = false; // cancel — discard the buffer
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
                // Printable ASCII only — paths and presets never need control bytes.
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
            else => return, // only text fields are editable
        };
        const n = @min(cur.len, self.edit_buf.len);
        @memcpy(self.edit_buf[0..n], cur[0..n]);
        self.edit_len = n;
        self.editing = true;
    }

    /// Commit the edit buffer into the field. mpv_path is the only text field;
    /// an empty buffer is treated as a no-op so we never hand mpv a blank argv0.
    fn commitEdit(self: *SettingsState, config: *Config) void {
        defer self.editing = false;
        const n = self.edit_len;
        if (n == 0) return;
        @memcpy(self.text_buf[0..n], self.edit_buf[0..n]);
        config.mpv_path = self.text_buf[0..n];
        self.dirty = true;
    }

    /// Display string for a setting's current value. Scalar values (resume
    /// offset, on/off) are formatted into this struct's `value_buf`; string
    /// fields return a borrow from `config`.
    pub fn value(self: *SettingsState, config: *const Config, id: SettingId) []const u8 {
        return switch (id) {
            .mpv_path => config.mpv_path,
            .default_quality => config.default_quality,
            .translation => config.translation,
            .skip_mode => config.skip_mode,
            .resume_offset => std.fmt.bufPrint(&self.value_buf, "{d}s", .{config.resume_offset_sec}) catch "?",
            // An unset preference displays the effective leader tagged
            // "(default)", so the row never reads blank AND unset stays
            // distinguishable from an explicit pin to the same provider
            // (ROD-344 review).
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
            .connect => "", // an action row has no stored value; its hint carries the affordance
        };
    }
};
