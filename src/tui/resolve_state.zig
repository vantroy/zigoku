//! "Who is resolving what" for the App (ROD-401): tier-A/tier-C in-flight state and
//! the provider-fallback walk, grouped from seven App peer fields into one. Product
//! semantics (tier ordering, absence gates, fallback hop rules) stay in resolve.zig
//! as free functions taking `*App`; this is state only.

const workers = @import("workers.zig");
const app_mod = @import("app.zig");

pub const ResolveTransport = struct {
    /// Tier-A add-to-watchlist resolve probes (ROD-327).
    add_drain: workers.ThreadDrain = .{},
    /// One Add probe at a time: mashed P must not fan CDN requests (ROD-309/327).
    add_resolving: bool = false,
    /// Tier-C Play resolve searches; separate from Add so both may be outstanding (ROD-328).
    play_drain: workers.ThreadDrain = .{},
    /// One Play tier-C search at a time (ROD-309/328).
    play_resolving: bool = false,
    /// Aid the in-flight Play search was fired for; late result dropped if nav moved (ROD-346).
    play_resolve_aid: ?i64 = null,
    /// Canonical id to bind once the current Browse episode probe succeeds (ROD-327).
    /// fireEpisodesForId nulls at entry so History/Discover cannot inherit a stale bind.
    pending_bind: ?i64 = null,
    /// Provider-fallback walk, or null (ROD-346). Built at first fetch failure, never at
    /// fire time: (for_source, for_id) is the keep-check key, live nav is not. Walk hops
    /// take it out before re-entering fireEpisodesForId (which clears it) and put it back.
    fallback: ?app_mod.App.Fallback = null,
};
