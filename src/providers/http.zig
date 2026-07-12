//! providers/http.zig: the one HTTP transport helper + ROD-173 error taxonomy the
//! allanime / senshi / megaplay providers share.
//!
//! Each provider makes the same shaped call: fetch a URL, buffer the body into an
//! arena, and split failures into four actionable classes so the caller can tell the
//! user whether to retry, wait, or reach for a VPN. The three copies (allanime.post,
//! senshi.request, megaplay.request) were kept in step by hand; this is the deferred
//! "stage 3" extraction their NOTE comments flagged (ROD-349).
//!
//! Diagnostics are ALWAYS-ON (`warn`, not gated behind `--debug`): the ROD-300 lesson
//! is that the next time a source shifts, zigoku.log must name it without a flag.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = @import("../log.zig");

/// Hard ceiling on a buffered response body (ROD-341). The provider payloads are
/// kilobytes (JSON metadata, m3u8 manifests, embed HTML); this bounds memory
/// against an adversarial-by-nature stream host (megaplay.buzz et al) that could
/// stream a response forever. The body writes into a fixed buffer, so an oversize
/// response overflows it and surfaces as a fetch failure; the provider is treated
/// as failed rather than trusted with an unbounded allocation.
pub const MAX_RESP_BYTES = 4 << 20; // 4 MiB

/// Which status codes count as success. AllAnime's GraphQL endpoint answers 200 on
/// success only; senshi and megaplay are REST-shaped and answer any 2xx (senshi's
/// write endpoints return 201). Kept a per-request choice so the extraction never
/// silently widens AllAnime's stricter contract.
pub const Accept = enum { ok_only, any_2xx };

pub const Request = struct {
    method: std.http.Method,
    url: []const u8,
    /// Non-null → sent as the request payload (the method still governs the verb).
    payload: ?[]const u8 = null,
    user_agent: []const u8,
    extra_headers: []const std.http.Header = &.{},
    /// Provider name for the always-on diagnostics.
    tag: []const u8,
    accept: Accept = .any_2xx,
    /// Untrusted-destination fetches set `.not_allowed` so a 3xx can't bounce a
    /// request past its caller's SSRF guard (ROD-266). Null keeps std's default
    /// (follow), correct for our own trusted endpoints.
    redirect_behavior: ?std.http.Client.Request.RedirectBehavior = null,
};

/// One request. Returns the response body (lives in `arena`). Failures split into the
/// ROD-173 classes: `NetworkDown` (our side), `Forbidden` (403/451, actively
/// blocked), `ServerError` (5xx, source down), `HttpNotOk` (any other non-success).
pub fn request(arena: Allocator, io: Io, req: Request) ![]u8 {
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();
    // A fixed buffer, not a growing Allocating writer: it caps the body at
    // MAX_RESP_BYTES, and an overflow fails the fetch instead of exhausting memory.
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
        // Log the raw error name here, at the single call site, so mapTransportError
        // stays a pure mapper (its unit test would otherwise spew warn lines).
        log.warn("{s} {s} {s}: transport {s}", .{ req.tag, @tagName(req.method), req.url, @errorName(e) });
        return mapTransportError(e);
    };
    const ok = switch (req.accept) {
        .ok_only => res.status == .ok,
        .any_2xx => res.status.class() == .success,
    };
    if (!ok) {
        // Keep the real status: the mapped class isn't enough; the caller only sees
        // the class, not the code. A non-success status is abnormal and is one of the
        // failure modes we need to see without --debug (ROD-300).
        log.warn("{s} {s} {s}: HTTP {d}", .{ req.tag, @tagName(req.method), req.url, @intFromEnum(res.status) });
        return statusToError(res.status);
    }
    return w.buffered();
}

/// Classify a non-success status (ROD-173): 403/451 mean we're being blocked; any 5xx
/// means the source itself is down; everything else stays the undifferentiated
/// `HttpNotOk` (an unexpected response, likely recipe/API drift).
pub fn statusToError(status: std.http.Status) error{ Forbidden, ServerError, HttpNotOk } {
    return switch (status) {
        .forbidden, .unavailable_for_legal_reasons => error.Forbidden,
        else => switch (status.class()) {
            .server_error => error.ServerError,
            else => error.HttpNotOk,
        },
    };
}

/// Map a transport-layer failure from `client.fetch` to `NetworkDown` when "check your
/// connection" is the right advice. Two distinct families in std.Io's `FetchError`
/// qualify (they are NOT aliases of each other):
///   * IP-level connect failures: refused / reset / host+network unreachable / timeout.
///   * DNS `HostName.LookupError`: NXDOMAIN, SERVFAIL, malformed records, no address,
///     unreadable resolv.conf. These are their own error values, so they must be listed
///     explicitly (an earlier draft wrongly assumed they aliased the connect errors).
/// `TlsInitializationFailed` is included: against our Cloudflare-fronted upstreams it is
/// overwhelmingly a reset/intercepted handshake, though it also absorbs the rare
/// server-side cert-validation failure (an accepted imprecision). Everything else (OOM,
/// protocol, local socket misconfig, an oversize-body `WriteFailed`) propagates
/// unchanged so we never mislabel it.
pub fn mapTransportError(e: anyerror) anyerror {
    return switch (e) {
        // IP-level connect failures.
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.HostUnreachable,
        error.NetworkUnreachable,
        error.NetworkDown,
        error.Timeout,
        error.TlsInitializationFailed,
        // DNS resolution failures (HostName.LookupError).
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
    // 403 and 451 are "they're blocking us", collapse to Forbidden.
    try std.testing.expectEqual(error.Forbidden, statusToError(.forbidden));
    try std.testing.expectEqual(error.Forbidden, statusToError(.unavailable_for_legal_reasons));
    // Every 5xx is "the source is down": ServerError, by class not by value, so
    // an unnamed 5xx still lands here.
    try std.testing.expectEqual(error.ServerError, statusToError(.internal_server_error));
    try std.testing.expectEqual(error.ServerError, statusToError(.bad_gateway));
    try std.testing.expectEqual(error.ServerError, statusToError(.service_unavailable));
    try std.testing.expectEqual(error.ServerError, statusToError(.gateway_timeout));
    // An unnamed 5xx (Status is non-exhaustive) must still classify by range, not
    // by tag, so a code we don't have a name for still reads as ServerError.
    try std.testing.expectEqual(error.ServerError, statusToError(@enumFromInt(599)));
    // Any other non-200 stays the undifferentiated HttpNotOk (recipe drift, 429…).
    try std.testing.expectEqual(error.HttpNotOk, statusToError(.not_found));
    try std.testing.expectEqual(error.HttpNotOk, statusToError(.bad_request));
    try std.testing.expectEqual(error.HttpNotOk, statusToError(.too_many_requests));
}

test "mapTransportError: connectivity failures become NetworkDown, rest pass through (ROD-173)" {
    // Genuine connectivity problems on our side → NetworkDown.
    try std.testing.expectEqual(error.NetworkDown, mapTransportError(error.ConnectionRefused));
    try std.testing.expectEqual(error.NetworkDown, mapTransportError(error.ConnectionResetByPeer));
    try std.testing.expectEqual(error.NetworkDown, mapTransportError(error.HostUnreachable));
    try std.testing.expectEqual(error.NetworkDown, mapTransportError(error.NetworkUnreachable));
    try std.testing.expectEqual(error.NetworkDown, mapTransportError(error.NetworkDown));
    try std.testing.expectEqual(error.NetworkDown, mapTransportError(error.Timeout));
    try std.testing.expectEqual(error.NetworkDown, mapTransportError(error.TlsInitializationFailed));
    // DNS resolution failures (HostName.LookupError) are their own error values,
    // not aliases of the connect errors; they must land on NetworkDown too so
    // "name didn't resolve" reads as a connectivity problem, per the ticket.
    try std.testing.expectEqual(error.NetworkDown, mapTransportError(error.UnknownHostName));
    try std.testing.expectEqual(error.NetworkDown, mapTransportError(error.NameServerFailure));
    try std.testing.expectEqual(error.NetworkDown, mapTransportError(error.NoAddressReturned));
    try std.testing.expectEqual(error.NetworkDown, mapTransportError(error.ResolvConfParseFailed));
    // Anything that isn't a transport failure must not be mislabelled as a dead
    // network; it propagates unchanged.
    try std.testing.expectEqual(error.OutOfMemory, mapTransportError(error.OutOfMemory));
    try std.testing.expectEqual(error.WriteFailed, mapTransportError(error.WriteFailed));
}
