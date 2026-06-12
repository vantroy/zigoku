# zigoku · 地獄

A terminal anime browser & player, built from scratch in [Zig](https://ziglang.org/).

> *Zig + jigoku ("hell").* A ground-up reimagining of the abandoned `ani-nexus-tui`,
> and — above all — a vehicle for learning Zig the hard (fun) way. This is a
> personal learning project: expect sharp edges, opinionated choices, and
> commit messages that double as study notes.

## What it does today

- **Full TUI** (libvaxis): tabbed shell with search, infinite-scroll results,
  a detail pane (metadata, reflowed synopsis, episode grid), and a history view
  with fuzzy filtering and per-episode progress bars. Toasts, spinner, status bar.
- **Cover art** rendered with Kitty graphics where supported, halfblock cells
  everywhere else — fetched and decoded asynchronously, behind LRU caches.
- **Search → resolve → play**: AllAnime catalog search, episode listing, stream
  resolution, playback in `mpv`.
- **History & resume** in SQLite (raw C interop): watch history, exact resume
  positions (live position over mpv's IPC socket, checkpointed during playback
  and persisted on quit), and a
  status-aware episode-list cache.
- **AniList enrichment**: AllAnime results are mapped to AniList entries for
  richer metadata and cover art.
- **Scriptable CLI** alongside the TUI: `zigoku <query>` runs the original
  prompt-driven search → pick → play flow, headless-friendly.

Known gap: quality selection is parsed but not honoured yet — playback uses the
1080p direct stream while the full m3u8 resolver is pending (ROD-92).

## Build & run

```sh
zig build run                 # no args → the TUI
zig build run -- frieren      # CLI flow: search → pick → play
zig build run -- "cowboy bebop" --dub
zig build test                # run tests
```

Requires Zig **0.16.0** and `mpv` on `PATH`. Cover art looks best in a terminal
with the Kitty graphics protocol (kitty, ghostty, WezTerm).

## Stack

- **TUI:** libvaxis (Kitty graphics + halfblock fallback)
- **Storage:** SQLite via raw C interop
- **Concurrency:** thread pool + channels
- **Source:** AllAnime, behind a swappable `SourceProvider` interface
- **Catalog:** AniList for metadata & cover art

The foundation was built as five isolated spikes (HTTP, SQLite/C-interop,
concurrency, the AllAnime resolver, mpv playback). **[SPIKES.md](SPIKES.md)** is
a guided, annotated tour through them — doubling as a Zig 0.16 crash course.
They're still runnable: `zig build spike-http -- frieren`, etc.

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
| **M5** | Playback polish: mpv IPC position ✅, checkpoints & exact resume ✅, AniSkip, full stream resolver & quality select | 🚧 in progress |
| **M6** | Config & settings: config file, settings tab, themes | planned |
| **M7** | Distribution & hardening: error/logging pass, cross-platform paths, release builds | planned |
| **M8** | Nice-to-haves: wide-terminal history layout & beyond | planned |

## Acknowledgements

- **[anipy-cli](https://github.com/sdaqo/anipy-cli)** by [sdaqo](https://github.com/sdaqo) (GPL-3.0) — showed us the way on AllAnime streaming when every other source had gone dark. The working recipe (POST instead of GET, Apollo persisted-query hashes, and the AES-256-GCM `tobeparsed` scheme) was learned by studying its `allanime_provider.py`. Zigoku reimplements the wire protocol in Zig from observed behavior — no code is copied — but the trail was theirs. Thank you. 🙏
- **[ani-nexus-tui](https://github.com/OsamuDazai666/ani-nexus-tui)** (CC BY-NC-SA 4.0) — studied for feature/UX inspiration.
- Catalog metadata & cover art from **[AniList](https://anilist.co/)**.

## License

[GPL-3.0](LICENSE). Our reference for the AllAnime protocol, anipy-cli, is
GPL-3.0; even though Zigoku reimplements the protocol rather than copying code,
GPL-3.0 keeps the lineage unambiguous — and it's a license we're happy to
carry anyway.
