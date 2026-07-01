#!/usr/bin/env bash
# capture-kitty.sh — ROD-255 media runner. Interprets a declarative .kbeats file to
# capture README media (stills + gifs) from the REAL zigoku, including Kitty-graphics
# cover art that vhs (and every cell-grid recorder) physically cannot render.
#
# Why kitty-under-Xvfb: the Kitty graphics protocol ships cover art as PIXELS to the
# framebuffer, not as text cells. vhs models a grid of cells, so covers come out as
# `▀` halfblocks. The only capture that works is grabbing PIXELS from a terminal that
# implements the protocol — so we drive a real kitty inside a headless X server and
# screenshot / x11grab its framebuffer. This runner retires the vhs tape pipeline.
#
# Non-obvious recipe bits (each cost real debugging — do not "simplify" them away):
#   1. kitty needs `-o linux_display_server=x11` (+ KITTY_ENABLE_WAYLAND=0). Without
#      it kitty starts, runs its child, stays alive — but never presents its GL surface
#      to the Xvfb framebuffer, so every grab is blank.
#   2. `unset TMUX` FIRST. If TMUX leaks in, kitten/vaxis emit the tmux-passthrough
#      form of the graphics protocol (\ePtmux;...ESC_G...) which a non-tmux kitty
#      rejects as a bad DCS — no cover.
#   3. Software GL (Xvfb + llvmpipe) renders the protocol fine, incl. gifs at 15fps.
#
# Reuses docs/media/capture-launch.sh VERBATIM (stubbed mpv, real store, colour env),
# inheriting its watchlist-READ-ONLY safety. On top, this runner LINTS every .kbeats
# file before it touches the store and refuses to run on:
#   • a watchlist-mutating key  — P (add), p/x/c/w (status), r (reset), u (undo);
#   • a `type` beat that is a single mutating char (`type p` — a typo for `key p`);
#   • a `grab`/`record` output path that isn't a plain basename (no `../` traversal).
# What the lint does NOT cover (author discipline still required, hence these cautions):
#   • Enter-to-PLAY: `Return` is safe in most views (open/zoom a detail) but PLAYS in a
#     Discover episode-grid detail — it fires a real play. That path currently writes
#     nothing only because capture-launch.sh stubs mpv (no IPC socket → no PositionUpdate
#     → no store write); do NOT send a 2nd `Return` inside a Discover-origin detail.
#   • a `type` beat outside an open `/`…search span (its chars reach the app as commands).
# The durable fix for both is a store-level read-only mode (a ZIGOKU_READONLY_STORE flag)
# rather than an unwinnable keystroke blocklist — tracked as a follow-up.
#
# Note: real kitty parses colon-style SGR correctly, so the vhs `VAXIS_FORCE_LEGACY_SGR`
# colour workaround is not needed here — colours come out accurate. (capture-launch.sh
# still sets it; harmless, kitty reads both forms.)
#
# Usage:  ./docs/media/capture-kitty.sh [--check] docs/media/demo.kbeats
#   --check : lint the beats file ONLY (exit 0 = safe, 3 = flagged) and do NOT boot
#             Xvfb/kitty or touch the store. Use this to vet a beats file safely before
#             a real run — a real run drives the REAL store, so a bad beat can mutate it.
# Requires: Xvfb, kitty, xdotool, xdpyinfo, ImageMagick (import + magick), ffmpeg, gifski.
set -uo pipefail

# ── config (env-overridable) ──────────────────────────────────────────────────
DISP="${ZC_DISPLAY:-:99}"
SCRW="${ZC_SCRW:-1600}"; SCRH="${ZC_SCRH:-1000}"   # Xvfb screen → ~150x51 grid; roomy
                                                   # enough for 2 full Discover cover rows
FONTSIZE="${ZC_FONTSIZE:-16}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTDIR="${ZC_OUTDIR:-$ROOT/docs/media}"
STILL_BUDGET="${ZC_STILL_BUDGET:-$((500*1024))}"   # GitHub sizing budget for stills

CHECK=""; ARGS=()
for a in "$@"; do
  case "$a" in
    --check) CHECK=1 ;;                                   # position-independent safety flag
    -*) echo "unknown option: $a" >&2; exit 2 ;;          # reject typos rather than ignore
    *) ARGS+=("$a") ;;
  esac
done
set -- "${ARGS[@]:-}"
BEATS="${1:-}"
[ -n "$BEATS" ] || { echo "usage: $0 [--check] <file.kbeats>" >&2; exit 2; }
[ -f "$BEATS" ] || { echo "no such beats file: $BEATS" >&2; exit 2; }

# --check needs none of the capture deps; only the full run does.
if [ -z "$CHECK" ]; then
  for bin in Xvfb kitty xdotool import magick ffmpeg gifski xdpyinfo; do
    command -v "$bin" >/dev/null || { echo "missing dependency: $bin" >&2; exit 1; }
  done
  [ -x "$ROOT/zig-out/bin/zigoku" ] || { echo "no binary — run 'zig build' first" >&2; exit 1; }
fi

# ── read-only lint: refuse dangerous beats before we touch the real store ──────
# Mutating keys (from the status bars): P (add), p/x/c/w (status), r (reset), u (undo).
# Resolve a key spec to its final char (strip modifiers: shift+p -> p, shift+h -> h) so
# `p`, `P`, `shift+p`, `shift+P` are all caught; x/c/w/r/u are lowercase-only bindings.
is_mutating() { case "${1##*+}" in p|P|x|c|w|r|u) return 0 ;; *) return 1 ;; esac; }
# Output filenames must be a plain basename — no `../` traversal or absolute path that
# could let `grab`/`record` write over the real store/config/dotfiles under $OUTDIR/..
is_bad_name() { case "$1" in ''|*/*|.*) return 0 ;; *) return 1 ;; esac; }

lint_err=0; lineno=0
while IFS= read -r raw || [ -n "$raw" ]; do
  lineno=$((lineno+1)); line="${raw%%#*}"; set -f; set -- $line; set +f
  case "${1:-}" in
    key)
      shift
      for spec in "$@"; do
        is_mutating "$spec" && { echo "LINT: line $lineno: mutating key '$spec' forbidden (protects the live watchlist)" >&2; lint_err=1; }
      done ;;
    type)
      shift
      # a whole-token single mutating char (`type p`) reaches the app as that command;
      # legit search text like `type chainsaw man` is a multi-char string and is fine.
      is_mutating "$*" && [ "${#1}" = 1 ] && { echo "LINT: line $lineno: 'type $*' sends a mutating key — use search text, not a bare command char" >&2; lint_err=1; } ;;
    grab|record)
      is_bad_name "${2:-}" && { echo "LINT: line $lineno: bad output filename '${2:-}' — basename only, no path" >&2; lint_err=1; } ;;
  esac
done < "$BEATS"
[ "$lint_err" = 0 ] || { echo "refusing to run — fix the flagged beats in $BEATS" >&2; exit 3; }
[ -n "$CHECK" ] && { echo "lint OK — $BEATS (--check: no capture run)"; exit 0; }

# ── critical env (see recipe notes) ───────────────────────────────────────────
unset TMUX TMUX_PANE
export DISPLAY="$DISP" LIBGL_ALWAYS_SOFTWARE=1 KITTY_ENABLE_WAYLAND=0

TMP="$(mktemp -d)"

# Isolate config on an EMPTY throwaway dir: zigoku reads $XDG_CONFIG_HOME/zigoku
# (src/paths.zig) and falls back to built-in DEFAULTS when it's absent. Two wins:
#   • Safety — the Settings tour cycles the palette and exiting Settings SAVES it; the
#     old vhs stills.tape wrote your real ~/.config/zigoku/config.zon and you had to
#     reset by hand. Here the save lands in $TMP and is discarded.
#   • Determinism — media renders in the default palette (terminal_ghost, the on-brand
#     out-of-box look) regardless of your personal palette, so the themes tour's
#     terminal_ghost→…→tokyonight cycle always matches the captions.
# Data store stays REAL (we do NOT touch XDG_DATA_HOME) — covers/watchlist are yours.
export XDG_CONFIG_HOME="$TMP/config"
mkdir -p "$XDG_CONFIG_HOME"
XVFB_PID=""; KITTY_PID=""; FF_PID=""
cleanup() {
  [ -n "$FF_PID" ] && kill "$FF_PID" 2>/dev/null || true
  [ -n "$KITTY_PID" ] && kill "$KITTY_PID" 2>/dev/null || true
  [ -n "$XVFB_PID" ] && kill "$XVFB_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# ── headless X + kitty running zigoku via the read-only launcher ──────────────
pkill -f "Xvfb $DISP" 2>/dev/null || true
rm -f "/tmp/.X${DISP#:}-lock" 2>/dev/null || true
sleep 0.5
Xvfb "$DISP" -screen 0 "${SCRW}x${SCRH}x24" -nolisten tcp >"$TMP/xvfb.log" 2>&1 &
XVFB_PID=$!
sleep 1
xdpyinfo >/dev/null 2>&1 || { echo "Xvfb $DISP failed to come up" >&2; cat "$TMP/xvfb.log" >&2; exit 1; }

kitty --class zigcap --config NONE \
      -o linux_display_server=x11 \
      -o initial_window_width="$SCRW" -o initial_window_height="$SCRH" \
      -o font_size="$FONTSIZE" -o cursor_blink_interval=0 \
      bash "$ROOT/docs/media/capture-launch.sh" >"$TMP/kitty.log" 2>&1 &
KITTY_PID=$!

WID=""
for _ in $(seq 1 30); do
  WID=$(xdotool search --class zigcap 2>/dev/null | head -1)
  [ -n "$WID" ] && break
  kill -0 "$KITTY_PID" 2>/dev/null || { echo "kitty died:" >&2; cat "$TMP/kitty.log" >&2; exit 1; }
  sleep 0.5
done
[ -n "$WID" ] || { echo "no kitty window appeared" >&2; exit 1; }
xdotool windowmap "$WID" 2>/dev/null; xdotool windowraise "$WID" 2>/dev/null
# kitty IGNORES initial_window_width under bare Xvfb (no WM) and opens at a small default,
# so force the window to (nearly) fill the screen and let the app reflow (SIGWINCH) before
# we read the final geometry. This is what gives Discover its 2nd full cover row.
xdotool windowsize "$WID" "$((SCRW-4))" "$((SCRH-4))"
sleep 1.5
read -r WINW WINH < <(xdotool getwindowgeometry --shell "$WID" | awk -F= '/WIDTH/{w=$2} /HEIGHT/{h=$2} END{print w, h}')
echo "booted: window ${WINW}x${WINH} on $DISP"

# ── beat helpers ──────────────────────────────────────────────────────────────
dur() {  # "900ms" -> 0.9 ; "2.5s" -> 2.5 ; "2" -> 2
  case "$1" in
    *ms) awk "BEGIN{printf \"%.3f\", ${1%ms}/1000}" ;;
    *s)  echo "${1%s}" ;;
    *)   echo "$1" ;;
  esac
}
resize_win() {  # resize <W>x<H> — resize the window, let the app reflow, update geometry.
  # Lets one beats file capture wide views (Discover grid, two-pane detail) AND narrow
  # ones (single-pane detail, settings list) without dead space. NEVER call mid-record —
  # the x11grab region is fixed at record start. NB: kitty snaps to cell-exact sizes.
  local rw="${1%x*}" rh="${1#*x}"
  xdotool windowsize "$WID" "$rw" "$rh"; sleep 1.2
  read -r WINW WINH < <(xdotool getwindowgeometry --shell "$WID" | awk -F= '/WIDTH/{w=$2} /HEIGHT/{h=$2} END{print w, h}')
  echo "  resize → ${WINW}x${WINH}"
}
grab() {  # grab <file> — framebuffer cropped to the kitty window, kept under budget
  is_bad_name "$1" && { echo "  refusing grab to unsafe path: '$1'" >&2; return 1; }  # defense in depth (lint already caught it)
  local out="$OUTDIR/$1" bytes
  import -window root "$TMP/grab.png"
  magick "$TMP/grab.png" -crop "${WINW}x${WINH}+0+0" +repage -strip "$out"
  # Cover-heavy grabs (the Discover wall) can blow the still budget. A 256-colour PNG
  # fixes it with no visible banding and no downscale — only applied when over budget.
  # NB: du under-reports on a compressed FS (btrfs/zstd); measure logical size with stat.
  bytes=$(stat -c%s "$out")
  if [ "$bytes" -gt "$STILL_BUDGET" ]; then
    magick "$out" -strip -colors 256 -define png:compression-level=9 "$out"
    bytes=$(stat -c%s "$out")
  fi
  echo "  grab → $1 ($(magick identify -format '%wx%h' "$out"), $((bytes/1024)) KB)"
}
REC_OUT=""; REC_FPS=15; REC_W=960
rec_start() {  # record <file> [fps=N] [width=N]
  is_bad_name "$1" && { echo "  refusing record to unsafe path: '$1'" >&2; return 1; }
  [ -n "$FF_PID" ] && { echo "  record already in progress ($REC_OUT) — endrecord first" >&2; return 1; }
  REC_OUT="$1"; REC_FPS=15; REC_W=960; shift
  for kv in "$@"; do case "$kv" in fps=*) REC_FPS="${kv#fps=}";; width=*) REC_W="${kv#width=}";; esac; done
  rm -rf "$TMP/frames"; mkdir -p "$TMP/frames"
  # -nostdin + </dev/null: keep ffmpeg off stdin. The read-loop is already on fd 3, so
  # the beats file is safe; this stops ffmpeg from fighting the invoking terminal for it.
  ffmpeg -nostdin -y -f x11grab -framerate "$REC_FPS" -video_size "${WINW}x${WINH}" -i "${DISP}.0+0,0" \
         "$TMP/frames/%05d.png" >"$TMP/ffmpeg.log" 2>&1 </dev/null &
  FF_PID=$!; sleep 0.4
  echo "  record ▶ $REC_OUT (${REC_FPS}fps, ${REC_W}w)"
}
rec_stop() {
  [ -n "$FF_PID" ] || { echo "  endrecord with no active record" >&2; return; }
  kill "$FF_PID" 2>/dev/null; wait "$FF_PID" 2>/dev/null; FF_PID=""
  local n; n=$(ls "$TMP/frames"/*.png 2>/dev/null | wc -l)
  gifski --fps "$REC_FPS" --width "$REC_W" -o "$OUTDIR/$REC_OUT" "$TMP/frames"/*.png >"$TMP/gifski.log" 2>&1 \
    && echo "  endrecord ⏹ $REC_OUT ($n frames → $(($(stat -c%s "$OUTDIR/$REC_OUT")/1024)) KB)" \
    || { echo "  gifski FAILED for $REC_OUT" >&2; tail -3 "$TMP/gifski.log" >&2; }
  REC_OUT=""
}

# ── interpret the beats ───────────────────────────────────────────────────────
echo "running $BEATS"
lineno=0
# Read the beats on fd 3, never fd 0 — so a child (ffmpeg) can't consume the script.
while IFS= read -r -u 3 raw || [ -n "$raw" ]; do
  lineno=$((lineno+1)); line="${raw%%#*}"; set -f; set -- $line; set +f  # -f: split words, don't glob
  cmd="${1:-}"; [ -n "$cmd" ] || continue
  shift
  case "$cmd" in
    key)    for spec in "$@"; do xdotool windowfocus "$WID" 2>/dev/null; xdotool key --clearmodifiers --window "$WID" "$spec"; done ;;
    type)   xdotool windowfocus "$WID" 2>/dev/null; xdotool type --clearmodifiers --window "$WID" "$*" ;;
    sleep)  sleep "$(dur "$1")" ;;
    resize) resize_win "$1" ;;
    grab)   grab "$1" ;;
    record) rec_start "$@" ;;
    endrecord) rec_stop ;;
    *)      echo "  ? unknown beat on line $lineno: $cmd" >&2 ;;
  esac
done 3< "$BEATS"

echo "done — assets written to $OUTDIR"
