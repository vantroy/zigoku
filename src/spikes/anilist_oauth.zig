//! ROD-282 spike — AniList Implicit Grant OAuth, end-to-end against the live API.
//!
//! Proves the cloud-sync half of ROD-129 before we build it:
//!   1. Implicit Grant token (client_id 43536, no secret) authenticates a request.
//!   2. Pull shape: MediaListCollection returns the user's lists/entries.
//!   3. Push shape: SaveMediaListEntry creates an entry, then DeleteMediaListEntry
//!      cleans it up — net-zero on the real list. Refuses if the entry pre-exists.
//!
//! Token capture is manual paste (SSH/tmux-safe): the token returns in the URL
//! *fragment*, which no loopback server can read. See the ROD-282 findings note.
//!
//! Run:
//!   zig build spike-oauth                                # prints the authorize URL
//!   zig build spike-oauth -- '<redirected URL>'          # auth + pull
//!   zig build spike-oauth -- '<url>' --write <mediaId>   # + push round-trip
//!
//! Throwaway — the real auth/sync lands in ROD-283..286.

const std = @import("std");

const CLIENT_ID = "43536";
const ENDPOINT = "https://graphql.anilist.co";
const AUTHORIZE = "https://anilist.co/api/v2/oauth/authorize?client_id=" ++ CLIENT_ID ++ "&response_type=token";

// GraphQL bodies — no embedded double quotes, so they interpolate JSON-safely.
const MLC_Q = "query($u:Int!){MediaListCollection(userId:$u,type:ANIME){lists{name status entries{id status progress media{id title{romaji}}}}}}";
const PRE_Q = "query($m:Int!){Media(id:$m){id title{romaji} mediaListEntry{id status progress}}}";
const SAVE_Q = "mutation($m:Int,$s:MediaListStatus,$p:Int){SaveMediaListEntry(mediaId:$m,status:$s,progress:$p){id status progress}}";
const DEL_Q = "mutation($id:Int){DeleteMediaListEntry(id:$id){deleted}}";

// ── Response shapes (std.json maps fields by name; unknown fields ignored) ─────

const GqlError = struct { message: []const u8 = "" };

const Title = struct { romaji: ?[]const u8 = null };

const Viewer = struct { id: u64 = 0, name: []const u8 = "" };
const ViewerData = struct { Viewer: ?Viewer = null };
const ViewerResp = struct { data: ?ViewerData = null, errors: ?[]GqlError = null };

const Media = struct { id: u64 = 0, title: Title = .{} };
const Entry = struct { id: u64 = 0, status: ?[]const u8 = null, progress: ?i64 = null, media: Media = .{} };
const List = struct { name: ?[]const u8 = null, status: ?[]const u8 = null, entries: []Entry = &.{} };
const Collection = struct { lists: []List = &.{} };
const MlcData = struct { MediaListCollection: ?Collection = null };
const MlcResp = struct { data: ?MlcData = null, errors: ?[]GqlError = null };

const PreEntry = struct { id: u64 = 0, status: ?[]const u8 = null, progress: ?i64 = null };
const PreMedia = struct { id: u64 = 0, title: Title = .{}, mediaListEntry: ?PreEntry = null };
const PreData = struct { Media: ?PreMedia = null };
const PreResp = struct { data: ?PreData = null, errors: ?[]GqlError = null };

const Saved = struct { id: u64 = 0, status: ?[]const u8 = null, progress: ?i64 = null };
const SaveData = struct { SaveMediaListEntry: ?Saved = null };
const SaveResp = struct { data: ?SaveData = null, errors: ?[]GqlError = null };

const Deleted = struct { deleted: bool = false };
const DelData = struct { DeleteMediaListEntry: ?Deleted = null };
const DelResp = struct { data: ?DelData = null, errors: ?[]GqlError = null };

// ── Helpers ───────────────────────────────────────────────────────────────────

const Http = struct { status: std.http.Status, body: []const u8 };

fn post(arena: std.mem.Allocator, io: std.Io, token: []const u8, body_json: []const u8) !Http {
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    var resp_aw = std.Io.Writer.Allocating.init(arena);
    const auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{token});
    const res = try client.fetch(.{
        .location = .{ .url = ENDPOINT },
        .method = .POST,
        .payload = body_json,
        .response_writer = &resp_aw.writer,
        .extra_headers = &.{
            .{ .name = "Authorization", .value = auth },
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Accept", .value = "application/json" },
        },
    });
    return .{ .status = res.status, .body = resp_aw.writer.buffered() };
}

fn parse(comptime T: type, arena: std.mem.Allocator, body: []const u8) !T {
    const parsed = try std.json.parseFromSlice(T, arena, body, .{ .ignore_unknown_fields = true });
    return parsed.value;
}

/// Print any GraphQL errors; returns true if the response carried at least one.
fn printErrs(out: *std.Io.Writer, errs: ?[]const GqlError) !bool {
    const es = errs orelse return false;
    if (es.len == 0) return false;
    for (es) |e| try out.print("  ✗ gql error: {s}\n", .{e.message});
    return true;
}

/// Pull the JWT out of a pasted redirect URL (`…#access_token=<jwt>&…`) or a raw token.
fn extractToken(raw: []const u8) []const u8 {
    const needle = "access_token=";
    const start = if (std.mem.indexOf(u8, raw, needle)) |i| raw[i + needle.len ..] else raw;
    const end = std.mem.indexOfAny(u8, start, "&\r\n\t \"'") orelse start.len;
    return std.mem.trim(u8, start[0..end], " \t\r\n\"'");
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var out_buf: [8192]u8 = undefined;
    var out_fw: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_fw.interface;

    // Args: first non-flag arg is the token/URL; `--write <mediaId>` opts into push.
    var token_arg: ?[]const u8 = null;
    var write_media: ?i64 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--write")) {
            i += 1;
            if (i < args.len) write_media = std.fmt.parseInt(i64, args[i], 10) catch null;
        } else if (token_arg == null) {
            token_arg = args[i];
        }
    }

    try out.print("── ROD-282 · AniList Implicit Grant spike ──\n\n", .{});

    const raw = token_arg orelse {
        try out.print(
            \\No token supplied. Step 1 — open this in a browser and approve:
            \\
            \\  {s}
            \\
            \\You'll land on http://localhost:80/#access_token=…  (a "can't connect"
            \\page is expected — nothing listens on :80; the token is in the address bar).
            \\
            \\Step 2 — re-run with the whole redirected URL (or just the token):
            \\
            \\  zig build spike-oauth -- '<paste redirected URL>'
            \\
            \\Optional push test (creates then deletes a list entry — net-zero):
            \\
            \\  zig build spike-oauth -- '<url>' --write <anilistMediaId>
            \\
        , .{AUTHORIZE});
        try out.flush();
        return;
    };

    const token = extractToken(raw);
    if (token.len < 20) {
        try out.print("✗ couldn't find an access_token in the input.\n", .{});
        try out.flush();
        return;
    }
    try out.print("token: {d} chars (starts {s}…)\n\n", .{ token.len, token[0..@min(token.len, 10)] });

    // [1] Viewer — proves the Bearer token authenticates, and yields our userId.
    try out.print("[1] Viewer (auth check)\n", .{});
    const v_res = try post(arena, io, token, "{\"query\":\"{Viewer{id name}}\"}");
    const vr = parse(ViewerResp, arena, v_res.body) catch {
        try out.print("  ✗ parse failed (status {d}). first 300B:\n  {s}\n", .{ @intFromEnum(v_res.status), v_res.body[0..@min(v_res.body.len, 300)] });
        try out.flush();
        return;
    };
    if (try printErrs(out, vr.errors)) {
        try out.flush();
        return;
    }
    const viewer = (if (vr.data) |d| d.Viewer else null) orelse {
        try out.print("  ✗ no Viewer in response.\n", .{});
        try out.flush();
        return;
    };
    try out.print("  ✓ authed as {s} (id {d})\n\n", .{ viewer.name, viewer.id });

    // [2] MediaListCollection — the pull shape (129d).
    try out.print("[2] MediaListCollection (pull shape)\n", .{});
    const mlc_body = try std.fmt.allocPrint(arena, "{{\"query\":\"{s}\",\"variables\":{{\"u\":{d}}}}}", .{ MLC_Q, viewer.id });
    const m_res = try post(arena, io, token, mlc_body);
    const mr = parse(MlcResp, arena, m_res.body) catch {
        try out.print("  ✗ parse failed (status {d}). first 300B:\n  {s}\n", .{ @intFromEnum(m_res.status), m_res.body[0..@min(m_res.body.len, 300)] });
        try out.flush();
        return;
    };
    if (try printErrs(out, mr.errors)) {
        try out.flush();
        return;
    }
    if (if (mr.data) |d| d.MediaListCollection else null) |mlc| {
        var total: usize = 0;
        for (mlc.lists) |l| total += l.entries.len;
        try out.print("  ✓ {d} list(s), {d} total entries\n", .{ mlc.lists.len, total });
        for (mlc.lists) |l| {
            try out.print("    · {s} [{s}] — {d} entries\n", .{ l.name orelse "(unnamed)", l.status orelse "?", l.entries.len });
        }
        var shown: usize = 0;
        sample: for (mlc.lists) |l| {
            for (l.entries) |e| {
                try out.print("      e.g. mediaId {d} · {s} · {s} · progress {d}\n", .{ e.media.id, e.media.title.romaji orelse "?", e.status orelse "?", e.progress orelse 0 });
                shown += 1;
                if (shown >= 3) break :sample;
            }
        }
    } else {
        try out.print("  (no MediaListCollection data)\n", .{});
    }
    try out.print("\n", .{});
    try out.flush();

    // [3] Push round-trip — opt-in, and never clobbers a pre-existing entry.
    const media_id = write_media orelse {
        try out.print("push test skipped (pass --write <mediaId> to exercise SaveMediaListEntry).\n", .{});
        try out.flush();
        return;
    };
    try out.print("[3] Push test on mediaId {d}\n", .{media_id});

    const pre_body = try std.fmt.allocPrint(arena, "{{\"query\":\"{s}\",\"variables\":{{\"m\":{d}}}}}", .{ PRE_Q, media_id });
    const p_res = try post(arena, io, token, pre_body);
    const pr = parse(PreResp, arena, p_res.body) catch {
        try out.print("  ✗ pre-check parse failed. first 300B:\n  {s}\n", .{p_res.body[0..@min(p_res.body.len, 300)]});
        try out.flush();
        return;
    };
    if (try printErrs(out, pr.errors)) {
        try out.flush();
        return;
    }
    const media = (if (pr.data) |d| d.Media else null) orelse {
        try out.print("  ✗ mediaId {d} not found on AniList.\n", .{media_id});
        try out.flush();
        return;
    };
    if (media.mediaListEntry) |existing| {
        try out.print(
            \\  ⚠ mediaId {d} ({s}) is ALREADY on your list (entry {d}, {s}, progress {d}).
            \\    Refusing to write — it would clobber real data. Pick a mediaId you don't have.
            \\
        , .{ media_id, media.title.romaji orelse "?", existing.id, existing.status orelse "?", existing.progress orelse 0 });
        try out.flush();
        return;
    }

    try out.print("  {s} not on your list — creating a throwaway entry…\n", .{media.title.romaji orelse "?"});
    const save_body = try std.fmt.allocPrint(arena, "{{\"query\":\"{s}\",\"variables\":{{\"m\":{d},\"s\":\"PLANNING\",\"p\":0}}}}", .{ SAVE_Q, media_id });
    const s_res = try post(arena, io, token, save_body);
    const sr = parse(SaveResp, arena, s_res.body) catch {
        try out.print("  ✗ save parse failed. first 300B:\n  {s}\n", .{s_res.body[0..@min(s_res.body.len, 300)]});
        try out.flush();
        return;
    };
    if (try printErrs(out, sr.errors)) {
        try out.flush();
        return;
    }
    const saved = (if (sr.data) |d| d.SaveMediaListEntry else null) orelse {
        try out.print("  ✗ no SaveMediaListEntry in response.\n", .{});
        try out.flush();
        return;
    };
    try out.print("  ✓ created entry {d} · {s} · progress {d}\n", .{ saved.id, saved.status orelse "?", saved.progress orelse 0 });

    try out.print("  cleaning up (DeleteMediaListEntry {d})…\n", .{saved.id});
    const del_body = try std.fmt.allocPrint(arena, "{{\"query\":\"{s}\",\"variables\":{{\"id\":{d}}}}}", .{ DEL_Q, saved.id });
    const d_res = try post(arena, io, token, del_body);
    const dr = parse(DelResp, arena, d_res.body) catch {
        try out.print("  ⚠ delete parse failed — entry {d} may remain. first 300B:\n  {s}\n", .{ saved.id, d_res.body[0..@min(d_res.body.len, 300)] });
        try out.flush();
        return;
    };
    if (try printErrs(out, dr.errors)) {
        try out.flush();
        return;
    }
    const deleted = if (dr.data) |d| (if (d.DeleteMediaListEntry) |x| x.deleted else false) else false;
    if (deleted) {
        try out.print("  ✓ cleaned up — net-zero on your list.\n", .{});
    } else {
        try out.print("  ⚠ delete returned deleted=false — check entry {d} manually.\n", .{saved.id});
    }
    try out.flush();
}
