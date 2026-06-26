# docs/media/demo.tape — hero demo: search → detail → play.
#
# Regenerate:  zig build && vhs docs/media/demo.tape   (→ docs/media/demo.gif)
# Requires:    vhs, ttyd, ffmpeg on PATH.
#
# Drives the real binary through docs/media/capture-launch.sh, which isolates the
# store (never the real watchlist) and stubs mpv (the play beat needs no display).
# Content is LIVE (AllAnime + AniList) so the exact show/cover varies per run — by
# design (ROD-148). Covers render as halfblock here; vhs has no Kitty graphics.

Output "docs/media/demo.gif"

Set Shell "bash"
Set FontSize 16
Set Width 1264          # 120 cols x 40 rows at FontSize 16 / Padding 16
Set Height 886
Set Padding 16
Set TypingSpeed 60ms

# ── Boot (hidden: skip the shell command + splash) ──────────────────────────
Hide
Type "./docs/media/capture-launch.sh"
Enter
Show



# The real store boots into the Watchlist. Flip to Browse first (H toggles
# Browse<->History) — without this, `/` filters the watchlist instead of
# searching the catalogue.
Sleep 2s
Type "j"
Sleep 3s
Type "k"
Sleep 5s
Type "H"
Sleep 900ms

# ── Search the catalogue ────────────────────────────────────────────────────
Type "/"
Sleep 500ms
Type "frieren"
Sleep 600ms
Enter
Sleep 7s           # live search + AniList enrichment (tune to your connection)

# ── Open + focus the detail pane (cover, kanji chips, synopsis, ep grid) ─────
Type "l"
Sleep 3500ms       # episode grid loads a beat after the pane opens

# Nudge RIGHT through a few episodes so the grid reads as interactive, then rest.
# Forward-only on purpose: `h` at the left edge of the grid means "back" and would
# drop out of the detail pane — never walk back here. The "enter play" affordance
# in the status bar is the play story for a terminal demo (mpv playback is a
# separate window a gif can't show). The hero ends on the money frame: cover +
# kanji chips + synopsis + episode grid, play-ready.
Type "l"
Sleep 600ms
Type "l"
Sleep 600ms
Type "l"
Sleep 2500ms       # rest on the grid, "enter play" lit

Sleep 1s           # trailing hold so the final frame isn't clipped
#
# NOTE: this drives a LIVE search. If a render lands on the empty Watchlist
# ("nothing watched yet"), the search returned no results that run — AllAnime was
# slow or rate-limiting. Just re-run `vhs docs/media/demo.tape`.
