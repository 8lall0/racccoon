#!/bin/bash
#
# Lua 5.4 for racccoon: the third_party/lua submodule (github.com/lua/lua,
# tag v5.4.7, unmodified) compiled to wasm32-wasi with zig's bundled
# wasi-libc, run on racccoon by /bin/wasm's WASI shim. Produces
# build/lua/lua.wasm; build.sh seeds it as /lib/lua.wasm plus the
# lib/lua/lua script as /bin/lua.
#
# Without zig or the submodule it uses the committed lib/lua/lua.wasm,
# and refreshes that fallback whenever it does build.
#
#   - lib/wasm/include/setjmp.h: racccoon's interpreter-assisted
#     setjmp/longjmp (wasi-libc's needs the wasm exception-handling
#     proposal). Lua's error handling (error/pcall) is built on it.
#   - lib/lua/racccoon_stubs.c: tmpfile() / system(), which wasi-libc
#     lacks (io.tmpfile and os.execute then fail cleanly).
#   - LUA_USE_C89: no POSIX popen/mkstemp/dlopen. lua_tmpnam stubbed.
#   - 256 KiB C stack: zig's 16 MiB default is over /bin/wasm's
#     linear-memory cap (user/bin/wasm.c3).

set -e
cd "$(dirname "$0")/.."

mkdir -p build/lua
SRC=third_party/lua
if command -v zig >/dev/null 2>&1 && [ -f "$SRC/lua.c" ]; then
  echo "==> Lua: compiling $SRC to wasm32-wasi..."
  files=$(ls "$SRC"/*.c | grep -v -E '/(ltests|onelua|luac)\.c$')
  zig cc -target wasm32-wasi -Os -Wl,-z,stack-size=262144 \
    -I lib/wasm/include \
    -DLUA_USE_C89 '-DLUA_TMPNAMBUFSIZE=32' '-Dlua_tmpnam(b,e)=(e=1)' \
    -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS \
    -lwasi-emulated-signal -lwasi-emulated-process-clocks \
    $files lib/lua/racccoon_stubs.c -o build/lua/lua.wasm
  cp build/lua/lua.wasm lib/lua/lua.wasm
else
  echo "==> Lua: no zig or no third_party/lua checkout — using the committed lib/lua/lua.wasm"
  cp lib/lua/lua.wasm build/lua/lua.wasm
fi
