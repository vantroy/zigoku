//! Zigoku — AniList connect modal (ROD-286).
//!
//! A captured overlay drawn on top of Settings while the in-TUI OAuth flow runs
//! (`App.connect != null`). Borderless by design (DESIGN.md §3.1 — box-drawing is
//! never pane/overlay chrome here): the float is a `bg.elevated` panel, the same
//! elevation signal toasts use, with no box drawn around it. It shows the authorize
//! URL (the browser was opened for the user; this is the fallback + the thing `[c]`
//! copies), a live "waiting" spinner, and the two keys the modal owns — `c` copy,
//! `esc` cancel. Below `min_w`/`min_h` the panel itself won't read as legible chrome,
//! so `draw` falls back to one bare line instead of drawing nothing (see
//! `drawCrampedFallback`). Pure render: the accept-loop worker, the clipboard write,
//! and teardown all live in app.zig / login_loopback.zig; this module only reads
//! `App.connect` and paints it.

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

/// Fixed modal height: 1 row top pad + title + blank + instruction + blank + fallback
/// caption + URL band (1 top-pad row + up to 3 URL lines) + blank + status + blank +
/// paste hint + blank + 2 key-hint lines, plus whatever's left over at the bottom as
/// pad. The paste-hint row's blank neighbours are reserved unconditionally — even
/// hidden (< `paste_hint_s`) it keeps its padded slot, so the hint doesn't shift the
/// rows below it into place the instant it appears (§3.1: divided by whitespace, not
/// a rule, but the whitespace still has to be *there* to divide with). Clipped by the
/// child window on a short terminal — see `min_h` for the floor below which this stops
/// being legible at all and `drawCrampedFallback` takes over.
const box_h: u16 = 19;
/// Preferred modal width, capped to the terminal with a 2-col margin each side.
const box_w_pref: u16 = 68;

/// Below this width/height the modal panel reads as cramped clutter rather than a
/// dialog — `draw` takes the bare-line fallback instead (same thresholds the old
/// unconditional bail used; only the behaviour below them changed).
const min_w: u16 = 24;
const min_h: u16 = 8;

/// Elapsed-wait threshold (seconds) before the status spinner escalates from
/// `focus` to `hot` — mirrors the app-wide §3.6 slow-path convention (the bottom bar
/// and cover block shift the same way past `slow_path_threshold_ms` in app.zig).
/// Reimplemented locally: `cs.started_ms` is this flow's own clock, not the shared
/// `async_start_ms` that convention reads.
const slow_wait_s: i64 = 3;

/// Elapsed-wait threshold (seconds) before the modal surfaces the terminal-safe
/// fallback hint. The loopback only completes when the browser can reach THIS host's
/// `127.0.0.1:PORT` — a remote/SSH box can't, and there the modal would otherwise just
/// sit on "waiting" forever. Past this, a hint points at `zigoku login --paste` (the
/// SSH-safe manual flow). Delayed well past a normal local approval so the happy path
/// never sees it — it's a "you might be stuck" signpost, not routine chrome.
const paste_hint_s: i64 = 20;

pub fn draw(self: *App, win: vaxis.Window, w: u16, h: u16) void {
    if (self.connect == null) return;
    // Mutable: `drawStatus` formats the "waiting… Ns" line into `cs.status_buf` (an
    // App-owned scratch), because vaxis holds the printed slice by reference until
    // render — a draw-local buffer would dangle. Everything else read here is const.
    const cs: *ConnectState = &self.connect.?;

    const bw: u16 = @min(box_w_pref, w -| 4);
    const bh: u16 = @min(box_h, h -| 2);
    if (bw < min_w or bh < min_h) {
        drawCrampedFallback(self, win, w, h);
        return;
    }

    const bx: u16 = (w -| bw) / 2;
    const by: u16 = (h -| bh) / 2;

    // The float is this fill alone — DESIGN.md §3.1 (Borderless Float System) treats
    // box-drawing as a last resort, never pane/overlay chrome, and `bg_elevated` is
    // already the palette's own "modal-ish overlay" elevation signal (§1.1). No border.
    const box = win.child(.{ .x_off = bx, .y_off = by, .width = bw, .height = bh });
    box.fill(.{ .style = .{ .bg = self.palette.bg_elevated } });

    const inner_x: u16 = 2;
    const iw: u16 = bw -| 4;
    const bg = self.palette.bg_elevated;

    // Title.
    centerText(box, 1, bw, "Connect AniList", self.s(self.palette.hot, .{ .bg = bg, .bold = true }));

    // The one required action, stated up front — the browser was already opened
    // for this. The fallback path (below) reads as conditional, not a confession
    // that it failed.
    centerText(box, 3, bw, "approve access in your browser to continue", self.s(self.palette.fg2, .{ .bg = bg }));
    // fg2 (not fg3) + italic: the italic keeps it a secondary caption, but fg3 is
    // `chrome`-adjacent in nord (nord3 dim text == the border), so it read as invisible.
    // fg2 has real contrast in every palette; italic still marks the hierarchy.
    centerText(box, 5, bw, "browser didn't open? use this link:", self.s(self.palette.fg2, .{ .bg = bg, .italic = true }));

    // The authorize URL, inset in its own `bg_surface` band so it reads as one
    // selectable block instead of blending into the modal body — legible (fg2, not
    // the near-invisible fg3 it used to render in), since this is a real fallback
    // action, not decoration. The band is one row taller than the text so the URL gets
    // a top-pad row (and left inset) instead of jamming against the band's edge. `[c]`
    // copies the whole string regardless of how much is visible here.
    const url_band = box.child(.{ .x_off = inner_x, .y_off = 6, .width = iw, .height = 4 });
    url_band.fill(.{ .style = .{ .bg = self.palette.bg_surface } });
    _ = drawWrappedText(box, 7, inner_x + 1, iw -| 2, 3, cs.listener.url, self.s(self.palette.fg2, .{ .bg = self.palette.bg_surface }));

    // Live status: spinner + "waiting …", with the elapsed seconds so a slow browser
    // hand-off still reads as progress, not a hang.
    const elapsed_s: i64 = if (cs.started_ms > 0 and self.now_ms > cs.started_ms)
        @divTrunc(self.now_ms - cs.started_ms, 1000)
    else
        0;
    drawStatus(self, box, 11, bw, cs, elapsed_s);

    // Escape-hatch hint, in its own padded slot (row 12 blank, row 13 the hint, row 14
    // blank) reserved whether or not it's showing — the rows below it don't shift into
    // place the instant it appears. Only past `paste_hint_s` does a possibly-stuck
    // (remote/SSH) user get pointed at the terminal fallback. `warn` (amber), not
    // `fg2`/`fg3` — this is an attention signal, not body text, and it must not read as
    // the same register as the caption two paragraphs up. Not `hot`: the spinner above
    // already escalates to `hot` past `slow_wait_s`, and the two would compete for the
    // "most urgent thing here" read. Plain weight, no italic — `warn` alone carries it.
    if (elapsed_s >= paste_hint_s) {
        centerText(box, 13, bw, "no callback? run  zigoku login --paste  in a terminal", self.s(self.palette.warn, .{ .bg = bg }));
    }

    // The two keys the modal owns, each its own centred "<key>  <action>" line (the
    // idiom `browse.zig`'s absent state uses) so the bracketed key actually pops
    // instead of the whole hint sitting in one flat dim colour. `c` acknowledges
    // once used.
    if (cs.copied) {
        centerKeyHint(box, 15, bw, "c", self.s(self.palette.focus, .{ .bg = bg, .bold = true }), "  copied \u{2713}", self.s(self.palette.fg, .{ .bg = bg }));
    } else {
        centerKeyHint(box, 15, bw, "c", self.s(self.palette.focus, .{ .bg = bg, .bold = true }), "  copy link", self.s(self.palette.fg2, .{ .bg = bg }));
    }
    // `cancel` in fg2 to match `copy link`: the two key hints are peers (and esc is if
    // anything the more important one), so it must not read dimmer — fg3 was both
    // invisible in nord and inconsistent with the copy hint above.
    centerKeyHint(box, 16, bw, "esc", self.s(self.palette.focus, .{ .bg = bg, .bold = true }), "  cancel", self.s(self.palette.fg2, .{ .bg = bg }));
}

fn drawStatus(self: *App, box: vaxis.Window, row: u16, bw: u16, cs: *ConnectState, elapsed_s: i64) void {
    const bg = self.palette.bg_elevated;
    // Format into the App-owned `status_buf`, never a stack local: vaxis keeps the
    // printed slice by reference until `vx.render()`, long after this frame's stack is
    // gone (that dangle rendered as garbage — the `waiting…` label read freed stack).
    const label = std.fmt.bufPrint(&cs.status_buf, "waiting for approval\u{2026} {d}s", .{elapsed_s}) catch "waiting for approval\u{2026}";
    // Spinner glyph immediately left of the centred label. Cyan while fresh,
    // escalating to hot past `slow_wait_s` — see that const's doc comment.
    const spin_color = if (elapsed_s >= slow_wait_s) self.palette.hot else self.palette.focus;
    const total: u16 = @as(u16, @intCast(vaxis.gwidth.gwidth(label, .unicode))) + 2;
    const start: u16 = if (bw > total) (bw - total) / 2 else 0;
    put(box, row, start, self.spinnerChar(), self.s(spin_color, .{ .bg = bg }));
    putClipped(box, row, start + 2, bw -| (start + 2), label, self.s(self.palette.fg2, .{ .bg = bg }));
}

/// Too cramped for the modal panel (see `min_w`/`min_h`): a bare one-line hint, no
/// panel. Without this, a mid-connect resize into a tiny terminal drew nothing at all —
/// Settings kept rendering underneath, looking fully interactive while every key but
/// `c`/`esc` was silently swallowed (`App.onKey`). This at least surfaces the one key
/// that still does something, on a filled band so it doesn't collide unreadably with
/// whatever Settings row happens to sit under it.
fn drawCrampedFallback(self: *App, win: vaxis.Window, w: u16, h: u16) void {
    const row = h / 2;
    const strip = win.child(.{ .x_off = 0, .y_off = row, .width = w, .height = 1 });
    strip.fill(.{ .style = .{ .bg = self.palette.bg_elevated } });
    centerText(win, row, w, "connect: esc to cancel", self.s(self.palette.fg2, .{ .bg = self.palette.bg_elevated }));
}
