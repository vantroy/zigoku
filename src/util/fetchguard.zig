//! SSRF guard for untrusted outbound fetches (ROD-266). Shared policy for every
//! provider-supplied URL. Pair with `redirect_behavior = .not_allowed` so a 3xx
//! cannot bounce past the guard.

const std = @import("std");
const Io = std.Io;

/// Only plain http(s); no userinfo (`https://allanime.day@evil/…`); refuse private/
/// loopback/link-local IP literals and `localhost`.
///
/// Validates the DECODED host (`getHost`/`toRaw`): the same bytes std.http resolves.
/// Raw-component checks miss `127%2e0%2e0%2e1` (percent-encode bypass).
///
/// Residual (ROD-172): public DNS whose A/AAAA is private (rebinding) is NOT caught;
/// std Io has no pre-connect resolve for resolve-then-validate-IP.
pub fn guardFetchUrl(url: []const u8) !void {
    const uri = std.Uri.parse(url) catch return error.BadFetchUrl;
    if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) return error.BadFetchUrl;
    if (uri.user != null or uri.password != null) return error.BadFetchUrl;
    var host_buf: [Io.net.HostName.max_len]u8 = undefined;
    const host = (uri.getHost(&host_buf) catch return error.BadFetchUrl).bytes;
    if (host.len == 0) return error.BadFetchUrl;
    if (std.ascii.eqlIgnoreCase(host, "localhost") or
        (host.len >= 10 and std.ascii.eqlIgnoreCase(host[host.len - 10 ..], ".localhost")))
        return error.BlockedHost;
    if (parseHostIp(host)) |ip| {
        if (isPrivateIp(ip)) return error.BlockedHost;
    } else {
        // Not a canonical IP. Reject alternate spellings a real host never uses
        // (one std getaddrinfo change away from becoming a bypass): any `:`, or
        // all-numeric / `0x` IPv4 (`2130706433`, `0x7f.0.0.1`, `127.1`).
        if (std.mem.indexOfScalar(u8, host, ':') != null) return error.BlockedHost;
        if (looksNumericHost(host)) return error.BlockedHost;
    }
}

/// Alternate (non-dotted-quad) IPv4 spelling. Only after `parseHostIp` rejected canonical.
fn looksNumericHost(host: []const u8) bool {
    if (host.len >= 2 and host[0] == '0' and (host[1] == 'x' or host[1] == 'X')) return true;
    var it = std.mem.splitScalar(u8, host, '.');
    var any_label = false;
    while (it.next()) |label| {
        if (label.len == 0) continue;
        any_label = true;
        for (label) |c| if (!std.ascii.isDigit(c)) return false;
    }
    return any_label;
}

fn parseHostIp(host: []const u8) ?Io.net.IpAddress {
    const h = if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host[1 .. host.len - 1] else host;
    return Io.net.IpAddress.parse(h, 0) catch null;
}

fn isPrivateIp(ip: Io.net.IpAddress) bool {
    return switch (ip) {
        .ip4 => |a| isPrivateV4(a.bytes),
        .ip6 => |a| isPrivateV6(a.bytes),
    };
}

fn isPrivateV4(b: [4]u8) bool {
    return switch (b[0]) {
        0, 10, 127 => true, // this-net, private, loopback
        100 => b[1] >= 64 and b[1] <= 127, // CGNAT 100.64/10
        169 => b[1] == 254, // link-local 169.254/16
        172 => b[1] >= 16 and b[1] <= 31, // private 172.16/12
        192 => b[1] == 168, // private 192.168/16
        else => b[0] >= 224, // multicast 224/4, reserved 240/4, broadcast
    };
}

fn isPrivateV6(b: [16]u8) bool {
    if (std.mem.allEqual(u8, b[0..15], 0)) return true; // :: and ::1
    if (b[0] == 0xfe and (b[1] & 0xc0) == 0x80) return true; // fe80::/10
    if ((b[0] & 0xfe) == 0xfc) return true; // ULA fc00::/7
    if (std.mem.allEqual(u8, b[0..10], 0) and b[10] == 0xff and b[11] == 0xff)
        return isPrivateV4(.{ b[12], b[13], b[14], b[15] }); // ::ffff:a.b.c.d
    return false;
}

test "isPrivateV4: private/loopback/link-local ranges blocked, public allowed" {
    try std.testing.expect(isPrivateV4(.{ 127, 0, 0, 1 }));
    try std.testing.expect(isPrivateV4(.{ 10, 1, 2, 3 }));
    try std.testing.expect(isPrivateV4(.{ 169, 254, 169, 254 })); // cloud metadata
    try std.testing.expect(isPrivateV4(.{ 172, 16, 0, 1 }));
    try std.testing.expect(isPrivateV4(.{ 192, 168, 1, 1 }));
    try std.testing.expect(isPrivateV4(.{ 100, 64, 0, 1 }));
    try std.testing.expect(!isPrivateV4(.{ 8, 8, 8, 8 }));
    try std.testing.expect(!isPrivateV4(.{ 172, 32, 0, 1 }));
    try std.testing.expect(!isPrivateV4(.{ 100, 128, 0, 1 }));
}

test "isPrivateV6: loopback/ULA/link-local/mapped blocked" {
    const loop = [_]u8{0} ** 15 ++ [_]u8{1};
    const unspec = [_]u8{0} ** 16;
    var fe80 = [_]u8{0} ** 16;
    fe80[0] = 0xfe;
    fe80[1] = 0x80;
    var ula = [_]u8{0} ** 16;
    ula[0] = 0xfd;
    const mapped = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127, 0, 0, 1 };
    var pub6 = [_]u8{0} ** 16;
    pub6[0] = 0x20;
    pub6[1] = 0x01; // 2001::
    try std.testing.expect(isPrivateV6(loop));
    try std.testing.expect(isPrivateV6(unspec));
    try std.testing.expect(isPrivateV6(fe80));
    try std.testing.expect(isPrivateV6(ula));
    try std.testing.expect(isPrivateV6(mapped));
    try std.testing.expect(!isPrivateV6(pub6));
}

test "guardFetchUrl: blocks SSRF vectors, allows public http(s)" {
    try std.testing.expectError(error.BadFetchUrl, guardFetchUrl("https://allanime.day@evil.example/x"));
    try std.testing.expectError(error.BadFetchUrl, guardFetchUrl("ftp://x/v.ts"));
    try std.testing.expectError(error.BlockedHost, guardFetchUrl("http://127.0.0.1/x"));
    try std.testing.expectError(error.BlockedHost, guardFetchUrl("http://169.254.169.254/latest/meta-data/"));
    try std.testing.expectError(error.BlockedHost, guardFetchUrl("http://localhost:8080/admin"));
    try std.testing.expectError(error.BlockedHost, guardFetchUrl("http://[::1]/x"));
    try std.testing.expectError(error.BlockedHost, guardFetchUrl("http://10.0.0.5/x"));
    try guardFetchUrl("https://cdn.real.example/v.m3u8");
    try guardFetchUrl("https://allanime.day/apivtwo/clock.json?id=x");
    try guardFetchUrl("http://8.8.8.8/x");
}

test "guardFetchUrl: percent-encoded host bypass blocked" {
    // DECODED host must match what std.http resolves.
    try std.testing.expectError(error.BlockedHost, guardFetchUrl("http://127%2e0%2e0%2e1/x"));
    try std.testing.expectError(error.BlockedHost, guardFetchUrl("http://%6c%6fcalhost:8080/x"));
}

test "guardFetchUrl: alternate IP encodings blocked (defense-in-depth)" {
    try std.testing.expectError(error.BlockedHost, guardFetchUrl("http://2130706433/x"));
    try std.testing.expectError(error.BlockedHost, guardFetchUrl("http://2852039166/latest"));
    try std.testing.expectError(error.BlockedHost, guardFetchUrl("http://0x7f000001/x"));
    try std.testing.expectError(error.BlockedHost, guardFetchUrl("http://0x7f.0.0.1/x"));
    try std.testing.expectError(error.BlockedHost, guardFetchUrl("http://127.1/x"));
    try std.testing.expectError(error.BlockedHost, guardFetchUrl("http://[::ffff:7f00:1]/x"));
}

test "isPrivateV4: multicast and broadcast blocked" {
    try std.testing.expect(isPrivateV4(.{ 224, 0, 0, 1 }));
    try std.testing.expect(isPrivateV4(.{ 255, 255, 255, 255 }));
    try std.testing.expect(!isPrivateV4(.{ 93, 184, 216, 34 }));
}
