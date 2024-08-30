const externs = @import("externs.zig");
const types = @import("types.zig");
const constants = @import("constants.zig");

const std = @import("std");

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

pub fn Initialize(
    allocator: std.mem.Allocator,
) !void {
    var config: types.PyConfig = undefined;
    externs.PyConfig_InitIsolatedConfig(&config);
    defer externs.PyConfig_Clear(&config);

    var status = externs.PyConfig_SetBytesString(
        &config,
        &config.program_name,
        "./test",
    );

    if (externs.PyStatus_Exception(status)) {
        externs.Py_ExitStatusException(status);
    }

    const utf32_path = try utf8ToUtf32Z(
        constants.LIB_PATH,
        allocator,
    );

    // need to set the search path to the python "Lib" folder
    // https://docs.python.org/3/c-api/init_config.html#python-path-configuration
    config.module_search_paths_set = 1;
    status = externs.PyWideStringList_Append(
        &config.module_search_paths,
        utf32_path.ptr,
    );

    if (externs.PyStatus_Exception(status)) {
        externs.Py_ExitStatusException(status);
    }

    status = externs.Py_InitializeFromConfig(&config);
    if (externs.PyStatus_Exception(status)) {
        externs.Py_ExitStatusException(status);
    }
}
