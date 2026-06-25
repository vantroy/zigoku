# Source-of-truth for the Homebrew formula (ROD-150).
#
# This file is reviewed here, then copied to the tap repo
# (github.com/vantroy/homebrew-zigoku) as Formula/zigoku.rb, where users reach
# it via `brew install vantroy/zigoku/zigoku`. The release workflow auto-bumps
# the tap copy on every tagged release.
#
# Binary formula: it downloads the prebuilt, sqlite-bundled release tarballs
# (ROD-216) per arch — no zig toolchain, no compile on the user's machine.
# See packaging/homebrew/README.md for the per-release bump steps.
#
# NOTE: no `version` stanza on purpose — Homebrew scans the version out of the
# URLs, and a redundant `version` line fails `brew audit --strict`. The bump
# step rewrites the version inside the URLs, not a separate stanza.
class Zigoku < Formula
  desc "Terminal anime browser & player"
  homepage "https://github.com/vantroy/zigoku"
  license "GPL-3.0-or-later"

  depends_on :macos             # binary formula; Linux uses the prebuilt tarball / source (AUR pkg planned, ROD-146)
  depends_on "mpv"              # runtime: playback shells out to it (src/player.zig)

  on_macos do
    on_arm do
      url "https://github.com/vantroy/zigoku/releases/download/v0.1.1/zigoku-v0.1.1-aarch64-macos.tar.gz"
      sha256 "ec9047d032351219ae36213edd833bcd3eaa35e60989e1923affb1f7d5ded1d6"
    end
    on_intel do
      url "https://github.com/vantroy/zigoku/releases/download/v0.1.1/zigoku-v0.1.1-x86_64-macos.tar.gz"
      sha256 "73f3d1ca85272df4923ef71815c971c1bc791f5dab52cde602f321b27c488411"
    end
  end

  def install
    # The tarball is zigoku-v{ver}-{target}/{zigoku,LICENSE,README.md}; brew
    # strips the single top-level dir, so the binary is at the staging root.
    bin.install "zigoku"
  end

  test do
    # `--version` prints the banner with the version string and exits 0
    # (same invocation the release workflow smoke-tests).
    assert_match version.to_s, shell_output("#{bin}/zigoku --version")
  end
end
