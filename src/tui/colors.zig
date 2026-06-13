//! Terminal Ghost color tokens (DESIGN.md §7.7).
//!
//! The single source of truth for every styled cell in the TUI. Component code
//! references these names — never inline hex. Tweak a color once, here.
//!
//! The system is dark-only and non-negotiable (Mission Control is always dark).
//! Color carries hierarchy: green = alive, cyan = focused, magenta = the one
//! thing happening now.

const vaxis = @import("vaxis");

const Color = vaxis.Color;

// ── Palette ──────────────────────────────────────────────────────────────────

/// All semantic color tokens for one theme. `App` holds a `*const Palette`
/// set from the user's config; render functions reference it instead of the
/// module-level constants so switching themes takes effect immediately.
pub const Palette = struct {
    bg_base: Color,
    bg_surface: Color,
    bg_elevated: Color,
    chrome: Color,
    fg: Color,
    fg2: Color,
    fg3: Color,
    focus: Color,
    hot: Color,
    warn: Color,
};

/// Current default: Terminal Ghost (unchanged hex values).
pub const terminal_ghost: Palette = .{
    .bg_base = bg_base,
    .bg_surface = bg_surface,
    .bg_elevated = bg_elevated,
    .chrome = chrome,
    .fg = fg,
    .fg2 = fg2,
    .fg3 = fg3,
    .focus = focus,
    .hot = hot,
    .warn = warn,
};

/// Pure monochrome phosphor. Focus/fg share the same hue; bold styling
/// handles visual distinction. `hot` is the complementary orange-red.
pub const phosphor: Palette = .{
    .bg_base = Color{ .rgb = .{ 0x01, 0x09, 0x04 } },
    .bg_surface = Color{ .rgb = .{ 0x04, 0x11, 0x08 } },
    .bg_elevated = Color{ .rgb = .{ 0x08, 0x1c, 0x10 } },
    .chrome = Color{ .rgb = .{ 0x12, 0x38, 0x20 } },
    .fg = Color{ .rgb = .{ 0x50, 0xff, 0x7a } },
    .fg2 = Color{ .rgb = .{ 0x20, 0x70, 0x3a } },
    .fg3 = Color{ .rgb = .{ 0x10, 0x30, 0x18 } },
    .focus = Color{ .rgb = .{ 0xa8, 0xff, 0xbe } }, // overdriven — brighter than fg so bold isn't the only diff
    .hot = Color{ .rgb = .{ 0xff, 0x6a, 0x39 } },
    .warn = Color{ .rgb = .{ 0xff, 0xe3, 0x39 } },
};

/// Nord adaptation. Semantic tokens mapped to Nord's polar night + snow storm
/// + aurora palette (https://www.nordtheme.com/docs/colors-and-palettes).
pub const nord: Palette = .{
    .bg_base = Color{ .rgb = .{ 0x2e, 0x34, 0x40 } },     // nord0
    .bg_surface = Color{ .rgb = .{ 0x3b, 0x42, 0x52 } },   // nord1
    .bg_elevated = Color{ .rgb = .{ 0x43, 0x4c, 0x5e } },  // nord2
    .chrome = Color{ .rgb = .{ 0x4c, 0x56, 0x6a } },       // nord3
    .fg = Color{ .rgb = .{ 0xd8, 0xde, 0xe9 } },           // nord4
    .fg2 = Color{ .rgb = .{ 0x81, 0xa1, 0xc1 } },          // nord9
    .fg3 = Color{ .rgb = .{ 0x4c, 0x56, 0x6a } },          // nord3 (dim text)
    .focus = Color{ .rgb = .{ 0x88, 0xc0, 0xd0 } },        // nord8
    .hot = Color{ .rgb = .{ 0xd0, 0x87, 0x70 } },          // nord12 (aurora orange — more urgency than nord15 purple)
    .warn = Color{ .rgb = .{ 0xeb, 0xcb, 0x8b } },         // nord13
};

// ── Backgrounds ─────────────────────────────────────────────────────────────
/// Void. The base canvas everything floats on.
pub const bg_base = Color{ .rgb = .{ 0x02, 0x0d, 0x06 } };
/// Surface — a panel lifted just off the void.
pub const bg_surface = Color{ .rgb = .{ 0x06, 0x14, 0x10 } };
/// Elevated — overlays, the active selection band.
pub const bg_elevated = Color{ .rgb = .{ 0x0b, 0x1f, 0x18 } };
/// Hairline chrome — separators, inactive borders. Barely there by design.
pub const chrome = Color{ .rgb = .{ 0x1a, 0x40, 0x30 } };

// ── Foregrounds (the green ramp) ────────────────────────────────────────────
/// Terminal Green. Primary text — "alive."
pub const fg = Color{ .rgb = .{ 0x39, 0xff, 0x6a } };
/// Secondary text — metadata, supporting detail.
pub const fg2 = Color{ .rgb = .{ 0x2a, 0x60, 0x40 } };
/// Tertiary text — disabled, placeholder, the dimmest legible green.
pub const fg3 = Color{ .rgb = .{ 0x16, 0x35, 0x25 } };

// ── Accents ─────────────────────────────────────────────────────────────────
/// Cyan. Focus — the pane/element the keyboard is driving.
pub const focus = Color{ .rgb = .{ 0x00, 0xe5, 0xcc } };
/// Spectral Magenta. The signature. The one thing happening now (cursor, the
/// live action). Used sparingly — two magentas dilute the pointer semantic.
pub const hot = Color{ .rgb = .{ 0xff, 0x2d, 0x78 } };
/// Amber. Warnings, degraded/stale states.
pub const warn = Color{ .rgb = .{ 0xe5, 0xb8, 0x00 } };
