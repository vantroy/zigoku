#!/bin/sh
# zigoku installer: fetch the matching release tarball, verify it, drop the
# binary on your PATH. Feeds off the tarballs release.yml publishes per tag.
#
#   curl -fsS https://raw.githubusercontent.com/vantroy/zigoku/master/install.sh | sh
#
# Knobs (all optional, via env):
#   ZIGOKU_VERSION   pin a release (e.g. 0.4.0 or v0.4.0); default = latest
#   BINDIR           where the binary lands; default = ~/.local/bin
#   PREFIX           if set and BINDIR is not, BINDIR = $PREFIX/bin
#
# POSIX sh on purpose: this runs on whatever /bin/sh a fresh box ships.
set -eu

REPO="vantroy/zigoku"
BIN="zigoku"

say()  { printf '%s\n' "$*"; }
err()  { printf 'error: %s\n' "$1" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ── One download tool, curl or wget ──────────────────────────────────────────
if have curl; then
  dl() { curl -fsSL "$1" -o "$2"; }
  dl_stdout() { curl -fsSL "$1"; }
elif have wget; then
  dl() { wget -qO "$2" "$1"; }
  dl_stdout() { wget -qO- "$1"; }
else
  err "need curl or wget to download; install one and retry"
fi

# ── One checksum tool, GNU sha256sum or BSD/macOS shasum ──────────────────────
if have sha256sum; then
  sha256() { sha256sum "$1" | awk '{print $1}'; }
elif have shasum; then
  sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  err "need sha256sum or shasum to verify the download; install one and retry"
fi

# ── Map this machine to a published target triple ────────────────────────────
os=$(uname -s)
arch=$(uname -m)

case "$os" in
  Linux)  plat="linux-musl" ;;
  Darwin) plat="macos" ;;
  *) err "unsupported OS '$os'; zigoku publishes Linux and macOS builds only" ;;
esac

case "$arch" in
  x86_64|amd64)  cpu="x86_64" ;;
  aarch64|arm64) cpu="aarch64" ;;
  *) err "unsupported architecture '$arch'; zigoku publishes x86_64 and aarch64 builds only" ;;
esac

# Rosetta 2 reports x86_64 on Apple Silicon; hand it the native aarch64 build,
# which the release ships anyway, not the emulated Intel one.
if [ "$plat" = "macos" ] && [ "$cpu" = "x86_64" ] \
   && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = "1" ]; then
  cpu="aarch64"
fi

target="${cpu}-${plat}"

# ── Resolve the version ───────────────────────────────────────────────────────
if [ "${ZIGOKU_VERSION:-}" != "" ]; then
  ver="${ZIGOKU_VERSION#v}"   # accept 0.4.0 or v0.4.0
else
  # The API's /releases/latest response carries tag_name directly in its JSON body.
  ver=$(dl_stdout "https://api.github.com/repos/${REPO}/releases/latest" \
        | grep '"tag_name"' | head -1 \
        | sed -E 's/.*"tag_name" *: *"v?([^"]+)".*/\1/')
  [ -n "$ver" ] || err "could not resolve the latest release tag (rate-limited? set ZIGOKU_VERSION to pin one)"
fi

tarball="${BIN}-v${ver}-${target}.tar.gz"
base="https://github.com/${REPO}/releases/download/v${ver}"

# ── Install location ──────────────────────────────────────────────────────────
if [ "${BINDIR:-}" != "" ]; then
  bindir="$BINDIR"
elif [ "${PREFIX:-}" != "" ]; then
  bindir="$PREFIX/bin"
else
  [ "${HOME:-}" != "" ] || err "HOME is unset; set BINDIR to choose an install dir"
  bindir="$HOME/.local/bin"
fi

say "zigoku installer"
say "  target   ${target}"
say "  version  v${ver}"
say "  into     ${bindir}"

# ── Download tarball + checksums into a scratch dir we always clean up ─────────
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zigoku-install.XXXXXX") || err "could not create a temp dir"
trap 'rm -rf "$tmp"' EXIT INT TERM

say "downloading ${tarball} ..."
dl "${base}/${tarball}" "$tmp/$tarball" \
  || err "download failed. Is v${ver} published for ${target}? See https://github.com/${REPO}/releases"
dl "${base}/sha256sums.txt" "$tmp/sha256sums.txt" \
  || err "could not fetch sha256sums.txt for v${ver}"

# ── Verify BEFORE we unpack anything from a piped installer ───────────────────
want=$(awk -v f="$tarball" '$2 == f {print $1}' "$tmp/sha256sums.txt")
[ -n "$want" ] || err "no checksum for ${tarball} in sha256sums.txt; refusing to install unverified"
got=$(sha256 "$tmp/$tarball")
if [ "$want" != "$got" ]; then
  err "checksum mismatch for ${tarball}
  expected ${want}
  got      ${got}
refusing to install a tampered or corrupt download"
fi
say "checksum OK"

# ── Unpack and place the binary ───────────────────────────────────────────────
tar -xzf "$tmp/$tarball" -C "$tmp" || err "could not extract ${tarball}"
srcbin="$tmp/${BIN}-v${ver}-${target}/${BIN}"
[ -f "$srcbin" ] || err "extracted archive is missing the ${BIN} binary"

mkdir -p "$bindir" || err "could not create ${bindir}"
install -m 0755 "$srcbin" "$bindir/${BIN}" 2>/dev/null \
  || { cp "$srcbin" "$bindir/${BIN}" && chmod 0755 "$bindir/${BIN}"; } \
  || err "could not write ${bindir}/${BIN} (permission? set BINDIR to a writable dir)"

say ""
say "installed ${BIN} v${ver} to ${bindir}/${BIN}"

# ── PATH hint + the one runtime dependency ────────────────────────────────────
case ":$PATH:" in
  *":$bindir:"*) : ;;
  *) say ""
     say "note: ${bindir} is not on your PATH. Add it, e.g.:"
     say "  export PATH=\"${bindir}:\$PATH\"" ;;
esac

if ! have mpv; then
  say ""
  say "note: zigoku plays through mpv, which isn't bundled. Install it:"
  say "  Linux:  your package manager (e.g. apt/pacman/dnf install mpv)"
  say "  macOS:  brew install mpv"
fi

say ""
say "run 'zigoku --version' to check, or just 'zigoku' to start."
