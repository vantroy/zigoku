# docs/media/stills.tape — non-cover stills: search results + settings/themes.
#
# Regenerate:  zig build && vhs docs/media/stills.tape
#   → docs/media/search.png   (search results: list + score badges + detail preview)
#   → docs/media/settings.png (settings tab, focused on the palette/themes row)
#   → docs/media/stills.gif   (incidental montage byproduct — vhs requires an Output;
#                              ignore or delete it, the PNGs are the deliverables)
# Requires:    vhs, ttyd, ffmpeg on PATH.
#
# Same launcher + live-content caveats as demo.tape: isolated store, stubbed mpv,
# covers as halfblock, content varies per run (ROD-148). If search lands empty,
# AllAnime was slow/rate-limiting — re-run.

Output "docs/media/stills.gif"

Set Shell "bash"
Set FontSize 16
Set Width 1200
Set Height 760
Set Padding 16
Set TypingSpeed 55ms

# ── Boot (hidden) ───────────────────────────────────────────────────────────
Hide
Type "./docs/media/capture-launch.sh"
Enter
Sleep 3s
Show
Sleep 1s

# Real store boots into the Watchlist — flip to Browse before searching, or `/`
# filters the watchlist instead of the catalogue (H toggles Browse<->History).
Type "H"
Sleep 900ms

# ── Still 1: search results ─────────────────────────────────────────────────
Type "/"
Sleep 500ms
Type "frieren"
Sleep 600ms
Enter
Sleep 7s           # live search + enrichment (tune to your connection)
Screenshot "docs/media/search.png"
Sleep 500ms        # a frame must follow a Screenshot or vhs drops it

# ── Still 2: settings / themes (land on the palette row) ────────────────────
Type "S"
Sleep 800ms
Type "jjjjjjj"     # 7 rows down: mpv path → … → palette (last interactive row)
Sleep 1200ms
Screenshot "docs/media/settings.png"
Sleep 800ms        # trailing frame so the Screenshot isn't dropped
