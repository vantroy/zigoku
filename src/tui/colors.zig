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
