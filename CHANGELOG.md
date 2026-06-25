# Changelog

All notable changes to zigoku are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!--
Curated by hand. `git cliff --unreleased` prints a grouped draft from the commit
log since the last tag — copy what's worth keeping into [Unreleased], then edit
for voice. At release, promote [Unreleased] → [X.Y.Z] with the date, bump the
version in build.zig.zon + src/root.zig, and refresh the compare links below.
-->

## [Unreleased]

## [0.1.2] - 2026-06-26

### Added

- **TokyoNight theme**: a fourth dark palette, selectable via `palette = "tokyonight"` in config or by cycling through the in-app Settings screen. Maps TokyoNight Night colours to zigoku's semantic tokens, with two deliberate adaptations: `fg2` tuned for even muted/dim spacing in the watchlist, and the focused-row colour brightened so it clears `fg` as the design requires.
- **AniList score in Browse**: each search result now shows a compact `[NN]` score badge in the list-row meta, tier-coloured so higher scores read brighter — bold accent at ≥ 91, full brightness ≥ 76, muted ≥ 51, dim below; `[--]` when unenriched. The title falls off last on a narrow pane — the score outlasts the episode count.
- **Homebrew tap**: macOS users can now install via `brew install vantroy/zigoku/zigoku`. No Zig toolchain required; the formula pulls the prebuilt, SQLite-bundled binary and lists mpv as its only runtime dependency.

### Fixed

- **Browse episode grid no longer bleeds across views**: switching from History detail to Browse left the previous grid visible in the list-hover preview. The grid is now gated on whether a detail show is actively focused — the browse-hover preview stays grid-free as intended.
- **Watch-state dim in Browse-opened shows**: the already-watched episode dim only seeded when opening a show from History; opening the same show from Browse showed nothing dimmed even with watch history present. Both code paths now share the same seed logic.
- **Toast styling corrected**: success and error toasts now bold the body text, not just the glyph prefix; info and warn stay plain. The previous rendering bolded every glyph regardless of kind and left success/error bodies unemphasised.
- **History row-1 no longer duplicates the episode count**: the first of each two-line History entry showed `ep N/M · status` in its right meta; the progress bar on line 2 showed the same fraction again. Row 1 is now title-only; the count stays on the bar where it belongs.
- **Settings cover-art cache path is now accurate**: the Settings screen previously showed a hardcoded `~/.cache/zigoku/covers` regardless of `$XDG_CACHE_HOME`. It now resolves and displays the real path, with `$HOME` collapsed to `~`.

## [0.1.1] - 2026-06-25

### Added

- **Cover-art disk cache**: fetched covers now persist under
  `$XDG_CACHE_HOME/zigoku/covers/` and survive restarts, so a cold start no
  longer re-downloads every visible cover.
- **First-run discoverability**: empty views show actionable guidance and scope
  tags instead of a blank pane.
- **macOS support**: SQLite is now bundled (fixing a startup segfault on stock
  macOS), and releases ship macOS binaries — arm64 and x86_64 — alongside the
  static Linux musl builds.

### Changed

- **Snappier Browse**: episodes lazy-load on detail entry rather than on hover,
  and the cover-preview fetch is debounced until the cursor settles.
- **ESC / q semantics**: ESC peels transient layers (toasts, filter, detail)
  while q quits — the old q/ESC ambiguity is gone.
- mpv's window title is now prefixed with `zigoku — `.

## [0.1.0] - 2026-06-23

First tagged release — a terminal anime browser & player built from scratch in
Zig. See the [README](README.md) for the full story.

### Added

- **TUI shell** (libvaxis): a unified two-pane interface — infinite-scroll search
  results, a detail pane (kanji metadata chips, reflowed synopsis, episode grid
  with resume `▸` and watched `●` markers), and a grouped watchlist. Active-pane
  focus hierarchy, toasts, spinner, and status bar.
- **Search → resolve → play**: AllAnime catalog search, episode listing, stream
  resolution (long-tail provider deciphering, m3u8/wixmp parsers), and playback
  in `mpv`. Quality cap-policy variant selection honours a configured default.
- **Watchlist & watch-state machine**: per-show status (planning / watching /
  paused / dropped / completed) with grouped history headers and fuzzy filtering.
  Add from browse with `P`; move state with `p`/`x`/`c`/`w`; recompute progress
  from per-episode history with `r`; undo the last change with `u`. Watchlist and
  progress refresh in-session right after playback.
- **History & resume** in SQLite (raw C interop): watch history and exact resume
  positions tracked live over mpv's IPC socket, checkpointed during playback and
  persisted on quit; a status-aware episode-list cache for instant back-navigation.
- **AniList enrichment**: AllAnime results are joined to AniList for richer
  metadata (season, genres, native title, format, studios, dates) and cover art —
  surfaced as kanji chips and persisted to the store.
- **Cover art**: Kitty graphics where supported, halfblock fallback everywhere
  else — fetched and decoded asynchronously behind LRU caches.
- **Config & settings**: a live-editable settings tab (mpv path, quality,
  language, AniSkip mode, cover art, theme) persisted to
  `~/.config/zigoku/config.zon`. Three palettes: `terminal_ghost` (default),
  `phosphor`, `nord`.
- **Scriptable CLI** alongside the TUI: `zigoku <query>` runs a headless-friendly
  search → pick → play flow; `--dub` and `--debug` flags supported.
- **Distribution**: an in-repo installer (`scripts/install.sh`) with prefix
  override and uninstall, plus an offline-safe end-to-end harness
  (`scripts/e2e.sh`).

[Unreleased]: https://github.com/vantroy/zigoku/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/vantroy/zigoku/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/vantroy/zigoku/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/vantroy/zigoku/releases/tag/v0.1.0
