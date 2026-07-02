#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_JPEG
#define STBI_ONLY_PNG
#define STBI_NO_STDIO
// Decode-bomb backstop: reject images whose declared dimensions exceed the
// limit before allocating pixels — a hostile PNG/JPEG header must not force a
// giant allocation. The value (STBI_MAX_DIMENSIONS) is injected by build.zig
// from src/decode_limits.zig, shared with cover.zig's max_decode_dimension so
// the WebP and stb backstops stay in lockstep.
#include "stb/stb_image.h"
