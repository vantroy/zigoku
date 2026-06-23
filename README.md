# zigoku · 地獄

[![CI](https://github.com/vantroy/zigoku/actions/workflows/ci.yml/badge.svg)](https://github.com/vantroy/zigoku/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/vantroy/zigoku?color=08872B)](https://github.com/vantroy/zigoku/releases/latest)
[![License: GPL-3.0](https://img.shields.io/github/license/vantroy/zigoku?color=blue)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.16.0-F7A41D?logo=zig&logoColor=white)](https://ziglang.org/)
[![Platform](https://img.shields.io/badge/platform-Linux-555)](https://github.com/vantroy/zigoku/releases/latest)

A terminal anime browser & player, built from scratch in [Zig](https://ziglang.org/).

> *Zig + jigoku ("hell").* A ground-up reimagining of the abandoned `ani-nexus-tui`,
> and — above all — a vehicle for learning Zig. This is a personal learning
> project: expect sharp edges, opinionated choices, and commit messages that
> double as study notes — see [Why this exists](#why-this-exists) for the
> story and how it's built.

## What it does today

- **Full TUI** (libvaxis): a unified two-pane shell — search with infinite-scroll
  results, a detail pane (kanji metadata chips, reflowed synopsis, and an episode
  grid with resume `▸` / watched `●` markers), and a grouped watchlist. Selection
  and active-pane focus hierarchy, toasts, spinner, status bar.
- **Watchlist & watch-state**: every show carries a status — planning / watching /
  paused / dropped / completed — with grouped history headers and fuzzy filtering.
  Add straight from browse with `P`, move state with `p`/`x`/`c`/`w`/`P`, recompute
  progress from per-episode history with `r`, and undo the last change with `u`.
  Progress and the watchlist refresh in-session right after playback.
- **Cover art** rendered with Kitty graphics where supported, halfblock cells
  everywhere else — fetched and decoded asynchronously, behind LRU caches.
- **Search → resolve → play**: AllAnime catalog search, episode listing, stream
  resolution, playback in `mpv`.
- **History & resume** in SQLite (raw C interop): watch history, exact resume
  positions (live position over mpv's IPC socket, checkpointed during playback
  and persisted on quit), and a
  status-aware episode-list cache.
- **AniList enrichment**: AllAnime results are mapped to AniList entries for
  richer metadata (season, genres, native title, format) and cover art — surfaced
  as kanji chips and persisted to the store.
- **Config & settings**: live-editable settings tab (mpv path, quality, language,
  AniSkip mode, cover art, themes). Persisted to `~/.config/zigoku/config.zon`.
  Three built-in color palettes: `terminal_ghost` (default green-on-void),
  `phosphor` (monochrome phosphor green), and `nord`.
- **Scriptable CLI** alongside the TUI: `zigoku <query>` runs the original
  prompt-driven search → pick → play flow, headless-friendly.

## Install

Zigoku is distributed as source, or as a prebuilt Linux binary (see below). To
install from source, clone it and run the installer:

```sh
git clone https://github.com/vantroy/zigoku.git
cd zigoku
./scripts/install.sh            # builds ReleaseSafe → ~/.local/bin/zigoku
```

The installer builds in `ReleaseSafe` and drops the binary in your prefix's
`bin/`. Override the prefix with `--prefix DIR` (or `PREFIX=DIR`), and remove
the binary later with `./scripts/install.sh --uninstall`. If `~/.local/bin`
isn't on your `PATH`, the installer tells you how to add it.

**Requirements:** Zig **0.16.0+** and system `sqlite3` (with dev headers) to
build; `mpv` on `PATH` at runtime. Cover art looks best in a terminal with the
Kitty graphics protocol (kitty, ghostty, WezTerm).

Once installed:

```sh
zigoku                        # no args → the TUI
zigoku frieren                # CLI flow: search → pick → play
zigoku "cowboy bebop" --dub
zigoku <query> --debug        # diagnostics to stderr (CLI) or the log file (TUI)
```

### Or: grab a prebuilt binary

Fully static, no shared-lib deps — not even glibc. SQLite is compiled in.
Runs on any Linux of that architecture; no Zig toolchain required.

**One hard runtime dependency that is not bundled and never will be: `mpv`.**
The binary shells out to whatever `mpv` is on your `PATH` to play video.
Without it, you get a browser. A very nice browser, but still.

1. Download the tarball for your arch from the [latest release](https://github.com/vantroy/zigoku/releases/latest):

   | Architecture | File |
   |---|---|
   | x86_64 (most desktops/servers) | `zigoku-vX.Y.Z-x86_64-linux-musl.tar.gz` |
   | aarch64 (ARM64) | `zigoku-vX.Y.Z-aarch64-linux-musl.tar.gz` |

2. Verify it against `sha256sums.txt` from the same release page (encouraged):

   ```sh
   sha256sum -c --ignore-missing sha256sums.txt
   ```

3. Extract and put it on your `PATH`:

   ```sh
   tar -xzf zigoku-vX.Y.Z-<target>.tar.gz
   mv zigoku ~/.local/bin/          # or wherever your PATH points
   # no chmod needed — tar preserves the executable bit
   ```

4. Make sure `mpv` is installed and on your `PATH`:

   ```sh
   command -v mpv
   ```

5. Run it:

   ```sh
   zigoku
   ```

Cover art looks best in a terminal with the Kitty graphics protocol (kitty,
ghostty, WezTerm); everywhere else you get halfblock cells. Functional either way.

## Build from source

To work on Zigoku without installing, drive it through `zig build`:

```sh
zig build run                 # no args → the TUI
zig build run -- frieren      # CLI flow: search → pick → play
zig build run -- "cowboy bebop" --dub
zig build test                # run the unit tests
./scripts/e2e.sh              # end-to-end harness (stubs mpv; offline-safe)
```

## Stack

- **TUI:** libvaxis (Kitty graphics + halfblock fallback)
- **Storage:** SQLite via raw C interop
- **Concurrency:** thread pool + channels
- **Source:** AllAnime, behind a swappable `SourceProvider` interface
- **Catalog:** AniList for metadata & cover art

## Roadmap

Condensed from the [Linear project](https://linear.app/vantroy/project/zigoku-地獄-2dff2e5d180c);
issue IDs in commit messages map back to it.

| Milestone | Scope | Status |
|-----------|-------|--------|
| **M0** | Foundation & spikes (HTTP, SQLite, concurrency, resolver, mpv) | ✅ done |
| **M1** | Vertical slice: CLI search → pick → play | ✅ done |
| **M2** | Persistence: SQLite history, resume, episode cache | ✅ done |
| **M3** | TUI shell: libvaxis, tabs, search/detail/history views | ✅ done |
| **M4** | Cover art: Kitty graphics, async pipeline, LRU caches, AniList bridge | ✅ done |
| **M5** | Playback polish: mpv IPC position ✅, checkpoints & exact resume ✅, AniSkip ✅, broader stream coverage ✅ | ✅ done |
| **M6** | Config & settings: config file ✅, settings tab ✅, themes ✅ | ✅ done |
| **M7** | Distribution & hardening: error/logging pass ✅, cross-platform paths ✅, installer & release build ✅ | ✅ done |
| **M8** | Nice-to-haves: quality selector ✅, wide-terminal history layout ✅, detail/episode caching ✅, post-playback state sync ✅ | ✅ done |
| **M9** | Polish — *the watchlist Odyssey*: watch-state machine + grouped history ✅, add-to-watchlist from browse ✅, progress recompute + single-level undo ✅, episode resume/watched chips ✅, richer detail metadata as kanji chips ✅, History↔Browse two-pane unification ✅, selection & active-pane focus hierarchy ✅, in-session refresh after playback ✅, four god-file carvings + tick/draw split ✅, DESIGN.md reconciliation ✅ | ✅ done |
| **M10** | Release: tag-driven builds + GitHub Releases, AUR & Homebrew, macOS CI, README badges & media | 📋 planned |

## Why this exists

The original goal was to learn Zig, and reading the language reference only
gets you so far. A real project — with networking, C interop, threads, a TUI,
and a database — forces you through the parts a toy exercise never touches. An
anime terminal player happened to be the itch worth scratching (RIP
`ani-nexus-tui`), so it became the learning vehicle.

What the project actually turned into is worth stating plainly: most of the
code here is written by AI — a personal agent setup ([`pi-code`](https://pi.dev/)) driving an
ensemble of models, organized as a small crew for implementation, review, and
verification — while the human side of the project owns the architecture, the
milestone planning, the design decisions, and the review of everything that
lands. The pace of the commit history
reflects that division of labor; nobody learned Zig from scratch and shipped
five milestones in a weekend, and this README won't pretend otherwise. The
learning still happens — it just moved up a layer: studying the generated
code, questioning its choices, and understanding every line well enough to
direct the next one. The clearest artifact of that process is the **spikes**. Before any real
architecture existed, every risky unknown got its own throwaway program in
[`src/spikes/`](src/spikes/) — HTTP + JSON, SQLite via C interop, threads + a
channel, the AllAnime stream resolver, mpv playback, and a TUI smoke test. Each
is a self-contained `main` with its own `zig build spike-*` step, never imported
by the real app; the ideas got promoted into proper modules, but the spikes stay
behind as runnable reference. **[SPIKES.md](SPIKES.md)** is a guided, annotated
tour through them, written as the Zig 0.16 crash course I wish had existed —
including the "writergate" `Io` story that breaks most pre-0.16 tutorials you'll
find online.

## Acknowledgements

- **[anipy-cli](https://github.com/sdaqo/anipy-cli)** by [sdaqo](https://github.com/sdaqo) (GPL-3.0) — showed us the way on AllAnime streaming when every other source had gone dark. The working recipe (POST instead of GET, Apollo persisted-query hashes, and the AES-256-GCM `tobeparsed` scheme) was learned by studying its `allanime_provider.py`. Zigoku reimplements the wire protocol in Zig from observed behavior — no code is copied — but the trail was theirs. Thank you. 🙏
- **[ani-nexus-tui](https://github.com/OsamuDazai666/ani-nexus-tui)** (CC BY-NC-SA 4.0) — studied for feature/UX inspiration.
- Catalog metadata & cover art from **[AniList](https://anilist.co/)**.

## License

[GPL-3.0](LICENSE). Our reference for the AllAnime protocol, anipy-cli, is
GPL-3.0; even though Zigoku reimplements the protocol rather than copying code,
GPL-3.0 keeps the lineage unambiguous — and it's a license we're happy to
carry anyway.
