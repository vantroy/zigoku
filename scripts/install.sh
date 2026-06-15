#!/usr/bin/env bash
# scripts/install.sh — build Zigoku (ReleaseSafe) and install it to a prefix.
#
# In-repo installer (ROD-90): clone the repo, then run this. There's no
# curl|bash one-liner and no package-manager recipe by design — this is a
# personal learning project, distributed as source.
#
# Usage:
#   ./scripts/install.sh                 # build + install to ~/.local
#   ./scripts/install.sh --prefix /usr/local
#   PREFIX=/opt/zigoku ./scripts/install.sh
#   ./scripts/install.sh --uninstall     # remove the installed binary
#
# The heavy lifting is just `zig build --prefix`: Zig's install step drops the
# binary at $PREFIX/bin/zigoku. We add preflight checks and post-install hints
# around it. `zig build` itself enforces the minimum Zig version (0.16.0) from
# build.zig.zon, so we don't second-guess the toolchain here.
#
# Tested with bash 5.x on Linux; zsh-compatible.

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
OPTIMIZE="ReleaseSafe"
UNINSTALL=false

# Colour helpers — degrade when stdout isn't a tty (CI/pipes).
if [ -t 1 ]; then
    GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'
else
    GREEN=''; RED=''; YELLOW=''; BOLD=''; RESET=''
fi

info()  { echo -e "${GREEN}::${RESET} $1"; }
warn()  { echo -e "${YELLOW}!!${RESET} $1"; }
err()   { echo -e "${RED}xx${RESET} $1" >&2; }

# ── Argument parsing ───────────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)
            [ $# -ge 2 ] || { err "--prefix needs a path"; exit 2; }
            PREFIX="$2"; shift 2 ;;
        --prefix=*)
            PREFIX="${1#--prefix=}"; shift ;;
        --uninstall)
            UNINSTALL=true; shift ;;
        -h|--help)
            cat <<EOF
zigoku installer

  ./scripts/install.sh [--prefix DIR] [--uninstall]

Options:
  --prefix DIR    install under DIR (binary → DIR/bin/zigoku). Default: \$HOME/.local
  --uninstall     remove the installed binary from the prefix
  -h, --help      show this help

Environment:
  PREFIX          same as --prefix (the flag wins if both are given)

Builds in ${OPTIMIZE} mode. Requires zig 0.16.0+ and system sqlite3 to build,
and mpv on PATH at runtime.
EOF
            exit 0 ;;
        *)
            err "unknown argument: $1 (try --help)"; exit 2 ;;
    esac
done

# Reject an empty prefix (e.g. `--prefix=`, `--prefix ""`, or `PREFIX=`): it would
# resolve to /bin/zigoku and let --uninstall rm a path it has no business touching.
[ -n "$PREFIX" ] || { err "prefix cannot be empty"; exit 2; }

BIN_DIR="$PREFIX/bin"
BIN_PATH="$BIN_DIR/zigoku"

# ── Uninstall path ─────────────────────────────────────────────────────────────

if [ "$UNINSTALL" = true ]; then
    if [ -e "$BIN_PATH" ]; then
        rm -f "$BIN_PATH"
        info "removed $BIN_PATH"
    else
        warn "nothing to remove at $BIN_PATH"
    fi
    echo
    info "note: Zigoku's data/config/cache (under XDG dirs) are left untouched."
    echo "   config: \${XDG_CONFIG_HOME:-~/.config}/zigoku"
    echo "   data:   \${XDG_DATA_HOME:-~/.local/share}/zigoku"
    echo "   cache:  \${XDG_CACHE_HOME:-~/.cache}/zigoku"
    exit 0
fi

# ── Preflight ──────────────────────────────────────────────────────────────────

echo
echo -e "${BOLD}╋ zigoku installer${RESET}"
echo

if ! command -v zig >/dev/null 2>&1; then
    err "zig not found on PATH. Install Zig 0.16.0+ from https://ziglang.org/download/"
    exit 1
fi
info "zig $(zig version) — build.zig.zon enforces the 0.16.0 minimum"

# sqlite3 is a build-time link dependency (src/store.zig). Warn early with a
# clear message rather than letting users decode a raw linker error.
if command -v pkg-config >/dev/null 2>&1; then
    if ! pkg-config --exists sqlite3; then
        warn "pkg-config can't find sqlite3 — the build links system sqlite3 and will"
        warn "fail without its dev headers (e.g. libsqlite3-dev / sqlite-devel)."
    fi
else
    warn "system sqlite3 (with dev headers) is required to build; couldn't verify it"
fi

# mpv is a runtime dependency only — playback shells out to it. Don't block.
if ! command -v mpv >/dev/null 2>&1; then
    warn "mpv not on PATH — playback won't work until you install it (runtime dep)"
fi

# ── Build + install ──────────────────────────────────────────────────────────

echo
info "building (${OPTIMIZE}) and installing to ${PREFIX} ..."
echo
( cd "$REPO" && zig build -Doptimize="$OPTIMIZE" --prefix "$PREFIX" )

if [ ! -x "$BIN_PATH" ]; then
    err "build reported success but $BIN_PATH is missing — something's off."
    exit 1
fi

echo
info "installed: ${BOLD}${BIN_PATH}${RESET}"

# ── Post-install hints ─────────────────────────────────────────────────────────

case ":$PATH:" in
    *":$BIN_DIR:"*)
        info "run it with: ${BOLD}zigoku${RESET}  (no args → TUI; or 'zigoku <query>')" ;;
    *)
        echo
        warn "$BIN_DIR is not on your PATH. Add it, e.g.:"
        echo "     echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.zshrc   # or ~/.bashrc"
        echo
        info "until then, run it directly: ${BOLD}${BIN_PATH}${RESET}" ;;
esac
echo
