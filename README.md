# zigoku · 地獄

A terminal anime browser & player, built from scratch in [Zig](https://ziglang.org/).

> *Zig + jigoku ("hell").* A ground-up reimagining of the abandoned `ani-nexus-tui`,
> and a vehicle for learning Zig the hard (fun) way.

## Status

Early days — building in vertical slices. See the [Linear project](https://linear.app/vantroy/project/zigoku-地獄-2dff2e5d180c) for the roadmap.

- **M1** — CLI: search → pick → play one episode (in progress)
- **M2** — SQLite history & resume (via C interop)
- **M3** — TUI shell (libvaxis)
- **M4+** — cover art, AniSkip, settings, distribution

## Build

```sh
zig build run            # print banner
zig build run -- frieren # (search lands in M1)
zig build test           # run tests
```

Requires Zig **0.16.0**. Playback will require `mpv` on `PATH`.

The foundation was built as five isolated spikes (HTTP, SQLite/C-interop,
concurrency, the AllAnime resolver, mpv playback). **[SPIKES.md](SPIKES.md)** is
a guided, annotated tour through them — doubling as a Zig 0.16 crash course.

## Stack

- **TUI:** libvaxis (Kitty graphics)
- **Storage:** SQLite via raw C interop
- **Concurrency:** thread pool + channels
- **Source:** AllAnime, behind a swappable `SourceProvider` interface

## Acknowledgements

- **[anipy-cli](https://github.com/sdaqo/anipy-cli)** by [sdaqo](https://github.com/sdaqo) (GPL-3.0) — showed us the way on AllAnime streaming when every other source had gone dark. The working recipe (POST instead of GET, Apollo persisted-query hashes, and the AES-256-GCM `tobeparsed` scheme) was learned by studying its `allanime_provider.py`. Zigoku reimplements the wire protocol in Zig from observed behavior — no code is copied — but the trail was theirs. Thank you. 🙏
- **[ani-nexus-tui](https://github.com/OsamuDazai666/ani-nexus-tui)** (CC BY-NC-SA 4.0) — studied for feature/UX inspiration.
- Catalog metadata & cover art from **[AniList](https://anilist.co/)**.

## License

TBD. Note for whoever decides: our reference tool **anipy-cli is GPL-3.0**. We
reimplemented the AllAnime *protocol* (facts/interop, not copyrightable
expression) rather than copying code, so a permissive license is defensible —
but if you want zero ambiguity, GPL-3.0 is the conservative choice. Not legal
advice; make the call with eyes open.
