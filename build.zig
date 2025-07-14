/// There are 3 stages of the python exe, the first two are used compile and embed modules for
/// the next stage which is referred to as "freezing" modules.
const PythonExeStage = union(enum) {
    /// stage1: used to "freeze" the modules used by bootstrap
    freeze_module,
    /// stage2: used to freeze the remaining modules for the final exe
    bootstrap: Stage2FrozenMods,
    /// stage3: the final python exe
    final: struct {
        stage2: Stage2FrozenMods,
        deepfreeze_c: std.Build.LazyPath,
    },

    pub fn stage2FrozenMods(self: PythonExeStage) ?Stage2FrozenMods {
        return switch (self) {
            .freeze_module => null,
            .bootstrap => |mods| mods,
            .final => |final| final.stage2,
        };
    }
};
const Stage2FrozenMods = struct {
    getpath_h: std.Build.LazyPath,
    importlib_bootstrap_h: std.Build.LazyPath,
    importlib_bootstrap_external_h: std.Build.LazyPath,
};

pub fn build(b: *std.Build) !void {
    const replace_exe = b.addExecutable(.{
        .name = "replace",
        .root_module = b.createModule(.{
            .root_source_file = b.path("replace.zig"),
            .target = b.graph.host,
        }),
    });
    const makesetup_exe = b.addExecutable(.{
        .name = "makesetup",
        .root_module = b.createModule(.{
            .root_source_file = b.path("makesetup.zig"),
            .target = b.graph.host,
        }),
    });

    const upstream = b.dependency("upstream", .{});

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ssl_enabled = b.option(bool, "ssl", "enable ssl") orelse switch (target.result.os.tag) {
        .macos => false, // there's an issue building openssl on macos
        else => true,
    };

    const libs_host: Libs = .{ .zlib = null, .openssl = null };
    const libs_target: Libs = .{
        .zlib = (b.dependency("zlib", .{
            .target = target,
            .optimize = optimize,
        })).artifact("z"),
        .openssl = if (ssl_enabled) (if (b.lazyDependency("openssl", .{
            .target = target,
            .optimize = optimize,
        })) |dep| dep.artifact("openssl") else null) else null,
    };

    const makesetup_host = addMakesetup(b, upstream, libs_host, .{
        .os_tag = b.graph.host.result.os.tag,
        .replace_exe = replace_exe,
        .makesetup_exe = makesetup_exe,
    });
    const makesetup_target = addMakesetup(b, upstream, libs_target, .{
        .os_tag = target.result.os.tag,
        .replace_exe = replace_exe,
        .makesetup_exe = makesetup_exe,
    });
    const pyconfig_host = try addPyconfig(b, upstream, b.graph.host, .{ .zlib = null, .openssl = null });

    const freeze_module_exe = addPythonExe(b, upstream, b.graph.host, .Debug, .{
        .name = "freeze_module",
        .makesetup_out = makesetup_host,
        .pyconfig = pyconfig_host,
        .stage = .freeze_module,
    });

    const stage2_frozen_mods: Stage2FrozenMods = .{
        .getpath_h = blk: {
            const freeze = b.addRunArtifact(freeze_module_exe);
            freeze.addArg("getpath");
            freeze.addFileArg(upstream.path("Modules/getpath.py"));
            break :blk freeze.addOutputFileArg("Python/frozen_modules/getpath.h");
        },
        .importlib_bootstrap_h = blk: {
            const freeze = b.addRunArtifact(freeze_module_exe);
            freeze.addArg("importlib._bootstrap");
            freeze.addFileArg(upstream.path("Lib/importlib/_bootstrap.py"));
            break :blk freeze.addOutputFileArg("Python/frozen_modules/importlib._bootstrap.h");
        },
        .importlib_bootstrap_external_h = blk: {
            const freeze = b.addRunArtifact(freeze_module_exe);
            freeze.addArg("importlib._bootstrap_external");
            freeze.addFileArg(upstream.path("Lib/importlib/_bootstrap_external.py"));
            break :blk freeze.addOutputFileArg("Python/frozen_modules/importlib._bootstrap_external.h");
        },
    };

    const deepfreeze_c = blk_deepfreeze_c: {
        const bootstrap_python_exe = addPythonExe(b, upstream, b.graph.host, .Debug, .{
            .name = "bootstrap_python",
            .makesetup_out = makesetup_host,
            .pyconfig = pyconfig_host,
            .stage = .{ .bootstrap = stage2_frozen_mods },
        });
        const bootstrap_packaged = packagePython(b, upstream, bootstrap_python_exe);

        const frozen_headers = b.allocator.alloc(std.Build.LazyPath, frozen_modules.len) catch @panic("OOM");
        // don't free

        const freeze_step = b.step("freeze", "");
        for (frozen_modules, frozen_module_names, frozen_headers) |mod_path, mod_name, *header| {
            const freeze = std.Build.Step.Run.create(b, b.fmt("run _freeze_module.py for '{s}'", .{mod_path}));
            freeze.addFileArg(bootstrap_packaged.exe);
            freeze.addFileArg(upstream.path("Programs/_freeze_module.py"));
            freeze.addArg(mod_name);
            freeze.addFileArg(upstream.path(mod_path));
            header.* = freeze.addOutputFileArg(b.fmt("{s}.h", .{mod_name}));
            freeze_step.dependOn(&freeze.step);
        }

        const run = std.Build.Step.Run.create(b, "run deepfreeze.py");
        run.addFileArg(bootstrap_packaged.exe);
        run.addFileArg(upstream.path("Tools/scripts/deepfreeze.py"));
        run.addArg("-o");
        const deepfreeze_c = run.addOutputFileArg("deepfreeze.c");
        {
            // Need to create a custom step because std.Build.Step.Run doesn't
            // have addSuffixedOutputArg.
            const AddModules = struct {
                step: std.Build.Step,
                run_deepfreeze: *std.Build.Step.Run,
                headers: []const std.Build.LazyPath,
            };
            const add_modules_make = struct {
                fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
                    _ = options;
                    const b2 = step.owner;
                    const self: *AddModules = @fieldParentPtr("step", step);
                    for (frozen_module_names, self.headers) |mod_name, header| {
                        self.run_deepfreeze.addArg(b2.fmt("{s}:{s}", .{ header.getPath(b2), mod_name }));
                    }
                }
            }.make;
            const add_modules = b.allocator.create(AddModules) catch @panic("OOM");
            add_modules.* = .{
                .step = std.Build.Step.init(.{
                    .id = .custom,
                    .name = "add modules to run deepfreeze.py",
                    .owner = b,
                    .makeFn = &add_modules_make,
                }),
                .run_deepfreeze = run,
                .headers = frozen_headers,
            };
            add_modules.step.dependOn(freeze_step);
            run.step.dependOn(&add_modules.step);
        }

        b.step("deepfreeze", "").dependOn(&run.step);
        break :blk_deepfreeze_c deepfreeze_c;
    };

    const final_exe = addPythonExe(b, upstream, target, optimize, .{
        .name = "python",
        .makesetup_out = makesetup_target,
        .pyconfig = try addPyconfig(b, upstream, target, libs_target),
        .stage = .{
            .final = .{
                .stage2 = stage2_frozen_mods,
                .deepfreeze_c = deepfreeze_c,
            },
        },
    });
    const final_packaged = packagePython(b, upstream, final_exe);
    const install_final = b.addInstallDirectory(.{
        .source_dir = final_packaged.root,
        .install_dir = .prefix,
        .install_subdir = "",
    });
    b.getInstallStep().dependOn(&install_final.step);

    const ci_step = b.step("ci", "The build/test step to run on the CI");
    ci_step.dependOn(b.getInstallStep());
    try ci(b, ssl_enabled, upstream, ci_step, .{
        .replace_exe = replace_exe,
        .makesetup_exe = makesetup_exe,
        .stage2_frozen_mods = stage2_frozen_mods,
        .deepfreeze_c = deepfreeze_c,
    });
}

fn addMakesetup(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    libs: Libs,
    args: struct {
        os_tag: std.Target.Os.Tag,
        replace_exe: *std.Build.Step.Compile,
        makesetup_exe: *std.Build.Step.Compile,
    },
) std.Build.LazyPath {
    const is_posix = (args.os_tag != .windows);

    const stdlib_modules = .{
        ._ssl = (libs.openssl != null),
        .zlib = (libs.zlib != null),

        // Modules that should always be present (POSIX and Windows):
        ._asyncio = true,
        ._bisect = true,
        ._contextvars = true,
        ._csv = true,
        ._datetime = true,
        ._decimal = false, // depends on libmpdec, disabled until it's available
        ._heapq = true,
        ._json = true,
        ._lsprof = true,
        ._multiprocessing = true,
        ._opcode = true,
        ._pickle = true,
        ._queue = true,
        ._random = true,
        ._socket = (args.os_tag != .windows),
        ._statistics = true,
        ._struct = true,
        ._typing = true,
        ._zoneinfo = true,
        .array = true,
        .audioop = true,
        .binascii = true,
        .cmath = true,
        .math = true,
        .mmap = true,
        .select = true,

        // text encodings and unicode
        ._codecs_cn = false,
        ._codecs_hk = false,
        ._codecs_iso2022 = false,
        ._codecs_jp = false,
        ._codecs_kr = false,
        ._codecs_tw = false,
        ._multibytecodec = true,
        .unicodedata = true,

        // Modules with some UNIX dependencies
        ._posixsubprocess = is_posix,
        .fcntl = is_posix,
        ._posixshmem = is_posix,
        .grp = is_posix,
        .ossaudiodev = (args.os_tag == .linux),
        .resource = (args.os_tag == .linux),
        .spwd = (args.os_tag == .linux),
        .syslog = is_posix,
        .termios = is_posix,

        ._md5 = true,
        ._sha1 = true,
        ._sha256 = true,
        ._sha512 = true,
        ._sha3 = true,
        ._blake2 = true,

        ._bz2 = false,
        ._lzma = false,

        ._dbm = false,
        ._gdbm = false,
        .readline = false,
        .pyexpat = false,
        ._elementtree = false,
        ._crypt = false,
        .nis = false,
        ._ctypes = false,
        ._curses = false,
        ._curses_panel = false,
        ._sqlite3 = false,
        ._hashlib = false,
        ._uuid = false,
        ._tkinter = false,
        ._scproxy = false,
        ._xxtestfuzz = false,
        ._testbuffer = false,
        ._testinternalcapi = false,
        ._testcapi = false,
        ._testclinic = false,
        ._testimportmultiple = false,
        ._testmultiphase = false,
        ._ctypes_test = false,
        .xxlimited = false,
        .xxlimited_35 = false,
        ._xxsubinterpreters = false,
    };

    const setup_bootstrap = blk: {
        const replace = b.addRunArtifact(args.replace_exe);
        replace.addFileArg(upstream.path("Modules/Setup.bootstrap.in"));
        const out = replace.addOutputFileArg("Setup.bootstrap");

        const pwd_enabled = is_posix;
        const value_str = if (pwd_enabled) "" else "#";
        replace.addArg(b.fmt("MODULE_PWD_TRUE={s}", .{value_str}));
        break :blk out;
    };

    const setup_stdlib = blk_stdlib: {
        const replace = b.addRunArtifact(args.replace_exe);
        replace.addFileArg(upstream.path("Modules/Setup.stdlib.in"));
        const out = replace.addOutputFileArg("Setup.stdlib");
        replace.addArg("MODULE_{NAME}_TRUE=MODULE_{NAME}_TRUE");
        replace.addArg("MODULE_BUILDTYPE=static");
        inline for (std.meta.fields(@TypeOf(stdlib_modules))) |field| {
            const name = field.name;
            const value = @field(stdlib_modules, name);
            var upcase_buf: [100]u8 = undefined;
            for (name, 0..) |c, i| {
                upcase_buf[i] = std.ascii.toUpper(c);
            }
            const value_str = if (value) "" else "#";
            replace.addArg(b.fmt("MODULE_{s}_TRUE={s}", .{ upcase_buf[0..name.len], value_str }));
        }
        break :blk_stdlib out;
    };

    const generate = b.addRunArtifact(args.makesetup_exe);
    generate.addDirectoryArg(upstream.path("."));
    const makesetup_out = generate.addOutputDirectoryArg("gen");
    generate.addFileArg(setup_bootstrap);
    generate.addFileArg(setup_stdlib);
    generate.addFileArg(upstream.path("Modules/Setup"));
    return makesetup_out;
}

fn packagePython(b: *std.Build, upstream: *std.Build.Dependency, exe: *std.Build.Step.Compile) struct {
    root: std.Build.LazyPath,
    exe: std.Build.LazyPath,
} {
    const write_files = b.addWriteFiles();
    _ = write_files.addCopyDirectory(upstream.path("Lib"), "lib/python3.11", .{});
    const empty_dir = b.addWriteFiles().getDirectory();
    _ = write_files.addCopyDirectory(empty_dir, "lib/python3.11/lib-dynload", .{});
    if (exe.producesPdbFile()) {
        _ = write_files.addCopyFile(exe.getEmittedPdb(), b.fmt("bin/{s}.pdb", .{exe.name}));
    }
    return .{
        .root = write_files.getDirectory(),
        .exe = write_files.addCopyFile(
            exe.getEmittedBin(),
            b.fmt("bin/{s}", .{exe.out_filename}),
        ),
    };
}

fn addPythonExe(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    args: struct {
        name: []const u8,
        makesetup_out: std.Build.LazyPath,
        pyconfig: Pyconfig,
        stage: PythonExeStage,
    },
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = args.name,
        .target = target,
        .optimize = optimize,
    });

    // workaround dictobject.c memcpy alignment issue
    exe.root_module.sanitize_c = false;
    // exe.bundle_ubsan_rt = true;

    exe.root_module.addCMacro("Py_BUILD_CORE", "");
    switch (optimize) {
        .Debug => {},
        .ReleaseSafe, .ReleaseSmall, .ReleaseFast => {
            const @"release_date_3.11" = "June 6, 2023";
            // need to redefine __DATE__ and __TIME__ for a reproducible build
            exe.root_module.addCMacro("__DATE__", "\"" ++ @"release_date_3.11" ++ "\"");
            exe.root_module.addCMacro("__TIME__", "\"00:00:00\"");
        },
    }
    exe.root_module.addCMacro("PLATFORM", switch (target.result.os.tag) {
        .linux => "\"linux\"",
        .macos => "\"darwin\"",
        .windows => "\"win32\"",
        else => std.debug.panic("todo: populate PLATFORM for os '{s}'", .{@tagName(target.result.os.tag)}),
    });
    switch (args.pyconfig.header) {
        .path => |path| exe.addIncludePath(path.dirname()),
        .config_header => |h| exe.addConfigHeader(h),
    }
    exe.addIncludePath(upstream.path("."));
    exe.addIncludePath(upstream.path("Include"));
    exe.addIncludePath(upstream.path("Include/internal"));
    if (args.stage.stage2FrozenMods()) |mods| {
        exe.addIncludePath(mods.getpath_h.dirname().dirname());
        exe.addIncludePath(mods.importlib_bootstrap_h.dirname().dirname().dirname());
        exe.addIncludePath(mods.importlib_bootstrap_external_h.dirname().dirname().dirname());
    }

    const flags_common = [_][]const u8{
        "-fwrapv",
        "-std=c11",
        "-fvisibility=hidden",
        "-DVPATH=\"\"",
    };

    {
        const AddModules = struct {
            step: std.Build.Step,
            root: std.Build.LazyPath,
            exe: *std.Build.Step.Compile,
            sources: std.Build.LazyPath,
        };
        const add_modules_make = struct {
            fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
                _ = options;
                const self: *AddModules = @fieldParentPtr("step", step);
                const sources = blk: {
                    var file = try std.fs.cwd().openFile(self.sources.getPath2(step.owner, step), .{});
                    defer file.close();
                    break :blk try file.readToEndAlloc(step.owner.allocator, std.math.maxInt(usize));
                };
                defer step.owner.allocator.free(sources);

                var files: std.ArrayListUnmanaged([]const u8) = .{};
                defer files.deinit(step.owner.allocator);

                var line_it = std.mem.splitScalar(u8, sources, '\n');
                while (line_it.next()) |line| {
                    if (line.len == 0) continue;
                    if (std.mem.startsWith(u8, line, "# ")) continue;
                    try files.append(step.owner.allocator, line);
                }

                self.exe.root_module.addCSourceFiles(.{
                    .root = self.root,
                    .files = files.items,
                    .flags = &flags_common,
                });
            }
        }.make;
        const add_modules = b.allocator.create(AddModules) catch @panic("OOM");
        add_modules.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = b.fmt("add module sources to {s} exe", .{exe.name}),
                .owner = b,
                .makeFn = &add_modules_make,
            }),
            .root = upstream.path("."),
            .exe = exe,
            .sources = args.makesetup_out.path(b, "sources.txt"),
        };
        add_modules.sources.addStepDependencies(&add_modules.step);
        exe.step.dependOn(&add_modules.step);
    }

    const library_src_omit_frozen = (parser_src ++ object_src ++ python_src ++ module_src);

    exe.addCSourceFiles(.{
        .root = upstream.path("."),
        .files = switch (args.stage) {
            .freeze_module => &([_][]const u8{
                "Programs/_freeze_module.c",
                "Modules/getbuildinfo.c",
                "Modules/getpath_noop.c",
            } ++ library_src_omit_frozen),
            .bootstrap => &([_][]const u8{
                "Programs/_bootstrap_python.c",
                "Modules/getbuildinfo.c",
            } ++ library_src_omit_frozen),
            .final => &(parser_src ++ object_src ++ python_src ++ module_src ++ [_][]const u8{
                "Programs/python.c",
                "Modules/getbuildinfo.c",
                "Python/frozen.c",
            }),
        },
        .flags = &flags_common,
    });

    exe.addCSourceFile(.{
        .file = args.makesetup_out.path(b, "config.c"),
        .flags = &flags_common,
    });

    switch (args.stage) {
        .freeze_module => {},
        .bootstrap, .final => exe.addCSourceFile(.{
            .file = upstream.path("Modules/getpath.c"),
            .flags = &(flags_common ++ [_][]const u8{
                "-DPREFIX=\"\"",
                "-DEXEC_PREFIX=\"\"",
                "-DVERSION=\"3.11\"",
                "-DPLATLIBDIR=\"lib\"",
            }),
        }),
    }
    switch (args.stage) {
        .freeze_module, .bootstrap => {},
        .final => |final| {
            exe.addCSourceFile(.{ .file = final.deepfreeze_c, .flags = &flags_common });
        },
    }

    if (target.result.os.tag == .windows) {
        exe.addCSourceFile(.{
            .file = upstream.path("Python/dynload_win.c"),
            .flags = &flags_common,
        });
    } else {
        exe.addCSourceFile(.{
            .file = upstream.path("Python/dynload_shlib.c"),
            .flags = &(flags_common ++ .{
                "-DSOABI=\"cpython-311-x86_64-linux-gnu\"",
            }),
        });
    }

    exe.linkLibC();
    if (args.pyconfig.libs.zlib) |zlib| exe.linkLibrary(zlib);
    if (args.pyconfig.libs.openssl) |openssl| exe.linkLibrary(openssl);

    if (target.result.os.tag == .windows) {
        exe.linkSystemLibrary("ws2_32");
        exe.linkSystemLibrary("api-ms-win-core-path-l1-1-0");
    }

    // TODO: do we need this
    // exe.rdynamic = true;

    return exe;
}

const Pyconfig = struct {
    libs: Libs,
    header: union(enum) {
        path: std.Build.LazyPath,
        config_header: *std.Build.Step.ConfigHeader,
    },
};

const Libs = struct {
    zlib: ?*std.Build.Step.Compile,
    openssl: ?*std.Build.Step.Compile,
};

fn addPyconfig(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    libs: Libs,
) !Pyconfig {
    const t = target.result;
    if (t.os.tag == .windows) return .{
        .libs = libs,
        .header = .{ .path = upstream.path("PC/pyconfig.h") },
    };
    const config_header = b.addConfigHeader(.{
        .style = .{ .autoconf = upstream.path("pyconfig.h.in") },
        .include_path = "pyconfig.h",
    }, .{
        .ALIGNOF_LONG = 8,
        .ALIGNOF_SIZE_T = 8,
        .DOUBLE_IS_LITTLE_ENDIAN_IEEE754 = 1,
        .ENABLE_IPV6 = 1,
        .MAJOR_IN_SYSMACROS = have(t.os.tag == .linux),
        .PTHREAD_KEY_T_IS_COMPATIBLE_WITH_INT = 1,
        .PTHREAD_SYSTEM_SCHED_SUPPORTED = 1,
        .PY_BUILTIN_HASHLIB_HASHES = "md5,sha1,sha256,sha512,sha3,blake2",
        .PY_COERCE_C_LOCALE = 1,
        .PY_FORMAT_SIZE_T = "z",
        .PY_SSL_DEFAULT_CIPHERS = 1,
        .PY_SUPPORT_TIER = 2,
        .RETSIGTYPE = .void,
        .SIZEOF_DOUBLE = 8,
        .SIZEOF_FLOAT = 4,
        .SIZEOF_FPOS_T = 16,
        .SIZEOF_INT = 4,
        .SIZEOF_LONG = 8,
        .SIZEOF_LONG_DOUBLE = 16,
        .SIZEOF_LONG_LONG = 8,
        .SIZEOF_OFF_T = 8,
        .SIZEOF_PID_T = 4,
        .SIZEOF_PTHREAD_KEY_T = 4,
        .SIZEOF_PTHREAD_T = 8,
        .SIZEOF_SHORT = 2,
        .SIZEOF_SIZE_T = 8,
        .SIZEOF_TIME_T = 8,
        .SIZEOF_UINTPTR_T = 8,
        .SIZEOF_VOID_P = 8,
        .SIZEOF_WCHAR_T = 4,
        .SIZEOF__BOOL = 1,
        .STDC_HEADERS = 1,
        .SYS_SELECT_WITH_SYS_TIME = 1,
        .TIME_WITH_SYS_TIME = 1,
        .WITH_DECIMAL_CONTEXTVAR = 1,
        .WITH_DOC_STRINGS = 1,
        .WITH_FREELISTS = 1,
        .WITH_PYMALLOC = 1,
        ._DARWIN_C_SOURCE = 1,
        ._FILE_OFFSET_BITS = 64,
        ._LARGEFILE_SOURCE = 1,
        ._NETBSD_SOURCE = 1,
        ._POSIX_C_SOURCE = .@"200809L",
        ._PYTHONFRAMEWORK = "",
        ._REENTRANT = 1,
        ._XOPEN_SOURCE = 700,
        ._XOPEN_SOURCE_EXTENDED = 1,
        .__BSD_VISIBLE = 1,
        ._ALL_SOURCE = 1,
        ._GNU_SOURCE = 1,
        ._POSIX_PTHREAD_SEMANTICS = 1,
        ._TANDEM_SOURCE = 1,
        .__EXTENSIONS__ = 1,

        .AC_APPLE_UNIVERSAL_BUILD = null,
        .AIX_BUILDDATE = null,
        .AIX_GENUINE_CPLUSPLUS = null,
        .ALT_SOABI = null,
        .ANDROID_API_LEVEL = null,
        .DOUBLE_IS_ARM_MIXED_ENDIAN_IEEE754 = null,
        .DOUBLE_IS_BIG_ENDIAN_IEEE754 = null,
        .FLOAT_WORDS_BIGENDIAN = null,
        .GETPGRP_HAVE_ARG = null,
        .MAJOR_IN_MKDEV = null,
        .MVWDELCH_IS_EXPRESSION = null,
        .PACKAGE_BUGREPORT = null,
        .PACKAGE_NAME = null,
        .PACKAGE_STRING = null,
        .PACKAGE_TARNAME = null,
        .PACKAGE_URL = null,
        .PACKAGE_VERSION = null,
        .POSIX_SEMAPHORES_NOT_ENABLED = null,
        .PYLONG_BITS_IN_DIGIT = null,
        .PY_SQLITE_ENABLE_LOAD_EXTENSION = null,
        .PY_SQLITE_HAVE_SERIALIZE = null,
        .PY_SSL_DEFAULT_CIPHER_STRING = null,
        .Py_DEBUG = null,
        .Py_ENABLE_SHARED = null,
        .Py_HASH_ALGORITHM = null,
        .Py_STATS = null,
        .Py_TRACE_REFS = null,
        .SETPGRP_HAVE_ARG = null,
        .SIGNED_RIGHT_SHIFT_ZERO_FILLS = null,
        .THREAD_STACK_SIZE = null,
        .TIMEMODULE_LIB = null,
        .TM_IN_SYS_TIME = null,
        .USE_COMPUTED_GOTOS = null,
        .WINDOW_HAS_FLAGS = null,
        .WITH_DTRACE = null,
        .WITH_DYLD = null,
        .WITH_EDITLINE = null,
        .WITH_LIBINTL = null,
        .WITH_NEXT_FRAMEWORK = null,
        .WITH_VALGRIND = null,
        .X87_DOUBLE_ROUNDING = null,
        ._BSD_SOURCE = null,
        ._INCLUDE__STDC_A1_SOURCE = null,
        ._LARGE_FILES = null,
        ._MINIX = null,
        ._POSIX_1_SOURCE = null,
        ._POSIX_SOURCE = null,
        ._POSIX_THREADS = null,
        ._WASI_EMULATED_GETPID = null,
        ._WASI_EMULATED_PROCESS_CLOCKS = null,
        ._WASI_EMULATED_SIGNAL = null,
        .clock_t = null,
        .@"const" = null,
        .gid_t = null,
        .mode_t = null,
        .off_t = null,
        .pid_t = null,
        .signed = null,
        .size_t = null,
        .socklen_t = null,
        .uid_t = null,
        .WORDS_BIGENDIAN = null,

        .HAVE_BROKEN_MBSTOWCS = null,
        .HAVE_BROKEN_NICE = null,
        .HAVE_BROKEN_PIPE_BUF = null,
        .HAVE_BROKEN_POLL = null,
        .HAVE_BROKEN_POSIX_SEMAPHORES = null,
        .HAVE_BROKEN_PTHREAD_SIGMASK = null,
        .HAVE_BROKEN_SEM_GETVALUE = null,
        .HAVE_BROKEN_UNSETENV = null,

        .HAVE_PTHREAD_STUBS = null,
        .HAVE_USABLE_WCHAR_T = null,
        .HAVE_NON_UNICODE_WCHAR_T_REPRESENTATION = null,
        .HAVE_CHROOT = have(t.os.tag == .linux),
    });

    const header_configs = .{
        .{ .HAVE_ALLOCA_H, "alloca.h" },
        .{ .HAVE_ASM_TYPES_H, "asm/types.h" },
        .{ .HAVE_BLUETOOTH_H, "bluetooth.h" },
        .{ .HAVE_BLUETOOTH_BLUETOOTH_H, "bluetooth/bluetooth.h" },
        .{ .HAVE_BZLIB_H, "bzlib.h" },
        .{ .HAVE_CONIO_H, "conio.h" },
        .{ .HAVE_CRYPT_H, "crypt.h" },
        .{ .HAVE_CURSES_H, "curses.h" },
        .{ .HAVE_DIRECT_H, "direct.h" },
        .{ .HAVE_DIRENT_H, "dirent.h" },
        .{ .HAVE_DB_H, "db.h" },
        .{ .HAVE_DLFCN_H, "dlfcn.h" },
        .{ .HAVE_ENDIAN_H, "endian.h" },
        .{ .HAVE_ERRNO_H, "errno.h" },
        .{ .HAVE_FCNTL_H, "fcntl.h" },
        .{ .HAVE_GDBM_DASH_NDBM_H, "gdbm-ndbm.h" },
        .{ .HAVE_GDBM_H, "gdbm.h" },
        .{ .HAVE_GDBM_NDBM_H, "gdbm/ndbm.h" },
        .{ .HAVE_GRP_H, "grp.h" },
        .{ .HAVE_IEEEFP_H, "ieeefp.h" },
        .{ .HAVE_IO_H, "io.h" },
        .{ .HAVE_INTTYPES_H, "inttypes.h" },
        .{ .HAVE_LANGINFO_H, "langinfo.h" },
        .{ .HAVE_LIBINTL_H, "libintl.h" },
        .{ .HAVE_LIBUTIL_H, "libutil.h" },
        .{ .HAVE_NETDB_H, "netdb.h" },
        .{ .HAVE_NETINET_IN_H, "netinet/in.h" },
        .{ .HAVE_NETPACKET_PACKET_H, "netpacket/packet.h" },
        .{ .HAVE_NET_IF_H, "net/if.h" },
        .{ .HAVE_POLL_H, "poll.h" },
        .{ .HAVE_PTHREAD_H, "pthread.h" },
        .{ .HAVE_PTY_H, "pty.h" },
        .{ .HAVE_SCHED_H, "sched.h" },
        .{ .HAVE_SETJMP_H, "setjmp.h" },
        .{ .HAVE_SHADOW_H, "shadow.h" },
        .{ .HAVE_SIGNAL_H, "signal.h" },
        .{ .HAVE_SPAWN_H, "spawn.h" },
        .{ .HAVE_STDINT_H, "stdint.h" },
        .{ .HAVE_STDLIB_H, "stdlib.h" },
        .{ .HAVE_STRINGS_H, "strings.h" },
        .{ .HAVE_STRING_H, "string.h" },
        .{ .HAVE_SYSEXITS_H, "sysexits.h" },
        .{ .HAVE_SYSLOG_H, "syslog.h" },
        .{ .HAVE_SYS_AUXV_H, "sys/auxv.h" },
        .{ .HAVE_SYS_EPOLL_H, "sys/epoll.h" },
        .{ .HAVE_SYS_EVENTFD_H, "sys/eventfd.h" },
        .{ .HAVE_SYS_FILE_H, "sys/file.h" },
        .{ .HAVE_SYS_IOCTL_H, "sys/ioctl.h" },
        .{ .HAVE_SYS_MMAN_H, "sys/mman.h" },
        .{ .HAVE_SYS_PARAM_H, "sys/param.h" },
        .{ .HAVE_SYS_POLL_H, "sys/poll.h" },
        .{ .HAVE_SYS_RANDOM_H, "sys/random.h" },
        .{ .HAVE_SYS_RESOURCE_H, "sys/resource.h" },
        .{ .HAVE_SYS_SELECT_H, "sys/select.h" },
        .{ .HAVE_SYS_SENDFILE_H, "sys/sendfile.h" },
        .{ .HAVE_SYS_SOCKET_H, "sys/socket.h" },
        .{ .HAVE_SYS_SOUNDCARD_H, "sys/soundcard.h" },
        .{ .HAVE_SYS_STATVFS_H, "sys/statvfs.h" },
        .{ .HAVE_SYS_STAT_H, "sys/stat.h" },
        .{ .HAVE_SYS_SYSCALL_H, "sys/syscall.h" },
        .{ .HAVE_SYS_SYSMACROS_H, "sys/sysmacros.h" },
        .{ .HAVE_SYS_TIMES_H, "sys/times.h" },
        .{ .HAVE_SYS_TIME_H, "sys/time.h" },
        .{ .HAVE_SYS_TYPES_H, "sys/types.h" },
        .{ .HAVE_SYS_UIO_H, "sys/uio.h" },
        .{ .HAVE_SYS_UN_H, "sys/un.h" },
        .{ .HAVE_SYS_UTSNAME_H, "sys/utsname.h" },
        .{ .HAVE_SYS_WAIT_H, "sys/wait.h" },
        .{ .HAVE_SYS_XATTR_H, "sys/xattr.h" },
        .{ .HAVE_TERMIOS_H, "termios.h" },
        .{ .HAVE_UNISTD_H, "unistd.h" },
        .{ .HAVE_UTIME_H, "utime.h" },
        .{ .HAVE_UTMP_H, "utmp.h" },
        .{ .HAVE_WCHAR_H, "wchar.h" },
        .{ .HAVE_LZMA_H, "lzma.h" },
        .{ .HAVE_MEMORY_H, "memory.h" },
        .{ .HAVE_NCURSES_H, "ncurses.h" },
        .{ .HAVE_NDBM_H, "ndmb.h" },
        .{ .HAVE_NDIR_H, "ndir.h" },
        .{ .HAVE_NETCAN_CAN_H, "netcan/can.h" },
        .{ .HAVE_PROCESS_H, "process.h" },
        .{ .HAVE_RPC_RPC_H, "rpc/rpc.h" },
        .{ .HAVE_STROPTS_H, "stropts.h" },
        .{ .HAVE_SYS_AUDIOIO_H, "sys/audioio.h" },
        .{ .HAVE_SYS_BSDTTY_H, "sys/bsdtty.h" },
        .{ .HAVE_SYS_DEVPOLL_H, "sys/devpoll.h" },
        .{ .HAVE_SYS_DIR_H, "sys/dir.h" },
        .{ .HAVE_SYS_ENDIAN_H, "sys/endian.h" },
        .{ .HAVE_SYS_EVENT_H, "sys/event.h" },
        .{ .HAVE_SYS_KERN_CONTROL_H, "sys/kern/contro.h" },
        .{ .HAVE_SYS_LOADAVG_H, "sys/loadavg.h" },
        .{ .HAVE_SYS_LOCK_H, "sys/lock.h" },
        .{ .HAVE_SYS_MEMFD_H, "sys/memfd.h" },
        .{ .HAVE_SYS_MKDEV_H, "sys/mkdev.h" },
        .{ .HAVE_SYS_MODEM_H, "sys/modem.h" },
        .{ .HAVE_SYS_NDIR_H, "sys/ndir.h" },
        .{ .HAVE_SYS_SYS_DOMAIN_H, "sys/sys/domain.h" },
        .{ .HAVE_SYS_TERMIO_H, "sys/termio.h" },
        .{ .HAVE_TERM_H, "term.h" },
        .{ .HAVE_UTIL_H, "util.h" },
        .{ .HAVE_UUID_H, "uuid.h" },
        .{ .HAVE_UUID_UUID_H, "uuid/uuid.h" },
        .{ .HAVE_ZLIB_H, "zlib.h" },
    };
    const exe_configs = .{
        .{ .HAVE_ACCEPT, "#include <sys/socket.h>\nint main(){accept(0, 0, 0);}" },
        .{ .HAVE_ACCEPT4, "#include <sys/socket.h>\nint main(){accept4(0, 0, 0, 0);}" },
        .{ .HAVE_ACOSH, "#include <math.h>\nint main(){acosh(1.0);}" },
        .{ .HAVE_ALARM, "#include <unistd.h>\nint main(){alarm(1);}" },
        .{ .HAVE_ASINH, "#include <math.h>\nint main(){asinh(1.0);}" },
        .{ .HAVE_ATANH, "#include <math.h>\nint main(){atanh(0.5);}" },
        .{ .HAVE_BIND, "#include <sys/socket.h>\nint main(){bind(0, 0, 0);}" },
        .{ .HAVE_BIND_TEXTDOMAIN_CODESET, "#include <libintl.h>\nint main(){bind_textdomain_codeset(0, 0);}" },
        .{ .HAVE_CHMOD, "#include <sys/stat.h>\nint main(){chmod(0, 0);}" },
        .{ .HAVE_CHOWN, "#include <unistd.h>\nint main(){chown(0, 0, 0);}" },
        // .{ .HAVE_CHROOT, "#include <unistd.h>\nint main(){chroot(0);}" },
        .{ .HAVE_CLOCK, "#include <time.h>\nint main(){clock();}" },
        .{ .HAVE_CLOCK_GETRES, "#include <time.h>\nint main(){struct timespec ts; clock_getres(CLOCK_REALTIME, &ts);}" },
        .{ .HAVE_CLOCK_GETTIME, "#include <time.h>\nint main(){struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);}" },
        .{ .HAVE_CLOCK_NANOSLEEP, "#include <time.h>\nint main(){struct timespec ts = {0, 0}; clock_nanosleep(CLOCK_REALTIME, 0, &ts, 0);}" },
        .{ .HAVE_CLOCK_SETTIME, "#include <time.h>\nint main(){struct timespec ts = {0, 0}; clock_settime(CLOCK_REALTIME, &ts);}" },
        .{ .HAVE_CLOSE_RANGE, "#define _GNU_SOURCE\n#include <unistd.h>\nint main(){close_range(0, 0, 0);}" },
        .{ .HAVE_CONFSTR, "#include <unistd.h>\nint main(){confstr(0, 0, 0);}" },
        .{ .HAVE_CONNECT, "#include <sys/socket.h>\nint main(){connect(0, 0, 0);}" },
        .{ .HAVE_COPY_FILE_RANGE, "#include <unistd.h>\nint main(){copy_file_range(0, 0, 0, 0, 0, 0);}" },
        .{ .HAVE_CTERMID, "#include <stdio.h>\nint main(){ctermid(0);}" },
        .{ .HAVE_DLOPEN, "#include <dlfcn.h>\nint main(){dlopen(0, 0);}" },
        .{ .HAVE_DUP, "#include <unistd.h>\nint main(){dup(0);}" },
        .{ .HAVE_DUP2, "#include <unistd.h>\nint main(){dup2(0, 0);}" },
        .{ .HAVE_DUP3, "#include <unistd.h>\nint main(){dup3(0, 0, 0);}" },
        .{ .HAVE_EPOLL_CREATE1, "#include <sys/epoll.h>\nint main(){epoll_create1(0);}" },
        .{ .HAVE_ERF, "#include <math.h>\nint main(){erf(1.0);}" },
        .{ .HAVE_ERFC, "#include <math.h>\nint main(){erfc(1.0);}" },
        .{ .HAVE_EVENTFD, "#include <sys/eventfd.h>\nint main(){eventfd(0, 0);}" },
        .{ .HAVE_EXECV, "#include <unistd.h>\nint main(){execv(0, 0);}" },
        .{ .HAVE_EXPLICIT_BZERO, "#include <strings.h>\nint main(){explicit_bzero(0, 0);}" },
        .{ .HAVE_EXPM1, "#include <math.h>\nint main(){expm1(1.0);}" },
        .{ .HAVE_FACCESSAT, "#include <unistd.h>\nint main(){faccessat(0, 0, 0, 0);}" },
        .{ .HAVE_FCHDIR, "#include <unistd.h>\nint main(){fchdir(0);}" },
        .{ .HAVE_FCHMOD, "#include <sys/stat.h>\nint main(){fchmod(0, 0);}" },
        .{ .HAVE_FCHMODAT, "#include <sys/stat.h>\nint main(){fchmodat(0, 0, 0, 0);}" },
        .{ .HAVE_FCHOWN, "#include <unistd.h>\nint main(){fchown(0, 0, 0);}" },
        .{ .HAVE_FCHOWNAT, "#include <unistd.h>\nint main(){fchownat(0, 0, 0, 0, 0);}" },
        .{ .HAVE_FDATASYNC, "#include <unistd.h>\nint main(){fdatasync(0);}" },
        .{ .HAVE_FDOPENDIR, "#include <dirent.h>\nint main(){fdopendir(0);}" },
        .{ .HAVE_FEXECVE, "#include <unistd.h>\nint main(){fexecve(0, 0, 0);}" },
        .{ .HAVE_FLOCK, "#include <sys/file.h>\nint main(){flock(0, 0);}" },
        .{ .HAVE_FORK, "#include <unistd.h>\nint main(){fork();}" },
        .{ .HAVE_FORKPTY, "#include <pty.h>\nint main(){forkpty(0, 0, 0, 0);}" },
        .{ .HAVE_FPATHCONF, "#include <unistd.h>\nint main(){fpathconf(0, 0);}" },
        .{ .HAVE_FSEEKO, "#include <stdio.h>\nint main(){fseeko(0, 0, 0);}" },
        .{ .HAVE_FSTATAT, "#include <sys/stat.h>\nint main(){struct stat st; fstatat(0, 0, &st, 0);}" },
        .{ .HAVE_FSTATVFS, "#include <sys/statvfs.h>\nint main(){struct statvfs st; fstatvfs(0, &st);}" },
        .{ .HAVE_FSYNC, "#include <unistd.h>\nint main(){fsync(0);}" },
        .{ .HAVE_FTELLO, "#include <stdio.h>\nint main(){ftello(0);}" },
        .{ .HAVE_FTIME, "#include <sys/timeb.h>\nint main(){struct timeb tb; ftime(&tb);}" },
        .{ .HAVE_FTRUNCATE, "#include <unistd.h>\nint main(){ftruncate(0, 0);}" },
        .{ .HAVE_FUTIMENS, "#include <sys/stat.h>\nint main(){futimens(0, 0);}" },
        .{ .HAVE_FUTIMES, "#include <sys/time.h>\nint main(){futimes(0, 0);}" },
        .{ .HAVE_FUTIMESAT, "#include <sys/time.h>\nint main(){futimesat(0, 0, 0);}" },
        .{ .HAVE_GAI_STRERROR, "#include <netdb.h>\nint main(){gai_strerror(0);}" },
        .{ .HAVE_GETADDRINFO, "#include <netdb.h>\nint main(){getaddrinfo(0, 0, 0, 0);}" },
        .{ .HAVE_GETC_UNLOCKED, "#include <stdio.h>\nint main(){getc_unlocked(0);}" },
        .{ .HAVE_GETEGID, "#include <unistd.h>\nint main(){getegid();}" },
        .{ .HAVE_GETENTROPY, "#include <unistd.h>\nint main(){getentropy(0, 0);}" },
        .{ .HAVE_GETEUID, "#include <unistd.h>\nint main(){geteuid();}" },
        .{ .HAVE_GETGID, "#include <unistd.h>\nint main(){getgid();}" },
        .{ .HAVE_GETGRGID, "#include <grp.h>\nint main(){getgrgid(0);}" },
        .{ .HAVE_GETGRGID_R, "#include <grp.h>\nint main(){struct group grp; char buf[1024]; struct group *result; getgrgid_r(0, &grp, buf, sizeof(buf), &result);}" },
        .{ .HAVE_GETGRNAM_R, "#include <grp.h>\nint main(){struct group grp; char buf[1024]; struct group *result; getgrnam_r(0, &grp, buf, sizeof(buf), &result);}" },
        .{ .HAVE_GETGROUPLIST, "#include <grp.h>\nint main(){int groups; int ngroups = 1; getgrouplist(0, 0, &groups, &ngroups);}" },
        .{ .HAVE_GETGROUPS, "#include <unistd.h>\nint main(){getgroups(0, 0);}" },
        .{ .HAVE_GETHOSTBYADDR, "#include <netdb.h>\nint main(){gethostbyaddr(0, 0, 0);}" },
        .{ .HAVE_GETHOSTBYNAME, "#include <netdb.h>\nint main(){gethostbyname(0);}" },
        .{ .HAVE_GETHOSTBYNAME_R, "#include <netdb.h>\nint main(){struct hostent he; char buf[1024]; struct hostent *result; int h_errno; gethostbyname_r(0, &he, buf, sizeof(buf), &result, &h_errno);}" },
        .{ .HAVE_GETHOSTNAME, "#include <unistd.h>\nint main(){gethostname(0, 0);}" },
        .{ .HAVE_GETITIMER, "#include <sys/time.h>\nint main(){struct itimerval it; getitimer(0, &it);}" },
        .{ .HAVE_GETLOADAVG, "#include <stdlib.h>\nint main(){double loadavg[3]; getloadavg(loadavg, 3);}" },
        .{ .HAVE_GETLOGIN, "#include <unistd.h>\nint main(){getlogin();}" },
        .{ .HAVE_GETNAMEINFO, "#include <netdb.h>\nint main(){getnameinfo(0, 0, 0, 0, 0, 0, 0);}" },
        .{ .HAVE_GETPAGESIZE, "#include <unistd.h>\nint main(){getpagesize();}" },
        .{ .HAVE_GETPEERNAME, "#include <sys/socket.h>\nint main(){getpeername(0, 0, 0);}" },
        .{ .HAVE_GETPGID, "#include <unistd.h>\nint main(){getpgid(0);}" },
        .{ .HAVE_GETPGRP, "#include <unistd.h>\nint main(){getpgrp();}" },
        .{ .HAVE_GETPID, "#include <unistd.h>\nint main(){getpid();}" },
        .{ .HAVE_GETPPID, "#include <unistd.h>\nint main(){getppid();}" },
        .{ .HAVE_GETPRIORITY, "#include <sys/resource.h>\nint main(){getpriority(0, 0);}" },
        .{ .HAVE_GETPROTOBYNAME, "#include <netdb.h>\nint main(){getprotobyname(0);}" },
        .{ .HAVE_GETPWENT, "#include <pwd.h>\nint main(){getpwent();}" },
        .{ .HAVE_GETPWNAM_R, "#include <pwd.h>\nint main(){struct passwd pw; char buf[1024]; struct passwd *result; getpwnam_r(0, &pw, buf, sizeof(buf), &result);}" },
        .{ .HAVE_GETPWUID, "#include <pwd.h>\nint main(){getpwuid(0);}" },
        .{ .HAVE_GETPWUID_R, "#include <pwd.h>\nint main(){struct passwd pw; char buf[1024]; struct passwd *result; getpwuid_r(0, &pw, buf, sizeof(buf), &result);}" },
        .{ .HAVE_GETRANDOM, "#include <sys/random.h>\nint main(){getrandom(0, 0, 0);}" },
        .{ .HAVE_GETRESGID, "#include <unistd.h>\nint main(){gid_t rgid, egid, sgid; getresgid(&rgid, &egid, &sgid);}" },
        .{ .HAVE_GETRESUID, "#define _GNU_SOURCE\n#include <unistd.h>\nint main(){uid_t ruid, euid, suid; getresuid(&ruid, &euid, &suid);}" },
        .{ .HAVE_GETRUSAGE, "#include <sys/resource.h>\nint main(){struct rusage ru; getrusage(0, &ru);}" },
        .{ .HAVE_GETSERVBYNAME, "#include <netdb.h>\nint main(){getservbyname(0, 0);}" },
        .{ .HAVE_GETSERVBYPORT, "#include <netdb.h>\nint main(){getservbyport(0, 0);}" },
        .{ .HAVE_GETSID, "#include <unistd.h>\nint main(){getsid(0);}" },
        .{ .HAVE_GETSOCKNAME, "#include <sys/socket.h>\nint main(){getsockname(0, 0, 0);}" },
        .{ .HAVE_GETSPENT, "#include <shadow.h>\nint main(){getspent();}" },
        .{ .HAVE_GETSPNAM, "#include <shadow.h>\nint main(){getspnam(0);}" },
        .{ .HAVE_GETUID, "#include <unistd.h>\nint main(){getuid();}" },
        .{ .HAVE_GETWD, "#include <unistd.h>\nint main(){getwd(0);}" },
        .{ .HAVE_HSTRERROR, "#include <netdb.h>\nint main(){hstrerror(0);}" },
        .{ .HAVE_HTOLE64, "#include <endian.h>\nint main(){htole64(0);}" },
        .{ .HAVE_IF_NAMEINDEX, "#include <net/if.h>\nint main(){if_nameindex();}" },
        .{ .HAVE_INET_ATON, "#include <arpa/inet.h>\nint main(){struct in_addr addr; inet_aton(0, &addr);}" },
        .{ .HAVE_INET_NTOA, "#include <arpa/inet.h>\nint main(){struct in_addr addr; inet_ntoa(addr);}" },
        .{ .HAVE_INET_PTON, "#include <arpa/inet.h>\nint main(){inet_pton(0, 0, 0);}" },
        .{ .HAVE_INITGROUPS, "#include <grp.h>\nint main(){initgroups(0, 0);}" },
        .{ .HAVE_KILL, "#include <signal.h>\nint main(){kill(0, 0);}" },
        .{ .HAVE_KILLPG, "#include <signal.h>\nint main(){killpg(0, 0);}" },
        .{ .HAVE_LCHOWN, "#include <unistd.h>\nint main(){lchown(0, 0, 0);}" },
        .{ .HAVE_LINK, "#include <unistd.h>\nint main(){link(0, 0);}" },
        .{ .HAVE_LINKAT, "#include <unistd.h>\nint main(){linkat(0, 0, 0, 0, 0);}" },
        .{ .HAVE_LISTEN, "#include <sys/socket.h>\nint main(){listen(0, 0);}" },
        .{ .HAVE_LOCKF, "#include <unistd.h>\nint main(){lockf(0, 0, 0);}" },
        .{ .HAVE_LOG1P, "#include <math.h>\nint main(){log1p(1.0);}" },
        .{ .HAVE_LOG2, "#include <math.h>\nint main(){log2(2.0);}" },
        .{ .HAVE_LOGIN_TTY, "#include <utmp.h>\nint main(){login_tty(0);}" },
        .{ .HAVE_LSTAT, "#include <sys/stat.h>\nint main(){struct stat st; lstat(0, &st);}" },
        .{ .HAVE_LUTIMES, "#include <sys/time.h>\nint main(){lutimes(0, 0);}" },
        .{ .HAVE_MADVISE, "#include <sys/mman.h>\nint main(){madvise(0, 0, 0);}" },
        .{ .HAVE_MAKEDEV, "#include <sys/types.h>\nint main(){makedev(0, 0);}" },
        .{ .HAVE_MBRTOWC, "#include <wchar.h>\nint main(){wchar_t wc; mbrtowc(&wc, 0, 0, 0);}" },
        .{ .HAVE_MEMFD_CREATE, "#include <sys/mman.h>\nint main(){memfd_create(0, 0);}" },
        .{ .HAVE_MEMRCHR, "#include <string.h>\nint main(){memrchr(0, 0, 0);}" },
        .{ .HAVE_MKDIRAT, "#include <sys/stat.h>\nint main(){mkdirat(0, 0, 0);}" },
        .{ .HAVE_MKFIFO, "#include <sys/stat.h>\nint main(){mkfifo(0, 0);}" },
        .{ .HAVE_MKFIFOAT, "#include <sys/stat.h>\nint main(){mkfifoat(0, 0, 0);}" },
        .{ .HAVE_MKNOD, "#include <sys/stat.h>\nint main(){mknod(0, 0, 0);}" },
        .{ .HAVE_MKNODAT, "#include <sys/stat.h>\nint main(){mknodat(0, 0, 0, 0);}" },
        .{ .HAVE_MKTIME, "#include <time.h>\nint main(){struct tm tm; mktime(&tm);}" },
        .{ .HAVE_MMAP, "#include <sys/mman.h>\nint main(){mmap(0, 0, 0, 0, 0, 0);}" },
        .{ .HAVE_MREMAP, "#define _GNU_SOURCE\n#include <sys/mman.h>\nint main(){mremap(0, 0, 0, 0);}" },
        .{ .HAVE_NANOSLEEP, "#include <time.h>\nint main(){struct timespec ts = {0, 0}; nanosleep(&ts, 0);}" },
        .{ .HAVE_NICE, "#include <unistd.h>\nint main(){nice(0);}" },
        .{ .HAVE_OPENAT, "#include <fcntl.h>\nint main(){openat(0, 0, 0);}" },
        .{ .HAVE_OPENDIR, "#include <dirent.h>\nint main(){opendir(0);}" },
        .{ .HAVE_OPENPTY, "#include <pty.h>\nint main(){openpty(0, 0, 0, 0, 0);}" },
        .{ .HAVE_PATHCONF, "#include <unistd.h>\nint main(){pathconf(0, 0);}" },
        .{ .HAVE_PAUSE, "#include <unistd.h>\nint main(){pause();}" },
        .{ .HAVE_PIPE, "#include <unistd.h>\nint main(){int pipefd[2]; pipe(pipefd);}" },
        .{ .HAVE_PIPE2, "#include <unistd.h>\nint main(){int pipefd[2]; pipe2(pipefd, 0);}" },
        .{ .HAVE_POLL, "#include <poll.h>\nint main(){poll(0, 0, 0);}" },
        .{ .HAVE_POSIX_FADVISE, "#include <fcntl.h>\nint main(){posix_fadvise(0, 0, 0, 0);}" },
        .{ .HAVE_POSIX_FALLOCATE, "#include <fcntl.h>\nint main(){posix_fallocate(0, 0, 0);}" },
        .{ .HAVE_POSIX_SPAWN, "#include <spawn.h>\nint main(){posix_spawn(0, 0, 0, 0, 0, 0);}" },
        .{ .HAVE_POSIX_SPAWNP, "#include <spawn.h>\nint main(){posix_spawnp(0, 0, 0, 0, 0, 0);}" },
        .{ .HAVE_PREAD, "#include <unistd.h>\nint main(){pread(0, 0, 0, 0);}" },
        .{ .HAVE_PREADV, "#include <sys/uio.h>\nint main(){preadv(0, 0, 0, 0);}" },
        .{ .HAVE_PREADV2, "#include <sys/uio.h>\nint main(){preadv2(0, 0, 0, 0, 0);}" },
        .{ .HAVE_PRLIMIT, "#include <sys/time.h>\n#include <sys/resource.h>\nint main(){prlimit(0, 0, 0, 0);}" },
        .{ .HAVE_PTHREAD_KILL, "#include <signal.h>\nint main(){pthread_kill(0, 0);}" },
        .{ .HAVE_PTHREAD_SIGMASK, "#include <pthread.h>\nint main(){pthread_sigmask(0, 0, 0);}" },
        .{ .HAVE_PWRITE, "#include <unistd.h>\nint main(){pwrite(0, 0, 0, 0);}" },
        .{ .HAVE_PWRITEV, "#include <sys/uio.h>\nint main(){pwritev(0, 0, 0, 0);}" },
        .{ .HAVE_PWRITEV2, "#include <sys/uio.h>\nint main(){pwritev2(0, 0, 0, 0, 0);}" },
        .{ .HAVE_READLINK, "#include <unistd.h>\nint main(){readlink(0, 0, 0);}" },
        .{ .HAVE_READLINKAT, "#include <unistd.h>\nint main(){readlinkat(0, 0, 0, 0);}" },
        .{ .HAVE_READV, "#include <sys/uio.h>\nint main(){readv(0, 0, 0);}" },
        .{ .HAVE_REALPATH, "#include <stdlib.h>\nint main(){realpath(0, 0);}" },
        .{ .HAVE_RECVFROM, "#include <sys/socket.h>\nint main(){recvfrom(0, 0, 0, 0, 0, 0);}" },
        .{ .HAVE_RENAMEAT, "#include <stdio.h>\nint main(){renameat(0, 0, 0, 0);}" },
        .{ .HAVE_SCHED_GET_PRIORITY_MAX, "#include <sched.h>\nint main(){sched_get_priority_max(0);}" },
        .{ .HAVE_SCHED_RR_GET_INTERVAL, "#include <sched.h>\nint main(){struct timespec ts; sched_rr_get_interval(0, &ts);}" },
        .{ .HAVE_SCHED_SETAFFINITY, "#define _GNU_SOURCE\n#include <sched.h>\nint main(){sched_setaffinity(0, 0, 0);}" },
        .{ .HAVE_SCHED_SETPARAM, "#include <sched.h>\nint main(){struct sched_param sp; sched_setparam(0, &sp);}" },
        .{ .HAVE_SCHED_SETSCHEDULER, "#include <sched.h>\nint main(){struct sched_param sp; sched_setscheduler(0, 0, &sp);}" },
        .{ .HAVE_SEM_CLOCKWAIT, "#include <semaphore.h>\nint main(){sem_clockwait(0, 0, 0);}" },
        .{ .HAVE_SEM_GETVALUE, "#include <semaphore.h>\nint main(){sem_getvalue(0, 0);}" },
        .{ .HAVE_SEM_OPEN, "#include <semaphore.h>\nint main(){sem_open(0, 0);}" },
        .{ .HAVE_SEM_TIMEDWAIT, "#include <semaphore.h>\nint main(){sem_timedwait(0, 0);}" },
        .{ .HAVE_SEM_UNLINK, "#include <semaphore.h>\nint main(){sem_unlink(0);}" },
        .{ .HAVE_SENDFILE, "#include <sys/sendfile.h>\nint main(){sendfile(0, 0, 0, 0);}" },
        .{ .HAVE_SENDTO, "#include <sys/socket.h>\nint main(){sendto(0, 0, 0, 0, 0, 0);}" },
        .{ .HAVE_SETEGID, "#include <unistd.h>\nint main(){setegid(0);}" },
        .{ .HAVE_SETEUID, "#include <unistd.h>\nint main(){seteuid(0);}" },
        .{ .HAVE_SETGID, "#include <unistd.h>\nint main(){setgid(0);}" },
        .{ .HAVE_SETGROUPS, "#include <grp.h>\nint main(){setgroups(0, 0);}" },
        .{ .HAVE_SETHOSTNAME, "#include <unistd.h>\nint main(){sethostname(0, 0);}" },
        .{ .HAVE_SETITIMER, "#include <sys/time.h>\nint main(){struct itimerval it; setitimer(0, &it, 0);}" },
        .{ .HAVE_SETLOCALE, "#include <locale.h>\nint main(){setlocale(0, 0);}" },
        .{ .HAVE_SETPGID, "#include <unistd.h>\nint main(){setpgid(0, 0);}" },
        .{ .HAVE_SETPGRP, "#include <unistd.h>\nint main(){setpgrp();}" },
        .{ .HAVE_SETPRIORITY, "#include <sys/resource.h>\nint main(){setpriority(0, 0, 0);}" },
        .{ .HAVE_SETREGID, "#include <unistd.h>\nint main(){setregid(0, 0);}" },
        .{ .HAVE_SETRESGID, "#include <unistd.h>\nint main(){setresgid(0, 0, 0);}" },
        .{ .HAVE_SETRESUID, "#define _GNU_SOURCE\n#include <unistd.h>\nint main(){setresuid(0, 0, 0);}" },
        .{ .HAVE_SETREUID, "#include <unistd.h>\nint main(){setreuid(0, 0);}" },
        .{ .HAVE_SETSID, "#include <unistd.h>\nint main(){setsid();}" },
        .{ .HAVE_SETSOCKOPT, "#include <sys/socket.h>\nint main(){setsockopt(0, 0, 0, 0, 0);}" },
        .{ .HAVE_SETUID, "#include <unistd.h>\nint main(){setuid(0);}" },
        .{ .HAVE_SETVBUF, "#include <stdio.h>\nint main(){setvbuf(0, 0, 0, 0);}" },
        .{ .HAVE_SHM_OPEN, "#include <sys/mman.h>\nint main(){shm_open(0, 0, 0);}" },
        .{ .HAVE_SHM_UNLINK, "#include <sys/mman.h>\nint main(){shm_unlink(0);}" },
        .{ .HAVE_SHUTDOWN, "#include <sys/socket.h>\nint main(){shutdown(0, 0);}" },
        .{ .HAVE_SIGACTION, "#include <signal.h>\nint main(){struct sigaction sa; sigaction(0, &sa, 0);}" },
        .{ .HAVE_SIGALTSTACK, "#include <signal.h>\nint main(){sigaltstack(0, 0);}" },
        .{ .HAVE_SIGFILLSET, "#include <signal.h>\nint main(){sigset_t set; sigfillset(&set);}" },
        .{ .HAVE_SIGINTERRUPT, "#include <signal.h>\nint main(){siginterrupt(0, 0);}" },
        .{ .HAVE_SIGPENDING, "#include <signal.h>\nint main(){sigset_t set; sigpending(&set);}" },
        .{ .HAVE_SIGRELSE, "#include <signal.h>\nint main(){sigrelse(0);}" },
        .{ .HAVE_SIGTIMEDWAIT, "#include <signal.h>\nint main(){sigset_t set; sigtimedwait(&set, 0, 0);}" },
        .{ .HAVE_SIGWAIT, "#include <signal.h>\nint main(){sigset_t set; sigwait(&set, 0);}" },
        .{ .HAVE_SIGWAITINFO, "#include <signal.h>\nint main(){sigset_t set; sigwaitinfo(&set, 0);}" },
        .{ .HAVE_SNPRINTF, "#include <stdio.h>\nint main(){snprintf(0, 0, 0);}" },
        .{ .HAVE_SOCKET, "#include <sys/socket.h>\nint main(){socket(0, 0, 0);}" },
        .{ .HAVE_SOCKETPAIR, "#include <sys/socket.h>\nint main(){int sv[2]; socketpair(0, 0, 0, sv);}" },
        .{ .HAVE_SPLICE, "#define _GNU_SOURCE\n#include <fcntl.h>\nint main(){splice(0, 0, 0, 0, 0, 0);}" },
        .{ .HAVE_STATVFS, "#include <sys/statvfs.h>\nint main(){struct statvfs st; statvfs(0, &st);}" },
        .{ .HAVE_STRFTIME, "#include <time.h>\nint main(){struct tm tm; strftime(0, 0, 0, &tm);}" },
        .{ .HAVE_STRSIGNAL, "#include <string.h>\nint main(){strsignal(0);}" },
        .{ .HAVE_SYMLINK, "#include <unistd.h>\nint main(){symlink(0, 0);}" },
        .{ .HAVE_SYMLINKAT, "#include <unistd.h>\nint main(){symlinkat(0, 0, 0);}" },
        .{ .HAVE_SYNC, "#include <unistd.h>\nint main(){sync();}" },
        .{ .HAVE_SYSCONF, "#include <unistd.h>\nint main(){sysconf(0);}" },
        .{ .HAVE_SYSTEM, "#include <stdlib.h>\nint main(){system(0);}" },
        .{ .HAVE_TCGETPGRP, "#include <unistd.h>\nint main(){tcgetpgrp(0);}" },
        .{ .HAVE_TCSETPGRP, "#include <unistd.h>\nint main(){tcsetpgrp(0, 0);}" },
        .{ .HAVE_TEMPNAM, "#include <stdio.h>\nint main(){tempnam(0, 0);}" },
        .{ .HAVE_TIMEGM, "#include <time.h>\nint main(){struct tm tm; timegm(&tm);}" },
        .{ .HAVE_TIMES, "#include <sys/times.h>\nint main(){struct tms tms; times(&tms);}" },
        .{ .HAVE_TMPFILE, "#include <stdio.h>\nint main(){tmpfile();}" },
        .{ .HAVE_TMPNAM, "#include <stdio.h>\nint main(){tmpnam(0);}" },
        .{ .HAVE_TMPNAM_R, "#include <stdio.h>\nint main(){tmpnam_r(0);}" },
        .{ .HAVE_TRUNCATE, "#include <unistd.h>\nint main(){truncate(0, 0);}" },
        .{ .HAVE_TTYNAME, "#include <unistd.h>\nint main(){ttyname(0);}" },
        .{ .HAVE_UMASK, "#include <sys/stat.h>\nint main(){umask(0);}" },
        .{ .HAVE_UNAME, "#include <sys/utsname.h>\nint main(){struct utsname uts; uname(&uts);}" },
        .{ .HAVE_UNLINKAT, "#include <unistd.h>\nint main(){unlinkat(0, 0, 0);}" },
        .{ .HAVE_UTIMENSAT, "#include <sys/stat.h>\nint main(){utimensat(0, 0, 0, 0);}" },
        .{ .HAVE_UTIMES, "#include <sys/time.h>\nint main(){utimes(0, 0);}" },
        .{ .HAVE_VFORK, "#include <unistd.h>\nint main(){vfork();}" },
        .{ .HAVE_WAIT, "#include <sys/wait.h>\nint main(){wait(0);}" },
        .{ .HAVE_WAIT3, "#include <sys/wait.h>\nint main(){wait3(0, 0, 0);}" },
        .{ .HAVE_WAIT4, "#include <sys/wait.h>\nint main(){wait4(0, 0, 0, 0);}" },
        .{ .HAVE_WAITID, "#include <sys/wait.h>\nint main(){waitid(0, 0, 0, 0);}" },
        .{ .HAVE_WAITPID, "#include <sys/wait.h>\nint main(){waitpid(0, 0, 0);}" },
        .{ .HAVE_WCSCOLL, "#include <wchar.h>\nint main(){wcscoll(0, 0);}" },
        .{ .HAVE_WCSFTIME, "#include <wchar.h>\nint main(){wcsftime(0, 0, 0, 0);}" },
        .{ .HAVE_WCSXFRM, "#include <wchar.h>\nint main(){wcsxfrm(0, 0, 0);}" },
        .{ .HAVE_WMEMCMP, "#include <wchar.h>\nint main(){wmemcmp(0, 0, 0);}" },
        .{ .HAVE_WRITEV, "#include <sys/uio.h>\nint main(){writev(0, 0, 0);}" },
        .{ .HAVE_UUID_CREATE, "#include <uuid.h>\nint main(){uuid_create(0,0);}" },
        // BSD/macOS specific functions
        .{ .HAVE_CHFLAGS, "#include <sys/stat.h>\nint main(){chflags(0, 0);}" },
        .{ .HAVE_LCHFLAGS, "#include <sys/stat.h>\nint main(){lchflags(0, 0);}" },
        .{ .HAVE_LCHMOD, "#include <sys/stat.h>\nint main(){lchmod(0, 0);}" },
        .{ .HAVE_KQUEUE, "#include <sys/event.h>\nint main(){kqueue();}" },
        .{ .HAVE_FDWALK, "#include <fcntl.h>\nint main(){fdwalk(0, 0);}" },
        .{ .HAVE_FORK1, "#include <sys/types.h>\n#include<sys/proc.h>\nint main(){fork1();}" },
        .{ .HAVE_GETPGRP, "#include <unistd.h>\nint main(){getpgrp();}" },
        .{ .HAVE_PLOCK, "#include <sys/lock.h>\nint main(){plock(0);}" },
        .{ .HAVE_RTPSPAWN, "#include <spawn.h>\nint main(){rtpspawn(0, 0, 0, 0, 0, 0);}" },
        .{ .HAVE_STRLCPY, "#include <string.h>\nint main(){strlcpy(0, 0, 0);}" },
        .{ .HAVE__GETPTY, "#include <stdlib.h>\nint main(){_getpty(0, 0, 0, 0);}" },
        // Additional math functions
        .{ .HAVE_FSEEK64, "#include <stdio.h>\nint main(){fseek64(0, 0, 0);}" },
        .{ .HAVE_FTELL64, "#include <stdio.h>\nint main(){ftell64(0);}" },
        // Library functions
        .{ .HAVE_CRYPT_R, "#include <crypt.h>\nint main(){struct crypt_data cd; crypt_r(0, 0, &cd);}" },
        .{ .HAVE_CTERMID_R, "#include <stdio.h>\nint main(){ctermid_r(0, 0);}" },
        .{ .HAVE_EXPLICIT_MEMSET, "#include <string.h>\nint main(){explicit_memset(0, 0, 0);}" },
        // UUID functions
        .{ .HAVE_UUID_ENC_BE, "#include <uuid.h>\nint main(){uuid_enc_be(0, 0);}" },
        .{ .HAVE_UUID_GENERATE_TIME_SAFE, "#include <uuid.h>\nint main(){uuid_generate_time_safe(0);}" },
        // Various other functions
        .{ .HAVE_DYLD_SHARED_CACHE_CONTAINS_PATH, "#include <mach-o/dyld.h>\nint main(){_dyld_shared_cache_contains_path(0);}" },
        // Curses functions
        .{ .HAVE_CURSES_FILTER, "#include <curses.h>\nint main(){filter();}" },
        .{ .HAVE_CURSES_HAS_KEY, "#include <curses.h>\nint main(){has_key(0);}" },
        .{ .HAVE_CURSES_IMMEDOK, "#include <curses.h>\nint main(){immedok(0, 0);}" },
        .{ .HAVE_CURSES_IS_PAD, "#include <curses.h>\nint main(){is_pad(0);}" },
        .{ .HAVE_CURSES_IS_TERM_RESIZED, "#include <curses.h>\nint main(){is_term_resized(0, 0);}" },
        .{ .HAVE_CURSES_RESIZETERM, "#include <curses.h>\nint main(){resizeterm(0, 0);}" },
        .{ .HAVE_CURSES_RESIZE_TERM, "#include <curses.h>\nint main(){resize_term(0, 0);}" },
        .{ .HAVE_CURSES_SYNCOK, "#include <curses.h>\nint main(){syncok(0, 0);}" },
        .{ .HAVE_CURSES_TYPEAHEAD, "#include <curses.h>\nint main(){typeahead(0);}" },
        .{ .HAVE_CURSES_USE_ENV, "#include <curses.h>\nint main(){use_env(0);}" },
        .{ .HAVE_CURSES_WCHGAT, "#include <curses.h>\nint main(){wchgat(0, 0, 0, 0, 0, 0);}" },
        // Readline functions
        .{ .HAVE_RL_APPEND_HISTORY, "#include <readline/history.h>\nint main(){append_history(0, 0);}" },
        .{ .HAVE_RL_CATCH_SIGNAL, "#include <readline/readline.h>\nint main(){rl_catch_signals = 0;}" },
        .{ .HAVE_RL_COMPLETION_MATCHES, "#include <readline/readline.h>\nint main(){rl_completion_matches(0, 0);}" },
        .{ .HAVE_RL_RESIZE_TERMINAL, "#include <readline/readline.h>\nint main(){rl_resize_terminal();}" },
        // Pthread functions
        .{ .HAVE_PTHREAD_CONDATTR_SETCLOCK, "#include <pthread.h>\nint main(){pthread_condattr_t attr; pthread_condattr_setclock(&attr, 0);}" },
        .{ .HAVE_PTHREAD_GETCPUCLOCKID, "#include <pthread.h>\nint main(){clockid_t clk; pthread_getcpuclockid(0, &clk);}" },
        // Header includes and type checks
        .{ .HAVE_ADDRINFO, "#include <netdb.h>\nint main(){struct addrinfo ai; return 0;}" },
        .{ .HAVE_ALIGNED_REQUIRED, "#include <stddef.h>\nint main(){char a[1]; return ((size_t)a) & 1;}" },
        .{ .HAVE_ALTZONE, "#include <time.h>\nint main(){return altzone;}" },

        // Broken function tests (these typically compile but have runtime issues)
        // .{ .HAVE_BROKEN_MBSTOWCS, "#include <stdlib.h>\n#include <wchar.h>\nint main(){return mbstowcs(NULL, \"test\", 0) == 0;}" },
        // .{ .HAVE_BROKEN_NICE, "#include <unistd.h>\nint main(){nice(1); return 0;}" },
        // .{ .HAVE_BROKEN_PIPE_BUF, "#include <limits.h>\nint main(){return PIPE_BUF;}" },
        // .{ .HAVE_BROKEN_POLL, "#include <poll.h>\nint main(){struct pollfd pfd; poll(&pfd, 1, 0); return 0;}" },
        // .{ .HAVE_BROKEN_POSIX_SEMAPHORES, "#include <semaphore.h>\nint main(){sem_t sem; return 0;}" },
        // .{ .HAVE_BROKEN_PTHREAD_SIGMASK, "#include <pthread.h>\n#include <signal.h>\nint main(){sigset_t set; pthread_sigmask(SIG_BLOCK, &set, NULL); return 0;}" },
        // .{ .HAVE_BROKEN_SEM_GETVALUE, "#include <semaphore.h>\nint main(){sem_t sem; int val; sem_getvalue(&sem, &val); return 0;}" },
        // .{ .HAVE_BROKEN_UNSETENV, "#include <stdlib.h>\nint main(){unsetenv(\"TEST\"); return 0;}" },

        // Compiler builtin features
        .{ .HAVE_BUILTIN_ATOMIC, "int main(){int x = 0; __atomic_store_n(&x, 1, __ATOMIC_SEQ_CST); return __atomic_load_n(&x, __ATOMIC_SEQ_CST);}" },
        .{ .HAVE_COMPUTED_GOTOS, "int main(){void *ptr = &&label; goto *ptr; label: return 0;}" },

        // RTLD declarations
        .{ .HAVE_DECL_RTLD_DEEPBIND, "#include <dlfcn.h>\nint main(){return RTLD_DEEPBIND;}" },
        .{ .HAVE_DECL_RTLD_GLOBAL, "#include <dlfcn.h>\nint main(){return RTLD_GLOBAL;}" },
        .{ .HAVE_DECL_RTLD_LAZY, "#include <dlfcn.h>\nint main(){return RTLD_LAZY;}" },
        .{ .HAVE_DECL_RTLD_LOCAL, "#include <dlfcn.h>\nint main(){return RTLD_LOCAL;}" },
        .{ .HAVE_DECL_RTLD_MEMBER, "#include <dlfcn.h>\nint main(){return RTLD_MEMBER;}" },
        .{ .HAVE_DECL_RTLD_NODELETE, "#include <dlfcn.h>\nint main(){return RTLD_NODELETE;}" },
        .{ .HAVE_DECL_RTLD_NOLOAD, "#include <dlfcn.h>\nint main(){return RTLD_NOLOAD;}" },
        .{ .HAVE_DECL_RTLD_NOW, "#include <dlfcn.h>\nint main(){return RTLD_NOW;}" },
        .{ .HAVE_DECL_TZNAME, "#include <time.h>\nint main(){return tzname[0] != NULL;}" },

        // Device and file system features
        .{ .HAVE_DEVICE_MACROS, "#include <sys/types.h>\n#include <sys/stat.h>\nint main(){dev_t d = 0; return major(d) | minor(d);}" },
        .{ .HAVE_DEV_PTC, "#include <fcntl.h>\nint main(){return open(\"/dev/ptc\", O_RDWR);}" },
        .{ .HAVE_DEV_PTMX, "#include <fcntl.h>\nint main(){return open(\"/dev/ptmx\", O_RDWR);}" },
        .{ .HAVE_DIRENT_D_TYPE, "#include <dirent.h>\nint main(){struct dirent d; return d.d_type;}" },
        .{ .HAVE_DIRFD, "#include <dirent.h>\nint main(){DIR *d = NULL; return dirfd(d);}" },

        // System features
        .{ .HAVE_DYNAMIC_LOADING, "#include <dlfcn.h>\nint main(){dlopen(\"test\", RTLD_NOW); return 0;}" },
        .{ .HAVE_EPOLL, "#include <sys/epoll.h>\nint main(){return epoll_create(1);}" },

        // GCC assembly features
        .{ .HAVE_GCC_ASM_FOR_MC68881, "int main(){unsigned int fpcr; __asm__(\"fmove.l %%fpcr,%0\" : \"=dm\" (fpcr)); return 0;}" },
        .{ .HAVE_GCC_ASM_FOR_X64, "int main(){unsigned long rax; __asm__(\"movq %%rax, %0\" : \"=r\" (rax)); return 0;}" },
        .{ .HAVE_GCC_ASM_FOR_X87, "int main(){unsigned int cw; __asm__(\"fnstcw %0\" : \"=m\" (cw)); return 0;}" },
        .{ .HAVE_GCC_UINT128_T, "int main(){__uint128_t x = 0; return (int)x;}" },

        // gethostbyname_r variants
        .{ .HAVE_GETHOSTBYNAME_R_3_ARG, "#include <netdb.h>\nint main(){struct hostent_data hed; gethostbyname_r(\"localhost\", NULL, &hed); return 0;}" },
        .{ .HAVE_GETHOSTBYNAME_R_5_ARG, "#include <netdb.h>\nint main(){struct hostent he; char buf[1024]; gethostbyname_r(\"localhost\", &he, buf, sizeof(buf), NULL); return 0;}" },
        .{ .HAVE_GETHOSTBYNAME_R_6_ARG, "#include <netdb.h>\nint main(){struct hostent he; char buf[1024]; struct hostent *result; int h_errno; gethostbyname_r(\"localhost\", &he, buf, sizeof(buf), &result, &h_errno); return 0;}" },

        // System calls and features
        .{ .HAVE_GETRANDOM_SYSCALL, "#include <sys/syscall.h>\n#include <unistd.h>\nint main(){return syscall(SYS_getrandom, NULL, 0, 0);}" },

        // Bug detection
        .{ .HAVE_GLIBC_MEMMOVE_BUG, "#include <string.h>\nint main(){char buf[10]; memmove(buf+1, buf, 5); return 0;}" },
        .{ .HAVE_IPA_PURE_CONST_BUG, "int main(){return 0;}" }, // Compiler-specific, hard to test

        // File and library support
        .{ .HAVE_LARGEFILE_SUPPORT, "#include <sys/types.h>\nint main(){off_t offset = 0; return sizeof(offset) > 4;}" },
        .{ .HAVE_LIBB2, "#include <blake2.h>\nint main(){blake2b_state state; return 0;}" },
        .{ .HAVE_LIBDB, "#include <db.h>\nint main(){DB *db; return 0;}" },
        .{ .HAVE_LIBDL, "#include <dlfcn.h>\nint main(){dlopen(\"test\", RTLD_NOW); return 0;}" },
        .{ .HAVE_LIBDLD, "int main(){return 0;}" }, // DLD library check
        .{ .HAVE_LIBGDBM_COMPAT, "#include <gdbm.h>\nint main(){GDBM_FILE gf; return 0;}" },
        .{ .HAVE_LIBIEEE, "int main(){return 0;}" }, // IEEE math library
        .{ .HAVE_LIBNDBM, "#include <ndbm.h>\nint main(){DBM *db; return 0;}" },
        .{ .HAVE_LIBREADLINE, "#include <readline/readline.h>\nint main(){readline(\"prompt\"); return 0;}" },
        .{ .HAVE_LIBRESOLV, "#include <resolv.h>\nint main(){res_init(); return 0;}" },
        .{ .HAVE_LIBSENDFILE, "#include <sys/sendfile.h>\nint main(){sendfile(0, 0, NULL, 0); return 0;}" },
        .{ .HAVE_LIBSQLITE3, "#include <sqlite3.h>\nint main(){sqlite3 *db; return 0;}" },

        // Linux-specific headers
        .{ .HAVE_LINUX_AUXVEC_H, "#include <linux/auxvec.h>\nint main(){return AT_NULL;}" },
        .{ .HAVE_LINUX_CAN_BCM_H, "#include <linux/can/bcm.h>\nint main(){struct bcm_msg_head msg; return 0;}" },
        .{ .HAVE_LINUX_CAN_H, "#include <linux/can.h>\nint main(){struct can_frame frame; return 0;}" },
        .{ .HAVE_LINUX_CAN_J1939_H, "#include <linux/can/j1939.h>\nint main(){return J1939_MAX_UNICAST_ADDR;}" },
        .{ .HAVE_LINUX_CAN_RAW_FD_FRAMES, "#include <linux/can/raw.h>\nint main(){return CAN_RAW_FD_FRAMES;}" },
        .{ .HAVE_LINUX_CAN_RAW_H, "#include <linux/can/raw.h>\nint main(){return CAN_RAW_FILTER;}" },
        .{ .HAVE_LINUX_CAN_RAW_JOIN_FILTERS, "#include <linux/can/raw.h>\nint main(){return CAN_RAW_JOIN_FILTERS;}" },
        .{ .HAVE_LINUX_MEMFD_H, "#include <linux/memfd.h>\nint main(){return MFD_CLOEXEC;}" },
        .{ .HAVE_LINUX_NETLINK_H, "#include <linux/netlink.h>\nint main(){struct nlmsghdr nlh; return 0;}" },
        .{ .HAVE_LINUX_QRTR_H, "#include <linux/qrtr.h>\nint main(){struct sockaddr_qrtr sq; return 0;}" },
        .{ .HAVE_LINUX_RANDOM_H, "#include <linux/random.h>\nint main(){return GRND_NONBLOCK;}" },
        .{ .HAVE_LINUX_SOUNDCARD_H, "#include <linux/soundcard.h>\nint main(){return SOUND_VERSION;}" },
        .{ .HAVE_LINUX_TIPC_H, "#include <linux/tipc.h>\nint main(){struct sockaddr_tipc addr; return 0;}" },
        .{ .HAVE_LINUX_VM_SOCKETS_H, "#include <linux/vm_sockets.h>\nint main(){return VMADDR_CID_ANY;}" },
        .{ .HAVE_LINUX_WAIT_H, "#include <linux/wait.h>\nint main(){return 0;}" },

        // Type support
        .{ .HAVE_LONG_DOUBLE, "int main(){long double x = 0.0L; return (int)x;}" },
        // .{ .HAVE_NON_UNICODE_WCHAR_T_REPRESENTATION, "#include <wchar.h>\nint main(){wchar_t w = L'\\x80'; return (int)w;}" },
        .{ .HAVE_PROTOTYPES, "int test(int x); int main(){return test(0);} int test(int x){return x;}" },

        // pthread features
        .{ .HAVE_PTHREAD_DESTRUCTOR, "#include <pthread.h>\nvoid destructor(void *); int main(){pthread_key_create(NULL, destructor); return 0;} void destructor(void *p){}" },
        .{ .HAVE_PTHREAD_INIT, "#include <pthread.h>\nint main(){pthread_init(); return 0;}" },
        // .{ .HAVE_PTHREAD_STUBS, "#include <pthread.h>\nint main(){pthread_mutex_t m = PTHREAD_MUTEX_INITIALIZER; return 0;}" },

        // Readline features
        .{ .HAVE_RL_COMPLETION_APPEND_CHARACTER, "#include <readline/readline.h>\nint main(){rl_completion_append_character = ' '; return 0;}" },
        .{ .HAVE_RL_COMPLETION_DISPLAY_MATCHES_HOOK, "#include <readline/readline.h>\nint main(){rl_completion_display_matches_hook = NULL; return 0;}" },
        .{ .HAVE_RL_COMPLETION_SUPPRESS_APPEND, "#include <readline/readline.h>\nint main(){rl_completion_suppress_append = 1; return 0;}" },
        .{ .HAVE_RL_PRE_INPUT_HOOK, "#include <readline/readline.h>\nint main(){rl_pre_input_hook = NULL; return 0;}" },

        // Signal and socket features
        .{ .HAVE_SIGINFO_T_SI_BAND, "#include <signal.h>\nint main(){siginfo_t si; return si.si_band;}" },
        .{ .HAVE_SOCKADDR_ALG, "#include <linux/if_alg.h>\nint main(){struct sockaddr_alg sa; return 0;}" },
        .{ .HAVE_SOCKADDR_SA_LEN, "#include <sys/socket.h>\nint main(){struct sockaddr sa; return sa.sa_len;}" },
        .{ .HAVE_SOCKADDR_STORAGE, "#include <sys/socket.h>\nint main(){struct sockaddr_storage ss; return 0;}" },

        // Type definitions
        .{ .HAVE_SSIZE_T, "#include <sys/types.h>\nint main(){ssize_t s = 0; return (int)s;}" },
        .{ .HAVE_STAT_TV_NSEC, "#include <sys/stat.h>\nint main(){struct stat st; return st.st_mtim.tv_nsec;}" },
        .{ .HAVE_STAT_TV_NSEC2, "#include <sys/stat.h>\nint main(){struct stat st; return st.st_mtimensec;}" },
        .{ .HAVE_STDARG_PROTOTYPES, "#include <stdarg.h>\nvoid test(int x, ...); int main(){test(1, 2); return 0;} void test(int x, ...){va_list ap; va_start(ap, x); va_end(ap);}" },
        .{ .HAVE_STD_ATOMIC, "#include <stdatomic.h>\nint main(){atomic_int x; atomic_uintptr_t y; return 0;}" },

        // Struct member checks
        .{ .HAVE_STRUCT_PASSWD_PW_GECOS, "#include <pwd.h>\nint main(){struct passwd pw; return pw.pw_gecos != NULL;}" },
        .{ .HAVE_STRUCT_PASSWD_PW_PASSWD, "#include <pwd.h>\nint main(){struct passwd pw; return pw.pw_passwd != NULL;}" },
        .{ .HAVE_STRUCT_STAT_ST_BIRTHTIME, "#include <sys/stat.h>\nint main(){struct stat st; return st.st_birthtime;}" },
        .{ .HAVE_STRUCT_STAT_ST_BLKSIZE, "#include <sys/stat.h>\nint main(){struct stat st; return st.st_blksize;}" },
        .{ .HAVE_STRUCT_STAT_ST_BLOCKS, "#include <sys/stat.h>\nint main(){struct stat st; return st.st_blocks;}" },
        .{ .HAVE_STRUCT_STAT_ST_FLAGS, "#include <sys/stat.h>\nint main(){struct stat st; return st.st_flags;}" },
        .{ .HAVE_STRUCT_STAT_ST_GEN, "#include <sys/stat.h>\nint main(){struct stat st; return st.st_gen;}" },
        .{ .HAVE_STRUCT_STAT_ST_RDEV, "#include <sys/stat.h>\nint main(){struct stat st; return st.st_rdev;}" },
        .{ .HAVE_STRUCT_TM_TM_ZONE, "#include <time.h>\nint main(){struct tm t; return t.tm_zone != NULL;}" },

        // Time and timezone features
        .{ .HAVE_TM_ZONE, "#include <time.h>\nint main(){struct tm t; return t.tm_zone != NULL;}" },
        .{ .HAVE_TZNAME, "#include <time.h>\nint main(){return tzname[0] != NULL;}" },
        // .{ .HAVE_USABLE_WCHAR_T, "#include <wchar.h>\nint main(){wchar_t w = L'A'; return sizeof(w) >= 2;}" },
        .{ .HAVE_WORKING_TZSET, "#include <time.h>\nint main(){tzset(); return 0;}" },
        .{ .HAVE_ZLIB_COPY, "#include <zlib.h>\nint main(){z_stream strm; inflateCopy(&strm, &strm); return 0;}" },
    };

    {
        const AddValues = struct {
            step: std.Build.Step,
            config_header: *std.Build.Step.ConfigHeader,
            header_checks: [header_configs.len]*CompileCheck,
            exe_checks: [exe_configs.len]*CompileCheck,
        };
        const add_values_make = struct {
            fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
                _ = options;
                const self: *AddValues = @fieldParentPtr("step", step);
                inline for (header_configs, self.header_checks) |header_config, header_check| {
                    self.config_header.addValue(@tagName(header_config[0]), ?u1, header_check.haveHeader(step));
                }
                inline for (exe_configs, self.exe_checks) |exe_config, header_check| {
                    self.config_header.addValue(@tagName(exe_config[0]), ?u1, try header_check.compiled(step, .{}));
                }
            }
        }.make;
        const add_values = b.allocator.create(AddValues) catch @panic("OOM");
        add_values.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "add dynamic values to pyconfig header",
                .owner = b,
                .makeFn = &add_values_make,
            }),
            .config_header = config_header,
            .header_checks = undefined,
            .exe_checks = undefined,
        };
        inline for (header_configs, &add_values.header_checks) |header_config, *check| {
            check.* = CompileCheck.create(b, target, .{ .header = header_config[1] });
            if (libs.zlib) |zlib| check.*.linkLibrary(zlib);
            if (libs.openssl) |openssl| check.*.linkLibrary(openssl);
            add_values.step.dependOn(&check.*.step);
        }
        inline for (exe_configs, &add_values.exe_checks) |exe_config, *check| {
            check.* = CompileCheck.create(b, target, .{ .exe = exe_config[1] });
            if (libs.zlib) |zlib| check.*.linkLibrary(zlib);
            if (libs.openssl) |openssl| check.*.linkLibrary(openssl);
            add_values.step.dependOn(&check.*.step);
        }
        config_header.step.dependOn(&add_values.step);
    }

    return .{
        .libs = libs,
        .header = .{ .config_header = config_header },
    };
}

fn have(x: bool) ?u1 {
    return if (x) 1 else null;
}

const python_src = [_][]const u8{
    "Python/_warnings.c",
    "Python/Python-ast.c",
    "Python/Python-tokenize.c",
    "Python/asdl.c",
    "Python/ast.c",
    "Python/ast_opt.c",
    "Python/ast_unparse.c",
    "Python/bltinmodule.c",
    "Python/ceval.c",
    "Python/codecs.c",
    "Python/compile.c",
    "Python/context.c",
    "Python/dynamic_annotations.c",
    "Python/errors.c",
    "Python/frame.c",
    "Python/frozenmain.c",
    "Python/future.c",
    "Python/getargs.c",
    "Python/getcompiler.c",
    "Python/getcopyright.c",
    "Python/getplatform.c",
    "Python/getversion.c",
    "Python/hamt.c",
    "Python/hashtable.c",
    "Python/import.c",
    "Python/importdl.c",
    "Python/initconfig.c",
    "Python/marshal.c",
    "Python/modsupport.c",
    "Python/mysnprintf.c",
    "Python/mystrtoul.c",
    "Python/pathconfig.c",
    "Python/preconfig.c",
    "Python/pyarena.c",
    "Python/pyctype.c",
    "Python/pyfpe.c",
    "Python/pyhash.c",
    "Python/pylifecycle.c",
    "Python/pymath.c",
    "Python/pystate.c",
    "Python/pythonrun.c",
    "Python/pytime.c",
    "Python/bootstrap_hash.c",
    "Python/specialize.c",
    "Python/structmember.c",
    "Python/symtable.c",
    "Python/sysmodule.c",
    "Python/thread.c",
    "Python/traceback.c",
    "Python/getopt.c",
    "Python/pystrcmp.c",
    "Python/pystrtod.c",
    "Python/pystrhex.c",
    "Python/dtoa.c",
    "Python/formatter_unicode.c",
    "Python/fileutils.c",
    "Python/suggestions.c",
    // Python/$(DYNLOADFILE) \
    // $(LIBOBJS) \
    // $(MACHDEP_OBJS) \
    // $(DTRACE_OBJS) \
    // @PLATFORM_OBJS@
};

const object_src = [_][]const u8{
    "Objects/abstract.c",
    "Objects/accu.c",
    "Objects/boolobject.c",
    "Objects/bytes_methods.c",
    "Objects/bytearrayobject.c",
    "Objects/bytesobject.c",
    "Objects/call.c",
    "Objects/capsule.c",
    "Objects/cellobject.c",
    "Objects/classobject.c",
    "Objects/codeobject.c",
    "Objects/complexobject.c",
    "Objects/descrobject.c",
    "Objects/enumobject.c",
    "Objects/exceptions.c",
    "Objects/genericaliasobject.c",
    "Objects/genobject.c",
    "Objects/fileobject.c",
    "Objects/floatobject.c",
    "Objects/frameobject.c",
    "Objects/funcobject.c",
    "Objects/interpreteridobject.c",
    "Objects/iterobject.c",
    "Objects/listobject.c",
    "Objects/longobject.c",
    "Objects/dictobject.c",
    "Objects/odictobject.c",
    "Objects/memoryobject.c",
    "Objects/methodobject.c",
    "Objects/moduleobject.c",
    "Objects/namespaceobject.c",
    "Objects/object.c",
    "Objects/obmalloc.c",
    "Objects/picklebufobject.c",
    "Objects/rangeobject.c",
    "Objects/setobject.c",
    "Objects/sliceobject.c",
    "Objects/structseq.c",
    "Objects/tupleobject.c",
    "Objects/typeobject.c",
    "Objects/unicodeobject.c",
    "Objects/unicodectype.c",
    "Objects/unionobject.c",
    "Objects/weakrefobject.c",
};

const parser_src = [_][]const u8{
    // PEGEN_OBJS
    "Parser/pegen.c",
    "Parser/pegen_errors.c",
    "Parser/action_helpers.c",
    "Parser/parser.c",
    "Parser/string_parser.c",
    "Parser/peg_api.c",

    // POBJS
    "Parser/token.c",

    //
    "Parser/myreadline.c",
    "Parser/tokenizer.c",
};

const module_src = [_][]const u8{
    "Modules/main.c",
    "Modules/gcmodule.c",
};

const frozen_modules = [_][]const u8{
    "Lib/importlib/_bootstrap.py",
    "Lib/importlib/_bootstrap_external.py",
    "Lib/zipimport.py",
    "Lib/abc.py",
    "Lib/codecs.py",
    "Lib/io.py",
    "Lib/_collections_abc.py",
    "Lib/_sitebuiltins.py",
    "Lib/genericpath.py",
    "Lib/ntpath.py",
    "Lib/posixpath.py",
    "Lib/os.py",
    "Lib/site.py",
    "Lib/stat.py",
    "Lib/importlib/util.py",
    "Lib/importlib/machinery.py",
    "Lib/runpy.py",
    "Lib/__hello__.py",
    "Lib/__phello__/__init__.py",
    "Lib/__phello__/ham/__init__.py",
    "Lib/__phello__/ham/eggs.py",
    "Lib/__phello__/spam.py",
    "Tools/freeze/flag.py",
};

const frozen_module_names: [frozen_modules.len][]const u8 = blk_names: {
    var names: [frozen_modules.len][]const u8 = undefined;
    for (&names, frozen_modules) |*name_ref, path| {
        if (std.mem.eql(u8, "Tools/freeze/flag.py", path)) {
            name_ref.* = "frozen_only";
            continue;
        }

        const name = blk_name: {
            const path_prefix = "Lib/";
            const path_suffix = blk: {
                const init_suffix = "/__init__.py";
                if (std.mem.endsWith(u8, path, init_suffix)) break :blk init_suffix;
                break :blk ".py";
            };
            var name_buf: [path.len - path_prefix.len - path_suffix.len]u8 = undefined;
            for (&name_buf, path[path_prefix.len..][0..name_buf.len]) |*name_char, path_char| {
                name_char.* = switch (path_char) {
                    '/' => '_',
                    else => |c| c,
                };
            }
            break :blk_name name_buf;
        };
        name_ref.* = &name;
    }
    break :blk_names names;
};

fn ci(
    b: *std.Build,
    ssl_enabled: bool,
    upstream: *std.Build.Dependency,
    ci_step: *std.Build.Step,
    args: struct {
        replace_exe: *std.Build.Step.Compile,
        makesetup_exe: *std.Build.Step.Compile,
        stage2_frozen_mods: Stage2FrozenMods,
        deepfreeze_c: std.Build.LazyPath,
    },
) !void {
    const CiTarget = struct { triple: []const u8, ssl: bool };
    const ci_targets = [_]CiTarget{
        // .{ .triple = "x86_64-windows", .ssl = false },
        // .{ .triple = "aarch64-windows", .ssl = true },
        // .{ .triple = "x86-windows", .ssl = true },

        .{ .triple = "x86_64-macos", .ssl = false },
        .{ .triple = "aarch64-macos", .ssl = false },

        .{ .triple = "x86_64-linux-musl", .ssl = true },
        .{ .triple = "x86_64-linux-gnu", .ssl = true },
        .{ .triple = "aarch64-linux-musl", .ssl = false },
        .{ .triple = "aarch64-linux-gnu", .ssl = false },
        // .{ .triple = "arm-linux-musl", .ssl = true }, // zlib doesn't build
        .{ .triple = "riscv64-linux-musl", .ssl = false },
        .{ .triple = "powerpc64le-linux-musl", .ssl = false },
        // .{ .triple = "x86-linux-musl", .ssl = false },
        // .{ .triple = "x86-linux-gnu", .ssl = false },
        .{ .triple = "s390x-linux-musl", .ssl = false },
    };

    for (ci_targets) |ci_target| {
        const target = b.resolveTargetQuery(try std.Target.Query.parse(
            .{ .arch_os_abi = ci_target.triple },
        ));
        const optimize: std.builtin.OptimizeMode = .ReleaseFast;
        const target_dest_dir: std.Build.InstallDir = .{ .custom = ci_target.triple };
        const install = b.step(b.fmt("install-{s}", .{ci_target.triple}), "");
        ci_step.dependOn(install);

        const libs: Libs = .{
            .zlib = (b.dependency("zlib", .{
                .target = target,
                .optimize = optimize,
            })).artifact("z"),
            .openssl = if (ssl_enabled and ci_target.ssl) (if (b.lazyDependency("openssl", .{
                .target = target,
                .optimize = optimize,
            })) |dep| dep.artifact("openssl") else null) else null,
        };
        const makesetup = addMakesetup(b, upstream, libs, .{
            .os_tag = target.result.os.tag,
            .replace_exe = args.replace_exe,
            .makesetup_exe = args.makesetup_exe,
        });
        const exe = addPythonExe(b, upstream, target, optimize, .{
            .name = "python",
            .makesetup_out = makesetup,
            .pyconfig = try addPyconfig(b, upstream, target, libs),
            .stage = .{
                .final = .{
                    .stage2 = args.stage2_frozen_mods,
                    .deepfreeze_c = args.deepfreeze_c,
                },
            },
        });

        install.dependOn(
            &b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = target_dest_dir } }).step,
        );
    }
}

const std = @import("std");
const CompileCheck = @import("CompileCheck.zig");
