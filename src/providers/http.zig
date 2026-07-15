//! Shared HTTP transport + ROD-173 error taxonomy for allanime / senshi / megaplay.
//!
//! Always-on diagnostics (`warn`, not `--debug`): ROD-300, source shift must show in
//! zigoku.log without a flag.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = @import("../log.zig");

/// Response body ceiling (ROD-341). Fixed buffer: oversize fails the fetch, no unbounded alloc.
pub const MAX_RESP_BYTES = 4 << 20; // 4 MiB

/// Success policy: AllAnime wants 200 only; REST providers accept any 2xx.
pub const Accept = enum { ok_only, any_2xx };

pub const Request = struct {
    method: std.http.Method,
    url: []const u8,
    payload: ?[]const u8 = null,
    user_agent: []const u8,
    extra_headers: []const std.http.Header = &.{},
    /// Provider name for always-on diagnostics.
    tag: []const u8,
    accept: Accept = .any_2xx,
    /// Untrusted destinations: `.not_allowed` so 3xx cannot bounce past SSRF (ROD-266).
    redirect_behavior: ?std.http.Client.Request.RedirectBehavior = null,
};

/// Returns body in `arena`. Failures: NetworkDown / Forbidden / ServerError / HttpNotOk (ROD-173).
pub fn request(arena: Allocator, io: Io, req: Request) ![]u8 {
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();
    const buf = try arena.alloc(u8, MAX_RESP_BYTES);
    var w = std.Io.Writer.fixed(buf);
    const res = client.fetch(.{
        .location = .{ .url = req.url },
        .method = req.method,
        .payload = req.payload,
        .response_writer = &w,
        .headers = .{ .user_agent = .{ .override = req.user_agent } },
        .extra_headers = req.extra_headers,
        .redirect_behavior = req.redirect_behavior,
    }) catch |e| {
        // Log here so mapTransportError stays pure (unit tests don't spew).
        log.warn("{s} {s} {s}: transport {s}", .{ req.tag, @tagName(req.method), req.url, @errorName(e) });
        return mapTransportError(e);
    };
    const ok = switch (req.accept) {
        .ok_only => res.status == .ok,
        .any_2xx => res.status.class() == .success,
    };
    if (!ok) {
        // Keep the real status: callers only see the mapped error class. Always-on,
        // not --debug-gated, per the ROD-300 always-visible-failure guarantee.
        log.warn("{s} {s} {s}: HTTP {d}", .{ req.tag, @tagName(req.method), req.url, @intFromEnum(res.status) });
        return statusToError(res.status);
    }
    return w.buffered();
}

/// 403/451 → Forbidden; 5xx → ServerError; else HttpNotOk (ROD-173).
pub fn statusToError(status: std.http.Status) error{ Forbidden, ServerError, HttpNotOk } {
    return switch (status) {
        .forbidden, .unavailable_for_legal_reasons => error.Forbidden,
        else => switch (status.class()) {
            .server_error => error.ServerError,
            else => error.HttpNotOk,
        },
    };
}

/// Map transport failure to NetworkDown when "check your connection" is right.
/// Connect failures and DNS LookupError are separate error families (not aliases);
/// both must be listed. TlsInitializationFailed included (CF reset/intercepted handshake).
/// Everything else propagates unchanged.
pub fn mapTransportError(e: anyerror) anyerror {
    return switch (e) {
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.HostUnreachable,
        error.NetworkUnreachable,
        error.NetworkDown,
        error.Timeout,
        error.TlsInitializationFailed,
        error.UnknownHostName,
        error.NameServerFailure,
        error.NoAddressReturned,
        error.ResolvConfParseFailed,
        error.DetectingNetworkConfigurationFailed,
        error.InvalidDnsARecord,
        error.InvalidDnsAAAARecord,
        error.InvalidDnsCnameRecord,
        => error.NetworkDown,
        else => e,
    };
}

test "statusToError: blocked / server-down / other split distinctly (ROD-173)" {
    try std.testing.expectEqual(error.Forbidden, statusToError(.forbidden));
    try std.testing.expectEqual(error.Forbidden, statusToError(.unavailable_for_legal_reasons));
    try std.testing.expectEqual(error.ServerError, statusToError(.internal_server_error));
    try std.testing.expectEqual(error.ServerError, statusToError(.bad_gateway));
    try std.testing.expectEqual(error.ServerError, statusToError(.service_unavailable));
    try std.testing.expectEqual(error.ServerError, statusToError(.gateway_timeout));
    // Non-exhaustive Status: unnamed 5xx still classifies by range.
    try std.testing.expectEqual(error.ServerError, statusToError(@enumFromInt(599)));
    try std.testing.expectEqual(error.HttpNotOk, statusToError(.not_found));
    try std.testing.expectEqual(error.HttpNotOk, statusToError(.bad_request));
    try std.testing.expectEqual(error.HttpNotOk, statusToError(.too_many_requests));
}

test "mapTransportError: connectivity failures become NetworkDown, rest pass through (ROD-173)" {
    try std.testing.expectEqual(error.NetworkDown, mapTransportError(error.ConnectionRefused));
    try std.testing.expectEqual(error.NetworkDown, mapTransportError(error.ConnectionResetByPeer));
    try std.testing.expectEqual(error.NetworkDown, mapTransportError(error.HostUnreachable));
    try std.testing.expectEqual(error.NetworkDown, mapTransportError(error.NetworkUnreachable));
    try std.testing.expectEqual(error.NetworkDown, mapTransportError(error.NetworkDown));
    try std.testing.expectEqual(error.NetworkDown, mapTransportError(error.Timeout));
    try std.testing.expectEqual(error.NetworkDown, mapTransportError(error.TlsInitializationFailed));
    try std.testing.expectEqual(error.NetworkDown, mapTransportError(error.UnknownHostName));
    try std.testing.expectEqual(error.NetworkDown, mapTransportError(error.NameServerFailure));
    try std.testing.expectEqual(error.NetworkDown, mapTransportError(error.NoAddressReturned));
    try std.testing.expectEqual(error.NetworkDown, mapTransportError(error.ResolvConfParseFailed));
    try std.testing.expectEqual(error.OutOfMemory, mapTransportError(error.OutOfMemory));
    try std.testing.expectEqual(error.WriteFailed, mapTransportError(error.WriteFailed));
}
