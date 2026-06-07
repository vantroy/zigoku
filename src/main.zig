//! Zigoku — CLI entry point.
//!
//! Thin shell for now: prints the banner and echoes the query. The real
//! search → resolve → play pipeline lands in M1 (ROD-59..64).

const std = @import("std");
const Io = std.Io;

const zigoku = @import("zigoku");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    try zigoku.writeBanner(stdout);

    if (args.len > 1) {
        try stdout.writeAll("\n  query: ");
        for (args[1..], 0..) |a, i| {
            if (i != 0) try stdout.writeByte(' ');
            try stdout.writeAll(a);
        }
        try stdout.writeAll("\n  (search lands in M1 — nothing to play yet)\n");
    } else {
        try stdout.writeAll("\n  usage: zigoku <query>\n");
    }

    try stdout.flush();
}
