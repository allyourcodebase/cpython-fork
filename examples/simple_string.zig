const std = @import("std");
const py = @import("python");

pub fn utf8ToUtf32Z(
    in: []const u8,
    allocator: std.mem.Allocator,
) ![:0]const u32 {
    var buffer = std.ArrayList(u32).init(allocator);
    for (in) |char| {
        try buffer.append(char);
    }
    return buffer.toOwnedSliceSentinel(0);
}

fn init_from_config(config: *py.types.PyConfig) !void {
    const status = py.externs.Py_InitializeFromConfig(config);

    // std.debug.print("END STATUS: {}\n", .{&status});

    if (py.externs.PyStatus_Exception(status)) {
        return error.Expection;
        // py.externs.Py_ExitStatusException(status);
    }
}

// https://github.com/Rexicon226/osmium/blob/e83ac667e006cf3a233c1868f76e57b155ba1739/src/frontend/Python.zig#L72
pub fn Initialize(
    allocator: std.mem.Allocator,
) !void {
    // _ = allocator;
    var config: py.types.PyConfig = undefined;
    py.externs.PyConfig_InitIsolatedConfig(&config);
    defer py.externs.PyConfig_Clear(&config);

    // py.externs.Py_SetProgramName("test");

    // mute some silly errors that probably do infact matter
    // config.pathconfig_warnings = 0;

    // config.program_name = @constCast(try utf8ToUtf32Z("test", allocator));

    var status = py.externs.PyConfig_SetBytesString(
        &config,
        &config.program_name,
        "./test",
    );

    if (py.externs.PyStatus_Exception(status)) {
        py.externs.Py_ExitStatusException(status);
    }

    // const lib_path = try allocator.dupeZ(u8, py.constants.LIB_PATH);

    // status = py.externs.PyConfig_SetBytesString(
    //     &config,
    //     &config.home,
    //     lib_path,
    // );

    // if (py.externs.PyStatus_Exception(status)) {
    //     py.externs.Py_ExitStatusException(status);
    // }

    // status = py.externs.PyConfig_SetBytesString(
    //     &config,
    //     &config.pythonpath_env,
    //     lib_path,
    // );

    // if (py.externs.PyStatus_Exception(status)) {
    //     py.externs.Py_ExitStatusException(status);
    // }

    // status = py.externs.PyConfig_Read(&config);
    // if (py.externs.PyStatus_Exception(status)) {
    //     py.externs.Py_ExitStatusException(status);
    // }

    std.debug.print("py.constants.LIB_PATH: {s}\n", .{py.constants.LIB_PATH});

    const utf32_path = try utf8ToUtf32Z(
        py.constants.LIB_PATH,
        allocator,
    );

    config.module_search_paths_set = 1;
    status = py.externs.PyWideStringList_Append(
        &config.module_search_paths,
        utf32_path.ptr,
    );

    if (py.externs.PyStatus_Exception(status)) {
        py.externs.Py_ExitStatusException(status);
    }

    std.debug.print("config: {}\n", .{config});
    try init_from_config(&config);
    // status = py.externs.Py_InitializeFromConfig(&config);

    // // std.debug.print("END STATUS: {}\n", .{&status});

    // if (py.externs.PyStatus_Exception(status)) {
    //     py.externs.Py_ExitStatusException(status);
    // }
    // needs to be a pointer discard because the stack protector gets overrun?
    // _ = &status;
    std.debug.print("END\n", .{});

    py.externs.PyConfig_Clear(&config);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    try Initialize(allocator);
    defer py.externs.Py_Finalize();

    std.debug.print("AFTER INIT\n", .{});

    py.externs.PyRun_SimpleString(
        \\from time import time,ctime
        \\print('Today is', ctime(time()))
    );

    // py.externs.PyRun_SimpleString("print('hi')");
}
