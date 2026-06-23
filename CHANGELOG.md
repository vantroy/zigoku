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

[Unreleased]: https://github.com/vantroy/zigoku/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/vantroy/zigoku/releases/tag/v0.1.0
