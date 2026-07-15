//! Terminal Ghost color tokens (DESIGN.md §7.7).
//!
//! Sole source for styled TUI cells: components use these names, never inline hex.
//! Dark-only. Hierarchy: green = alive, cyan = focused, magenta = now.

const vaxis = @import("vaxis");

const Color = vaxis.Color;

/// Semantic tokens for one theme. `App` holds `*const Palette` from config.
/// Map aliases to DESIGN.md §1.2 (`fg2 // text.muted` convention) so code and spec stay aligned.
pub const Palette = struct {
    bg_base: Color,
    bg_surface: Color,
    bg_elevated: Color,
    chrome: Color, // border.hair
    fg: Color, // text.primary
    fg2: Color, // text.muted
    fg3: Color, // text.dim
    focus: Color, // state.focus
    hot: Color, // state.now
    warn: Color, // state.warn
};

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

/// Monochrome phosphor. Focus/fg same hue; bold distinguishes. `hot` is complementary.
pub const phosphor: Palette = .{
    .bg_base = Color{ .rgb = .{ 0x01, 0x09, 0x04 } },
    .bg_surface = Color{ .rgb = .{ 0x04, 0x11, 0x08 } },
    .bg_elevated = Color{ .rgb = .{ 0x08, 0x1c, 0x10 } },
    .chrome = Color{ .rgb = .{ 0x12, 0x38, 0x20 } },
    .fg = Color{ .rgb = .{ 0x50, 0xff, 0x7a } },
    .fg2 = Color{ .rgb = .{ 0x20, 0x70, 0x3a } },
    .fg3 = Color{ .rgb = .{ 0x10, 0x30, 0x18 } },
    .focus = Color{ .rgb = .{ 0xa8, 0xff, 0xbe } }, // brighter than fg so bold isn't the only diff
    .hot = Color{ .rgb = .{ 0xff, 0x6a, 0x39 } },
    .warn = Color{ .rgb = .{ 0xff, 0xe3, 0x39 } },
};

/// Nord polar night + snow + aurora (https://www.nordtheme.com/docs/colors-and-palettes).
pub const nord: Palette = .{
    .bg_base = Color{ .rgb = .{ 0x2e, 0x34, 0x40 } }, // nord0
    .bg_surface = Color{ .rgb = .{ 0x3b, 0x42, 0x52 } }, // nord1
    .bg_elevated = Color{ .rgb = .{ 0x43, 0x4c, 0x5e } }, // nord2
    .chrome = Color{ .rgb = .{ 0x4c, 0x56, 0x6a } }, // nord3
    .fg = Color{ .rgb = .{ 0xd8, 0xde, 0xe9 } }, // nord4
    .fg2 = Color{ .rgb = .{ 0x81, 0xa1, 0xc1 } }, // nord9
    .fg3 = Color{ .rgb = .{ 0x4c, 0x56, 0x6a } }, // nord3 (dim text)
    .focus = Color{ .rgb = .{ 0x88, 0xc0, 0xd0 } }, // nord8
    .hot = Color{ .rgb = .{ 0xd0, 0x87, 0x70 } }, // nord12 (urgency over nord15 purple)
    .warn = Color{ .rgb = .{ 0xeb, 0xcb, 0x8b } }, // nord13
};

/// TokyoNight night (https://github.com/folke/tokyonight.nvim).
pub const tokyonight: Palette = .{
    .bg_base = Color{ .rgb = .{ 0x1a, 0x1b, 0x26 } }, // night bg
    .bg_surface = Color{ .rgb = .{ 0x24, 0x28, 0x3b } }, // storm bg (focused-row band)
    .bg_elevated = Color{ .rgb = .{ 0x29, 0x2e, 0x42 } }, // bg_highlight (toasts)
    .chrome = Color{ .rgb = .{ 0x3b, 0x42, 0x61 } }, // border
    .fg = Color{ .rgb = .{ 0xc0, 0xca, 0xf5 } }, // fg
    // Muted between TN fg_dark and dark5 for even fg/fg2/fg3 spacing.
    .fg2 = Color{ .rgb = .{ 0x9a, 0xa5, 0xce } },
    .fg3 = Color{ .rgb = .{ 0x56, 0x5f, 0x89 } }, // comment
    // TN cyan L≈0.56 reads under fg; lifted (L≈0.75) so focus out-reads fg (§1.4).
    .focus = Color{ .rgb = .{ 0xb0, 0xe8, 0xff } },
    .hot = Color{ .rgb = .{ 0xf7, 0x76, 0x8e } }, // red / urgency
    .warn = Color{ .rgb = .{ 0xe0, 0xaf, 0x68 } }, // yellow
};

// Terminal Ghost literals (default palette source)

pub const bg_base = Color{ .rgb = .{ 0x02, 0x0d, 0x06 } };
pub const bg_surface = Color{ .rgb = .{ 0x06, 0x14, 0x10 } };
pub const bg_elevated = Color{ .rgb = .{ 0x0b, 0x1f, 0x18 } };
pub const chrome = Color{ .rgb = .{ 0x1a, 0x40, 0x30 } };

pub const fg = Color{ .rgb = .{ 0x39, 0xff, 0x6a } };
pub const fg2 = Color{ .rgb = .{ 0x2a, 0x60, 0x40 } };
pub const fg3 = Color{ .rgb = .{ 0x16, 0x35, 0x25 } };

/// Focus cyan, overdriven so focused row clears fg-green luminance (ROD-156 #4).
/// 0x00ffee was too hot; warmer teal L≈0.770 > fg L≈0.734; keeps cyan-ghost identity (§1.1).
pub const focus = Color{ .rgb = .{ 0x20, 0xff, 0xdd } };
/// Spectral magenta: one-thing-now pointer. Sparse; two magentas dilute the semantic.
pub const hot = Color{ .rgb = .{ 0xff, 0x2d, 0x78 } };
pub const warn = Color{ .rgb = .{ 0xe5, 0xb8, 0x00 } };
