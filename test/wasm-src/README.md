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
