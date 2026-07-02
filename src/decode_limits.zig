// Single source of truth for the decoder-level image-dimension backstop, shared
// by the two decode paths so they can't drift apart: cover.zig enforces it on
// the WebP branch (max_decode_dimension), and build.zig injects it into the stb
// C shim as -DSTBI_MAX_DIMENSIONS. Rationale for the value and the two-layer
// design lives on cover.zig's `max_decode_dimension`.
pub const max_dimension = 8192;
