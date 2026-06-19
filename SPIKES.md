# Zigoku Spikes — a guided tour (and a Zig 0.16 crash course)

These five throwaway programs in `src/spikes/` exist to prove the project's
riskiest unknowns *in isolation* — but they double as the best Zig tutorial in
this repo, because each one is a single idea with no framework around it. Read
them in the order below and you'll have touched almost every part of the
language Zigoku needs.

Every spike is its own `build.zig` step and its own `main`. None are installed;
none are imported by the real app. When M1 starts, the *ideas* here get promoted
into real modules behind clean interfaces — the spikes stay as reference.

```
zig build spike-http        -- frieren           # ROD-55  HTTP + JSON
zig build spike-sqlite                           # ROD-56  SQLite via C interop
zig build spike-concurrency                      # ROD-58  threads + channel
zig build spike-stream      -- frieren           # ROD-62  POST + AES-GCM resolver
zig build spike-mpv         -- frieren           # ROD-57  full pipeline → mpv
```

> **The one piece of context that explains 90% of the weird:** Zig 0.16 is
> mid-rewrite of its I/O story ("writergate" + the `Io` interface). Blocking
> operations — file I/O, time, sockets, mutexes — now take an `Io` value that
> represents *how* to block (thread, evented, etc.). You get one `io` from
> `main`'s `std.process.Init` parameter and thread it everywhere. Most stale
> tutorials you'll find online predate this and won't compile. When in doubt,
> the `zig init` output and the std source under `/usr/lib/zig/std` are ground
> truth — not blog posts.

---

## Zig-in-five-minutes (the idioms you'll see in every spike)

| Idiom | What it means |
|---|---|
| `const x = ...;` / `var x = ...;` | `const` is immutable. Unused locals are a **compile error** (a feature). |
| `!T` | An error union: "a `T` or an error." `fn f() !T`. |
| `try expr` | If `expr` is an error, return it; else unwrap. The everyday error path. |
| `expr catch \|err\| {...}` | Handle the error inline instead of propagating. |
| `?T` | An optional: "a `T` or `null`." |
| `x orelse default` | Unwrap an optional, or use `default` if null. |
| `if (opt) \|v\| {...}` | Unwrap an optional into `v` only if non-null. |
| `[]const u8` | A slice = `{ ptr, len }`. This *is* Zig's string. No null terminator. |
| `defer stmt;` | Run `stmt` when the current scope exits. Cleanup lives next to acquisition. |
| `std.mem.Allocator` | Allocation is **explicit and injected** — functions take the allocator they use. |
| `comptime` | Code that runs at compile time. String concat with `++`, format strings, generics. |
| `fn Foo(comptime T: type) type` | Generics are just functions returning types. See `Channel(T)`. |

The single most important cultural point: **there is no hidden allocation and no
hidden control flow.** If memory is allocated, an allocator was passed. If an
error can happen, it's in the type. This is why the code is verbose and why it's
easy to reason about. Lean into it.

---

## 1. `http_search.zig` — HTTP, JSON, and the new writer (start here)

**Proves:** Zig's stdlib can do an HTTPS POST (TLS + system CA bundle), send a
JSON body with custom headers, and parse the response into typed structs. This
was the original go/no-go: if the network layer didn't work, nothing else
mattered. It hits **AniList** (our catalog source).

**Run:** `zig build spike-http -- frieren`

**Concepts:** allocators, error unions, `std.http.Client`, `std.json`, the
0.16 `Io.Writer`.

**Walkthrough:**

- `pub fn main(init: std.process.Init) !void` — the 0.16 main signature. `init`
  hands you three things this spike uses: `init.arena` (an arena allocator that
  lives as long as the process — perfect for "allocate freely, never free"),
  `init.io` (the I/O handle), and `init.minimal.args`.
- **The output writer dance:**
  ```zig
  var out_buf: [4096]u8 = undefined;
  var out_fw: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
  const out = &out_fw.interface;
  ```
  You provide the buffer; the writer is a thin layer over the fd; you write to
  its `.interface` and **must `flush()`** at the end. This is writergate: I/O is
  explicit buffering now, not magic.
- **The fetch:**
  ```zig
  var client: std.http.Client = .{ .allocator = arena, .io = io };
  var aw = std.Io.Writer.Allocating.init(arena);
  _ = try client.fetch(.{ .location = .{ .url = ENDPOINT }, .method = .POST,
      .payload = body, .response_writer = &aw.writer, .extra_headers = &.{...} });
  const json = aw.writer.buffered();
  ```
  `Writer.Allocating` is a growable in-memory writer; `fetch` streams the
  response body into it, and `.buffered()` hands you the bytes. The slice points
  into `arena` memory, so it stays valid after the call.
- **Typed JSON:** the `Media`/`Title`/`Page` structs mirror the JSON shape.
  `std.json.parseFromSlice(Resp, arena, json, .{ .ignore_unknown_fields = true })`
  matches struct fields to JSON keys *by name*. Optional fields with defaults
  (`?u32 = null`) make missing keys harmless. `ignore_unknown_fields` lets the
  server send 50 fields we don't care about.

**Try this:**
- Add `genres: [][]const u8 = &.{}` to `Media` and print the first genre. (JSON
  arrays → Zig slices.)
- Delete the `flush()` call and watch the output vanish — proof that buffering
  is now your job.
- Point `ENDPOINT` at `http://` (no TLS) and read the error. The CA-bundle path
  only runs for `https`.

---

## 2. `sqlite_store.zig` — C interop, the Zig superpower

**Proves:** Zig links a C library (`libsqlite3`) with zero glue code and drives
it directly. This is *the* reason to use Zig for a project like this. The schema
is **ours** — AniList-keyed, watchlist semantics, real migrations.

**Run:** `zig build spike-sqlite`

**Concepts:** `@cImport`, system-library linking, the C↔Zig type boundary,
prepared statements, `PRAGMA user_version` migrations.

**Walkthrough:**

- **The import is the whole trick:**
  ```zig
  const c = @cImport({
      @cInclude("sqlite3.h");
      @cInclude("time.h");
  });
  ```
  Zig parses the C headers at compile time and gives you `c.sqlite3_open_v2`,
  `c.SQLITE_OK`, `c.time`, etc. as if they were Zig. The linking lives in
  `build.zig`:
  ```zig
  .link_libc = true,                       // in createModule
  mod.linkSystemLibrary("sqlite3", .{});   // on the module, not the exe
  ```
- **The C boundary, made tidy:** the helper layer (`exec`, `prepare`, `bindText`,
  `colText`, …) is the interesting part — it's where you decide how much of C's
  sharp edges to wrap. Notes:
  - `?*c.sqlite3` / `?*c.sqlite3_stmt` — C pointers are optional in Zig (they can
    be null), so you handle null explicitly.
  - `bindText` passes a **null destructor** (`SQLITE_STATIC`): "I promise this
    string outlives the step, don't copy it." True here because everything is
    arena- or literal-backed. Get this wrong in real code and you get
    use-after-free; the comment says why.
  - `colText` reads with `sqlite3_column_bytes` for an exact length instead of
    assuming null-termination — slices carry their length, so use it.
- **Migrations done right:** `PRAGMA user_version` is a free integer in the DB
  header. `migrate()` reads it, applies forward steps, and stamps the new
  version. This is the honest version of what ani-nexus did with
  `ALTER TABLE ... (ignore errors)`.
- **Verification mindset:** the spike seeds rows, double-writes one episode to
  prove the `ON CONFLICT` upsert (120s → 540s, last wins), then reads back. We
  also checked it externally with the `sqlite3` CLI (schema, WAL, FK cascade) —
  trust, but verify with a second tool.

**Try this:**
- `sqlite3 /tmp/zigoku-spike.db ".schema"` after a run — see what Zig actually wrote.
- Add a `v2` migration (`ALTER TABLE anime ADD COLUMN fav INTEGER DEFAULT 0;`),
  bump `SCHEMA_VERSION`, add an `if (v < 2)` block. Run twice — the second run
  is a no-op. That's the migration pattern Zigoku will ship.
- Break the SQL (typo a column) and read how the error surfaces through
  `sqlite3_errmsg` — that's the `check`/`prepare` helper earning its keep.

---

## 3. `concurrency.zig` — threads, generics, and io-aware locks

**Proves:** the pattern the TUI rides on — offload blocking work (network,
decode) to worker threads that post results back to the UI thread through a
channel. Zig 0.16 has no async runtime, so this is OS threads + a hand-built
channel.

**Run:** `zig build spike-concurrency`

**Concepts:** generics (`Channel(T)`), `std.Thread`, the **0.16 sync model**
(`std.Io.Mutex`/`Condition`), thread-safe allocation.

**Walkthrough:**

- **A generic type is a function:**
  ```zig
  fn Channel(comptime T: type) type { return struct { ... }; }
  ```
  `Channel(Msg)` is a concrete type produced at compile time. Inside, `@This()`
  refers to the struct being defined. This is the entire generics story — no
  separate template language.
- **The 0.16 gotcha that cost the most time:** blocking sync primitives moved to
  `std.Io` and take `io` on *every* call:
  ```zig
  self.mutex.lockUncancelable(self.io);
  defer self.mutex.unlock(self.io);
  self.not_empty.waitUncancelable(self.io, &self.mutex);
  self.not_empty.signal(self.io);
  ```
  They're futex-based. The channel stores `io` so callers don't thread it. We
  use the `*Uncancelable` variants because the cancellable ones return a
  `Cancelable` error set we don't need here (cancellation is a whole separate
  0.16 feature — futures that can be aborted).
- **The two allocators, on purpose:** the channel queue and the cross-thread
  message strings use `std.heap.page_allocator` (always thread-safe). Each worker
  spins up its *own* `ArenaAllocator` for fetch/parse scratch and only `dupe`s
  the one string it hands back. Arenas aren't safe for concurrent use; the page
  allocator is. Picking the right allocator per scope is a core Zig skill.
- **The proof is in the order:** five workers fetch concurrently; results print
  in *completion* order (e.g. `4, 3, 1, 0, 2`), not spawn order. That scramble is
  the evidence of real parallelism, and the channel is what serializes it safely
  back onto one thread.

**Try this:**
- Bump the queue to a bounded size and add a `not_full` condition + `wait` in
  `send` — now you've built backpressure (a real bounded channel).
- Make one query garbage (`"asdfqwer"`) and confirm the `ok = false` path posts a
  clean error message instead of crashing a worker.
- Remove the `dupe` and pass the arena slice directly — then watch it become a
  use-after-free once that worker's arena deinits. (Do this in a scratch copy;
  it's instructive precisely because it's wrong.)

**Addendum (ROD-153) — the *other* half of 0.16 concurrency:** the worker model
above is raw `std.Thread` + channel because it's *fire-and-forget* — spawn, post
a result back through the event loop, exit; nothing is awaited in-scope. The
`std.Io` concurrency API (the "futures that can be aborted" the lock notes above
hint at) shines for the opposite shape: a short-lived, **structured, awaited-
right-here** race. See `withDeadline` in `src/providers/allanime.zig` — it bounds
a long-tail GET in wall-clock time by spawning the fetch with `io.concurrent`,
racing it against a timer task through an `Io.Select`, and `cancel`-ing the
loser. The payoff is real: on the Threaded backend a `cancel` interrupts the
fetch's blocked `recv` with `SIG.IO`, so a stalled CDN genuinely unwinds instead
of hanging. std's stream reader has *no* per-read deadline, so this race is the
only way to put a clock on it. Two concurrency models now coexist on purpose —
threads+channel for background jobs, Io-concurrency for in-scope races — and the
rule of thumb is exactly that: **do you await it here, or does it report back
later?**

---

## 4. `allanime_stream.zig` — protocol + crypto, the reverse-engineering one

**Proves:** the full AllAnime stream-resolution recipe in Zig — the thing that
reopened the whole project. POST (not GET) past Cloudflare, Apollo persisted
queries, and AES-256-GCM decryption of the payload, ending in a verified-playable
1080p URL. Credit to anipy-cli (GPL-3.0) for the trail; reimplemented from the
observed protocol.

**Run:** `zig build spike-stream -- frieren`

**Concepts:** `std.crypto` (SHA-256, AES-256-GCM), `std.base64`, building JSON by
hand, slice→array coercion, comptime string building.

**Walkthrough:**

- **Comptime string building** sidesteps escaping hell. The `extensions` field is
  a JSON *string containing JSON*, so its quotes are backslash-escaped. Built
  once at compile time:
  ```zig
  const EXT_VIDEO = "{\\\"persistedQuery\\\":{...\\\"sha256Hash\\\":\\\"" ++ HASH_VIDEO ++ "\\\"}}";
  ```
  `++` concatenates at comptime; `\\\"` emits a literal `\"`.
- **The crypto, line by line** (this is the juicy part):
  ```zig
  var key: [32]u8 = undefined;
  std.crypto.hash.sha2.Sha256.hash(GCM_SEED, &key, .{});   // key = sha256("Xot36i3lK3:v1")

  const raw = try arena.alloc(u8, try b64.calcSizeForSlice(tbp));
  try b64.decode(raw, tbp);                                 // base64 → bytes

  const nonce: [12]u8 = raw[1..][0..12].*;                  // raw[0] is a 1-byte prefix
  const tag:   [16]u8 = raw[raw.len - 16 ..][0..16].*;      // GCM tag is the last 16
  const ciphertext    = raw[13 .. raw.len - 16];
  try Aes256Gcm.decrypt(plain, ciphertext, tag, "", nonce, key);
  ```
  Two things worth internalizing:
  - **`raw[1..][0..12].*`** is the idiom for "give me a `[12]u8` *array* from a
    slice." `raw[1..]` reslices from offset 1; `[0..12]` takes a compile-time-known
    length, producing a `*[12]u8`; `.*` dereferences to the array value. GCM's
    nonce/key/tag are fixed-size arrays, not slices, so you need this.
  - **GCM fails closed.** `decrypt` *verifies* the tag; wrong key/nonce/tag/offset
    → `error.AuthenticationFailed`, not garbage. That's why I read the std
    signature before writing — argument order matters and the type system won't
    catch a swapped nonce/tag (both are byte arrays).
- **The shape of the data** drives the structs: `tobeparsed` is the encrypted
  blob; after decrypt it's `{ "episode": { "sourceUrls": [ {sourceName, sourceUrl} ] } }`.
  We scan for the `tools.fast4speed.rsvp` provider — a direct MP4, no further
  work. The other providers carry `--<hex>` paths needing an XOR-`0x38` decipher
  + m3u8 follow; that's the remaining ROD-62 implementation work, and it's the
  *easy* part now.

**Try this:**
- Change one byte of the `GCM_SEED` and watch `decrypt` return
  `AuthenticationFailed` — feel the "fails closed" guarantee.
- Print the full decrypted JSON (`plain`) and explore the other `sourceUrls`.
  Implement the `XOR 0x38` decipher (`for each hex byte: char = byte ^ 0x38`) on a
  `--` path and see where it points.
- Diff this against `../anime-tuis/anipy-cli/.../allanime_provider.py` — same
  protocol, two languages. Good for seeing what Zig makes explicit that Python hides.

---

## 5. `mpv_play.zig` — processes, and the whole thing in one command

**Proves:** the capstone — search → resolve → decrypt → hand the stream to `mpv`.
One binary, end to end. Reuses the resolver from #4 and adds process spawning.

**Run:** `zig build spike-mpv -- frieren` (window), or append mpv flags:
`zig build spike-mpv -- frieren --frames=1 --vo=null --no-audio` (headless probe).

**Concepts:** `std.process.spawn`, `Child`, `std.ArrayList` (unmanaged),
argument pass-through, tagged-union `switch`.

**Walkthrough:**

- **Spawning in 0.16** is io-mediated like everything else:
  ```zig
  var child = try std.process.spawn(io, .{ .argv = argv.items });
  const term = try child.wait(io);
  ```
  `SpawnOptions.stdin/stdout/stderr` default to `.inherit`, so mpv just takes the
  terminal/display — no plumbing needed. `argv[0]` ("mpv") is resolved via the
  parent's `PATH`.
- **Building argv** uses the 0.16 *unmanaged* `ArrayList`:
  ```zig
  var argv: std.ArrayList([]const u8) = .empty;
  try argv.append(arena, "mpv");        // allocator passed to append, not stored
  ```
  Unmanaged collections don't hold an allocator — you pass it to each mutating
  call. This is the std default now; it makes ownership explicit.
- **Tagged-union result:** `Term` is `union(enum) { exited: u8, signal, stopped,
  unknown }`. We `switch` on it. Note the tags are **lowercase** in 0.16 (`.exited`,
  not `.Exited`) — a small thing that cost a compile error.
- **The pass-through trick** (`args[2..]` → mpv) is why one program serves both a
  human ("open a window") and CI/verification ("decode one frame headless and
  exit 0"). The headless probe is how we confirmed playback without a display.

**Try this:**
- Add `--start=300` to jump 5 minutes in — that's the resume mechanic, previewed.
- Swap `spawn`+`wait` for `std.process.run(...)` (captures stdout/stderr instead
  of inheriting) and print what mpv logged. Different tool for different jobs.
- Pass a deliberately bad URL and read how `spawn` vs `wait` vs mpv's own exit
  code distribute the failure.

---

## The Zig 0.16 landmine map (consolidated)

Everything here bit us at least once. Keep it handy for M1.

| You'd reach for… | In 0.16 it's… |
|---|---|
| `std.fs.deleteFileAbsolute`, `std.posix.unlink` | gone (fs moved behind `Io`). With libc: `std.c.unlink(path)`. |
| `std.time.timestamp()` | gone (time behind `Io`). With libc: `c.time(null)` via `@cInclude("time.h")`. |
| `std.Thread.Mutex` / `std.Thread.Condition` | moved to **`std.Io.Mutex`** / **`std.Io.Condition`**; every op takes `io`. |
| `std.Uri.percentEncode` | it's `std.Uri.Component.percentEncode`. |
| `exe.linkSystemLibrary(...)` | linking is on the **Module**: `createModule(.{..., .link_libc = true})` + `mod.linkSystemLibrary(name, .{})`. |
| `pub fn main() !void` with manual stdout | `pub fn main(init: std.process.Init) !void`; writers need an explicit buffer + `flush()`. |
| `ArrayList` that owns its allocator | unmanaged by default: `.empty`, then `list.append(gpa, x)` / `list.deinit(gpa)`. |
| `Term.Exited` (capitalized) | lowercase tags: `.exited`, `.signal`, `.stopped`, `.unknown`. |
| blog-post std APIs | read `/usr/lib/zig/std/**` directly — it's the only source of truth on 0.16. |

---

## What's spike-grade vs. what M1 must fix

These are *proofs*, not production. Before this code becomes the app:

- **Error handling is coarse.** Spikes `try` and bail. Real modules need typed
  error sets and user-facing messages (esp. the resolver, which is the most
  likely thing to rot).
- **No cancellation/timeouts on the channel.** Fine for a 5-fetch demo; the TUI
  needs to cancel stale work (the `Cancelable` variants we skipped).
- **Resolver only handles the easy path.** `tools.fast4speed.rsvp` direct links
  only; the `--hex`/m3u8 providers and quality selection are unimplemented.
- **Hard-coded everything.** Sub-only, episode 1, first search result, no AniList↔
  AllAnime title matching (that join is the real M1 glue).
- **Arena-for-everything.** Spikes never free because the process is short. Long-
  running modules will need real lifetimes (free decoded images, bound caches).

## Where this goes (M1)

The five ideas collapse into real modules behind interfaces:

- `http_search` + `allanime_stream` → a `CatalogProvider` (AniList) and a
  `StreamProvider` (AllAnime) behind one seam — ROD-59/60/62.
- `sqlite_store` → the `db` module from this exact schema — ROD-65.
- `concurrency` → the worker/channel layer the TUI pumps — ROD-71.
- `mpv_play` → the player module — ROD-63 and the M5 IPC tracking.

Read the spikes, break them, then we build the real thing on top. — Mak
