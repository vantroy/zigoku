# docs/media — capture manifest

How the README's screenshots & demo are produced and regenerated. Two sources:

- **vhs** (scripted, checked-in `.tape` files) — flow, layout, navigation. Drives
  the real binary headlessly via [`capture-launch.sh`](capture-launch.sh).
  **Covers render as halfblock here** — vhs's terminal has no Kitty graphics.
- **Hand-captured** (Rod, real terminal) — the Kitty-graphics **cover-art** shots.
  vhs physically can't render these; they're shot in bare ghostty/kitty (no tmux —
  tmux also strips Kitty graphics).

> **Content is live, not deterministic.** Tapes hit live AllAnime + AniList, so the
> exact shows/covers differ each run. The *flow* is reproducible; the *content* isn't.
> If a render lands on the empty Watchlist ("nothing watched yet"), the live search
> returned nothing that run (AllAnime slow / rate-limiting) — just re-run.

## Regenerate (vhs assets)

```sh
zig build                         # tapes drive ./zig-out/bin/zigoku — build first
vhs docs/media/demo.tape          # → docs/media/demo.gif (hero)
vhs docs/media/stills.tape        # → docs/media/search.png, settings.png (+ stills.gif)
```

Requires `vhs`, `ttyd`, `ffmpeg` on PATH. Verified working with vhs v0.11.0.
`stills.gif` is an incidental montage (vhs requires an `Output`) — ignore/delete it;
the PNGs are the deliverables.

## Asset list

| File | Source | Shows | Caption note |
|---|---|---|---|
| `demo.gif` | vhs · `demo.tape` | **Hero:** search → enriched detail → episode grid, play-ready. | "Recorded headlessly with vhs; covers shown as halfblock fallback." |
| `search.png` | vhs · `stills.tape` | Search results, score badges, live detail preview. | halfblock covers |
| `settings.png` | vhs · `stills.tape` | Settings tab focused on the **palette** row (themes). | — |
| `history.png` | **hand-capture preferred** | History: grouped headers + progress bars + fuzzy filter. | vhs can't fill progress bars (empty fresh store); shoot off the real watchlist. |
| `detail-cover.png` | **hand-capture** (Rod) | Detail pane with **real Kitty-graphics cover art** + kanji chips + synopsis + episode grid. | "Cover art in a Kitty-graphics terminal (kitty/ghostty/WezTerm)." |
| `browse-covers.png` | **hand-capture** (Rod) | Optional second cover-art angle. | same caption |

**On the hero's ending:** it stops on the detail pane + episode grid with the
`enter play` affordance lit — *not* an mpv playback frame. Headless, the play key
hands off to a stubbed mpv that exits instantly, so the app immediately runs its
post-playback sync and jumps back to the Watchlist — a dead end for the hero. A
terminal gif can't show mpv's video window anyway, so "→ play" lives in the caption
+ the status-bar affordance. This is deliberate, not a missing beat.

## Rod's hand-capture shot list

Real terminal, **no tmux** (it strips Kitty graphics). ghostty or kitty, ~120×40.

1. **`detail-cover.png`** — search a show with good art (Frieren, FMA:B…), open detail
   (`l`). Capture the full pane: cover + kanji chips + synopsis + episode grid.
2. **`history.png`** — your real watchlist in History (`H`): grouped headers, filled
   progress bars, optionally with the fuzzy filter (`/`) active.
3. *(optional)* **`browse-covers.png`** — a second cover-art angle.

Drop them in this dir with the filenames above. Crop/size pass is Mira's.

## README text reconciliation (for Aya)

Drift found while driving the live app — the prose should be corrected:

- **Palettes: README says "Three", there are now FOUR** — `terminal_ghost`,
  `phosphor`, `nord`, **`tokyonight`** (`src/tui/settings_state.zig:88`).
- **AUR**: not in the repo (only `packaging/homebrew/`). Per ROD-148, stub it as
  "coming soon", document the live three (Homebrew + prebuilt binary + source).
- **Boot view**: a fresh/empty store opens to **Browse** (the catalogue); a populated
  store opens to **History**. Minor, but worth not mis-stating.

## Tuning notes (verified)

- Geometry: `Set Width 1200`, `Set Height 760`, `Set FontSize 16`, `Set Padding 16`
  → ~120×38 cells, which fits the two-pane + full episode grid.
- A `Screenshot` must be followed by another frame (a `Sleep`) or vhs drops it.
- `Output "x.png"` makes a *directory* of frame layers in vhs 0.11 — don't use it for
  stills; use the `Screenshot` command.
- Sizing is a non-issue: the void-black background compresses to tens of KB (hero
  ≈ 40–300 KB), far under the GitHub budget (hero < 3 MB, stills < 500 KB).
- View nav without F-keys (vhs can't send them): **`H`** toggles Browse↔History,
  **`S`** opens Settings — both plain letters vhs types fine. The launcher uses the
  **real store**, so the app boots into the **Watchlist** — tapes press `H` to reach
  Browse before searching, or `/` filters the watchlist instead of the catalogue.
- **Colour:** zigoku emits truecolor in colon-style SGR (`\e[38:2:R:G:Bm`), which vhs
  mis-parses (greens → burnt orange). `capture-launch.sh` exports
  `VAXIS_FORCE_LEGACY_SGR=1` (semicolon form vhs reads) + `COLORTERM=truecolor`. The
  app also honours `COLORTERM` → `caps.rgb` (`src/tui/app.zig`). Without these, orange.
- **Real-store safety:** capture runs on `~/.local/share/zigoku`, but the demo/stills
  tapes are watchlist-read-only and mpv is stubbed. Browse search upserts enrichment
  with `history_visible=0` (invisible in History) and `MAX(...)` on conflict, so it
  never floods History or un-hides anything. Never add P/play/status keys to a tape.
