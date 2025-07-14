pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // no need to free
    const arena = arena_instance.allocator();

    const all_args = try std.process.argsAlloc(arena);
    // no need to free

    if (all_args.len <= 1) {
        try std.io.getStdErr().writer().writeAll("usage: replace IN_FILE OUT_FILE NAME=VALUE...\n");
        std.process.exit(0xff);
    }
    const args = all_args[1..];
    if (args.len < 2) errExit("expected at least 2 cmdline args but got {}", .{args.len});

    const in_path = args[0];
    const out_path = args[1];
    const replacements = args[2..];

    var map: std.StringHashMapUnmanaged(struct {
        count: usize,
        value: []const u8,
    }) = .{};
    for (replacements) |r| {
        const eq_index = std.mem.indexOfScalar(u8, r, '=') orelse errExit(
            "expected NAME=VALUE cmdline arg but got '{s}'",
            .{r},
        );
        try map.put(arena, r[0..eq_index], .{ .count = 0, .value = r[eq_index + 1 ..] });
    }

    const in = blk: {
        const file = std.fs.cwd().openFile(in_path, .{}) catch |e| std.debug.panic(
            "open '{s}' failed with {s}",
            .{ in_path, @errorName(e) },
        );
        defer file.close();
        break :blk try file.readToEndAlloc(arena, std.math.maxInt(usize));
    };
    // no need to free

    var out_file = try std.fs.cwd().createFile(out_path, .{});
    defer out_file.close();
    var bw = std.io.bufferedWriter(out_file.writer());
    const writer = bw.writer();

    var missing_count: usize = 0;
    var offset: usize = 0;
    while (true) {
        const at_index = std.mem.indexOfScalarPos(u8, in, offset, '@') orelse break;
        try writer.writeAll(in[offset..at_index]);
        const end = std.mem.indexOfScalarPos(u8, in, at_index + 1, '@') orelse errExit(
            "{s}: unterminated '@' at offset {}",
            .{ in_path, at_index },
        );
        const name = in[at_index + 1 .. end];
        if (map.getEntry(name)) |entry| {
            entry.value_ptr.count += 1;
            try writer.writeAll(entry.value_ptr.value);
        } else {
            std.log.err("undefined variable '{s}'", .{name});
            try writer.print("MISSING_VAR_{s}", .{name});
            missing_count += 1;
        }
        offset = end + 1;
    }
    try writer.writeAll(in[offset..]);
    try bw.flush();
    if (missing_count > 0) errExit("{} missing variable(s) for template '{s}'", .{ missing_count, in_path });

    var unused_count: usize = 0;
    var it = map.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.count == 0) {
            std.log.err("unused variable '{s}'", .{entry.key_ptr.*});
            unused_count += 1;
        }
    }
    if (unused_count != 0) {
        std.log.err("{} unused variable(s), the did not appear in template '{s}'", .{ unused_count, in_path });
        std.process.exit(0xff);
    }
}

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

const std = @import("std");
