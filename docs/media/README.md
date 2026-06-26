# docs/media — capture manifest

How the README's screenshots & demo are produced and regenerated. Two sources:

- **vhs** (scripted, checked-in `.tape` files) — flow, layout, navigation. Drives
  the real binary headlessly via [`capture-launch.sh`](capture-launch.sh).
  **Covers render as halfblock here** — vhs's terminal has no Kitty graphics.
- **Hand-captured** (Rod, real terminal) — the Kitty-graphics **cover-art** shots.
  vhs physically can't render these; they're shot in bare ghostty/kitty (no tmux —
  tmux also strips Kitty graphics).

All assets are **120×40** (the app's design grid). For vhs that's
`Set Width 1264` / `Set Height 886` at `FontSize 16` / `Padding 16`.

## Regenerate (vhs assets)

```sh
zig build                         # tapes drive ./zig-out/bin/zigoku — build first
vhs docs/media/demo.tape          # → demo.gif (hero; LIVE search, content varies)
vhs docs/media/stills.tape        # → stills.gif + watchlist.png, settings.png,
                                  #   detail-themed.png (themes tour; local, deterministic)
```

Requires `vhs`, `ttyd`, `ffmpeg` on PATH (verified with vhs v0.11.0).

> **demo.tape is live, stills.tape is not.** `demo.tape` hits live AllAnime +
> AniList, so the show/cover varies per run; if it lands on the empty Watchlist,
> the search returned nothing (slow/rate-limited) — re-run. `stills.tape` only
> navigates the local watchlist + settings + cached detail, so it's deterministic.

## Asset list

| File | Source | Shows |
|---|---|---|
| `demo.gif` | vhs · `demo.tape` | **Hero:** Watchlist → Browse → search → enriched detail → episode grid, play-ready. |
| `stills.gif` | vhs · `stills.tape` | **Themes tour:** watchlist → settings palette cycle → re-themed detail. |
| `watchlist.png` | vhs · `stills.tape` | Populated watchlist (terminal_ghost), grouped status + progress bars. |
| `settings.png` | vhs · `stills.tape` | Settings tab, palette row focused (themes). |
| `detail-themed.png` | vhs · `stills.tape` | Two-pane detail re-themed to **tokyonight**. |
| `detail-cover.png` | hand-capture | Detail with **real Kitty-graphics cover art** + kanji chips + synopsis + grid. |
| `history.png` | hand-capture | Real watchlist: grouped headers + progress bars. |
| `browse-covers.png` | hand-capture | Second real-cover-art angle. |

Captions for the Kitty-graphics shots should note the terminal (kitty / ghostty /
WezTerm); the vhs assets show covers as the halfblock fallback.

**On the hero's ending:** `demo.gif` stops on the detail pane + episode grid with
the `enter play` affordance lit — *not* an mpv playback frame. Headless, the play
key hands off to a stubbed mpv that exits instantly, so the app jumps back to the
Watchlist — a dead end. A terminal gif can't show mpv's video window anyway, so
"→ play" lives in the caption + the status-bar affordance. Deliberate, not missing.

## Tuning notes (verified)

- Geometry: `Set Width 1264` / `Set Height 886` at `FontSize 16` / `Padding 16` =
  exactly **120 cols × 40 rows** (vhs Width/Height are pixels, not cells).
- A `Screenshot` must be followed by another frame (a `Sleep`) or vhs drops it.
- `Output "x.png"` makes a *directory* of frame layers in vhs 0.11 — don't use it for
  stills; use the `Screenshot` command.
- vhs has **no F-keys**, so views switch via **`H`** (Browse↔History) and **`S`**
  (Settings). The launcher uses the **real store**, so the app boots into the
  **Watchlist** — tapes press `H` to reach Browse before searching.
- **Colour:** zigoku emits truecolor in colon-style SGR (`\e[38:2:R:G:Bm`), which vhs
  mis-parses (greens → burnt orange). `capture-launch.sh` exports
  `VAXIS_FORCE_LEGACY_SGR=1` (semicolon form vhs reads) + `COLORTERM=truecolor`. The
  app also honours `COLORTERM` → `caps.rgb` (`src/tui/app.zig`). Without these, orange.
- **Real-store safety:** capture runs on `~/.local/share/zigoku`, but the tapes are
  watchlist-read-only and mpv is stubbed. Browse search upserts enrichment with
  `history_visible=0` (invisible in History) and `MAX(...)` on conflict, so it never
  floods History or un-hides anything. Never add P/play/status keys to a tape.
  ⚠️ `stills.tape` cycles the palette and the `H` exiting Settings **saves** it — your
  next normal launch boots the last palette (tokyonight). Cycle back or reset if unwanted.
