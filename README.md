# CPython Zig Package

This is a fork of [CPython](https://www.python.org/), packaged for Zig.

Unnecessary files have been deleted, and the build system has been replaced
with `build.zig`. There are no system dependencies; the only thing required to
build this package is [Zig](https://ziglang.org/download/).

A static executable will be built when targeting musl (i.e. `x86_64-linux-musl`).

### Runtime Libraries

Python requires library files at runtime, it looks for them using a list of candidates
combined with the executable's filesystem path and environment variables, i.e.

- `<EXECUTABLE_PATH>/lib/python3.11`
- `<EXECUTABLE_PATH>/../lib/python3.11`
- `$PYTHONHOME/lib/python3.11`

The build will install them to `$libdir/python3.11` which cpython should find.

## Project Status

My personal use case is to run the latest
[ytdlp](https://github.com/yt-dlp/yt-dlp) releases. This package is capable of
doing that, however, there may be missing features beyond what is required for
this use case, such as missing C modules.

I have tested on x86_64-linux-gnu and x86_64-linux-musl but not any other
targets yet. Probably, other targets will need some work before they are
additionally supported.

Contributions to broaden the support status are welcome.
