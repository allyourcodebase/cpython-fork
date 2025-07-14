const CompileCheck = @This();

step: std.Build.Step,
target: std.Build.ResolvedTarget,
kind: Kind,
source_content: []const u8,
source_path: std.Build.LazyPath,
result: ?Result = null,

include_dirs: std.ArrayListUnmanaged(std.Build.Module.IncludeDir) = .{},
link_objects: std.ArrayListUnmanaged(std.Build.Module.LinkObject) = .{},

const Result = union(enum) {
    pass,
    fail: struct {
        stderr: []const u8,
        files_not_found_count: u32,
        undeclared_function_count: u32,
        undeclared_identifier_count: u32,
    },
};

pub const Kind = union(enum) {
    exe: []const u8,
    header: []const u8,
};

pub fn create(b: *std.Build, target: std.Build.ResolvedTarget, kind: Kind) *CompileCheck {
    const write_files = b.addWriteFiles();
    const source_content = switch (kind) {
        .exe => |src| src,
        .header => |h| b.fmt("#include <{s}>", .{h}),
    };
    const source_path = write_files.add(
        switch (kind) {
            .exe => "compilecheck-exe.c",
            .header => "copmilecheck-header.c",
        },
        source_content,
    );
    const check = b.allocator.create(CompileCheck) catch @panic("OOM");
    check.* = .{
        .step = std.Build.Step.init(.{
            .id = .custom,
            .name = switch (kind) {
                .exe => "compile check exe",
                .header => |h| b.fmt("compile check header '{s}'", .{h}),
            },
            .owner = b,
            .makeFn = make,
        }),
        .target = target,
        .kind = switch (kind) {
            .exe => |src| .{ .exe = b.dupe(src) },
            .header => |h| .{ .header = b.dupe(h) },
        },
        .source_content = source_content,
        .source_path = source_path,
    };
    source_path.addStepDependencies(&check.step);
    return check;
}

pub fn haveHeader(check: *CompileCheck, asking_step: *std.Build.Step) ?u1 {
    std.debug.assert(check.kind == .header);
    if (!dependsOn(asking_step, &check.step)) std.debug.panic("haveHeader called on CompileCheck without a dependency", .{});
    return switch (check.result.?) {
        .pass => 1,
        .fail => null,
    };
}

pub fn compiled(
    check: *CompileCheck,
    asking_step: *std.Build.Step,
    opt: struct {
        allow_file_not_found: bool = true,
        allow_undeclared_function: bool = true,
        allow_undeclared_identifier: bool = true,
    },
) !?u1 {
    std.debug.assert(check.kind == .exe);
    if (!dependsOn(asking_step, &check.step)) std.debug.panic("compiled called on CompileCheck without a dependency", .{});
    return switch (check.result.?) {
        .pass => 1,
        .fail => |result| {
            if (!opt.allow_file_not_found and result.files_not_found_count > 0) return check.notAllowed(
                asking_step,
                "file not found",
                result.stderr,
            );
            if (!opt.allow_undeclared_function and result.undeclared_function_count > 0) return check.notAllowed(
                asking_step,
                "undeclared function",
                result.stderr,
            );
            if (!opt.allow_undeclared_identifier and result.undeclared_identifier_count > 0) return check.notAllowed(
                asking_step,
                "undeclared identifier",
                result.stderr,
            );
            return null;
        },
    };
}

pub fn linkLibrary(check: *CompileCheck, library: *std.Build.Step.Compile) void {
    std.debug.assert(library.kind == .lib);
    check.linkLibraryOrObject(library);
}
fn linkLibraryOrObject(check: *CompileCheck, other: *std.Build.Step.Compile) void {
    const allocator = check.step.owner.allocator;
    const bin = other.getEmittedBin();
    bin.addStepDependencies(&check.step);

    if (other.rootModuleTarget().os.tag == .windows and other.isDynamicLibrary()) {
        const lib = other.getEmittedImplib();
        lib.addStepDependencies(&check.step);
    }

    check.link_objects.append(allocator, .{ .other_step = other }) catch @panic("OOM");
    check.include_dirs.append(allocator, .{ .other_step = other }) catch @panic("OOM");

    other.getEmittedIncludeTree().addStepDependencies(&check.step);
}

fn notAllowed(
    check: *const CompileCheck,
    asking_step: *std.Build.Step,
    with: []const u8,
    stderr: []const u8,
) error{ MakeFailed, OutOfMemory } {
    return asking_step.fail(
        "compile check for code:\n----\n{s}\n----\nis not allowed to fail with '{s}' but did with the following output:\n----\n{s}\n----\n",
        .{ check.source_content, with, stderr },
    );
}

fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
    _ = options;
    const b = step.owner;
    const check: *CompileCheck = @fieldParentPtr("step", step);
    std.debug.assert(check.result == null);

    // TODO: for faster rebuilds implement the cache check
    const source_path = check.source_path.getPath2(b, step);

    const result = blk: {
        var zig_args: std.ArrayList([]const u8) = .init(b.allocator);
        defer zig_args.deinit();
        try zig_args.append(b.graph.zig_exe);
        try zig_args.append(switch (check.kind) {
            .exe => "build-exe",
            .header => "build-obj",
        });
        try zig_args.append("-lc");
        try zig_args.append("-target");
        try zig_args.append(try check.target.query.zigTriple(b.allocator));
        try zig_args.append(source_path);
        for (check.include_dirs.items) |include_dir| {
            try include_dir.appendZigProcessFlags(b, &zig_args, step);
        }
        const links = switch (check.kind) {
            .exe => true,
            .header => false,
        };
        if (links) {
            for (check.link_objects.items) |link_object| {
                switch (link_object) {
                    .other_step => |other| {
                        switch (other.kind) {
                            .exe => return step.fail("cannot link with an executable build artifact", .{}),
                            .@"test" => return step.fail("cannot link with a test", .{}),
                            .obj => {
                                try zig_args.append(other.getEmittedBin().getPath2(b, step));
                            },
                            .lib => {
                                const other_produces_implib = other.producesImplib();
                                // For DLLs, we must link against the implib.
                                // For everything else, we directly link
                                // against the library file.
                                const full_path_lib = if (other_produces_implib)
                                    getGeneratedFilePath(other, "generated_implib", step)
                                else
                                    getGeneratedFilePath(other, "generated_bin", step);
                                try zig_args.append(full_path_lib);
                            },
                        }
                    },
                    else => |o| std.debug.panic("todo: handle link object {s}", .{@tagName(o)}),
                }
            }
        }
        break :blk try std.process.Child.run(.{
            .allocator = b.allocator,
            .argv = zig_args.items,
        });
    };

    std.debug.assert(result.stdout.len == 0);
    switch (result.term) {
        .Exited => |code| if (code == 0) {
            std.debug.assert(result.stderr.len == 0);
            check.result = .pass;
        } else {
            var files_not_found_count: u32 = 0;
            var undeclared_function_count: u32 = 0;
            var undeclared_identifier_count: u32 = 0;
            var found_header = false;
            var line_it = std.mem.splitScalar(u8, result.stderr, '\n');
            while (line_it.next()) |line_untrimmed| {
                const line = std.mem.trimRight(u8, line_untrimmed, "\r");
                if (line.len == 0) continue;

                const error_prefix = "error: ";
                const error_start = std.mem.indexOf(u8, line, error_prefix) orelse {
                    continue;
                };
                const err = line[error_start + error_prefix.len ..];
                if (std.mem.endsWith(u8, err, "file not found")) {
                    switch (check.kind) {
                        .exe => {},
                        .header => |h| found_header = found_header or (std.mem.indexOf(u8, err, h) != null),
                    }
                    files_not_found_count += 1;
                } else if (std.mem.startsWith(u8, err, "call to undeclared function ")) {
                    switch (check.kind) {
                        .exe => {},
                        .header => return check.notAllowed(step, "undeclared function", result.stderr),
                    }
                    undeclared_function_count += 1;
                } else if (std.mem.startsWith(u8, err, "use of undeclared identifier")) {
                    switch (check.kind) {
                        .exe => {},
                        .header => return check.notAllowed(step, "undeclared identifier", result.stderr),
                    }
                    undeclared_identifier_count += 1;
                } else {
                    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
                    // std.debug.panic("todo: parse compiler error message '{s}' from the following:\n----\n{s}\n----\n", .{ err, result.stderr });
                }
            }

            check.result = .{ .fail = .{
                .stderr = result.stderr,
                .files_not_found_count = files_not_found_count,
                .undeclared_function_count = undeclared_function_count,
                .undeclared_identifier_count = undeclared_identifier_count,
            } };
        },
        inline else => return step.fail("zig {}", .{fmtTerm(result.term)}),
    }
}

fn dependsOn(asking: *std.Build.Step, candidate: *std.Build.Step) bool {
    std.debug.assert(asking != candidate);
    for (asking.dependencies.items) |dep| {
        if (dep == candidate or dependsOn(dep, candidate)) return true;
    }
    return false;
}

fn getGeneratedFilePath(compile: *std.Build.Step.Compile, comptime tag_name: []const u8, asking_step: ?*std.Build.Step) []const u8 {
    const maybe_path: ?*std.Build.GeneratedFile = @field(compile, tag_name);

    const generated_file = maybe_path orelse {
        std.debug.lockStdErr();
        const stderr = std.io.getStdErr();

        std.Build.dumpBadGetPathHelp(&compile.step, stderr, compile.step.owner, asking_step) catch {};

        @panic("missing emit option for " ++ tag_name);
    };

    const path = generated_file.path orelse {
        std.debug.lockStdErr();
        const stderr = std.io.getStdErr();

        std.Build.dumpBadGetPathHelp(&compile.step, stderr, compile.step.owner, asking_step) catch {};

        @panic(tag_name ++ " is null. Is there a missing step dependency?");
    };

    return path;
}

fn fmtTerm(term: ?std.process.Child.Term) std.fmt.Formatter(formatTerm) {
    return .{ .data = term };
}
fn formatTerm(
    term: ?std.process.Child.Term,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;
    if (term) |t| switch (t) {
        .Exited => |code| try writer.print("exited with code {}", .{code}),
        .Signal => |sig| try writer.print("terminated with signal {}", .{sig}),
        .Stopped => |sig| try writer.print("stopped with signal {}", .{sig}),
        .Unknown => |code| try writer.print("terminated for unknown reason with code {}", .{code}),
    } else {
        try writer.writeAll("exited with any code");
    }
}

const std = @import("std");
