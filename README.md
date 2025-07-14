# cpython

Builds [cpython](https://github.com/python/cpython) with [Zig](https://ziglang.org/).

There are no system dependencies; the only thing required to build this package is [Zig](https://ziglang.org/).

Supports building a static python executable for linux with the musl abi (i.e. `zig build -Dtarget=x86_64-linux-musl`).
