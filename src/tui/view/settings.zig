//! Zigoku — Settings view render pass (ROD-86, §5.5 contract).
//! Extracted from app.zig along the tick/draw seam (ROD-144). The settings
//! *state* (cursor, edit buffer, cycle/toggle handlers) lives in `SettingsState`
//! (settings_state.zig, ROD-161); this module is the pure render of that state.

const std = @import("std");
const vaxis = @import("vaxis");
const app_mod = @import("../app.zig");
const render = @import("../render.zig");

const App = app_mod.App;
const SettingRow = app_mod.SettingRow;
const settings_rows = app_mod.settings_rows;
const put = render.put;
const putClipped = render.putClipped;
const fillRow = render.fillRow;

/// Static-lifetime hairline source for the Settings headers. vaxis stores
/// printed text *by reference* (a cell's grapheme points into the passed
/// slice), so this must outlive vx.render(): a comptime literal lives in
/// rodata; a stack buffer would dangle and render as garbage.
const settings_hairline_cols = 256;
const settings_hairline = "─" ** settings_hairline_cols;

// ── Settings render (ROD-86, §5.5 contract) ─────────────────────────────
//
// Columns (relative to the body window): marker 0–1, label @4, value @36,
// hint right-anchored at w-2-len. Focus matches the Browse list (bg_surface
// fill, no loud cyan). Edit mode deepens to bg_elevated + a magenta marker.

const settings_label_col: u16 = 4;
const settings_value_col: u16 = 36;

pub fn drawSettings(self: *App, win: vaxis.Window, top: u16, visible: u16, w: u16) void {
    _ = visible; // settings fits; vaxis clips any overflow against the window
    var y = top;

    // Player — the first five interactive rows.
    y = drawSettingsHeader(self, win, y, w, "Player");
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const r = settings_rows[i];
        drawSettingRow(self, win, y, w, r, self.settings.value(&self.config, r.id), i == self.settings.cursor);
        y += 1;
    }
    y += 1;

    // Catalog — read-only system state, never focusable (skipped by nav).
    y = drawSettingsHeader(self, win, y, w, "Catalog");
    drawInertRow(self, win, y, w, "enrichment sync", "automatic");
    y += 1;
    // Real resolved cover-cache path (honours $XDG_CACHE_HOME), resolved once in
    // run() and HOME-collapsed; falls back to the default literal only when no
    // cache home could be located (ROD-225).
    drawInertRow(self, win, y, w, "cover art cache", self.cover_cache_display orelse "~/.cache/zigoku/covers");
    y += 1;
    y += 1;

    // Interface — the toggle/cycle rows 5..10 (cover art … title language).
    y = drawSettingsHeader(self, win, y, w, "Interface");
    while (i < 10) : (i += 1) {
        const r = settings_rows[i];
        drawSettingRow(self, win, y, w, r, self.settings.value(&self.config, r.id), i == self.settings.cursor);
        y += 1;
    }
    y += 1;

    // AniList Sync (ROD-286) — a read-only account status (like Catalog), then the
    // interactive connect action + sync master-switch toggle (rows 10..end).
    y = drawSettingsHeader(self, win, y, w, "AniList Sync");
    drawInertRow(self, win, y, w, "account", accountStatus(self));
    y += 1;
    while (i < settings_rows.len) : (i += 1) {
        const r = settings_rows[i];
        drawSettingRow(self, win, y, w, r, self.settings.value(&self.config, r.id), i == self.settings.cursor);
        y += 1;
    }
}

/// The read-only "account" value in the AniList Sync section. Connected → the AniList
/// user name (a session-stable slice from the auth arena — safe to hand vaxis by
/// reference); a present-but-expired token → a reconnect prompt; otherwise "not
/// connected". The nuance between the last two is derived from `anilist_connected`
/// (which already folds in expiry) plus `hasAniList` (a token exists at all).
fn accountStatus(self: *const App) []const u8 {
    if (self.anilist_connected) return self.anilist_auth.anilist.user_name;
    if (self.anilist_auth.hasAniList()) return "reconnect — token expired";
    return "not connected";
}

fn drawSettingsHeader(self: *const App, win: vaxis.Window, y: u16, w: u16, title: []const u8) u16 {
    put(win, y, settings_label_col, title, self.s(self.palette.fg, .{ .bold = true }));
    // Full-width hairline in `chrome` — a deliberate section boundary. The
    // source is a static literal (see settings_hairline): vaxis keeps the
    // slice by reference until render, so a stack buffer would dangle.
    const cols: u16 = @min(w, settings_hairline_cols);
    put(win, y + 1, 0, settings_hairline[0 .. cols * 3], self.s(self.palette.chrome, .{}));
    return y + 2;
}

fn drawSettingRow(self: *App, win: vaxis.Window, y: u16, w: u16, row: SettingRow, value: []const u8, focused: bool) void {
    const editing = focused and self.settings.editing;
    const row_bg = if (editing) self.palette.bg_elevated else if (focused) self.palette.bg_surface else self.palette.bg_base;
    if (editing) {
        fillRow(win, y, w, self.palette.bg_elevated);
    } else if (focused) {
        fillRow(win, y, w, self.palette.bg_surface);
    }

    // ASCII separator on purpose: hint_col is computed from byte length, so a
    // multi-byte glyph (e.g. U+00B7) would misalign the right-anchored hint.
    const hint: []const u8 = if (editing) "esc  enter" else row.hint;
    const hint_len: u16 = @intCast(hint.len);
    const hint_col: u16 = if (w > hint_len + 2) w - 2 - hint_len else 0;

    const marker = if (focused) "▸ " else "  ";
    const marker_color = if (editing) self.palette.hot else self.palette.focus;
    put(win, y, 0, marker, self.s(marker_color, .{ .bg = row_bg }));

    const label_style = if (focused)
        self.s(self.palette.focus, .{ .bg = row_bg, .bold = true })
    else
        self.s(self.palette.fg, .{ .bg = row_bg });
    putClipped(win, y, settings_label_col, settings_value_col -| settings_label_col -| 2, row.label, label_style);

    const value_budget: u16 = if (hint_col > settings_value_col + 2) hint_col - settings_value_col - 2 else 0;
    if (editing) {
        drawSettingsEditField(self, win, y, settings_value_col, value_budget, row_bg);
    } else if (row.kind == .toggle) {
        // §5.5: visual toggle widget. ON = focus cyan; OFF = fg3 dim.
        const is_on = std.mem.eql(u8, value, "on");
        const toggle_color = if (is_on) self.palette.focus else self.palette.fg3;
        const toggle_text: []const u8 = if (is_on) "[████ on ████]" else "[████ off ████]";
        putClipped(win, y, settings_value_col, value_budget, toggle_text, self.s(toggle_color, .{ .bg = row_bg }));
    } else {
        const value_style = if (focused)
            self.s(self.palette.fg, .{ .bg = row_bg })
        else
            self.s(self.palette.fg2, .{ .bg = row_bg });
        putClipped(win, y, settings_value_col, value_budget, value, value_style);
    }

    put(win, y, hint_col, hint, self.s(self.palette.fg3, .{ .bg = row_bg }));
}

/// Render the live edit buffer with an inverted cursor block at the end
/// (input is append-only, so the cursor always trails the text).
fn drawSettingsEditField(self: *App, win: vaxis.Window, y: u16, col: u16, budget: u16, row_bg: vaxis.Color) void {
    const buf = self.settings.edit_buf[0..self.settings.edit_len];
    const text_budget: u16 = if (budget > 1) budget - 1 else 0;
    putClipped(win, y, col, text_budget, buf, self.s(self.palette.fg, .{ .bg = row_bg }));
    const cursor_off: u16 = @intCast(@min(buf.len, text_budget));
    if (budget > 0) put(win, y, col + cursor_off, " ", self.s(self.palette.fg, .{ .bg = self.palette.hot }));
}

/// A non-interactive Catalog row: dim+italic, no marker, no hint.
fn drawInertRow(self: *const App, win: vaxis.Window, y: u16, w: u16, label: []const u8, value: []const u8) void {
    const sty = self.s(self.palette.fg3, .{ .italic = true });
    putClipped(win, y, settings_label_col, settings_value_col -| settings_label_col -| 2, label, sty);
    putClipped(win, y, settings_value_col, w -| settings_value_col, value, sty);
}
