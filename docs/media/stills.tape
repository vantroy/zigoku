# docs/media/stills.tape — populated-watchlist themes tour (gif + stills).
#
# Run on the REAL, populated store (boots into the Watchlist):
#   zig build && vhs docs/media/stills.tape
#     → docs/media/stills.gif          (the tour)
#     → docs/media/watchlist.png       (populated watchlist, terminal_ghost)
#     → docs/media/settings.png        (settings, palette row focused — themes)
#     → docs/media/detail-themed.png   (detail re-themed to tokyonight)
# Requires: vhs, ttyd, ffmpeg on PATH.
#
# ⚠️ This cycles the palette in Settings (terminal_ghost → phosphor → nord →
#    tokyonight). The `H` that exits Settings SAVES the last palette to your real
#    ~/.config/zigoku/config.zon — your next normal launch will boot tokyonight.
#    (Rod is handling that.) The watchlist is otherwise read-only.
#
# NOTE: a Screenshot must be followed by another frame (a Sleep) or vhs drops it —
# that's why each Screenshot below sits ahead of a Sleep, not at the very end.

Output "docs/media/stills.gif"

Set Shell "bash"
Set FontSize 16
Set Width 1264          # 120 cols x 40 rows at FontSize 16 / Padding 16
Set Height 886
Set Padding 16
Set TypingSpeed 55ms

# open
Hide
Type "./docs/media/capture-launch.sh"
Enter
Sleep 3s
Show
Sleep 3s                 # wait 3 seconds (settle on the Watchlist)

# scroll the watchlist — j j j, 500ms between
Type "j"
Sleep 500ms
Type "j"
Sleep 500ms
Type "j"
Sleep 500ms              # let the scroll settle
Screenshot "docs/media/watchlist.png"
Sleep 2500ms             # wait 3 seconds (500 + 2500), trailing frame for the shot

# Settings → palette row
Type "S"
Sleep 2s                 # wait 2 seconds
Type "jjjjjjj"           # j 7 times → palette row (last interactive row)
Sleep 800ms              # settle on the palette row (terminal_ghost, on-brand)
Screenshot "docs/media/settings.png"
Sleep 700ms              # trailing frame for the settings shot

# cycle palettes — l 3 times, 1.5s between each
Type "l"                 # phosphor
Sleep 1500ms
Type "l"                 # nord
Sleep 1500ms
Type "l"                 # tokyonight
Sleep 1500ms

# back to the (now re-themed) Watchlist, open a detail
Type "H"
Sleep 2s                 # wait 2 seconds
Type "h"
Sleep 1500ms             # wait 1.5 seconds
Type "l"
Sleep 1s                 # let the detail paint
Screenshot "docs/media/detail-themed.png"
Sleep 1s                 # wait 2 seconds (1 + 1), trailing frame for the shot
