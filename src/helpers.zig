const externs = @import("externs.zig");
const constants = @import("constants.zig");

pub fn Sys_SetPath(path: [:0]const u16) void {
    externs.PySys_SetPath(path.ptr);
}

pub fn SetProgramName(name: [:0]const u8) void {
    externs.Py_SetProgramName(name.ptr);
}

pub fn CompileString(source: [:0]const u8, filename: [:0]const u8) ?*anyopaque {
    return externs.Py_CompileString(source.ptr, filename.ptr, constants.Py_file_input);
}

pub fn Marshal_WriteObjectToString(code: ?*anyopaque) ?*anyopaque {
    return externs.PyMarshal_WriteObjectToString(code, constants.Py_MARSHAL_VERSION);
}

pub fn Bytes_Size(code: ?*anyopaque) usize {
    return externs.PyBytes_Size(code);
}

pub fn Bytes_AsString(code: ?*anyopaque) ?[*:0]u8 {
    return externs.PyBytes_AsString(code);
}

pub fn PrintError() void {
    externs.PyErr_Print();

    // TODO: fetch and normalize here
}
