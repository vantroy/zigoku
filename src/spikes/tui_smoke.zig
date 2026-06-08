//! ROD-71 spike: prove libvaxis 0.6.0 boots under Zig 0.16's std.Io.
//!
//! This is the make-or-break for M3. It exercises the full vaxis stack the
//! real TUI shell will stand on: init under std.Io, alt-screen, the threaded
//! event loop (tty reader spawned via io.concurrent), a render tick, styled
//! cells in the Terminal Ghost palette, key handling, and live resize.
//!
//! It also demonstrates the architectural seam that matters: vaxis's Loop
//! exposes postEvent, so a custom event variant (.work) can be injected into
//! the SAME queue the tty reader feeds. That's how worker-thread results
//! (search/episodes/resolve, our existing Channel pattern) will reach the UI
//! thread — one unified nextEvent() drain, no second polling loop.
//!
//! Run in a real terminal: `zig build spike-tui`. Quit with q or Esc.
const std = @import("std");
const vaxis = @import("vaxis");

// The unified event type. vaxis fills key_press / winsize / focus; we own
// .work to show the backend→UI injection path.
const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
    work: []const u8,
};

// Terminal Ghost palette (DESIGN.md §7.5 / src/tui/colors.zig handoff).
const void_bg = vaxis.Color{ .rgb = .{ 0x02, 0x0d, 0x06 } };
const fg = vaxis.Color{ .rgb = .{ 0x39, 0xff, 0x6a } };
const fg_dim = vaxis.Color{ .rgb = .{ 0x2a, 0x60, 0x40 } };
const focus = vaxis.Color{ .rgb = .{ 0x00, 0xe5, 0xcc } };
const hot = vaxis.Color{ .rgb = .{ 0xff, 0x2d, 0x78 } };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);
    defer tty.deinit();
    const writer = tty.writer();

    var vx = try vaxis.init(io, gpa, init.environ_map, .{});
    defer vx.deinit(gpa, writer);

    var loop = vaxis.Loop(Event).init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try loop.installResizeHandler();
    try vx.enterAltScreen(writer);
    // DA1 query so caps (kitty graphics/keyboard) are known before first draw.
    try vx.queryTerminal(writer, .fromMilliseconds(500));

    // Prove the injection seam: post a synthetic "worker result" into the
    // same queue the tty thread feeds.
    try loop.postEvent(.{ .work = "channel→UI inject OK" });

    var frame: u64 = 0;
    var last_work: []const u8 = "(waiting…)";

    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (key.matches('q', .{}) or key.matches(vaxis.Key.escape, .{})) break;
            },
            .winsize => |ws| try vx.resize(gpa, writer, ws),
            .work => |msg| last_work = msg,
            else => {},
        }

        frame += 1;
        const win = vx.window();
        win.clear();
        win.fill(.{ .style = .{ .bg = void_bg } });

        _ = win.printSegment(.{
            .text = "地獄 · zigoku",
            .style = .{ .fg = fg, .bg = void_bg, .bold = true },
        }, .{ .row_offset = 1, .col_offset = 2 });

        _ = win.printSegment(.{
            .text = "ROD-71 · libvaxis 0.6.0 on Zig 0.16 · std.Io",
            .style = .{ .fg = focus, .bg = void_bg },
        }, .{ .row_offset = 2, .col_offset = 2 });

        var buf: [64]u8 = undefined;
        const stat = std.fmt.bufPrint(&buf, "frame {d} · {d}x{d}", .{
            frame, win.width, win.height,
        }) catch "frame ?";
        _ = win.printSegment(.{
            .text = stat,
            .style = .{ .fg = fg_dim, .bg = void_bg },
        }, .{ .row_offset = 4, .col_offset = 2 });

        _ = win.printSegment(.{
            .text = last_work,
            .style = .{ .fg = fg, .bg = void_bg },
        }, .{ .row_offset = 5, .col_offset = 2 });

        // The signature: a magenta block cursor, terminal-blinked.
        _ = win.printSegment(.{
            .text = "\u{258C}",
            .style = .{ .fg = hot, .bg = void_bg, .blink = true },
        }, .{ .row_offset = 7, .col_offset = 2 });
        _ = win.printSegment(.{
            .text = "press q or Esc to quit",
            .style = .{ .fg = fg_dim, .bg = void_bg },
        }, .{ .row_offset = 7, .col_offset = 4 });

        try vx.render(writer);
    }
}
