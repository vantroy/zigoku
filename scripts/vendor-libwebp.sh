#!/usr/bin/env bash
# scripts/vendor-libwebp.sh — refresh the in-tree libwebp *decoder* subset.
#
# zigoku decodes cover art from C: PNG/JPEG via stb_image, WebP via libwebp.
# Both are vendored in-tree (src/c/) so builds stay hermetic across every
# release target — no system libwebp, no distro assumptions (matches the
# stb_image decision, not the system-or-bundle sqlite one).
#
# This script pulls a pinned libwebp release, verifies its SHA-256, and copies
# ONLY the decoder translation units (LIBWEBPDECODER_OBJS = DEC + DSP_DEC +
# UTILS_DEC, straight out of upstream's makefile.unix) plus every header they
# need. No encoder, mux, demux or sharpyuv *code* is compiled or linked.
#
# One header exception: dsp/lossless.h is shared between encoder and decoder and
# forward-declares an encoder-only function, so it #includes enc/histogram_enc.h.
# Upstream's own libwebpdecoder.a build resolves this the same way — the full
# header tree is present, only the encoder .c files are skipped. So we vendor
# src/enc/*.h (headers only, closure verified to stay within dec/dsp/utils/webp/
# enc — no sharpyuv/mux/demux). Zero encoder objects reach the link.
#
# libwebp sources self-include root-relative ("src/dec/vp8i_dec.h"), so the
# tree is laid out as src/c/webp/src/{dec,dsp,utils,webp} and build.zig points
# its include path at src/c/webp.
#
# Bumping libwebp: change WEBP_VERSION + WEBP_SHA256 below, re-run, rebuild the
# 4-target matrix, then eyeball the diff. If upstream adds/removes a decoder
# source, reconcile the *_C lists here AND the file list in build.zig.
#
# Usage:
#   ./scripts/vendor-libwebp.sh          # fetch, verify, re-vendor into src/c/webp
#
# Requires: bash, curl, tar, sha256sum. Run from anywhere in the repo.

set -euo pipefail

WEBP_VERSION="1.5.0"
WEBP_SHA256="7d6fab70cf844bf6769077bd5d7a74893f8ffd4dfb42861745750c63c2a5c92c"
WEBP_URL="https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${WEBP_VERSION}.tar.gz"

# Repo root = parent of this script's dir. Vendored decoder lands in src/c/webp.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEST="${REPO_ROOT}/src/c/webp"

# LIBWEBPDECODER_OBJS, transcribed from libwebp-${WEBP_VERSION}/makefile.unix.
# ISA variants (mips/msa/neon/sse2/sse41) are kept verbatim: each body is
# guarded by a WEBP_USE_* macro that lights up only for its target, so the
# irrelevant ones compile to empty translation units. Copying the full set
# keeps re-vendoring a mechanical mirror instead of a hand-prune.
DEC_C="alpha_dec buffer_dec frame_dec idec_dec io_dec quant_dec tree_dec vp8_dec vp8l_dec webp_dec"
DSP_DEC_C="alpha_processing alpha_processing_mips_dsp_r2 alpha_processing_neon \
alpha_processing_sse2 alpha_processing_sse41 cpu dec dec_clip_tables dec_mips32 \
dec_mips_dsp_r2 dec_msa dec_neon dec_sse2 dec_sse41 filters filters_mips_dsp_r2 \
filters_msa filters_neon filters_sse2 lossless lossless_mips_dsp_r2 lossless_msa \
lossless_neon lossless_sse2 lossless_sse41 rescaler rescaler_mips32 \
rescaler_mips_dsp_r2 rescaler_msa rescaler_neon rescaler_sse2 upsampling \
upsampling_mips_dsp_r2 upsampling_msa upsampling_neon upsampling_sse2 \
upsampling_sse41 yuv yuv_mips32 yuv_mips_dsp_r2 yuv_neon yuv_sse2 yuv_sse41"
UTILS_DEC_C="bit_reader_utils color_cache_utils filters_utils huffman_utils palette \
quant_levels_dec_utils random_utils rescaler_utils thread_utils utils"

say() { printf '  %s\n' "$*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "==> libwebp ${WEBP_VERSION}: fetch"
TARBALL="${WORK}/libwebp.tar.gz"
curl -fsSL -o "${TARBALL}" "${WEBP_URL}"

echo "==> verify SHA-256"
ACTUAL="$(sha256sum "${TARBALL}" | cut -d' ' -f1)"
if [ "${ACTUAL}" != "${WEBP_SHA256}" ]; then
  echo "SHA-256 mismatch!" >&2
  echo "  expected: ${WEBP_SHA256}" >&2
  echo "  actual:   ${ACTUAL}" >&2
  exit 1
fi
say "ok: ${ACTUAL}"

echo "==> extract"
tar xzf "${TARBALL}" -C "${WORK}"
SRC="${WORK}/libwebp-${WEBP_VERSION}"
[ -d "${SRC}/src/dec" ] || { echo "unexpected tarball layout" >&2; exit 1; }

echo "==> re-vendor into ${DEST#"${REPO_ROOT}/"}"
rm -rf "${DEST}/src"
mkdir -p "${DEST}/src/dec" "${DEST}/src/dsp" "${DEST}/src/utils" \
         "${DEST}/src/webp" "${DEST}/src/enc"

# Copy the decoder .c set, failing loudly if upstream moved a file.
copy_c() { # $1=subdir  $2=space-separated basenames
  local sub="$1"; shift
  local f
  for f in $1; do
    cp "${SRC}/src/${sub}/${f}.c" "${DEST}/src/${sub}/${f}.c" \
      || { echo "missing upstream ${sub}/${f}.c — reconcile the *_C list" >&2; exit 1; }
  done
}
copy_c dec "${DEC_C}"
copy_c dsp "${DSP_DEC_C}"
copy_c utils "${UTILS_DEC_C}"

# Headers are include-time and cheap; copy them all so nothing dangles. The
# enc/*.h come along only to satisfy dsp/lossless.h's shared declaration — no
# encoder .c is compiled (see header note at top).
cp "${SRC}"/src/dec/*.h   "${DEST}/src/dec/"
cp "${SRC}"/src/dsp/*.h   "${DEST}/src/dsp/"
cp "${SRC}"/src/utils/*.h "${DEST}/src/utils/"
cp "${SRC}"/src/webp/*.h  "${DEST}/src/webp/"
cp "${SRC}"/src/enc/*.h   "${DEST}/src/enc/"

# mux.h / demux.h are the public muxer/demuxer API — nothing in the decoder
# graph includes them (encode.h stays: utils/palette.c, utils/utils.c and the
# enc/*.h headers pull it in). Drop them so the vendored surface is honestly
# decode-only. webp/config.h is never vendored: every include of it sits behind
# #ifdef HAVE_CONFIG_H, which we don't define.
rm -f "${DEST}/src/webp/mux.h" "${DEST}/src/webp/demux.h"

# License + provenance travel with the code (public repo, BSD-3 + patent grant).
cp "${SRC}/COPYING" "${SRC}/PATENTS" "${SRC}/AUTHORS" "${DEST}/"
cat > "${DEST}/VERSION" <<EOF
libwebp ${WEBP_VERSION} (decoder subset)
source: ${WEBP_URL}
sha256: ${WEBP_SHA256}
vendored via scripts/vendor-libwebp.sh — decoder translation units only.
EOF

C_COUNT="$(find "${DEST}/src" -name '*.c' | wc -l | tr -d ' ')"
H_COUNT="$(find "${DEST}/src" -name '*.h' | wc -l | tr -d ' ')"
echo "==> done: ${C_COUNT} .c + ${H_COUNT} .h under ${DEST#"${REPO_ROOT}/"}/src"
say "next: rebuild the 4-target matrix before trusting the bump."
