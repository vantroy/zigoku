#!/usr/bin/env bash
# capture-launch.sh — launch zigoku for media capture (vhs tapes).
#
# Uses your REAL store (~/.local/share/zigoku) so the app boots into your actual
# Watchlist and the catalogue shows real covers/metadata. That is SAFE for the
# demo/stills tapes, by construction:
#   - mpv is STUBBED → the play key opens no player, writes no resume/history.
#   - the tapes are watchlist-READ-ONLY: they only search + open detail. Browse
#     search upserts enrichment with history_visible=0 (store.zig persistResults,
#     visible=false), so it never surfaces in History (WHERE history_visible != 0)
#     and — because ON CONFLICT does history_visible = MAX(excluded, existing) — it
#     can never un-hide a show you've hidden. Pure invisible cache writes.
#   ⚠️ NEVER add watchlist-mutating keys to a capture tape: P (add), p/x/c/w
#      (status), r (recompute), u (undo), or Enter-to-play. Those DO write.
#
# Colour fix: zigoku emits truecolor in COLON-style SGR (`\e[38:2:R:G:Bm`); vhs's
# headless terminal mis-parses it and greens come out burnt orange. vaxis's
# VAXIS_FORCE_LEGACY_SGR switches to the SEMICOLON form (`\e[38;2;R;G;Bm`) vhs
# renders correctly; COLORTERM pins the truecolor level. Capture-only — real
# terminals get the modern form.
#
# Usage (from repo root, as a vhs tape does):
#   ./docs/media/capture-launch.sh [zigoku args...]
# Requires a built binary at ./zig-out/bin/zigoku (run `zig build` first).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/zig-out/bin/zigoku"
[ -x "$BIN" ] || { echo "no binary at $BIN — run 'zig build' first" >&2; exit 1; }

# Stub mpv on a throwaway PATH dir so the play key never opens a real player.
STUB="$(mktemp -d)"
trap 'rm -rf "$STUB"' EXIT
cat > "$STUB/mpv" <<'MPV'
#!/usr/bin/env bash
exit 0
MPV
chmod +x "$STUB/mpv"

export PATH="$STUB:$PATH"
export COLORTERM=truecolor
export VAXIS_FORCE_LEGACY_SGR=1

"$BIN" "$@" 2>/dev/null
