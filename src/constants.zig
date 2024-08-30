pub const Py_file_input: c_int = 257;
pub const Py_MARSHAL_VERSION: c_int = 4;

const build_options = @import("build_options");

pub const LIB_PATH = build_options.lib_path;
