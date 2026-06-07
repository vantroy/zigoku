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

## Stack

- **TUI:** libvaxis (Kitty graphics)
- **Storage:** SQLite via raw C interop
- **Concurrency:** thread pool + channels
- **Source:** AllAnime, behind a swappable `SourceProvider` interface

## License

TBD.
