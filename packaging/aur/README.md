# AUR package (ROD-146)

`zigoku/PKGBUILD` here is the **source of truth**. It's reviewed in-repo, then
copied to the AUR git repo (`ssh://aur@aur.archlinux.org/zigoku.git`) where users
reach it via `paru -S zigoku` / `yay -S zigoku`.

It's a **source build**, on purpose: the plain package name is conventionally the
from-source build (a prebuilt binary would be `zigoku-bin`). It compiles the
tagged release with the system Zig and links the system `libsqlite3` — only
runtime dep beyond that is `mpv` (playback shells out to it).

## Status: authored + tested locally, push pending

AUR new-account registration has been closed since mid-June 2026, so the package
can't be pushed to the registry yet. Everything else is done and verified:
`makepkg` builds a working `zigoku-<ver>-1-x86_64.pkg.tar.zst` from a clean
checkout, and the binary runs. When registration reopens, the only remaining step
is the push (see below) — an account + SSH-key operation.

Until then, Arch users can install straight from this directory:

```sh
cd packaging/aur/zigoku
makepkg -si          # builds + installs; pulls zig/git as makedepends
```

## Why the PKGBUILD looks like this — the clean-chroot dep story

`zig build` normally fetches the Zig deps (vaxis, zigimg, uucode) over the
network. AUR clean chroots have **no network in `build()`**, which is the #1
reason Zig AUR packages fail to build for other people. The fix here:

1. The three deps are listed as **git sources** pinned by commit. makepkg fetches
   them in its download phase (which *is* allowed network), not in `build()`.
2. `prepare()` remaps each checkout into a package dir named by that dep's **Zig
   content-hash** (`zig-pkg/<hash>/`).
3. `build()` runs `zig build --system "$srcdir/zig-pkg"`, which **hard-disables
   fetching** and resolves every dep from that dir.

Verified to build with an empty `ZIG_GLOBAL_CACHE_DIR` — no network, no global
cache, no surprises in a chroot. `sqlite` is not vendored: on Linux the build
links system `libsqlite3` (`bundle-sqlite` defaults off), so it's a runtime
`depends`, not a build input.

## Per-release bump

On a new tagged release, update `zigoku/PKGBUILD`:

> One-time, at the first release that carries the `build.zig` hardening: add
> `-Dpie` to the `zig build` line in `build()` (Arch's standard PIE hardening).
> The stb reproducibility fix is automatic — no flag.

1. Bump `pkgver`; reset `pkgrel=1`.
2. Refresh the source tarball checksum:
   ```sh
   cd packaging/aur/zigoku && updpkgsums          # rewrites the first sha256sums entry
   ```
   (The three `SKIP`s stay — git sources are pinned by commit, not checksum.)
3. **Only if a Zig dep changed** (fork bump, uucode/zigimg update): update both the
   `#commit=` pin in `source=()` **and** the matching `_*_hash` — they must move
   together. The hashes are the Zig content-hashes verbatim from the manifests:
   * `_vaxis_hash`, `_uucode_hash` → zigoku's `build.zig.zon`
   * `_zigimg_hash` → the vaxis fork's `build.zig.zon` (it's a transitive dep)
4. Regenerate `.SRCINFO` and re-test:
   ```sh
   makepkg --printsrcinfo > .SRCINFO
   makepkg -f            # clean build; then check the binary runs
   namcap PKGBUILD
   ```

## Publishing (when the AUR account is live)

```sh
git clone ssh://aur@aur.archlinux.org/zigoku.git aur-zigoku
cp zigoku/PKGBUILD zigoku/.SRCINFO aur-zigoku/
cd aur-zigoku && git commit -am "zigoku <ver>-1" && git push
```

`.SRCINFO` **must** be committed alongside `PKGBUILD` — the AUR rejects pushes
without it. Manual, and Rod's: the AUR account + SSH key + the actual push.

## Known namcap / makepkg warnings

Verified in a real clean chroot (`extra-x86_64-build`) as well as a plain
`makepkg`. Two are benign, one is handled here, one is fixed in `build.zig` (lands
at the next release, since the PKGBUILD builds the *released* tarball), and one is
kept on purpose:

| Warning | Verdict |
|---|---|
| `Dependency included, but may not be needed ('mpv')` | Expected — `mpv` is a runtime shell-out, invisible to namcap. Keep it. |
| `Unused shared library '.../ld-linux-x86-64.so.2'` | namcap noise for how Zig emits the interpreter entry. Ignore. |
| `Directory (usr/src/debug/zigoku) is empty` | Handled: `options=('!debug')` — nothing to split from an already-stripped binary. |
| `ELF file lacks PIE` | Fixed: `build.zig` gained a `-Dpie` option. Add `-Dpie` to `build()` from the release that includes it (see bump steps). |
| `Package contains reference to $srcdir` (`stb_image.h`) | **Kept, deliberately.** The path lives in stb's UBSan type descriptors; stripping it means disabling UBSan on an attacker-reachable image decoder (cover art is fetched over the network). Not worth trading a real mitigation for a cosmetic warning — this matches the release build's UBSan posture. `-ffile-prefix-map` only remaps part of it, so it isn't a clean fix either. |
