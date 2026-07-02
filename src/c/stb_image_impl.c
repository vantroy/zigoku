#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_JPEG
#define STBI_ONLY_PNG
#define STBI_NO_STDIO
// Decode-bomb backstop: reject images whose declared dimensions exceed this
// before allocating pixels. Mirrors cover.zig's max_decode_dimension for the
// WebP path — a hostile PNG/JPEG header should not be able to force a giant
// allocation either. Cover art is orders of magnitude smaller than this.
#define STBI_MAX_DIMENSIONS 8192
#include "stb/stb_image.h"
