# Deprecrated

This repo has been deprecated in favor of https://github.com/allyourcodebase/cpython

# CPython Zig Package

This is a fork of [CPython](https://www.python.org/), packaged for Zig.

Unnecessary files have been deleted, and the build system has been replaced
with `build.zig`. There are no system dependencies; the only thing required to
build this package is [Zig](https://ziglang.org/download/).

This builds a static executable, which can be then executed like this:
```
PYTHONPATH=Lib zig-out/bin/cpython
```

## Project Status

My personal use case is to run the latest
[ytdlp](https://github.com/yt-dlp/yt-dlp) releases. This package is capable of
doing that, however, there may be missing features beyond what is required for
this use case, such as missing C modules.

I have tested on x86_64-linux-gnu and x86_64-linux-musl but not any other
targets yet. Probably, other targets will need some work before they are
additionally supported.

Contributions to broaden the support status are welcome.
