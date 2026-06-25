# Homebrew tap (ROD-150)

`zigoku.rb` here is the **source of truth**. The live tap is a separate public
repo, `github.com/vantroy/homebrew-zigoku`, holding a copy at `Formula/zigoku.rb`.
Users install via the fully-qualified name (no explicit `brew tap` needed):

```sh
brew install vantroy/zigoku/zigoku
```

It's a **binary formula**: it downloads the prebuilt, sqlite-bundled macOS
release tarballs (ROD-216) per arch. No zig toolchain, no compile on the user's
machine, and — because SQLite is compiled in (ROD-212) — no `sqlite` dependency.
Only runtime dep is `mpv` (playback shells out to it).

## Per-release bump

Every release pins `version` + two `url`/`sha256` pairs, so each one needs an update:

1. Read the new checksums from the release:
   ```sh
   curl -fsSL https://github.com/vantroy/zigoku/releases/download/vX.Y.Z/sha256sums.txt | grep macos
   ```
2. In `zigoku.rb`: bump `version` and replace both `sha256` lines (arm64 = `aarch64-macos`, intel = `x86_64-macos`).
3. Validate on macOS hardware:
   ```sh
   brew install ./zigoku.rb        # installs the correct-arch binary
   brew test zigoku                # --version banner check
   brew audit --strict zigoku      # clean lint
   ```
4. Copy to the tap repo and push:
   ```sh
   cp zigoku.rb ../homebrew-zigoku/Formula/zigoku.rb
   ```

> **Automated:** `release.yml`'s `update-tap` job runs steps 1–2 on every tagged
> release — it reads `sha256sums.txt`, bumps `version` + both `sha256`s in the tap's
> `Formula/zigoku.rb`, and pushes via a write-scoped deploy key. Hand-bumping here is
> only for out-of-band fixes; keep this file and the tap copy in sync.

## Signing note

The release workflow ad-hoc signs both mac binaries (`codesign --force --sign -`)
and gates on `codesign --verify` — but that lands from the **next** release on.
**v0.1.1's `x86_64-macos` binary is unsigned** (Zig's linker only signs the native
arm64 build). This formula ships it anyway, by decision (ROD-150): it still runs
(verified under Rosetta) and brew strips quarantine on install. From the first
release built after the signing gate, refresh the Intel `sha256` to the signed
artifact — then `codesign --verify` passes for both arches.
