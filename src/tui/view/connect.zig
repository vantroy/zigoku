//! AniList connect modal (ROD-286).
//!
//! Captured overlay while in-TUI OAuth runs (`App.connect != null`). Borderless
//! (§3.1), `bg.elevated` panel. Pure render: worker/clipboard/teardown live in
//! app.zig / login_loopback.zig; this only paints `App.connect`.

const std = @import("std");
const vaxis = @import("vaxis");
const app_mod = @import("../app.zig");
const render = @import("../render.zig");

const App = app_mod.App;
const ConnectState = app_mod.ConnectState;
const put = render.put;
const putClipped = render.putClipped;
const centerText = render.centerText;
const centerKeyHint = render.centerKeyHint;
const drawWrappedText = render.drawWrappedText;

/// Fixed modal height (title, URL band, status, paste slot, key hints + blanks).
/// Paste hint keeps its padded slot even when hidden so rows below do not jump (§3.1).
/// Below `min_h`, `drawCrampedFallback` takes over.
const box_h: u16 = 19;
/// Preferred modal width, capped to terminal with 2-col margin each side.
const box_w_pref: u16 = 68;

/// Below these sizes the panel is unreadable; use the bare-line fallback.
const min_w: u16 = 24;
const min_h: u16 = 8;

/// Seconds before status spinner escalates focus → hot (§3.6 slow-path).
/// Local clock via `cs.started_ms`, not shared `async_start_ms`.
const slow_wait_s: i64 = 3;

/// Seconds before the SSH/remote paste fallback hint. Loopback needs browser
/// reachability to this host's 127.0.0.1:PORT; delayed past normal local approval.
const paste_hint_s: i64 = 20;

pub fn draw(self: *App, win: vaxis.Window, w: u16, h: u16) void {
    if (self.connect == null) return;
    // Mutable: `drawStatus` formats into `cs.status_buf` (App-owned). vaxis holds
    // the printed slice until render; a draw-local buffer would dangle.
    const cs: *ConnectState = &self.connect.?;

    const bw: u16 = @min(box_w_pref, w -| 4);
    const bh: u16 = @min(box_h, h -| 2);
    if (bw < min_w or bh < min_h) {
        drawCrampedFallback(self, win, w, h);
        return;
    }

    const bx: u16 = (w -| bw) / 2;
    const by: u16 = (h -| bh) / 2;

    // Float is this fill alone (§3.1 Borderless Float; no box-drawing chrome).
    const box = win.child(.{ .x_off = bx, .y_off = by, .width = bw, .height = bh });
    box.fill(.{ .style = .{ .bg = self.palette.bg_elevated } });

    const inner_x: u16 = 2;
    const iw: u16 = bw -| 4;
    const bg = self.palette.bg_elevated;

    centerText(box, 1, bw, "Connect AniList", self.s(self.palette.hot, .{ .bg = bg, .bold = true }));

    centerText(box, 3, bw, "approve access in your browser to continue", self.s(self.palette.fg2, .{ .bg = bg }));
    // fg2 + italic: secondary caption with real contrast (fg3 is chrome-adjacent in nord).
    centerText(box, 5, bw, "browser didn't open? use this link:", self.s(self.palette.fg2, .{ .bg = bg, .italic = true }));

    // Authorize URL on bg_surface band; [c] copies the full string regardless of wrap.
    const url_band = box.child(.{ .x_off = inner_x, .y_off = 6, .width = iw, .height = 4 });
    url_band.fill(.{ .style = .{ .bg = self.palette.bg_surface } });
    _ = drawWrappedText(box, 7, inner_x + 1, iw -| 2, 3, cs.listener.url, self.s(self.palette.fg2, .{ .bg = self.palette.bg_surface }));

    const elapsed_s: i64 = if (cs.started_ms > 0 and self.now_ms > cs.started_ms)
        @divTrunc(self.now_ms - cs.started_ms, 1000)
    else
        0;
    drawStatus(self, box, 11, bw, cs, elapsed_s);

    // Rows 12-14 reserved for paste hint whether shown or not (no layout jump).
    // warn (not hot): spinner already owns hot past slow_wait_s.
    if (elapsed_s >= paste_hint_s) {
        centerText(box, 13, bw, "no callback? run  zigoku login --paste  in a terminal", self.s(self.palette.warn, .{ .bg = bg }));
    }

    if (cs.copied) {
        centerKeyHint(box, 15, bw, "c", self.s(self.palette.focus, .{ .bg = bg, .bold = true }), "  copied \u{2713}", self.s(self.palette.fg, .{ .bg = bg }));
    } else {
        centerKeyHint(box, 15, bw, "c", self.s(self.palette.focus, .{ .bg = bg, .bold = true }), "  copy link", self.s(self.palette.fg2, .{ .bg = bg }));
    }
    // esc in fg2 to match copy: peer affordances (fg3 was invisible in nord).
    centerKeyHint(box, 16, bw, "esc", self.s(self.palette.focus, .{ .bg = bg, .bold = true }), "  cancel", self.s(self.palette.fg2, .{ .bg = bg }));
}

fn drawStatus(self: *App, box: vaxis.Window, row: u16, bw: u16, cs: *ConnectState, elapsed_s: i64) void {
    const bg = self.palette.bg_elevated;
    // App-owned status_buf only: vaxis keeps the slice until render (stack dangle = garbage).
    const label = std.fmt.bufPrint(&cs.status_buf, "waiting for approval\u{2026} {d}s", .{elapsed_s}) catch "waiting for approval\u{2026}";
    const spin_color = if (elapsed_s >= slow_wait_s) self.palette.hot else self.palette.focus;
    const total: u16 = @as(u16, @intCast(vaxis.gwidth.gwidth(label, .unicode))) + 2;
    const start: u16 = if (bw > total) (bw - total) / 2 else 0;
    put(box, row, start, self.spinnerChar(), self.s(spin_color, .{ .bg = bg }));
    putClipped(box, row, start + 2, bw -| (start + 2), label, self.s(self.palette.fg2, .{ .bg = bg }));
}

/// Too cramped for the panel: bare one-line hint. Without this, a tiny-terminal
/// resize mid-connect drew nothing while keys still captured (`App.onKey`).
fn drawCrampedFallback(self: *App, win: vaxis.Window, w: u16, h: u16) void {
    const row = h / 2;
    const strip = win.child(.{ .x_off = 0, .y_off = row, .width = w, .height = 1 });
    strip.fill(.{ .style = .{ .bg = self.palette.bg_elevated } });
    centerText(win, row, w, "connect: esc to cancel", self.s(self.palette.fg2, .{ .bg = self.palette.bg_elevated }));
}
