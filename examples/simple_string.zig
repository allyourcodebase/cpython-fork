const std = @import("std");
const py = @import("python");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    try py.helpers.Initialize(allocator);
    defer py.externs.Py_Finalize();

    py.externs.PyRun_SimpleString(
        \\from time import time,ctime
        \\print('Today is', ctime(time()))
    );
}
