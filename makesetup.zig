pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // no need to free
    const arena = arena_instance.allocator();

    const all_args = try std.process.argsAlloc(arena);
    // no need to free

    if (all_args.len <= 1) {
        try std.io.getStdErr().writer().writeAll("usage: makesetup UPSTREAM_SRC OUT_DIR SETUP_FILES...\n");
        std.process.exit(0xff);
    }
    const args = all_args[1..];
    if (args.len < 3) errExit("expected at least 3 cmdline args but got {}", .{args.len});

    const upstream_src = args[0];
    const out_path = args[1];
    const setup_files = args[2..];

    const setup = try parseSetupFiles(arena, setup_files);

    const config_in_path = std.fs.path.join(arena, &.{ upstream_src, "Modules", "config.c.in" }) catch |e| oom(e);
    const config_in = blk: {
        const config_in = std.fs.cwd().openFile(config_in_path, .{}) catch |e| std.debug.panic(
            "open file '{s}' failed with {s}",
            .{ config_in_path, @errorName(e) },
        );
        defer config_in.close();
        break :blk try config_in.readToEndAlloc(arena, std.math.maxInt(usize));
    };
    // no need to free

    var out_dir = try std.fs.cwd().makeOpenPath(out_path, .{});
    defer out_dir.close();

    {
        var file = try out_dir.createFile("config.c", .{});
        defer file.close();
        var bw = std.io.bufferedWriter(file.writer());
        const writer = bw.writer();
        try writer.print("/* Generated automatically from {s} by makesetup. */\n", .{config_in_path});
        var lines = std.mem.splitScalar(u8, config_in, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "MARKER 1")) |_| {
                var it = setup.modules.iterator();
                while (it.next()) |entry| {
                    if (!entry.value_ptr.enabled) continue;
                    try writer.print("extern PyObject* PyInit_{s}(void);\n", .{entry.key_ptr.*});
                }
            } else if (std.mem.indexOf(u8, line, "MARKER 2")) |_| {
                var it = setup.modules.iterator();
                while (it.next()) |entry| {
                    if (!entry.value_ptr.enabled) continue;
                    try writer.print("    {{\"{s}\", PyInit_{0s}}},\n", .{entry.key_ptr.*});
                }
            }
            try writer.writeAll(line);
            try writer.writeByte('\n');
        }
        try bw.flush();
    }

    {
        var out_file = try out_dir.createFile("module-compile-args.txt", .{});
        defer out_file.close();
        var bw = std.io.bufferedWriter(out_file.writer());
        const writer = bw.writer();

        var it = setup.modules.iterator();
        while (it.next()) |entry| {
            const module_name = entry.key_ptr.*;
            {
                const suffix: []const u8 = if (entry.value_ptr.enabled) "" else " (DISABLED)";
                try writer.print("# Module '{s}'{s}\n", .{ module_name, suffix });
            }
            const prefix: []const u8 = if (entry.value_ptr.enabled) "" else "# ";
            for (entry.value_ptr.compile_args) |compile_arg| switch (compile_arg) {
                .source => |src| try writer.print("{s}Modules/{s}\n", .{ prefix, src }),
                .include => |inc| try writer.print("{s}-I{s}\n", .{ prefix, inc }),
            };
        }
        try bw.flush();
    }
}

const CompileArg = union(enum) {
    source: []const u8,
    include: []const u8,
};

const Kind = enum { static, shared };
const Module = struct {
    kind: ?Kind,
    enabled: bool,
    defines: []const []const u8,
    compile_args: []const CompileArg,
    libs: []const []const u8,
};
const Setup = struct {
    modules: std.StringArrayHashMapUnmanaged(Module) = .{},
};

fn parseSetupFiles(allocator: std.mem.Allocator, setup_files: []const []const u8) !Setup {
    var setup: Setup = .{};
    for (setup_files) |file_path| {
        const content = blk: {
            var file = std.fs.cwd().openFile(file_path, .{}) catch |e| std.debug.panic(
                "open '{s}' failed with {s}",
                .{ file_path, @errorName(e) },
            );
            defer file.close();
            break :blk try file.readToEndAlloc(allocator, std.math.maxInt(usize));
        };
        // DO NOT FREE content (we slice into the content and save references to it)
        try parseSetupFile(allocator, &setup, file_path, content);
    }
    return setup;
}

fn parseSetupFile(
    allocator: std.mem.Allocator,
    setup: *Setup,
    file_path: []const u8,
    content: []const u8,
) !void {
    var kind: ?Kind = null;
    var block_enabled: bool = true;
    var defs: std.StringHashMapUnmanaged([]const u8) = .{};
    defer defs.deinit(allocator);

    var lineno: u32 = 1;
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |line_untrimmed| : (lineno += 1) {
        const line = std.mem.trim(u8, line_untrimmed, " \t\r");
        if (line.len == 0 or line[0] == '#') {
            // ignore
        } else if (std.mem.eql(u8, line, "*static*")) {
            kind = .static;
        } else if (std.mem.eql(u8, line, "*shared*")) {
            kind = .shared;
        } else if (std.mem.eql(u8, line, "*disabled*")) {
            block_enabled = false;
        } else if (std.mem.indexOfScalar(u8, line, '=')) |eq_index| {
            const name = line[0..eq_index];
            const value = line[eq_index + 1 ..];
            defs.put(allocator, name, value) catch |e| oom(e);
        } else {
            // # Lines have the following structure:
            // #
            // # <module> ... [<sourcefile> ...] [<cpparg> ...] [<library> ...]
            // #
            // # <sourcefile> is anything ending in .c (.C, .cc, .c++ are C++ files)
            // # <cpparg> is anything starting with -I, -D, -U or -C
            // # <library> is anything ending in .a or beginning with -l or -L
            // # <module> is anything else but should be a valid Python
            // # identifier (letters, digits, underscores, beginning with non-digit)
            // #
            var parts = std.mem.tokenizeAny(u8, line, " ");
            const name = parts.next() orelse continue;

            {
                const valid_name = blk: {
                    for (name) |c| switch (c) {
                        '_', '0'...'9', 'A'...'Z', 'a'...'z' => {},
                        else => break :blk false,
                    };
                    break :blk true;
                };
                if (!valid_name) errExit("{s}:{}: invalid module name '{s}'", .{ file_path, lineno, name });
            }

            var defines: std.ArrayListUnmanaged([]const u8) = .{};
            var compile_args: std.ArrayListUnmanaged(CompileArg) = .{};
            var libraries: std.ArrayListUnmanaged([]const u8) = .{};
            var libs: std.ArrayListUnmanaged([]const u8) = .{};
            while (parts.next()) |part| {
                if (std.mem.startsWith(u8, part, "$")) {
                    // seems ok to ignore these for now
                    // std.log.err("TODO: handle '{s}'", .{part});
                    continue;
                }
                if (std.mem.startsWith(u8, part, "#")) {
                    break;
                } else if (std.mem.endsWith(u8, part, ".c")) {
                    compile_args.append(allocator, .{ .source = part }) catch |e| oom(e);
                } else if (std.mem.endsWith(u8, part, ".a")) {
                    libraries.append(allocator, part) catch |e| oom(e);
                } else if (std.mem.startsWith(u8, part, "-D")) {
                    if (part.len == 2) errExit("{s}:{}: expected '-DDEFINE' but just got '-D'", .{ file_path, lineno });
                    defines.append(allocator, part[2..]) catch |e| oom(e);
                } else if (std.mem.startsWith(u8, part, "-I")) {
                    if (part.len == 2) errExit("{s}:{}: expected '-IPATH' but just got '-I'", .{ file_path, lineno });
                    compile_args.append(allocator, .{ .include = part[2..] }) catch |e| oom(e);
                } else if (std.mem.startsWith(u8, part, "-l")) {
                    if (part.len == 2) errExit("{s}:{}: expected '-lLIB' but just got '-l'", .{ file_path, lineno });
                    libs.append(allocator, part[2..]) catch |e| oom(e);
                } else if (std.mem.eql(u8, part, "\\")) {
                    if (parts.next()) |_| errExit("{s}:{}: stray '\\' not at end of line", .{ file_path, lineno });
                    const next_line = line_it.next() orelse break;
                    lineno += 1;
                    parts = std.mem.tokenizeAny(u8, next_line, " ");
                } else std.debug.panic("{s}:{}: handle part '{s}' from this line '{s}'", .{ file_path, lineno, part, line });
            }

            const entry = setup.modules.getOrPut(allocator, name) catch |e| oom(e);
            if (entry.found_existing) {
                if (!block_enabled) continue;
                if (entry.value_ptr.enabled) {
                    std.debug.panic("multiple entries for module '{s}'", .{name});
                }
            }
            entry.value_ptr.* = .{
                .kind = kind,
                .enabled = block_enabled,
                .defines = defines.toOwnedSlice(allocator) catch |e| oom(e),
                .compile_args = compile_args.toOwnedSlice(allocator) catch |e| oom(e),
                .libs = libs.toOwnedSlice(allocator) catch |e| oom(e),
            };
        }
    }
}

// const ExprIt = struct {
//     s: []const u8,
//     offset: usize = 0,

//     pub const Entry = union(enum) {
//         string: []const u8,
//         expr: []const u8,
//     };
//     pub fn next(self: *ExprIt) ?Entry {
//         if (self.offset == self.s.len) return null;
//         const old_offset = self.offset;
//         self.offset = std.mem.indexOfScalarPos(u8, self.s, self.offset, '$') orelse {
//             self.offset = self.s.len;
//             return .{ .string = self.s[old_offset..] };
//         };
//         if (self.offset > old_offset) return .{ .string = self.s[old_offset..self.offset] };
//         self.offset += 1;
//         // string ends with '$'
//         if (self.offset == self.s.len) return .{ .string = self.s[old_offset..] };
//         if (self.s[self.offset] != '(') std.debug.panic("todo: handle '$' not followed by '(': '{s}'", .{self.s});
//         self.offset += 1;
//         const end = std.mem.indexOfScalarPos(u8, self.s, self.offset, ')') orelse std.debug.panic("unterminated $(: '{s}'", .{self.s});
//         const expr_start = self.offset;
//         self.offset = end + 1;
//         return .{ .expr = self.s[expr_start..end] };
//     }
// };

// fn fmtResolve(s: []const u8, arg: struct { srcdir: []const u8 }) FmtResolve {
//     return .{ .s = s, .srcdir = arg.srcdir };
// }
// const FmtResolve = struct {
//     s: []const u8,
//     srcdir: []const u8,
//     pub fn format(
//         self: @This(),
//         comptime fmt: []const u8,
//         options: std.fmt.FormatOptions,
//         writer: anytype,
//     ) !void {
//         _ = fmt;
//         _ = options;
//         var it: ExprIt = .{ .s = self.s };
//         while (it.next()) |entry| switch (entry) {
//             .string => |s| try writer.writeAll(s),
//             .expr => |e| {
//                 if (std.mem.eql(u8, e, "srcdir")) {
//                     try writer.writeAll(self.srcdir);
//                 } else std.debug.panic("todo: resolve expression '{s}'", .{e});
//             },
//         };
//     }
// };

fn oom(e: error{OutOfMemory}) noreturn {
    errExit("{s}", .{@errorName(e)});
}
fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

const std = @import("std");
const print = std.debug.print;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const Allocator = std.mem.Allocator;
