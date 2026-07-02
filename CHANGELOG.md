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

## [0.2.2] - 2026-07-03

### Changed

- **Discover's first page now fills the screen**: on large monitors, the fixed 30-card page used to leave empty rows below the last card. The grid now keeps loading more pages until it fills the visible viewport (or the feed runs out), and refills again if you resize into more room.

### Fixed

- **The last blank Discover covers now render**: a small share of covers — roughly one or two in fifty — showed as blank placeholders. Two separate causes, both closed: AllAnime serves some cover URLs as a bare relative path the app couldn't fetch, and its cover CDN returns WebP regardless of the file extension, which the app couldn't decode even when the fetch succeeded. Those covers now resolve and decode (WebP included), so the grid fills without the odd gap.

- **Discover no longer freezes the screen while it loads**: switching time windows used to block the whole app until the in-flight fetch returned, because the feed and metadata work ran on the UI thread. That work now runs off-thread, and every request — feed, metadata, and cover — carries a wall-clock deadline, so a slow or unresponsive server can't hang a fetch (or, under sustained load, back new ones up behind it). A bad connection now degrades instead of locking up.

## [0.2.1] - 2026-07-02

### Changed

- **History's detail view now matches Browse's**: opening a show in History shows its episode grid immediately, at any width — the extra "focus the pane, then press again" step is gone. Browse and History detail now behave identically.

- **Two-column detail no longer cramps at borderline widths**: the layout used to measure the whole terminal to decide whether to split into two columns, which could claim a column too narrow to hold it — clipping genres and metadata. It now measures the pane itself, so the split only triggers when there's genuinely room.

### Added

- **Metadata rail in the detail view**: the empty space below a show's header now shows episode count and format (TV, Movie, etc.) — a compact one-liner in narrow panes, a labeled two-column rail where there's room to spread out.

- **AUR package for Arch Linux**: a `PKGBUILD` for a from-source build is now in the repo (`packaging/aur/zigoku`) — `makepkg -si` builds and installs it against your system Zig, SQLite, and mpv. It isn't on the AUR registry yet (new-account registration has been closed since mid-June), so `paru -S zigoku` isn't live; that lands the moment registration reopens.

## [0.2.0] - 2026-07-01

### Added

- **Discover view**: a new top-level view — `D` from anywhere — showing popular anime as a navigable cover grid. Time window switches with keys `1`–`4` (Daily / Weekly / Monthly / All-Time), each with its own scroll position and page cache; pressing load-more pages forward. The view handles loading, empty, and offline states without falling over. Opening a card zooms to a detail panel where the synopsis loads lazily.

- **Cover art in Discover**: covers render inline in each grid cell — Kitty graphics where the terminal supports it, half-block characters everywhere else — fetched with bounded concurrency, scaled to fill the cell, and written to the disk cache so a revisit costs nothing. A peek row fills the partial band below the last complete row with the next batch of covers, signalling that more is below.

- **AniList metadata on Discover cards**: each card shows a tier-coloured score badge, genre glyphs, and a season/year chip. The AllAnime popular feed does not carry reliable score, genre, or season data; a single batched AniList request per page fills the gap while keeping load latency low. Long titles are ellipsis-truncated so they never overflow the cell.

- **Persistent tab strip and symmetric view keys**: a tab strip across the top of the screen now names all active views at all times. Single-key switching is symmetric across the app — `B` Browse, `H` History, `D` Discover, `S` Settings — and the Discover window bar is annotated with its `1`–`4` keys. Views were also renamed for consistency.

- **`--version` / `-V`**: the CLI now prints the build version and exits.

- **First-run empty-watchlist guidance updated**: an empty History view now leads with Discover ("see what's popular") as the primary next step, with Browse ("search for a show") as the secondary. Previously it pointed only at Browse's blank search prompt.

### Fixed

- **Kitty cover acknowledgements now fully quieted**: pending acks are already drained on quit to keep them from surfacing in the shell. Cover placements and deletions are now additionally issued with the quiet flag — via a pinned libvaxis build — so the terminal never queues them in the first place. This closes the paths the drain alone couldn't cover: acks arriving mid-load when the user quits before the batch completes, and the transmit/delete reply pairs that bled through in tmux and SSH sessions.

- **Discover time-window cycle no longer overflows at the end**: pressing the cycle key past All-Time wrapped a too-narrow index and landed on an out-of-range window. The index type now covers the full range correctly.

## [0.1.5] - 2026-06-28

### Added

- **Configurable startup view**: zigoku now opens on whichever view is set via `landing` in `config.zon` — `"history"` or `"browse"` — with a matching "landing view" cycle row in the Settings tab. Previously the app always started on History; History remains the default when the setting is absent or unrecognised.

- **Resume landing**: `landing = "last_watched"` in `config.zon` (selectable in the Settings landing cycle) opens the most-recently-watched show's detail pane at startup, with the episode cursor parked on the next episode to continue. Previously the app always landed on a list view; empty history and fetch failures fall back gracefully to History.

### Fixed

- **Kitty graphics acknowledgements no longer bleed onto the shell prompt after quitting**: the terminal replies to each cover-art transmission with an `_Gi=N;OK` response; these arrive asynchronously and were left unread when the app exited, landing in the tty buffer for the shell to echo as garbage on the next prompt. The quit path now drains any pending acks before exiting — bounded to avoid delay, and skipped entirely when no cover art was transmitted during the session.

## [0.1.4] - 2026-06-27

### Fixed

- **Quitting no longer freezes the screen after a busy Browse session**: exiting while background cover and metadata fetches were in flight waited for each worker to time out — up to five seconds of a frozen alt-screen if Browse had fired a storm of requests. Settings save synchronously and the store is autocommit, so nothing durable needs draining; quit now restores the terminal and exits at once, leaving any in-flight network work to the OS.

- **Browse errors no longer disable the History view**: a search or metadata-fetch failure in Browse wrongly raised History's "unavailable" banner — and because nothing cleared it, History stayed unreachable until the app restarted. Browse and network errors are now scoped to Browse and surface as a toast; History gets its own error path, and a successful load clears any prior failure so a transient blip self-heals rather than latching for the session.

## [0.1.3] - 2026-06-27

### Added

- **Truecolor via `COLORTERM`**: zigoku now honours `COLORTERM=truecolor` (or `24bit`) to enable 24-bit colour in terminals that advertise it but do not answer the capability query — common in some tmux and SSH setups. Without it, the palette fell back to 256-colour approximation.

- **Failure-specific error toasts for playback and episode loads**: failures now surface a specific reason instead of a generic fallback. DNS and connectivity losses, blocked requests (403), and server errors each produce a distinct toast — enough to tell whether to check your connection, try a VPN, or wait out a source outage.

- **Distinct `mpv not found` and `mpv crashed` messages**: a missing mpv binary shows `mpv not found — install mpv`; a crash or non-zero exit shows `mpv exited with error`. Both are distinct from source and network failures.

### Fixed

- **Scrolling no longer stalls against slow connections**: navigating the watchlist while an episode prefetch was in flight on a slow endpoint could briefly block input until the fetch completed. Superseded prefetches now run to completion in the background — the main loop never waits on them.

- **English and native titles in Watchlist detail**: the Watchlist and History detail pane now shows the English and native-script titles below the romaji title, matching the Browse detail view. The data was already in the store; only the render path was missing.

- **SQLite bind errors are now caught and surfaced**: a failed parameter bind previously ran the statement with a `NULL` substitution, which could produce data corruption on a column-index mismatch. The error now propagates instead of being discarded.

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

[Unreleased]: https://github.com/vantroy/zigoku/compare/v0.2.2...HEAD
[0.2.2]: https://github.com/vantroy/zigoku/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/vantroy/zigoku/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/vantroy/zigoku/compare/v0.1.5...v0.2.0
[0.1.5]: https://github.com/vantroy/zigoku/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/vantroy/zigoku/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/vantroy/zigoku/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/vantroy/zigoku/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/vantroy/zigoku/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/vantroy/zigoku/releases/tag/v0.1.0
