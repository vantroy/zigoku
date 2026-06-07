//! ROD-58 spike — concurrency model: thread pool + channel.
//!
//! Zig 0.16 has no async runtime, so the TUI will offload blocking work (network
//! fetches, image decode) to worker threads that post results back to the UI
//! thread through a channel. This proves that exact shape:
//!   - a generic thread-safe Channel(T) (mutex + condvar + FIFO)
//!   - N worker threads each running a REAL concurrent AniList search
//!   - the main thread draining results as they arrive (out of order)
//!
//! Run: `zig build spike-concurrency`

const std = @import("std");

// ── Channel(T): a thread-safe blocking FIFO ───────────────────────────────────

// In Zig 0.16, blocking sync primitives live under std.Io and take `io` on every
// op (futex-based, scheduler-aware). The channel stores the shared io so callers
// don't have to thread it through. We use the *Uncancelable variants — this spike
// has no cancellation points.
fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        io: std.Io,
        mutex: std.Io.Mutex = .init,
        not_empty: std.Io.Condition = .init,
        queue: std.ArrayList(T) = .empty,
        closed: bool = false,

        fn init(gpa: std.mem.Allocator, io: std.Io) Self {
            return .{ .gpa = gpa, .io = io };
        }

        fn deinit(self: *Self) void {
            self.queue.deinit(self.gpa);
        }

        /// Producer side. Appends and wakes one waiter.
        fn send(self: *Self, item: T) !void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try self.queue.append(self.gpa, item);
            self.not_empty.signal(self.io);
        }

        /// Consumer side. Blocks until an item is available, or returns null once
        /// the channel is closed AND drained.
        fn recv(self: *Self) ?T {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            while (self.queue.items.len == 0 and !self.closed) {
                self.not_empty.waitUncancelable(self.io, &self.mutex);
            }
            if (self.queue.items.len == 0) return null; // closed + empty
            return self.queue.orderedRemove(0);
        }

        fn close(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.closed = true;
            self.not_empty.broadcast(self.io);
        }
    };
}

// ── AniList search (minimal, reused shape from the http spike) ─────────────────

const ENDPOINT = "https://graphql.anilist.co";
const GQL = "query($search:String){Page(perPage:1){media(search:$search,type:ANIME,sort:SEARCH_MATCH){title{romaji english} episodes} pageInfo{total}}}";

const Title = struct { romaji: ?[]const u8 = null, english: ?[]const u8 = null };
const Media = struct { title: Title = .{}, episodes: ?u32 = null };
const PageInfo = struct { total: ?u32 = null };
const Page = struct { media: []Media, pageInfo: PageInfo = .{} };
const Data = struct { Page: Page };
const Resp = struct { data: ?Data = null };

const SearchOut = struct { total: u32, top: []const u8, eps: u32 };

fn searchAniList(io: std.Io, arena: std.mem.Allocator, query: []const u8) !SearchOut {
    const body = try std.fmt.allocPrint(
        arena,
        "{{\"query\":\"{s}\",\"variables\":{{\"search\":\"{s}\"}}}}",
        .{ GQL, query },
    );

    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    var aw = std.Io.Writer.Allocating.init(arena);
    _ = try client.fetch(.{
        .location = .{ .url = ENDPOINT },
        .method = .POST,
        .payload = body,
        .response_writer = &aw.writer,
        .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
    });

    const parsed = try std.json.parseFromSlice(Resp, arena, aw.writer.buffered(), .{
        .ignore_unknown_fields = true,
    });
    const data = parsed.value.data orelse return error.NoData;
    const top = if (data.Page.media.len > 0)
        (data.Page.media[0].title.english orelse data.Page.media[0].title.romaji orelse "?")
    else
        "(no results)";
    const eps = if (data.Page.media.len > 0) (data.Page.media[0].episodes orelse 0) else 0;
    return .{ .total = data.Page.pageInfo.total orelse 0, .top = top, .eps = eps };
}

// ── Worker ────────────────────────────────────────────────────────────────────

const Msg = struct {
    id: u32,
    query: []const u8,
    ok: bool,
    err: []const u8 = "",
    total: u32 = 0,
    eps: u32 = 0,
    top: []const u8 = "", // page-allocated when ok (outlives the worker arena)
};

const Job = struct {
    chan: *Channel(Msg),
    io: std.Io,
    query: []const u8,
    id: u32,
};

fn worker(job: Job) void {
    // Each worker owns a private arena for fetch/parse scratch. Thread-safe page
    // allocator backs it, and we dupe the one string we hand back to main.
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (searchAniList(job.io, arena, job.query)) |out| {
        const top = std.heap.page_allocator.dupe(u8, out.top) catch out.top;
        job.chan.send(.{
            .id = job.id,
            .query = job.query,
            .ok = true,
            .total = out.total,
            .eps = out.eps,
            .top = top,
        }) catch {};
    } else |err| {
        job.chan.send(.{
            .id = job.id,
            .query = job.query,
            .ok = false,
            .err = @errorName(err),
        }) catch {};
    }
}

// ── main ──────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const shared = std.heap.page_allocator;

    var chan = Channel(Msg).init(shared, io);
    defer chan.deinit();

    const queries = [_][]const u8{ "frieren", "one piece", "spy x family", "bocchi the rock", "vinland saga" };

    std.debug.print("→ spawning {d} workers, each running a concurrent AniList search\n\n", .{queries.len});

    var threads: [queries.len]std.Thread = undefined;
    for (queries, 0..) |q, i| {
        threads[i] = try std.Thread.spawn(.{}, worker, .{Job{
            .chan = &chan,
            .io = io,
            .query = q,
            .id = @intCast(i),
        }});
    }

    // Drain results as they land — order reflects which fetch finished first,
    // not spawn order. This is the UI thread's update loop in miniature.
    var received: usize = 0;
    while (received < queries.len) : (received += 1) {
        const msg = chan.recv() orelse break;
        if (msg.ok) {
            std.debug.print("  [{d}/{d}] worker {d} \"{s}\" → {s}  ({d} eps, {d} total matches)\n", .{
                received + 1, queries.len, msg.id, msg.query, msg.top, msg.eps, msg.total,
            });
            if (msg.top.len > 0) shared.free(msg.top);
        } else {
            std.debug.print("  [{d}/{d}] worker {d} \"{s}\" ✗ {s}\n", .{
                received + 1, queries.len, msg.id, msg.query, msg.err,
            });
        }
    }

    for (&threads) |*t| t.join();
    std.debug.print("\n✓ threads + channel works — concurrent fetches drained on the main thread.\n", .{});
}
