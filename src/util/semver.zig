//! Version comparison for the update check (ROD-370). We compare our built-in
//! `zigoku.version` against the tag GitHub reports for the latest release, and a
//! plain string compare gets `0.10.0` < `0.9.0` wrong. This parses the
//! `major.minor.patch` core numerically and orders on that.
//!
//! Prerelease handling is coarse on purpose: a `-suffix` (e.g. `0.5.0-dev`) makes
//! a version rank BELOW the same core without one, per semver, but we don't order
//! two prereleases against each other by identifier; the nag logic never needs
//! it. Build metadata (`+sha`) is ignored entirely.

const std = @import("std");

pub const Error = error{InvalidVersion};

/// A parsed `major.minor.patch` with a flag for whether a `-prerelease` tail was
/// present. `prerelease` carries only presence, not the identifier, matching this
/// module's coarse ordering.
pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    prerelease: bool,

    /// Parse `[v]MAJOR.MINOR.PATCH[-prerelease][+build]`. Accepts an optional
    /// leading `v` (GitHub tags carry it; our `zigoku.version` doesn't). Rejects
    /// anything without three numeric core segments so a garbage remote tag can't
    /// masquerade as a version; the caller treats a parse error as "no update".
    pub fn parse(text: []const u8) Error!Version {
        var s = text;
        if (s.len > 0 and (s[0] == 'v' or s[0] == 'V')) s = s[1..];

        // Split the core off any prerelease (`-`) or build-metadata (`+`) tail.
        // A `-` before a `+` starts the prerelease; a leading `+` is build only.
        var core = s;
        var prerelease = false;
        if (std.mem.indexOfScalar(u8, s, '-')) |i| {
            core = s[0..i];
            // A prerelease segment with actual content, not a bare trailing '-'.
            prerelease = i + 1 < s.len and s[i + 1] != '+';
        } else if (std.mem.indexOfScalar(u8, s, '+')) |i| {
            core = s[0..i];
        }

        var it = std.mem.splitScalar(u8, core, '.');
        const major = try parseField(it.next());
        const minor = try parseField(it.next());
        const patch = try parseField(it.next());
        if (it.next() != null) return Error.InvalidVersion; // a 4th segment isn't a version we cut

        return .{ .major = major, .minor = minor, .patch = patch, .prerelease = prerelease };
    }

    fn parseField(seg: ?[]const u8) Error!u32 {
        const field = seg orelse return Error.InvalidVersion;
        if (field.len == 0) return Error.InvalidVersion;
        return std.fmt.parseInt(u32, field, 10) catch Error.InvalidVersion;
    }

    /// Order `self` against `other`: core numerically, then a version WITH a
    /// prerelease ranks below the same core WITHOUT one (`0.4.1-dev` < `0.4.1`).
    pub fn order(self: Version, other: Version) std.math.Order {
        return switch (std.math.order(self.major, other.major)) {
            .eq => switch (std.math.order(self.minor, other.minor)) {
                .eq => switch (std.math.order(self.patch, other.patch)) {
                    .eq => orderPrerelease(self.prerelease, other.prerelease),
                    else => |o| o,
                },
                else => |o| o,
            },
            else => |o| o,
        };
    }

    fn orderPrerelease(self_pre: bool, other_pre: bool) std.math.Order {
        if (self_pre == other_pre) return .eq;
        // A prerelease is LESS than a release with the same core.
        return if (self_pre) .lt else .gt;
    }
};

/// True when `latest` is strictly newer than `current`: the one question the
/// update check asks. A parse failure on either side yields `false`: we never
/// nag on a version we couldn't read (a malformed remote tag stays silent).
pub fn isNewer(latest: []const u8, current: []const u8) bool {
    const l = Version.parse(latest) catch return false;
    const c = Version.parse(current) catch return false;
    return l.order(c) == .gt;
}

test "parse accepts optional v prefix and plain core" {
    const a = try Version.parse("0.4.1");
    try std.testing.expectEqual(@as(u32, 0), a.major);
    try std.testing.expectEqual(@as(u32, 4), a.minor);
    try std.testing.expectEqual(@as(u32, 1), a.patch);
    try std.testing.expect(!a.prerelease);

    const b = try Version.parse("v0.4.1");
    try std.testing.expectEqual(std.math.Order.eq, a.order(b));
}

test "parse rejects garbage and wrong-arity cores" {
    try std.testing.expectError(Error.InvalidVersion, Version.parse(""));
    try std.testing.expectError(Error.InvalidVersion, Version.parse("v"));
    try std.testing.expectError(Error.InvalidVersion, Version.parse("0.4"));
    try std.testing.expectError(Error.InvalidVersion, Version.parse("0.4.1.2"));
    try std.testing.expectError(Error.InvalidVersion, Version.parse("0.x.1"));
    try std.testing.expectError(Error.InvalidVersion, Version.parse("latest"));
    try std.testing.expectError(Error.InvalidVersion, Version.parse("0..1"));
}

test "order compares fields numerically, not lexically" {
    const lo = try Version.parse("0.9.0");
    const hi = try Version.parse("0.10.0");
    // The bug a string compare would introduce: "0.10.0" < "0.9.0" lexically.
    try std.testing.expectEqual(std.math.Order.lt, lo.order(hi));
    try std.testing.expectEqual(std.math.Order.gt, hi.order(lo));
}

test "order ranks a prerelease below the same released core" {
    const dev = try Version.parse("0.4.1-dev");
    const rel = try Version.parse("0.4.1");
    try std.testing.expectEqual(std.math.Order.lt, dev.order(rel));
    try std.testing.expectEqual(std.math.Order.gt, rel.order(dev));
}

test "build metadata is ignored, not treated as prerelease" {
    const a = try Version.parse("0.4.1+abc123");
    try std.testing.expect(!a.prerelease);
    const b = try Version.parse("0.4.1");
    try std.testing.expectEqual(std.math.Order.eq, a.order(b));
}

test "isNewer: the update-check question" {
    // Remote ahead → update available.
    try std.testing.expect(isNewer("0.5.0", "0.4.1"));
    try std.testing.expect(isNewer("0.10.0", "0.9.9"));
    // Equal or behind → no nag.
    try std.testing.expect(!isNewer("0.4.1", "0.4.1"));
    try std.testing.expect(!isNewer("0.4.0", "0.4.1"));
    // Local dev build ahead of the last release must never nag.
    try std.testing.expect(!isNewer("0.4.1", "0.5.0-dev"));
    // A malformed remote tag stays silent rather than nagging.
    try std.testing.expect(!isNewer("garbage", "0.4.1"));
    try std.testing.expect(!isNewer("", "0.4.1"));
}
