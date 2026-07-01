# docs/media — capture manifest

How the README's screenshots & demo are produced and regenerated. **One pipeline:**
a real **kitty** driven inside a headless **Xvfb**, screenshotted / recorded at the
pixel level. This replaces the old vhs tapes — the reason is cover art.

The Kitty graphics protocol ships cover art as **pixels** to the framebuffer, not as
text cells. vhs (and every cell-grid recorder — asciinema, termtosvg, agg) models the
terminal as a grid of cells, so it renders covers as `▀` halfblocks and can never
capture one. Driving a real kitty and grabbing its framebuffer is the only way — and
it means every asset, including the hero gif and the Discover feed, shows **real
covers** (ROD-255).

Default capture is a roomy **1600×1000** Xvfb screen (font size 16 ≈ a 150×51 grid), so
the Discover feed shows **two full rows** of cover art. Views that don't reflow to fill
that width — the single-pane detail and the settings list — are shrunk per-grab with a
`resize` beat (see below) so they read balanced instead of half-empty. kitty ignores
`initial_window_width` under a bare (no-WM) Xvfb, so the runner sets the size with
`xdotool windowsize` after launch and lets the app reflow.

## Regenerate

```sh
zig build                                        # beats drive ./zig-out/bin/zigoku
./docs/media/capture-kitty.sh docs/media/demo.kbeats     # → demo.gif (hero)
./docs/media/capture-kitty.sh docs/media/discover.kbeats # → discover.gif (Discover tour)
./docs/media/capture-kitty.sh docs/media/browse.kbeats   # → browse.gif (Browse search tour)
./docs/media/capture-kitty.sh docs/media/covers.kbeats   # → detail-cover / browse-covers / history .png
./docs/media/capture-kitty.sh docs/media/stills.kbeats   # → stills.gif + watchlist / settings / detail-themed .png
```

Requires `Xvfb`, `kitty`, `xdotool`, `xdpyinfo`, `ffmpeg`, `gifski`, ImageMagick
(`import` + `magick`) on PATH (verified with kitty 0.47, ffmpeg + gifski, Mesa llvmpipe
software GL).

> **Content is live where it says so.** `demo`, `discover`, `browse`, and `covers`
> beats read your real store / the live Discover feed / live AllAnime search, so the
> exact shows/covers vary per run. That's by design (ROD-148/247). If a live search or
> feed is slow, a tour may catch a `searching…`/`loading…` frame — re-run or lengthen
> the sleep. Timing is tunable per beats file.

## The `.kbeats` format

A beats file is a line-oriented capture script the runner interprets against a live
zigoku. Comments start with `#`. Commands:

| Beat | Effect |
|---|---|
| `key <spec> [<spec>…]` | send key chords via xdotool (`key shift+h`, `key j j j`, `key Return`) |
| `type <text>` | type literal text (search boxes) |
| `sleep <dur>` | wait — `900ms`, `2.5s`, or bare seconds |
| `resize <W>x<H>` | resize the window (app reflows); use before a `grab` that wants a narrower/shorter frame. Never mid-`record`. |
| `grab <file.png>` | screenshot the framebuffer, crop to the window, write to `docs/media/` |
| `record <file.gif> [fps=N] [width=N]` … `endrecord` | x11grab the window, encode with gifski |

It's the same iterate loop as a vhs tape: edit the beats, re-run, eyeball, adjust
`sleep`/keys. See `demo.kbeats` for a worked example.

## Asset list

| File | Beats | Shows |
|---|---|---|
| `demo.gif` | `demo.kbeats` | **Hero:** watchlist master-detail with **live cover art** (cover updates per selection) → typed filter down to the Frieren detail. |
| `discover.gif` | `discover.kbeats` | **Discover tour:** the ranked cover wall — sweep the grid, switch the ranking window, a fresh wall of covers loads. |
| `browse.gif` | `browse.kbeats` | **Browse tour:** live catalogue search — type a query and real covers stream into the two-pane results. |
| `stills.gif` | `stills.kbeats` | **Themes tour:** Settings palette cycle re-theming a two-pane detail. |
| `watchlist.png` | `stills.kbeats` | Populated watchlist (default **terminal_ghost**), grouped status + progress bars. |
| `settings.png` | `stills.kbeats` | Settings tab, palette row focused. |
| `detail-themed.png` | `stills.kbeats` | Two-pane detail re-themed to **tokyonight**. |
| `detail-cover.png` | `covers.kbeats` | **Discover** #1 detail: real cover + kanji chips + score + synopsis + episode grid. |
| `browse-covers.png` | `covers.kbeats` | **Discover feed:** a wall of real Kitty-graphics cover art (ROD-247). |
| `history.png` | `covers.kbeats` | Real watchlist master-detail, scrolled to a planning-group cover. |

**On the hero's ending:** the play beat can't be shown headlessly — mpv is stubbed, so
"→ play" lives in the caption + the status-bar affordance, and the hero ends on the
enriched detail. Deliberate, not missing.

## Safety (the live watchlist is never touched)

The runner reuses `capture-launch.sh` verbatim (stubbed mpv, real store) and adds two
guards on top:

- **Read-only lint.** The runner refuses to run any beats file containing a
  watchlist-mutating key — `P` (add), `p/x/c/w` (status), `r` (reset), `u` (undo) — a
  single-char `type` command (`type p`), or a `grab`/`record` path that isn't a basename.
  Vet a beats file safely with `capture-kitty.sh --check <file>` (lints only, never boots
  Xvfb or touches the store). **Caveat:** a real run drives the REAL store, and the lint
  can't catch a multi-char `type` sent *outside* an open `/` search (its chars reach the
  app as commands) or a 2nd `Return` in a Discover detail (plays). The durable fix is a
  store-level read-only mode — tracked as a follow-up. Until then: `--check`, and keep
  every `type` inside a `/`…search span.
- **Config isolation.** `XDG_CONFIG_HOME` points at an empty throwaway dir, so the
  Settings/palette tour's save is discarded and the app renders in the **default**
  palette (deterministic media, independent of your personal config). The data store
  (`XDG_DATA_HOME`) is left real, so covers/watchlist are your actual library.

## Tuning notes (verified)

- **kitty must present under Xvfb:** the runner sets `-o linux_display_server=x11` +
  `KITTY_ENABLE_WAYLAND=0`. Without it kitty runs but never paints to the framebuffer.
- **`unset TMUX`:** if TMUX leaks in, kitten/vaxis emit the tmux-passthrough form of the
  graphics protocol, which a non-tmux kitty rejects — no cover. The runner unsets it.
- **Colour is accurate:** real kitty parses colon-style SGR correctly, so the old vhs
  `VAXIS_FORCE_LEGACY_SGR` workaround is unnecessary (greens stay green).
- **Sizing (GitHub budget):** hero gif **< 3 MB**, stills **< 500 KB**. `grab` auto-
  quantizes a still to a 256-colour PNG only if it would bust the budget (the Discover
  cover-wall needs it; nothing else does) — no visible banding, no downscale.
- **Software GL** (llvmpipe) is plenty at 15fps. On a compressed FS, `du` under-reports
  on-disk size — the runner reports logical bytes (`stat`) so the budget check is honest.
