//! Zigoku — Settings controller subsystem (ROD-161).
//!
//! The second cut of the controller/subsystem split (after ROD-160's
//! `CoverState`). Owns the Settings tab's data model + edit state: the row
//! table, the cursor over the interactive rows, and the in-progress text-edit
//! buffer. Cycle/toggle/edit mutate the caller's `Config` *in place* through an
//! explicitly-passed `*Config` — this struct never reaches back into App or
//! navigation state.
//!
//! Keystone (per Theta): the subsystem owns its own state transitions but never
//! the *projections* of those transitions onto App-live state. `onKey` returns a
//! `KeyResult` verdict; the controller (App.onSettingsKey) maps `.config_changed`
//! to a palette/translation re-sync and `.save_and_exit` to persist + nav, so the
//! settings struct stays free of `App`, `palette`, `translation`, toasts, and the
//! `active_view`/`active_pane` writes. Embed by value (`settings: SettingsState =
//! .{}`); no back-reference, no `@fieldParentPtr`.
//!
//! The view (`view/settings.zig`) renders this state; the data model
//! (`SettingId`/`SettingRow`/`settings_rows`) is re-exported from app.zig so
//! existing `app_mod.*` references keep resolving.

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
    subtitle_language,
    resume_offset,
    skip_mode,
    cover_art,
    kanji_chips,
    palette,
};

pub const SettingKind = enum { text, cycle, toggle };

pub const SettingRow = struct {
    id: SettingId,
    label: []const u8,
    kind: SettingKind,
    hint: []const u8,
};

pub const settings_rows = [_]SettingRow{
    .{ .id = .mpv_path, .label = "mpv path", .kind = .text, .hint = "enter to edit" },
    .{ .id = .default_quality, .label = "default quality", .kind = .cycle, .hint = "hjkl to cycle" },
    .{ .id = .subtitle_language, .label = "subtitle language", .kind = .cycle, .hint = "hjkl to cycle" },
    .{ .id = .resume_offset, .label = "resume offset", .kind = .cycle, .hint = "hjkl to cycle" },
    .{ .id = .skip_mode, .label = "skip mode", .kind = .cycle, .hint = "hjkl to cycle" },
    .{ .id = .cover_art, .label = "cover art", .kind = .toggle, .hint = "space to toggle" },
    .{ .id = .kanji_chips, .label = "kanji chips", .kind = .toggle, .hint = "space to toggle" },
    .{ .id = .palette, .label = "palette", .kind = .cycle, .hint = "hjkl to cycle" },
};

/// Number of interactive (focusable) settings rows — the Catalog rows are not
/// in `settings_rows` and are skipped by navigation. Exposed for tests.
pub const settings_row_count = settings_rows.len;

comptime {
    // `drawSettings` splits this table 0..5 = Player, 5..8 = Interface. Pin the
    // boundary so inserting/removing a row can't silently misattribute it to the
    // wrong group header — this breaks the build instead.
    std.debug.assert(settings_rows.len == 8);
    std.debug.assert(settings_rows[4].id == .skip_mode);
    std.debug.assert(settings_rows[5].id == .cover_art);
}

const quality_presets = [_][]const u8{ "worst", "480", "720", "1080", "best" };
const language_presets = [_][]const u8{ "sub", "dub" };
const skip_presets = [_][]const u8{ "none", "intro", "outro", "both" };
const resume_presets = [_]u32{ 0, 3, 5, 10, 15, 30 };
const palette_presets = [_][]const u8{ "terminal_ghost", "phosphor", "nord" };

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
fn cycle(config: *Config, id: SettingId, dir: i8) void {
    switch (id) {
        .default_quality => config.default_quality = cyclePreset(&quality_presets, config.default_quality, dir),
        .subtitle_language => config.translation = cyclePreset(&language_presets, config.translation, dir),
        .skip_mode => config.skip_mode = cyclePreset(&skip_presets, config.skip_mode, dir),
        .resume_offset => config.resume_offset_sec = cyclePresetU32(&resume_presets, config.resume_offset_sec, dir),
        .palette => config.palette = cyclePreset(&palette_presets, config.palette, dir),
        else => {},
    }
}

fn toggle(config: *Config, id: SettingId) void {
    switch (id) {
        .cover_art => config.cover_art = !config.cover_art,
        .kanji_chips => config.kanji_chips = !config.kanji_chips,
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
        /// `q` — controller persists config and leaves to Browse.
        save_and_exit,
    };

    /// Reset to a clean entry state (top row, not editing). Called by the
    /// controller when the Settings tab is (re)entered, so a stray cursor or
    /// half-finished edit from a prior visit never bleeds in.
    pub fn reset(self: *SettingsState) void {
        self.cursor = 0;
        self.editing = false;
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
                cycle(config, row.id, 1);
                return .config_changed;
            }
            return .consumed;
        }
        if (key.matches('h', .{}) or key.matches(vaxis.Key.left, .{})) {
            if (row.kind == .cycle) {
                cycle(config, row.id, -1);
                return .config_changed;
            }
            return .consumed;
        }
        if (key.matches(vaxis.Key.space, .{})) {
            if (row.kind == .toggle) toggle(config, row.id);
            // `.consumed`, not `.config_changed`: the toggle fields (cover_art,
            // kanji_chips) have no App-live projection — nothing mirrors them the
            // way `translation`/`palette` mirror their cycle fields, so no
            // re-sync is owed. A *new* toggle that does project would need
            // `.config_changed` here instead.
            return .consumed;
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            if (row.kind == .text) self.beginEdit(config, row.id);
            return .consumed;
        }
        if (key.matches('q', .{})) return .save_and_exit;
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
    }

    /// Display string for a setting's current value. Scalar values (resume
    /// offset, on/off) are formatted into this struct's `value_buf`; string
    /// fields return a borrow from `config`.
    pub fn value(self: *SettingsState, config: *const Config, id: SettingId) []const u8 {
        return switch (id) {
            .mpv_path => config.mpv_path,
            .default_quality => config.default_quality,
            .subtitle_language => config.translation,
            .skip_mode => config.skip_mode,
            .resume_offset => std.fmt.bufPrint(&self.value_buf, "{d}s", .{config.resume_offset_sec}) catch "?",
            .cover_art => if (config.cover_art) "on" else "off",
            .kanji_chips => if (config.kanji_chips) "on" else "off",
            .palette => config.palette,
        };
    }
};
