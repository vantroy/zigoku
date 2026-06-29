//! Zigoku — Discover/Popular view render pass (ROD-239).
//! The v0.2 headline feature: a popularity-ranked, window-toggled feed. Built in
//! chunks — this chunk renders the chrome (window bar) + states; the cover-grid
//! body and real cards land with the data + layout chunks. Reads DiscoverState
//! through `self.discover.*` and writes only the window it's handed (ROD-144/155).

const std = @import("std");
const vaxis = @import("vaxis");
const app_mod = @import("../app.zig");
const render = @import("../render.zig");

const App = app_mod.App;
const put = render.put;
const centerText = render.centerText;

/// The window-toggle segmented bar (§ Discover layout): the active window in
/// state.focus+bold, the rest in text.muted, separator dots in text.dim. Passive
/// here — the keys that drive it (cycle / direct-select) land in the data chunk.
fn drawWindowBar(self: *const App, win: vaxis.Window, row: u16) void {
    const labels = [_][]const u8{ "Daily", "Weekly", "Monthly", "All-Time" };
    const active = @intFromEnum(self.discover.window);
    var col: u16 = 2;
    for (labels, 0..) |label, i| {
        const style = if (i == active)
            self.s(self.palette.focus, .{ .bold = true })
        else
            self.s(self.palette.fg2, .{});
        put(win, row, col, label, style);
        col += @as(u16, @intCast(label.len));
        if (i + 1 < labels.len) {
            put(win, row, col + 1, "·", self.s(self.palette.fg3, .{}));
            col += 3;
        }
    }
}

/// Full-canvas Discover pass. `top` is the first content row (below the spacer);
/// `visible` is the content height; `w` the body width.
pub fn draw(self: *const App, win: vaxis.Window, top: u16, visible: u16, w: u16) void {
    drawWindowBar(self, win, top);

    // The grid begins two rows below the window bar (bar row + a spacer).
    const grid_top: u16 = top + 2;
    const grid_h: u16 = if (visible > 2) visible - 2 else 0;

    const slot = self.discover.activeSlot();
    if (slot.results.items.len == 0) {
        // Empty state (§9 absent). In this chunk the feed isn't fetched yet, so
        // this is what every window shows; once data flows it's the genuine
        // "feed returned nothing" case.
        centerText(win, grid_top + grid_h / 2, w, "no entries", self.s(self.palette.fg2, .{ .italic = true }));
        return;
    }
    // The cover-grid body lands in the layout chunk; the cards fill from here.
}
