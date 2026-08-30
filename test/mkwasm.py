#!/usr/bin/env python3
# Emits the hand-built .wasm test fixtures for /bin/wasm (roadmap §4).
# There is no wat2wasm on the build host, so the module bytes are
# assembled here. Run: python3 test/mkwasm.py <outdir>  (default: build/wasm)
#
# Each fixture imports the racccoon host module ("racccoon") and is
# entered at an exported "_start" (no params, no result).

import sys, os, struct

def uleb(n):
    out = bytearray()
    while True:
        b = n & 0x7f
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)

def sleb(n):
    out = bytearray()
    more = True
    while more:
        b = n & 0x7f
        n >>= 7
        if (n == 0 and not (b & 0x40)) or (n == -1 and (b & 0x40)):
            more = False
        else:
            b |= 0x80
        out.append(b)
    return bytes(out)

def vec(items):
    return uleb(len(items)) + b"".join(items)

def section(sid, body):
    return bytes([sid]) + uleb(len(body)) + body

def name(s):
    b = s.encode()
    return uleb(len(b)) + b

I32, I64, F32, F64 = 0x7f, 0x7e, 0x7d, 0x7c

def functype(params, results):
    return b"\x60" + vec([bytes([t]) for t in params]) + vec([bytes([t]) for t in results])

def module(types, imports, funcs, exports, code, start=None, mem=None,
           globals_=None, table=None, elems=None, data=None):
    parts = [b"\x00asm", struct.pack("<I", 1)]
    if types:   parts.append(section(1, vec(types)))
    if imports: parts.append(section(2, vec(imports)))
    if funcs:   parts.append(section(3, vec([uleb(t) for t in funcs])))
    if table is not None: parts.append(section(4, vec([table])))
    if mem is not None:   parts.append(section(5, vec([mem])))
    if globals_: parts.append(section(6, vec(globals_)))
    if exports: parts.append(section(7, vec(exports)))
    if start is not None: parts.append(section(8, uleb(start)))
    if elems:   parts.append(section(9, vec(elems)))
    if code:    parts.append(section(10, vec(code)))
    if data:    parts.append(section(11, vec(data)))
    return b"".join(parts)

def import_func(mod, fld, typeidx):
    return name(mod) + name(fld) + b"\x00" + uleb(typeidx)

def export_func(nm, funcidx):
    return name(nm) + b"\x00" + uleb(funcidx)

def body(locals_decls, instrs):
    # locals_decls: list of (count, type)
    b = vec([uleb(c) + bytes([t]) for (c, t) in locals_decls]) + instrs + b"\x0b"
    return uleb(len(b)) + b

# opcode helpers
def i32c(n):  return b"\x41" + sleb(n)
def i64c(n):  return b"\x42" + sleb(n)
def call(n):  return b"\x10" + uleb(n)
LG = lambda n: b"\x20" + uleb(n)   # local.get
LS = lambda n: b"\x21" + uleb(n)   # local.set
I32_ADD, I32_SUB, I32_MUL = b"\x6a", b"\x6b", b"\x6c"
I32_LT_S, I32_GT_S, I32_EQ = b"\x48", b"\x4a", b"\x46"
DROP = b"\x1a"
# control
BLOCK = lambda bt: b"\x02" + bytes([bt])
LOOP  = lambda bt: b"\x03" + bytes([bt])
IF    = lambda bt: b"\x04" + bytes([bt])
ELSE, END = b"\x05", b"\x0b"
BR    = lambda d: b"\x0c" + uleb(d)
BR_IF = lambda d: b"\x0d" + uleb(d)
BT_VOID = 0x40

fixtures = {}

# --- add.wasm : print_i32(2 + 3) -> "5" ---------------------------------
# type 0: () -> ()      _start
# type 1: (i32) -> ()   racccoon.print_i32
# type 2: (i32,i32)->i32  add
t = [functype([], []), functype([I32], []), functype([I32, I32], [I32])]
imp = [import_func("racccoon", "print_i32", 1)]        # -> funcidx 0
fn  = [2, 0]                                            # funcidx 1: add, 2: _start
exp = [export_func("_start", 2)]
code = [
    body([], LG(0) + LG(1) + I32_ADD),                 # add
    body([], i32c(2) + i32c(3) + call(1) + call(0)),   # _start
]
fixtures["add.wasm"] = module(t, imp, fn, exp, code)

# --- loop.wasm : print_i32(sum 1..10) -> "55" --------------------------
# type 0: () -> ()
# type 1: (i32) -> ()
t = [functype([], []), functype([I32], [])]
imp = [import_func("racccoon", "print_i32", 1)]        # funcidx 0
fn  = [0]                                               # funcidx 1: _start
exp = [export_func("_start", 1)]
# locals: 0 = i (counter), 1 = acc
start_body = (
    i32c(1) + LS(0) +
    i32c(0) + LS(1) +
    BLOCK(BT_VOID) +
      LOOP(BT_VOID) +
        LG(0) + i32c(10) + I32_GT_S + BR_IF(1) +        # if i > 10 -> break outer
        LG(1) + LG(0) + I32_ADD + LS(1) +               # acc += i
        LG(0) + i32c(1) + I32_ADD + LS(0) +             # i += 1
        BR(0) +                                          # continue loop
      END +
    END +
    LG(1) + call(0)                                     # print_i32(acc)
)
code = [body([(2, I32)], start_body)]
fixtures["loop.wasm"] = module(t, imp, fn, exp, code)

def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "build/wasm"
    os.makedirs(outdir, exist_ok=True)
    for fn, data in fixtures.items():
        p = os.path.join(outdir, fn)
        with open(p, "wb") as f:
            f.write(data)
        print(f"{p}  ({len(data)} bytes)")

if __name__ == "__main__":
    main()
