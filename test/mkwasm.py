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

# --- mem.wasm : data seg + load/store/grow/compare -> "142" -----------
# type 0: () -> ()      _start
# type 1: (i32) -> ()   racccoon.print_i32
t = [functype([], []), functype([I32], [])]
imp = [import_func("racccoon", "print_i32", 1)]         # funcidx 0
fn  = [0]                                                # funcidx 1: _start
exp = [export_func("_start", 1)]
mem = b"\x00" + uleb(1)                                 # limits: flag 0, min 1 page
I32_LOAD  = lambda off: b"\x28\x02" + uleb(off)         # align=2
I32_STORE = lambda off: b"\x36\x02" + uleb(off)
# active data segment (mode 0) @ offset 0: bytes  0A 00 00 00  (= i32 10)
data = [uleb(0) + i32c(0) + END + uleb(4) + bytes([10, 0, 0, 0])]
# mem[0] starts at 10 (data seg). store 10+32 at mem[4]; grow +1;
# print load(mem[4]) + memory.size*50  = 42 + 2*50 = 142
start_body = (
    i32c(4) + i32c(0) + I32_LOAD(0) + i32c(32) + I32_ADD + I32_STORE(0) +
    i32c(1) + b"\x40\x00" + DROP +                      # memory.grow 1
    i32c(4) + I32_LOAD(0) +                             # 42
    b"\x3f\x00" + i32c(50) + I32_MUL +                  # memory.size(=2) * 50 = 100
    I32_ADD +                                            # 142
    call(0)
)
code = [body([], start_body)]
fixtures["mem.wasm"] = module(t, imp, fn, exp, code, mem=mem, data=data)


# --- fac.wasm : recursion + if/else -> fac(5) = "120" -----------------
# type 0: () -> ()        _start
# type 1: (i32) -> ()     racccoon.print_i32
# type 2: (i32) -> i32    fac
t = [functype([], []), functype([I32], []), functype([I32], [I32])]
imp = [import_func("racccoon", "print_i32", 1)]         # funcidx 0
fn  = [2, 0]                                             # funcidx 1: fac, 2: _start
exp = [export_func("_start", 2)]
I32_LE_S = b"\x4c"
fac_body = (
    LG(0) + i32c(1) + I32_LE_S +
    IF(I32) +
      i32c(1) +
    ELSE +
      LG(0) +
      LG(0) + i32c(1) + I32_SUB + call(1) +
      I32_MUL +
    END
)
start_body = i32c(5) + call(1) + call(0)
code = [body([], fac_body), body([], start_body)]
fixtures["fac.wasm"] = module(t, imp, fn, exp, code)


# --- echo.wasm : args + print_str + call_indirect -> "a b c\n" ---------
# type 0: () -> ()            _start
# type 1: () -> i32           racccoon.arg_count
# type 2: (i32,i32,i32)->i32  racccoon.arg
# type 3: (i32,i32) -> ()     racccoon.print_str  /  emit (table[0])
t = [functype([], []), functype([], [I32]),
     functype([I32, I32, I32], [I32]), functype([I32, I32], [])]
imp = [import_func("racccoon", "arg_count", 1),   # funcidx 0
       import_func("racccoon", "arg", 2),         # funcidx 1
       import_func("racccoon", "print_str", 3)]   # funcidx 2
fn_ = [3, 0]                                       # funcidx 3: emit(t3), 4: _start(t0)
exp = [export_func("_start", 4)]
mem = b"\x00" + uleb(1)
table = b"\x70\x00" + uleb(1)                      # funcref, min 1
elems = [uleb(0) + i32c(0) + END + vec([uleb(3)])] # active, offset 0, [funcidx 3]
# data @ 256: ' ' '\n'
data = [uleb(0) + i32c(256) + END + uleb(2) + bytes([0x20, 0x0a])]
I32_GE_S = b"\x4e"
CALL_IND = lambda ti: b"\x11" + uleb(ti) + b"\x00"
emit_body = LG(0) + LG(1) + call(2)               # print_str(ptr,len)
# locals: 0=i, 1=n, 2=count
start_body = (
    call(0) + LS(2) +                             # count = arg_count()
    i32c(0) + LS(0) +                             # i = 0
    BLOCK(BT_VOID) +
      LOOP(BT_VOID) +
        LG(0) + LG(2) + I32_GE_S + BR_IF(1) +     # i >= count -> break
        LG(0) + i32c(0) + i32c(256) + call(1) + LS(1) +   # n = arg(i, 0, 256)
        i32c(0) + LG(1) + i32c(0) + CALL_IND(3) + # emit(0, n) via table slot 0
        LG(0) + i32c(1) + I32_ADD + LG(2) + I32_LT_S +
        IF(BT_VOID) +
          i32c(256) + i32c(1) + call(2) +         # print_str(" ", 1)
        END +
        LG(0) + i32c(1) + I32_ADD + LS(0) +       # i += 1
        BR(0) +
      END +
    END +
    i32c(257) + i32c(1) + call(2)                 # print_str("\n", 1)
)
code = [body([], emit_body), body([(3, I32)], start_body)]
fixtures["echo.wasm"] = module(t, imp, fn_, exp, code,
                               mem=mem, table=table, elems=elems, data=data)

# --- start.wasm : SEC_START + mutable global + print_i64 -> "123" ------
# type 0: () -> ()      startf / _start
# type 1: (i64) -> ()   racccoon.print_i64
t = [functype([], []), functype([I64], [])]
imp = [import_func("racccoon", "print_i64", 1)]   # funcidx 0
fn_ = [0, 0]                                       # funcidx 1: startf, 2: _start
exp = [export_func("_start", 2)]
# one mutable i64 global, init 0
globals_ = [bytes([I64, 0x01]) + i64c(0) + END]
I64_ADD = b"\x7c"
GG = lambda n: b"\x23" + uleb(n)   # global.get
GS = lambda n: b"\x24" + uleb(n)   # global.set
startf_body = GG(0) + i64c(100) + I64_ADD + GS(0)          # g += 100  (runs first)
start_body  = GG(0) + i64c(23) + I64_ADD + call(0)         # print_i64(g + 23) -> 123
code = [body([], startf_body), body([], start_body)]
fixtures["start.wasm"] = module(t, imp, fn_, exp, code, start=1, globals_=globals_)


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
