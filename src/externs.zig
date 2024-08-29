const types = @import("types.zig");

const PyConfig = types.PyConfig;
const PyPreConfig = types.PyPreConfig;
const PyStatus = types.PyStatus;
const PyWideStringList = types.PyWideStringList;
const wchar = types.wchar;

pub extern fn Py_PreInitialize(*const PyPreConfig) PyStatus;
pub extern fn PyPreConfig_InitPythonConfig(*PyPreConfig) void;
pub extern fn PyStatus_Exception(PyStatus) bool;
pub extern fn Py_ExitStatusException(PyStatus) noreturn;

pub extern fn Py_Initialize() void;
pub extern fn Py_Finalize() void;

pub extern fn PySys_SetPath([*:0]const wchar) void;

pub extern fn Py_DecRef(?*anyopaque) void;

pub extern fn Py_DecodeLocale([*:0]const u8, *usize) ?[*:0]u8;
pub extern fn PyConfig_SetBytesString(*PyConfig, *const [*:0]wchar, [*:0]const u8) PyStatus;
pub extern fn Py_SetProgramName([*:0]const u8) void;

pub extern fn Py_CompileString([*:0]const u8, [*:0]const u8, c_int) ?*anyopaque;
pub extern fn PyMarshal_WriteObjectToString(?*anyopaque, c_int) ?*anyopaque;
pub extern fn PyBytes_Size(?*anyopaque) usize;
pub extern fn PyBytes_AsString(?*anyopaque) ?[*:0]u8;

pub extern fn PyErr_Print() void;
pub extern fn PyErr_Fetch(?*anyopaque, ?*anyopaque, ?*anyopaque) void;
pub extern fn PyErr_NormalizeException(?*anyopaque, ?*anyopaque, ?*anyopaque) void;

pub extern fn PyConfig_InitPythonConfig(*PyConfig) void;
pub extern fn PyConfig_Clear(*PyConfig) void;
pub extern fn PyConfig_Read(*PyConfig) PyStatus;
pub extern fn Py_InitializeFromConfig(*PyConfig) PyStatus;

pub extern fn PyWideStringList_Append(*PyWideStringList, [*:0]const u32) PyStatus;
