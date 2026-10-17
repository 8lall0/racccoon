# wasm test programs (compiled)

Real programs, compiled from Zig to `wasm32-freestanding`, that run on
`/bin/wasm` (roadmap §4). They import the racccoon host module — not
WASI — so they map directly onto the interpreter's host calls.

`scripts/build.sh` compiles each `*.zig` here with `zig` if it's on
PATH, and falls back to the committed `*.wasm` next to it otherwise.
Regenerate + commit the `.wasm` after editing a source:

    zig build-exe fib.zig -target wasm32-freestanding -O ReleaseSmall \
        -fno-entry --export=_start && mv fib.wasm .

Current set:
- `fib.zig`   — `wasm fib.wasm [n]` → the n-th Fibonacci number (i64),
                default n=10. Loop + i64 arith + arg parsing.
- `upper.zig` — `wasm upper.wasm <text>` → the text upper-cased.
                arg / print_str + linear-memory read/write.

## WASI programs (C, wasm32-wasi)

Standard C, no racccoon-specific code, built by `scripts/build.sh` with
`zig cc -target wasm32-wasi -Os -Wl,-z,stack-size=262144` (fallback: the
committed `.wasm`). They exercise `/bin/wasm`'s `wasi_snapshot_preview1`
shim. Each self-checks: exit 0, or the number of the first failed check,
which is all the dev shell's `wasitest` looks at. They also build and pass
natively (`zig cc wasi_files.c && ./a.out`), which is how the checks
themselves were validated.

- `wasi_hello.c` — printf, argv (`a b`), environ (`WASITEST=hello`, set by
  wasitest), signed-byte loads/extends.
- `wasi_files.c` — fopen w/r/a/r+, fgets, fseek/ftell, stat, mkdir,
  readdir, rename, remove, rmdir, ENOENT/ENOTEMPTY. Needs a writable `tmp/`.
- `wasi_exit.c` — `exit(7)` must reach the shell as 7.
- `wasi_wc.c` — wc over stdin: `echo hi there | wasm wasi_wc.wasm` → `1 2 9`.
