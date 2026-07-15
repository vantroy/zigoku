//! "Who is resolving what" for the App (ROD-401): tier-A/tier-C in-flight state and
//! the provider-fallback walk, grouped from seven App peer fields into one. Product
//! semantics (tier ordering, absence gates, fallback hop rules) stay in resolve.zig
//! as free functions taking `*App`; this is state only.

const workers = @import("workers.zig");
const app_mod = @import("app.zig");

pub const ResolveTransport = struct {
    // Tier-A add probe: one at a time so mashed P can't fan CDN requests (ROD-309/327).
    add_drain: workers.ThreadDrain = .{},
    add_resolving: bool = false,

    // Tier-C Play probe, independent of Add so both may be outstanding (ROD-328).
    // play_resolve_aid gates a late result against nav that already moved on (ROD-346).
    play_drain: workers.ThreadDrain = .{},
    play_resolving: bool = false,
    play_resolve_aid: ?i64 = null,

    /// Nulled at episode-fetch entry (ROD-327); armed for the probe about to succeed.
    pending_bind: ?i64 = null,

    /// Provider-fallback walk (ROD-346). Keep-check key is (for_source, for_id) at fire
    /// time, not live nav; hops park it out and reinstall across fireEpisodesForId.
    fallback: ?app_mod.App.Fallback = null,
};
