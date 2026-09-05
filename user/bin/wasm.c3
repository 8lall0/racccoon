module user;

import std::nolibc::main_stub;
import std::nolibc::mem;

// /bin/wasm — a WebAssembly interpreter (roadmap §4). Reads a .wasm file
// through fsd, decodes + structurally validates it, and interprets it on
// an operand stack, bridging a small racccoon-native host module
// ("racccoon", NOT WASI) to racccoon syscalls.
//
//   wasm foo.wasm [args...]
//
// Milestones 1a-1d: the integer core — consts, locals/globals, calls,
// all i32/i64 arithmetic, linear memory, control flow
// (block/loop/if/br/br_table), the table + element + start sections,
// call_indirect, and the host imports print_str / arg_count / arg /
// read_file / write_file / time / print_i64.
//
// Milestone 2: f32/f64 — const/load/store, all arithmetic + comparison
// + min/max/copysign/sqrt + the directed roundings, the full i32/i64
// <-> f32/f64 conversion set (trapping and 0xFC saturating), and
// reinterpret/promote/demote. Hardware FP (§3): the operators lower to
// fadd.d etc. directly; sqrt and the roundings use small @naked asm.
//
// Next: milestone 3 — real compiled programs (raise limits, decide
// AssemblyScript / `env` import compat).
//
// All working memory (the module bytes, the value/locals/frame stacks,
// the section tables) comes from map_pages() (SYS_MAP) — userspace has
// no heap and a /bin image is capped at 256 KiB.

// --- wasm binary constants ----------------------------------------------
const uint WASM_MAGIC   = 0x6d736100; // "\0asm" little-endian
const uint WASM_VERSION = 1;

const char SEC_TYPE   = 1;
const char SEC_IMPORT = 2;
const char SEC_FUNC   = 3;
const char SEC_TABLE  = 4;
const char SEC_MEM    = 5;
const char SEC_GLOBAL = 6;
const char SEC_EXPORT = 7;
const char SEC_START  = 8;
const char SEC_ELEM   = 9;
const char SEC_CODE   = 10;
const char SEC_DATA   = 11;

const char VT_I32 = 0x7f;
const char VT_I64 = 0x7e;
const char VT_F32 = 0x7d;
const char VT_F64 = 0x7c;

// external kinds (import/export desc)
const char EXT_FUNC   = 0;
const char EXT_TABLE  = 1;
const char EXT_MEM    = 2;
const char EXT_GLOBAL = 3;

const char OP_UNREACHABLE = 0x00;
const char OP_NOP         = 0x01;
const char OP_BLOCK       = 0x02;
const char OP_LOOP        = 0x03;
const char OP_IF          = 0x04;
const char OP_ELSE        = 0x05;
const char OP_END         = 0x0b;
const char OP_BR          = 0x0c;
const char OP_BR_IF       = 0x0d;
const char OP_BR_TABLE    = 0x0e;
const char OP_RETURN      = 0x0f;
const char OP_CALL        = 0x10;
const char OP_CALL_INDIRECT = 0x11;
const char OP_DROP        = 0x1a;
const char OP_SELECT      = 0x1b;
const char OP_SELECT_T    = 0x1c;
const char OP_LOCAL_GET   = 0x20;
const char OP_LOCAL_SET   = 0x21;
const char OP_LOCAL_TEE   = 0x22;
const char OP_GLOBAL_GET  = 0x23;
const char OP_GLOBAL_SET  = 0x24;

// memory load/store  0x28..0x40
const char OP_I32_LOAD    = 0x28; const char OP_I64_LOAD    = 0x29;
const char OP_F32_LOAD    = 0x2a; const char OP_F64_LOAD    = 0x2b;
const char OP_I32_LOAD8_S = 0x2c; const char OP_I32_LOAD8_U = 0x2d;
const char OP_I32_LOAD16_S= 0x2e; const char OP_I32_LOAD16_U= 0x2f;
const char OP_I64_LOAD8_S = 0x30; const char OP_I64_LOAD8_U = 0x31;
const char OP_I64_LOAD16_S= 0x32; const char OP_I64_LOAD16_U= 0x33;
const char OP_I64_LOAD32_S= 0x34; const char OP_I64_LOAD32_U= 0x35;
const char OP_I32_STORE   = 0x36; const char OP_I64_STORE   = 0x37;
const char OP_F32_STORE   = 0x38; const char OP_F64_STORE   = 0x39;
const char OP_I32_STORE8  = 0x3a; const char OP_I32_STORE16 = 0x3b;
const char OP_I64_STORE8  = 0x3c; const char OP_I64_STORE16 = 0x3d;
const char OP_I64_STORE32 = 0x3e;
const char OP_MEMORY_SIZE = 0x3f; const char OP_MEMORY_GROW = 0x40;

const char OP_I32_CONST   = 0x41; const char OP_I64_CONST   = 0x42;
const char OP_F32_CONST   = 0x43; const char OP_F64_CONST   = 0x44;

// i32 comparisons 0x45..0x4f
const char OP_I32_EQZ  = 0x45; const char OP_I32_EQ  = 0x46; const char OP_I32_NE  = 0x47;
const char OP_I32_LT_S = 0x48; const char OP_I32_LT_U = 0x49; const char OP_I32_GT_S = 0x4a;
const char OP_I32_GT_U = 0x4b; const char OP_I32_LE_S = 0x4c; const char OP_I32_LE_U = 0x4d;
const char OP_I32_GE_S = 0x4e; const char OP_I32_GE_U = 0x4f;
// i64 comparisons 0x50..0x5a
const char OP_I64_EQZ  = 0x50; const char OP_I64_EQ  = 0x51; const char OP_I64_NE  = 0x52;
const char OP_I64_LT_S = 0x53; const char OP_I64_LT_U = 0x54; const char OP_I64_GT_S = 0x55;
const char OP_I64_GT_U = 0x56; const char OP_I64_LE_S = 0x57; const char OP_I64_LE_U = 0x58;
const char OP_I64_GE_S = 0x59; const char OP_I64_GE_U = 0x5a;

// i32 numeric 0x67..0x78
const char OP_I32_CLZ = 0x67; const char OP_I32_CTZ = 0x68; const char OP_I32_POPCNT = 0x69;
const char OP_I32_ADD = 0x6a; const char OP_I32_SUB = 0x6b; const char OP_I32_MUL = 0x6c;
const char OP_I32_DIV_S = 0x6d; const char OP_I32_DIV_U = 0x6e;
const char OP_I32_REM_S = 0x6f; const char OP_I32_REM_U = 0x70;
const char OP_I32_AND = 0x71; const char OP_I32_OR = 0x72; const char OP_I32_XOR = 0x73;
const char OP_I32_SHL = 0x74; const char OP_I32_SHR_S = 0x75; const char OP_I32_SHR_U = 0x76;
const char OP_I32_ROTL = 0x77; const char OP_I32_ROTR = 0x78;
// i64 numeric 0x79..0x8a
const char OP_I64_CLZ = 0x79; const char OP_I64_CTZ = 0x7a; const char OP_I64_POPCNT = 0x7b;
const char OP_I64_ADD = 0x7c; const char OP_I64_SUB = 0x7d; const char OP_I64_MUL = 0x7e;
const char OP_I64_DIV_S = 0x7f; const char OP_I64_DIV_U = 0x80;
const char OP_I64_REM_S = 0x81; const char OP_I64_REM_U = 0x82;
const char OP_I64_AND = 0x83; const char OP_I64_OR = 0x84; const char OP_I64_XOR = 0x85;
const char OP_I64_SHL = 0x86; const char OP_I64_SHR_S = 0x87; const char OP_I64_SHR_U = 0x88;
const char OP_I64_ROTL = 0x89; const char OP_I64_ROTR = 0x8a;

// f32 comparisons 0x5b..0x60
const char OP_F32_EQ = 0x5b; const char OP_F32_NE = 0x5c; const char OP_F32_LT = 0x5d;
const char OP_F32_GT = 0x5e; const char OP_F32_LE = 0x5f; const char OP_F32_GE = 0x60;
// f64 comparisons 0x61..0x66
const char OP_F64_EQ = 0x61; const char OP_F64_NE = 0x62; const char OP_F64_LT = 0x63;
const char OP_F64_GT = 0x64; const char OP_F64_LE = 0x65; const char OP_F64_GE = 0x66;

// f32 numeric 0x8b..0x98
const char OP_F32_ABS = 0x8b; const char OP_F32_NEG = 0x8c; const char OP_F32_CEIL = 0x8d;
const char OP_F32_FLOOR = 0x8e; const char OP_F32_TRUNC = 0x8f; const char OP_F32_NEAREST = 0x90;
const char OP_F32_SQRT = 0x91; const char OP_F32_ADD = 0x92; const char OP_F32_SUB = 0x93;
const char OP_F32_MUL = 0x94; const char OP_F32_DIV = 0x95; const char OP_F32_MIN = 0x96;
const char OP_F32_MAX = 0x97; const char OP_F32_COPYSIGN = 0x98;
// f64 numeric 0x99..0xa6
const char OP_F64_ABS = 0x99; const char OP_F64_NEG = 0x9a; const char OP_F64_CEIL = 0x9b;
const char OP_F64_FLOOR = 0x9c; const char OP_F64_TRUNC = 0x9d; const char OP_F64_NEAREST = 0x9e;
const char OP_F64_SQRT = 0x9f; const char OP_F64_ADD = 0xa0; const char OP_F64_SUB = 0xa1;
const char OP_F64_MUL = 0xa2; const char OP_F64_DIV = 0xa3; const char OP_F64_MIN = 0xa4;
const char OP_F64_MAX = 0xa5; const char OP_F64_COPYSIGN = 0xa6;

// conversions
const char OP_I32_WRAP_I64    = 0xa7;
const char OP_I32_TRUNC_F32_S = 0xa8; const char OP_I32_TRUNC_F32_U = 0xa9;
const char OP_I32_TRUNC_F64_S = 0xaa; const char OP_I32_TRUNC_F64_U = 0xab;
const char OP_I64_EXTEND_I32_S = 0xac; const char OP_I64_EXTEND_I32_U = 0xad;
const char OP_I64_TRUNC_F32_S = 0xae; const char OP_I64_TRUNC_F32_U = 0xaf;
const char OP_I64_TRUNC_F64_S = 0xb0; const char OP_I64_TRUNC_F64_U = 0xb1;
const char OP_F32_CONVERT_I32_S = 0xb2; const char OP_F32_CONVERT_I32_U = 0xb3;
const char OP_F32_CONVERT_I64_S = 0xb4; const char OP_F32_CONVERT_I64_U = 0xb5;
const char OP_F32_DEMOTE_F64  = 0xb6;
const char OP_F64_CONVERT_I32_S = 0xb7; const char OP_F64_CONVERT_I32_U = 0xb8;
const char OP_F64_CONVERT_I64_S = 0xb9; const char OP_F64_CONVERT_I64_U = 0xba;
const char OP_F64_PROMOTE_F32 = 0xbb;
const char OP_I32_REINTERPRET_F32 = 0xbc; const char OP_I64_REINTERPRET_F64 = 0xbd;
const char OP_F32_REINTERPRET_I32 = 0xbe; const char OP_F64_REINTERPRET_I64 = 0xbf;
const char OP_I32_EXTEND8_S  = 0xc0; const char OP_I32_EXTEND16_S = 0xc1;
const char OP_I64_EXTEND8_S  = 0xc2; const char OP_I64_EXTEND16_S = 0xc3;
const char OP_I64_EXTEND32_S = 0xc4;

// saturating-truncation prefix (0xfc <subop>) — the subset real
// LLVM/wasm-ld output actually emits
const char OP_PREFIX_FC = 0xfc;
const uint FC_I32_TRUNC_SAT_F32_S = 0; const uint FC_I32_TRUNC_SAT_F32_U = 1;
const uint FC_I32_TRUNC_SAT_F64_S = 2; const uint FC_I32_TRUNC_SAT_F64_U = 3;
const uint FC_I64_TRUNC_SAT_F32_S = 4; const uint FC_I64_TRUNC_SAT_F32_U = 5;
const uint FC_I64_TRUNC_SAT_F64_S = 6; const uint FC_I64_TRUNC_SAT_F64_U = 7;
// bulk-memory (roadmap §4 follow-up): memory.copy/memory.fill only —
// the "easy" half (bounds-checked memmove/memset, no passive segments).
// memory.init/data.drop need SEC_DATA to track passive segments (mode
// 1/2), which decode_data (active-only today) doesn't; table.*
// likewise needs SEC_ELEM passive-segment tracking. Left for later.
const uint FC_MEMORY_INIT = 8;  const uint FC_DATA_DROP  = 9;
const uint FC_MEMORY_COPY = 10; const uint FC_MEMORY_FILL = 11;

const int WPAGE = 65536;             // wasm linear-memory page size
const int MEM_HARD_CAP_PAGES = 240;  // ~15 MiB — under HEAP_MAX_BYTES with room for the other allocs

// host function ids (module "racccoon")
const int HOST_PRINT_I32  = 0;   // (i32)
const int HOST_PROC_EXIT  = 1;   // (i32)
const int HOST_PRINT_STR  = 2;   // (ptr:i32, len:i32)
const int HOST_ARG_COUNT  = 3;   // () -> i32
const int HOST_ARG        = 4;   // (i:i32, ptr:i32, cap:i32) -> i32  (bytes written, -1 if none)
const int HOST_READ_FILE  = 5;   // (path:i32, plen:i32, buf:i32, cap:i32) -> i32
const int HOST_WRITE_FILE = 6;   // (path:i32, plen:i32, buf:i32, len:i32) -> i32
const int HOST_TIME       = 7;   // () -> i64
const int HOST_PRINT_I64  = 8;   // (i64)

// --- limits (grow as real modules need) -------------------------------
const int TYPES_MAX    = 128;
const int FUNCS_MAX    = 512;
const int EXPORTS_MAX  = 128;
const int GLOBALS_MAX  = 128;
const int TABLE_MAX    = 4096;   // funcref table slots
const int PARAMS_MAX   = 16;
const int VSTACK_MAX   = 8192;   // 64 KiB
const int LOCALS_MAX   = 8192;   // 64 KiB
const int FRAMES_MAX   = 512;
const int MODULE_MAX   = 512 * 1024;
const int BLOCKS_MAX   = 4096;   // block/loop/if opcodes across the whole module
const int CTL_MAX      = 1024;   // active control-stack entries
const int SCAN_MAX     = 512;    // block nesting depth during the load-time scan

// blocktype byte
const char BT_VOID = 0x40;

struct WType
{
    int nparams;
    char[PARAMS_MAX] params;
    int nresults;
    char result0;              // 0 or 1 result this milestone
}

struct WFunc
{
    int  type_idx;
    bool is_import;
    int  host_id;              // if is_import: which HOST_* (or -1 = unresolved)
    uint code_off;             // offset into g_mod of the first opcode (locals already parsed)
    uint code_end;             // one past the function body's final END
    int  nlocals;              // params + declared locals
}

struct WExport
{
    char[64] name;
    char kind;
    int  index;
}

struct WFrame
{
    int  func_idx;
    uint ip;                   // offset into g_mod
    int  locals_base;          // into g_locals
    int  vstack_base;          // value-stack height on entry (for RETURN unwind)
    int  ctl_base;             // control-stack height on entry
}

// one block/loop/if opcode, from the load-time scan. start_pc is the
// offset of the block-kind opcode byte; the whole module's entries are
// kept in ascending start_pc order for binary search.
struct WBlock
{
    uint start_pc;
    uint else_pc;              // 0 if none
    uint end_pc;               // offset of the matching END byte
    char arity;                // 0 or 1 result value
}

// an entered block, on the control stack
struct WCtl
{
    char kind;                 // OP_BLOCK / OP_LOOP / OP_IF
    uint target_pc;            // where a `br` to this label jumps
    int  vstack_height;        // stack height to restore on branch/exit
    char arity;
}

// --- module state (all map_pages'd in wasm_alloc) ---------------------
char*   g_mod;      uint g_mod_len;
WType*  g_types;    int  g_ntypes;
WFunc*  g_funcs;    int  g_nfuncs;
WExport* g_exports; int  g_nexports;
long*   g_globals;  int  g_nglobals;   // value only; mutability not enforced yet

long*   g_vstack;   int  g_vtop;
long*   g_locals;   int  g_ltop;
WFrame* g_frames;   int  g_fcount;

char*   g_mem;             // linear memory (SYS_MAP'd LAST so memory.grow can extend it)
int     g_mem_pages;       // current size in 64 KiB pages
int     g_mem_cap_pages;   // pre-allocated ceiling (declared max, capped)
bool    g_has_mem;

WBlock* g_blocks;   int  g_nblocks;   // load-time block sidetable, ascending start_pc
WCtl*   g_ctl;      int  g_ctop;

int*    g_table;    int  g_table_len; // funcref table: slot -> funcidx (-1 = null)
int     g_start_func = -1;            // SEC_START, run before _start

// argv for the host `arg` import — set in main
String[] g_args;

// --- fatal-exit helper ------------------------------------------------
fn void die(char* msg)
{
    print("wasm: ");
    print(msg);
    putchar('\n');
    exitcode(1);
}

// --- LEB128 decode, cursor + hard end -------------------------------
struct Cur { uint p; uint end; }

fn char cur_byte(Cur* c)
{
    if (c.p >= c.end) { die("truncated"); }
    char b = g_mod[c.p];
    c.p++;
    return b;
}

fn uint read_u32(Cur* c)
{
    uint result = 0;
    int shift = 0;
    for (;;)
    {
        char b = cur_byte(c);
        result |= ((uint)b & 0x7f) << shift;
        if (((uint)b & 0x80) == 0) break;
        shift += 7;
        if (shift >= 35) { die("u32 leb too long"); }
    }
    return result;
}

fn long read_i64(Cur* c)
{
    long result = 0;
    int shift = 0;
    char b = 0;
    for (;;)
    {
        b = cur_byte(c);
        result |= ((long)((uint)b & 0x7f)) << shift;
        shift += 7;
        if (((uint)b & 0x80) == 0) break;
        if (shift >= 70) { die("i64 leb too long"); }
    }
    if (shift < 64 && ((uint)b & 0x40) != 0)
    {
        result |= -(((long)1) << shift);
    }
    return result;
}

fn int read_i32(Cur* c)
{
    return (int)read_i64(c);
}

fn void skip(Cur* c, uint n)
{
    if (n > c.end - c.p) { die("skip past end"); }
    c.p += n;
}

// --- allocation ------------------------------------------------------
fn char* wasm_alloc(uint bytes)
{
    char* p = (char*)map_pages(bytes);
    if (p == null) { die("out of memory"); }
    return p;
}

// --- section decoders ----------------------------------------------
fn void decode_types(Cur* c)
{
    g_ntypes = (int)read_u32(c);
    if (g_ntypes < 0 || g_ntypes > TYPES_MAX) { die("too many types"); }
    for (int i = 0; i < g_ntypes; i++)
    {
        if (cur_byte(c) != 0x60) { die("bad functype tag"); }
        WType* t = &g_types[i];
        t.nparams = (int)read_u32(c);
        if (t.nparams < 0 || t.nparams > PARAMS_MAX) { die("too many params"); }
        for (int k = 0; k < t.nparams; k++) { t.params[k] = cur_byte(c); }
        t.nresults = (int)read_u32(c);
        if (t.nresults < 0 || t.nresults > 1) { die("multi-result unsupported"); }
        t.result0 = t.nresults == 1 ? cur_byte(c) : (char)0;
    }
}

// name into a fixed buffer, NUL-terminated, truncated if long
fn void read_name(Cur* c, char* out, int cap)
{
    uint n = read_u32(c);
    if (n > c.end - c.p) { die("name past end"); }
    int k = 0;
    for (uint i = 0; i < n; i++)
    {
        char ch = g_mod[c.p + i];
        if (k < cap - 1) { out[k] = ch; k++; }
    }
    out[k] = 0;
    c.p += n;
}

fn void decode_imports(Cur* c)
{
    uint n = read_u32(c);
    for (uint i = 0; i < n; i++)
    {
        char[64] mod @noinit;
        char[64] fld @noinit;
        read_name(c, &mod[0], 64);
        read_name(c, &fld[0], 64);
        char kind = cur_byte(c);
        if (kind == EXT_FUNC)
        {
            uint type_idx = read_u32(c);
            if ((int)type_idx >= g_ntypes) { die("import type idx"); }
            if (g_nfuncs >= FUNCS_MAX) { die("too many funcs"); }
            WFunc* f = &g_funcs[g_nfuncs];
            g_nfuncs++;
            f.type_idx = (int)type_idx;
            f.is_import = true;
            f.host_id = resolve_host(&mod[0], &fld[0]);
            f.nlocals = g_types[type_idx].nparams;
        }
        else if (kind == EXT_TABLE)   { cur_byte(c); read_limits(c); }
        else if (kind == EXT_MEM)     { read_limits(c); }
        else if (kind == EXT_GLOBAL)  { cur_byte(c); cur_byte(c); }
        else { die("bad import kind"); }
    }
}

fn void read_limits(Cur* c)
{
    char flag = cur_byte(c);
    read_u32(c);                       // min
    if ((flag & 1) != 0) { read_u32(c); } // max
}

fn int resolve_host(char* mod, char* fld)
{
    if (strcmp(mod, "racccoon") != 0) { return -1; }
    if (strcmp(fld, "print_i32")  == 0) { return HOST_PRINT_I32; }
    if (strcmp(fld, "print_i64")  == 0) { return HOST_PRINT_I64; }
    if (strcmp(fld, "proc_exit")  == 0) { return HOST_PROC_EXIT; }
    if (strcmp(fld, "print_str")  == 0) { return HOST_PRINT_STR; }
    if (strcmp(fld, "arg_count")  == 0) { return HOST_ARG_COUNT; }
    if (strcmp(fld, "arg")        == 0) { return HOST_ARG; }
    if (strcmp(fld, "read_file")  == 0) { return HOST_READ_FILE; }
    if (strcmp(fld, "write_file") == 0) { return HOST_WRITE_FILE; }
    if (strcmp(fld, "time")       == 0) { return HOST_TIME; }
    return -1;
}

// bounds-checked linear-memory region -> returns a real pointer or dies
fn char* mem_ptr(uint off, uint len)
{
    if (!g_has_mem) { die("host: no memory"); }
    long lim = (long)g_mem_pages * WPAGE;
    if ((long)off + (long)len > lim) { die("host: memory range out of bounds"); }
    return &g_mem[off];
}

fn void decode_funcsec(Cur* c)
{
    uint n = read_u32(c);
    for (uint i = 0; i < n; i++)
    {
        uint type_idx = read_u32(c);
        if ((int)type_idx >= g_ntypes) { die("func type idx"); }
        if (g_nfuncs >= FUNCS_MAX) { die("too many funcs"); }
        WFunc* f = &g_funcs[g_nfuncs];
        g_nfuncs++;
        f.type_idx = (int)type_idx;
        f.is_import = false;
        f.host_id = -1;
        f.nlocals = 0;             // filled by decode_code
    }
}

fn void decode_globals(Cur* c)
{
    g_nglobals = (int)read_u32(c);
    if (g_nglobals < 0 || g_nglobals > GLOBALS_MAX) { die("too many globals"); }
    for (int i = 0; i < g_nglobals; i++)
    {
        cur_byte(c);               // valtype
        cur_byte(c);               // mutability
        g_globals[i] = read_const_expr(c);
    }
}

// a constant init expression: one const/global.get opcode then END
fn long read_const_expr(Cur* c)
{
    long v = 0;
    char op = cur_byte(c);
    if (op == OP_I32_CONST) { v = (long)read_i32(c); }
    else if (op == OP_I64_CONST) { v = read_i64(c); }
    else if (op == OP_F32_CONST) { if (4 > c.end - c.p) { die("truncated f32"); } v = (long)(uint)*(uint*)&g_mod[c.p]; c.p += 4; }
    else if (op == OP_F64_CONST) { if (8 > c.end - c.p) { die("truncated f64"); } v = *(long*)&g_mod[c.p]; c.p += 8; }
    else if (op == OP_GLOBAL_GET)
    {
        uint gi = read_u32(c);
        if ((int)gi >= g_nglobals) { die("const-expr global idx"); }
        v = g_globals[gi];
    }
    else { die("const-expr: unsupported opcode"); }
    if (cur_byte(c) != OP_END) { die("const-expr not END-terminated"); }
    return v;
}

fn void decode_table(Cur* c)
{
    uint n = read_u32(c);
    if (n == 0) { return; }
    if (n > 1) { die("multi-table unsupported"); }
    cur_byte(c);                       // elemtype (funcref)
    char flag = cur_byte(c);
    uint minc = read_u32(c);
    if ((flag & 1) != 0) { read_u32(c); }   // max
    if ((int)minc > TABLE_MAX) { die("table too large"); }
    g_table_len = (int)minc;
    for (int i = 0; i < g_table_len; i++) { g_table[i] = -1; }
}

fn void decode_elem(Cur* c)
{
    uint n = read_u32(c);
    for (uint i = 0; i < n; i++)
    {
        uint mode = read_u32(c);
        if (mode != 0) { die("non-active element segment unsupported"); }
        long off = read_const_expr(c);   // table offset (i32)
        uint cnt = read_u32(c);
        for (uint k = 0; k < cnt; k++)
        {
            uint fidx = read_u32(c);
            long slot = off + (long)k;
            if (slot < 0 || slot >= g_table_len) { die("element out of table bounds"); }
            if ((int)fidx >= g_nfuncs) { die("element funcidx"); }
            g_table[slot] = (int)fidx;
        }
    }
}

fn void decode_start(Cur* c)
{
    uint fi = read_u32(c);
    if ((int)fi >= g_nfuncs) { die("start funcidx"); }
    g_start_func = (int)fi;
}

fn void decode_exports(Cur* c)
{
    g_nexports = (int)read_u32(c);
    if (g_nexports < 0 || g_nexports > EXPORTS_MAX) { die("too many exports"); }
    for (int i = 0; i < g_nexports; i++)
    {
        WExport* e = &g_exports[i];
        read_name(c, &e.name[0], 64);
        e.kind = cur_byte(c);
        e.index = (int)read_u32(c);
    }
}

fn void decode_code(Cur* c)
{
    uint n = read_u32(c);
    // code entries pair with the non-import funcs, in order
    int fi = 0;
    while (fi < g_nfuncs && g_funcs[fi].is_import) { fi++; }
    for (uint i = 0; i < n; i++)
    {
        if (fi >= g_nfuncs) { die("code/func count mismatch"); }
        WFunc* f = &g_funcs[fi];
        uint body_len = read_u32(c);
        if (body_len > c.end - c.p) { die("code body past end"); }
        uint body_start = c.p;
        uint body_end = c.p + body_len;

        Cur bc; bc.p = body_start; bc.end = body_end;
        int nlocals = g_types[f.type_idx].nparams;
        uint ldecls = read_u32(&bc);
        for (uint d = 0; d < ldecls; d++)
        {
            uint cnt = read_u32(&bc);
            cur_byte(&bc);         // local type
            nlocals += (int)cnt;
        }
        if (nlocals > LOCALS_MAX) { die("function has too many locals"); }
        f.nlocals = nlocals;
        f.code_off = bc.p;
        f.code_end = body_end;
        scan_function(f);      // fills the block sidetable for this function

        c.p = body_end;
        // advance to the next non-import func
        fi++;
        while (fi < g_nfuncs && g_funcs[fi].is_import) { fi++; }
    }
}

// SEC_MEM=5 — at most one memory. Allocated here (SYS_MAP), and since
// nothing else map_pages() after decode, memory.grow can extend the
// region in place. Section order (MEM before DATA) means g_mem exists
// before decode_data runs.
fn void decode_mem(Cur* c)
{
    uint n = read_u32(c);
    if (n == 0) { return; }
    if (n > 1) { die("multi-memory unsupported"); }
    char flag = cur_byte(c);
    uint minp = read_u32(c);
    uint maxp = (flag & 1) != 0 ? read_u32(c) : 0;
    if ((int)minp > MEM_HARD_CAP_PAGES) { die("initial memory too large"); }
    int cap = (int)minp;
    if ((flag & 1) != 0 && (int)maxp <= 64 && (int)maxp > cap) { cap = (int)maxp; }
    if (cap < 1) { cap = 1; }
    g_mem = wasm_alloc((uint)(cap * WPAGE));
    g_mem_pages = (int)minp;
    g_mem_cap_pages = cap;
    g_has_mem = true;
}

// SEC_DATA=11 — active data segments only (mode 0: memidx implicit 0,
// offset is a const expr). Runs after decode_mem alloc'd g_mem.
fn void decode_data(Cur* c)
{
    uint n = read_u32(c);
    for (uint i = 0; i < n; i++)
    {
        uint mode = read_u32(c);
        if (mode != 0) { die("passive/explicit data segment unsupported"); }
        // offset expr: a single i32.const then END
        if (cur_byte(c) != OP_I32_CONST) { die("data offset not i32.const"); }
        int off = read_i32(c);
        if (cur_byte(c) != OP_END) { die("data offset not END-terminated"); }
        uint len = read_u32(c);
        if (len > c.end - c.p) { die("data segment past end"); }
        if (!g_has_mem) { die("data segment with no memory"); }
        long lim = (long)g_mem_pages * WPAGE;
        if (off < 0 || (long)off + (long)len > lim) { die("data segment out of bounds"); }
        for (uint k = 0; k < len; k++) { g_mem[(uint)off + k] = g_mod[c.p + k]; }
        c.p += len;
    }
}

// --- immediate readers (advance fr.ip) --------------------------------
fn uint imm_u32(WFrame* fr)
{
    Cur c; c.p = fr.ip; c.end = g_mod_len;
    uint v = read_u32(&c);
    fr.ip = c.p;
    return v;
}

fn int imm_i32(WFrame* fr)
{
    Cur c; c.p = fr.ip; c.end = g_mod_len;
    int v = read_i32(&c);
    fr.ip = c.p;
    return v;
}

fn long imm_i64(WFrame* fr)
{
    Cur c; c.p = fr.ip; c.end = g_mod_len;
    long v = read_i64(&c);
    fr.ip = c.p;
    return v;
}

// memarg: align (ignored) + offset. Returns the effective linear-memory
// address, bounds-checked for `size` bytes; dies on OOB.
fn uint mem_ea(WFrame* fr, int size)
{
    imm_u32(fr);                       // align hint — ignored
    uint moff = imm_u32(fr);
    uint base = (uint)vpop();           // i32 dynamic address
    long ea = (long)base + (long)moff;
    if (!g_has_mem) { die("memory op with no memory"); }
    long lim = (long)g_mem_pages * WPAGE;
    if (ea < 0 || ea + (long)size > lim) { die("out-of-bounds memory access"); }
    return (uint)ea;
}

// --- bit-count helpers (no stdlib) ----------------------------------
fn int clz32(uint x) { if (x == 0) return 32; int n = 0; while ((x & 0x80000000u) == 0) { n++; x <<= 1; } return n; }
fn int ctz32(uint x) { if (x == 0) return 32; int n = 0; while ((x & 1u) == 0) { n++; x >>= 1; } return n; }
fn int pop32(uint x)  { int n = 0; while (x != 0) { n += (int)(x & 1u); x >>= 1; } return n; }
fn int clz64(ulong x) { if (x == 0) return 64; int n = 0; while ((x & 0x8000000000000000u) == 0) { n++; x <<= 1; } return n; }
fn int ctz64(ulong x) { if (x == 0) return 64; int n = 0; while ((x & 1u) == 0) { n++; x >>= 1; } return n; }
fn int pop64(ulong x)  { int n = 0; while (x != 0) { n += (int)(x & 1u); x >>= 1; } return n; }

fn int wasm_mem_grow(int delta)
{
    int old = g_mem_pages;
    if (delta < 0) { return -1; }
    long want = (long)old + (long)delta;
    if (want > MEM_HARD_CAP_PAGES) { return -1; }
    if ((int)want > g_mem_cap_pages)
    {
        int extra = (int)want - g_mem_cap_pages;
        char* p = (char*)map_pages((uint)(extra * WPAGE));
        if (p == null || p != g_mem + g_mem_cap_pages * WPAGE) { return -1; }
        g_mem_cap_pages = (int)want;
    }
    g_mem_pages = (int)want;
    return old;
}

// Advance `c` past one instruction (opcode + immediates) and return the
// opcode. Used only by the load-time block scan.
fn char next_instr(Cur* c)
{
    char op = cur_byte(c);
    if (op == OP_BLOCK || op == OP_LOOP || op == OP_IF)
    {
        // blocktype: a single byte (0x40 or a valtype) or an s33 type index
        char bt = g_mod[c.p];
        if (bt == BT_VOID || bt == VT_I32 || bt == VT_I64 || bt == VT_F32 || bt == VT_F64)
        {
            c.p++;
        }
        else { read_i64(c); }
    }
    else if (op == OP_BR || op == OP_BR_IF || op == OP_CALL
          || (op >= OP_LOCAL_GET && op <= OP_GLOBAL_SET))
    {
        read_u32(c);
    }
    else if (op == OP_CALL_INDIRECT) { read_u32(c); read_u32(c); }
    else if (op == OP_BR_TABLE)
    {
        uint cnt = read_u32(c);
        for (uint i = 0; i <= cnt; i++) { read_u32(c); }
    }
    else if (op == OP_SELECT_T)
    {
        uint cnt = read_u32(c);
        skip(c, cnt);
    }
    else if (op >= OP_I32_LOAD && op <= OP_I64_STORE32) { read_u32(c); read_u32(c); }
    else if (op == OP_MEMORY_SIZE || op == OP_MEMORY_GROW) { cur_byte(c); }
    else if (op == OP_I32_CONST || op == OP_I64_CONST) { read_i64(c); }
    else if (op == OP_F32_CONST) { skip(c, 4); }
    else if (op == OP_F64_CONST) { skip(c, 8); }
    else if ((uint)op == 0xfc)
    {
        uint sub = read_u32(c);
        // memory.copy: 2 reserved memidx bytes; memory.fill: 1. Both
        // LEB128-encoded (always 0x00 in the MVP single-memory case),
        // so read_u32 (not a raw byte skip) reads them correctly.
        if (sub == FC_MEMORY_COPY) { read_u32(c); read_u32(c); }
        else if (sub == FC_MEMORY_FILL) { read_u32(c); }
    }
    // everything else: no immediates
    return op;
}

// Scan a function body once, recording every block/loop/if -> its
// matching else/end into the global sidetable (ascending start_pc).
fn void scan_function(WFunc* f)
{
    uint[SCAN_MAX] open @noinit;      // start_pc of each open block
    int[SCAN_MAX]  slot @noinit;      // its g_blocks index
    int depth = 0;

    Cur c; c.p = f.code_off; c.end = f.code_end;
    while (c.p < c.end)
    {
        uint pc = c.p;
        char op = next_instr(&c);
        if (op == OP_BLOCK || op == OP_LOOP || op == OP_IF)
        {
            if (depth >= SCAN_MAX) { die("block nesting too deep"); }
            if (g_nblocks >= BLOCKS_MAX) { die("too many blocks"); }
            int idx = g_nblocks;
            g_nblocks++;
            g_blocks[idx].start_pc = pc;
            g_blocks[idx].else_pc = 0;
            g_blocks[idx].end_pc = 0;
            // arity: re-read the blocktype byte at pc+1
            char bt = g_mod[pc + 1];
            g_blocks[idx].arity = (bt == VT_I32 || bt == VT_I64 || bt == VT_F32 || bt == VT_F64) ? (char)1 : (char)0;
            open[depth] = pc;
            slot[depth] = idx;
            depth++;
        }
        else if (op == OP_ELSE)
        {
            if (depth == 0) { die("else without if"); }
            g_blocks[slot[depth - 1]].else_pc = pc;
        }
        else if (op == OP_END)
        {
            if (depth == 0) { break; }  // the function's final END
            depth--;
            g_blocks[slot[depth]].end_pc = pc;
        }
    }
    if (depth != 0) { die("unbalanced blocks"); }
}

// binary search the sidetable by start_pc
fn WBlock* find_block(uint start_pc)
{
    int lo = 0;
    int hi = g_nblocks - 1;
    while (lo <= hi)
    {
        int mid = (lo + hi) / 2;
        if (g_blocks[mid].start_pc == start_pc) { return &g_blocks[mid]; }
        if (g_blocks[mid].start_pc < start_pc) { lo = mid + 1; }
        else { hi = mid - 1; }
    }
    die("block not in sidetable");
    return null;
}

// --- top-level decode --------------------------------------------------
fn void decode_module()
{
    Cur c; c.p = 0; c.end = g_mod_len;
    if (g_mod_len < 8) { die("too short"); }
    uint magic = *(uint*)&g_mod[0];
    uint ver   = *(uint*)&g_mod[4];
    if (magic != WASM_MAGIC) { die("bad magic"); }
    if (ver != WASM_VERSION) { die("bad version"); }
    c.p = 8;

    char last_sec = 0;
    while (c.p < c.end)
    {
        char sid = cur_byte(&c);
        uint slen = read_u32(&c);
        if (slen > c.end - c.p) { die("section past end"); }
        uint sbody_end = c.p + slen;
        Cur sc; sc.p = c.p; sc.end = sbody_end;

        if (sid == 0)
        {
            // custom section — skip
        }
        else if (sid <= SEC_DATA)
        {
            if (sid <= last_sec) { die("section out of order"); }
            last_sec = sid;
            switch (sid)
            {
                case SEC_TYPE:   decode_types(&sc);
                case SEC_IMPORT: decode_imports(&sc);
                case SEC_FUNC:   decode_funcsec(&sc);
                case SEC_TABLE:  decode_table(&sc);
                case SEC_MEM:    decode_mem(&sc);
                case SEC_GLOBAL: decode_globals(&sc);
                case SEC_EXPORT: decode_exports(&sc);
                case SEC_START:  decode_start(&sc);
                case SEC_ELEM:   decode_elem(&sc);
                case SEC_CODE:   decode_code(&sc);
                case SEC_DATA:   decode_data(&sc);
                default: die("bad section id");
            }
        }
        else { die("bad section id"); }

        c.p = sbody_end;
    }
}

// --- interpreter -----------------------------------------------------
fn void vpush(long v)
{
    if (g_vtop >= VSTACK_MAX) { die("value stack overflow"); }
    g_vstack[g_vtop] = v;
    g_vtop++;
}

fn long vpop()
{
    if (g_vtop <= 0) { die("value stack underflow"); }
    g_vtop--;
    return g_vstack[g_vtop];
}

// --- float <-> value-stack packing ---------------------------------
// f64 occupies the whole 64-bit slot; f32 lives in the low 32 bits
// (upper 32 are don't-care, exactly like i32). Reinterpret via a
// pointer cast — no conversion.
fn double  vpop_f64()        { long b = vpop(); return *(double*)&b; }
fn void    vpush_f64(double d){ vpush(*(long*)&d); }
fn float   vpop_f32()        { long b = vpop(); uint u = (uint)b; return *(float*)&u; }
fn void    vpush_f32(float f) { uint u = *(uint*)&f; vpush((long)u); }

// --- FP instructions the compiler won't emit from an operator -------
// sqrt and the directed roundings need the actual RISC-V ops. @naked +
// opaque asm(`...`), the same escape hatch src/process.c3's fp_save
// uses (the block asm{} form only knows integer lw/sw). lp64d: a
// double arg arrives in fa0, the return goes back in fa0.
fn double f_sqrt_d(double x) @naked @noinline @nostrip { asm(`fsqrt.d fa0, fa0
    ret`); }
fn float  f_sqrt_s(float x)  @naked @noinline @nostrip { asm(`fsqrt.s fa0, fa0
    ret`); }
// round-to-integral, ties-to-even (wasm `nearest`): convert to i64 with
// the round-nearest mode, convert back. The C3-side wrappers below guard
// the |x| >= 2^52 / NaN / inf cases where this would saturate or be lossy.
fn double f_rint_d(double x)  @naked @noinline @nostrip { asm(`fcvt.l.d a0, fa0, rne
    fcvt.d.l fa0, a0
    ret`); }
fn double f_ceil_d(double x)  @naked @noinline @nostrip { asm(`fcvt.l.d a0, fa0, rup
    fcvt.d.l fa0, a0
    ret`); }
fn double f_floor_d(double x) @naked @noinline @nostrip { asm(`fcvt.l.d a0, fa0, rdn
    fcvt.d.l fa0, a0
    ret`); }

const double F_TWO52 = 4503599627370496.0;   // 2^52 — every double this size or larger is already integral

// wasm f64 round ops. `kind`: 0 nearest, 1 ceil, 2 floor, 3 trunc.
// NaN / inf / already-integral pass straight through; the sign of a
// zero result is taken from the input (wasm keeps -0.0).
fn double f_round_d(double x, int kind)
{
    if (x != x) { return x; }                     // NaN
    double ax = x < 0.0 ? -x : x;
    if (!(ax < F_TWO52)) { return x; }             // inf, or too big to be non-integral
    double r;
    switch (kind)
    {
        case 1:  r = f_ceil_d(x);
        case 2:  r = f_floor_d(x);
        case 3:  r = (double)(long)x;              // trunc = round-toward-zero
        default: r = f_rint_d(x);                  // nearest, ties-to-even
    }
    if (r == 0.0 && x < 0.0)
    {
        long negzero = (long)0x8000000000000000;
        return *(double*)&negzero;
    }
    return r;
}

// wasm min/max: if either operand is NaN the result is NaN; -0 < +0.
// (RISC-V fmin.d/fmax.d differ on the NaN case, so do it by hand.)
fn double f_min_d(double a, double b)
{
    if (a != a || b != b) { double q = a != a ? a : b; long n = *(long*)&q | (long)0x0008000000000000; return *(double*)&n; }
    if (a == 0.0 && b == 0.0) { long na = *(long*)&a; long nb = *(long*)&b; long n = na | nb; return *(double*)&n; } // -0 if either is -0
    return a < b ? a : b;
}
fn double f_max_d(double a, double b)
{
    if (a != a || b != b) { double q = a != a ? a : b; long n = *(long*)&q | (long)0x0008000000000000; return *(double*)&n; }
    if (a == 0.0 && b == 0.0) { long na = *(long*)&a; long nb = *(long*)&b; long n = na & nb; return *(double*)&n; } // +0 unless both -0
    return a > b ? a : b;
}

// f64 -> i64 truncation with wasm's trap-on-out-of-range semantics
// (die() is our clean exit). `is_signed` picks the range.
fn long f_trunc_to_i64(double x, bool is_signed)
{
    if (x != x) { die("f->i: NaN"); }
    if (is_signed)
    {
        if (!(x >= -9223372036854775808.0 && x < 9223372036854775808.0)) { die("f->i: out of range"); }
        return (long)x;
    }
    if (!(x >= 0.0 && x < 18446744073709551616.0)) { die("f->i: out of range"); }
    if (x < 9223372036854775808.0) { return (long)x; }
    return (long)(x - 9223372036854775808.0) | (long)0x8000000000000000;
}

fn int f_trunc_to_i32(double x, bool is_signed)
{
    if (x != x) { die("f->i: NaN"); }
    if (is_signed)
    {
        if (!(x >= -2147483648.0 && x < 2147483648.0)) { die("f->i: out of range"); }
        return (int)x;
    }
    if (!(x >= 0.0 && x < 4294967296.0)) { die("f->i: out of range"); }
    return (int)(uint)(long)x;
}

// saturating variant (0xfc trunc_sat): clamp instead of trap; NaN -> 0.
fn long f_trunc_sat_i64(double x, bool is_signed)
{
    if (x != x) { return 0; }
    if (is_signed)
    {
        if (x <= -9223372036854775808.0) { return (long)0x8000000000000000; }
        if (x >= 9223372036854775808.0)  { return (long)0x7FFFFFFFFFFFFFFF; }
        return (long)x;
    }
    if (x <= 0.0) { return 0; }
    if (x >= 18446744073709551616.0) { return (long)0xFFFFFFFFFFFFFFFF; }
    if (x < 9223372036854775808.0) { return (long)x; }
    return (long)(x - 9223372036854775808.0) | (long)0x8000000000000000;
}
fn int f_trunc_sat_i32(double x, bool is_signed)
{
    if (x != x) { return 0; }
    if (is_signed)
    {
        if (x <= -2147483648.0) { return (int)0x80000000; }
        if (x >= 2147483648.0)  { return (int)0x7FFFFFFF; }
        return (int)x;
    }
    if (x <= 0.0) { return 0; }
    if (x >= 4294967296.0) { return (int)0xFFFFFFFF; }
    return (int)(uint)(long)x;
}

// copy a (ptr,len) region of linear memory into `out` as a NUL-terminated
// string, truncating to cap-1 bytes. dies if the region is out of bounds.
fn void mem_cstr(uint off, uint len, char* out, int cap)
{
    char* p = mem_ptr(off, len);
    int k = 0;
    for (uint i = 0; i < len; i++)
    {
        if (k < cap - 1) { out[k] = p[i]; k++; }
    }
    out[k] = 0;
}

fn void host_call(int host_id)
{
    switch (host_id)
    {
        case HOST_PRINT_I32:
            int v = (int)vpop();
            print_int32(v);
            putchar('\n');
        case HOST_PRINT_I64:
            long lv = vpop();
            if (lv < 0) { putchar('-'); print_uint64((ulong)(-lv)); }
            else { print_uint64((ulong)lv); }
            putchar('\n');
        case HOST_PROC_EXIT:
            exitcode((int)vpop());
        case HOST_PRINT_STR:
            uint slen = (uint)vpop();
            uint soff = (uint)vpop();
            char* sp = mem_ptr(soff, slen);
            for (uint i = 0; i < slen; i++) { putchar(sp[i]); }
        case HOST_ARG_COUNT:
            vpush((long)g_args.len);
        case HOST_ARG:
            uint acap = (uint)vpop();
            uint aoff = (uint)vpop();
            int aidx = (int)vpop();
            if (aidx < 0 || aidx >= (int)g_args.len) { vpush((long)(int)-1); }
            else
            {
                char* a = g_args[aidx].ptr;
                uint alen = 0;
                while (a[alen] != 0) { alen++; }
                char* dst = mem_ptr(aoff, alen < acap ? alen : acap);
                uint n = alen < acap ? alen : acap;
                for (uint i = 0; i < n; i++) { dst[i] = a[i]; }
                vpush((long)(int)n);
            }
        case HOST_READ_FILE:
            uint rcap  = (uint)vpop();
            uint rbuf  = (uint)vpop();
            uint rplen = (uint)vpop();
            uint rpoff = (uint)vpop();
            char[256] rpath @noinit;
            mem_cstr(rpoff, rplen, &rpath[0], 256);
            char* rdst = mem_ptr(rbuf, rcap);
            int rgot = fs_read(&rpath[0], rdst, (int)rcap);
            vpush((long)rgot);
        case HOST_WRITE_FILE:
            uint wlen  = (uint)vpop();
            uint wbuf  = (uint)vpop();
            uint wplen = (uint)vpop();
            uint wpoff = (uint)vpop();
            char[256] wpath @noinit;
            mem_cstr(wpoff, wplen, &wpath[0], 256);
            char* wsrc = mem_ptr(wbuf, wlen);
            int wput = fs_write(&wpath[0], wsrc, (int)wlen);
            vpush((long)wput);
        case HOST_TIME:
            vpush((long)rdtime());
        default:
            die("unresolved host import");
    }
}

fn void print_uint64(ulong n)
{
    char[24] buf @noinit;
    int i = 24;
    if (n == 0) { putchar('0'); return; }
    while (n != 0) { i--; buf[i] = (char)('0' + (int)(n % 10)); n /= 10; }
    while (i < 24) { putchar(buf[i]); i++; }
}

// signed-decimal print — user.c3 only has print_uint
fn void print_int32(int v)
{
    if (v < 0) { putchar('-'); print_uint((uint)(-(long)v)); }
    else { print_uint((uint)v); }
}

fn void push_frame(int func_idx)
{
    if (g_fcount >= FRAMES_MAX) { die("call stack overflow"); }
    WFunc* f = &g_funcs[func_idx];
    WType* t = &g_types[f.type_idx];

    int lbase = g_ltop;
    if (lbase + f.nlocals > LOCALS_MAX) { die("locals pool overflow"); }
    // params: top t.nparams values, param 0 deepest
    for (int k = t.nparams - 1; k >= 0; k--)
    {
        g_locals[lbase + k] = vpop();
    }
    for (int k = t.nparams; k < f.nlocals; k++) { g_locals[lbase + k] = 0; }
    g_ltop = lbase + f.nlocals;

    WFrame* fr = &g_frames[g_fcount];
    g_fcount++;
    fr.func_idx = func_idx;
    fr.ip = f.code_off;
    fr.locals_base = lbase;
    fr.vstack_base = g_vtop;
    fr.ctl_base = g_ctop;
}

fn void frame_return()
{
    WFrame* fr = &g_frames[g_fcount - 1];
    WFunc* f = &g_funcs[fr.func_idx];
    int nres = g_types[f.type_idx].nresults;
    // move the top nres values down to the caller's stack position
    long r0 = 0;
    if (nres == 1) { r0 = g_vstack[g_vtop - 1]; }
    g_vtop = fr.vstack_base;
    g_ltop = fr.locals_base;
    g_ctop = fr.ctl_base;
    g_fcount--;
    if (nres == 1) { vpush(r0); }
}

// Branch out of `depth` enclosing labels (0 = innermost). Pops that
// many control entries, sets ip to the (depth+1)th's target, and
// restores the value stack — keeping the branched-to label's result
// value(s) if it has arity.
fn void do_branch(WFrame* fr, uint depth)
{
    if ((int)depth >= g_ctop - fr.ctl_base) { die("branch depth"); }
    WCtl* tgt = &g_ctl[g_ctop - 1 - (int)depth];
    long keep = 0;
    bool have = tgt.arity == 1 && g_vtop > tgt.vstack_height;
    if (have) { keep = g_vstack[g_vtop - 1]; }
    g_vtop = tgt.vstack_height;
    if (have) { vpush(keep); }
    fr.ip = tgt.target_pc;
    // a branch to a block/if exits it (and everything inside);
    // a branch to a loop re-enters it, so keep that entry.
    g_ctop = g_ctop - (int)depth;
    if (tgt.kind != OP_LOOP) { g_ctop--; }
}

// read a blocktype at fr.ip, advance past it, return arity (0/1)
fn char read_blocktype(WFrame* fr)
{
    char bt = g_mod[fr.ip];
    if (bt == BT_VOID) { fr.ip++; return 0; }
    if (bt == VT_I32 || bt == VT_I64 || bt == VT_F32 || bt == VT_F64) { fr.ip++; return 1; }
    imm_i64(fr);   // s33 type index — treat as arity from its result count
    return 0;      // (multi-value block types not fully modelled this milestone)
}

fn void interp()
{
    while (g_fcount > 0)
    {
        WFrame* fr = &g_frames[g_fcount - 1];
        if (fr.ip >= g_mod_len) { die("ip past module"); }
        char op = g_mod[fr.ip];
        fr.ip++;

        switch (op)
        {
            case OP_NOP:      break;
            case OP_UNREACHABLE: die("unreachable executed");
            case OP_END:
                if (g_ctop > fr.ctl_base) { g_ctop--; }   // block ended naturally
                else { frame_return(); }
            case OP_RETURN:   frame_return();
            case OP_DROP:     vpop();
            case OP_SELECT:
                long sc = vpop(); long sv2 = vpop(); long sv1 = vpop();
                vpush((int)sc != 0 ? sv1 : sv2);
            case OP_SELECT_T:
                uint stn = imm_u32(fr);
                for (uint z = 0; z < stn; z++) { fr.ip++; }
                long sc = vpop(); long sv2 = vpop(); long sv1 = vpop();
                vpush((int)sc != 0 ? sv1 : sv2);

            case OP_BLOCK:
                uint bpc = fr.ip - 1;
                char bar = read_blocktype(fr);
                WBlock* bi = find_block(bpc);
                if (g_ctop >= CTL_MAX) { die("control stack overflow"); }
                g_ctl[g_ctop].kind = OP_BLOCK;
                g_ctl[g_ctop].target_pc = bi.end_pc + 1;   // past the END
                g_ctl[g_ctop].vstack_height = g_vtop;
                g_ctl[g_ctop].arity = bar;
                g_ctop++;
            case OP_LOOP:
                char lar = read_blocktype(fr);
                if (g_ctop >= CTL_MAX) { die("control stack overflow"); }
                g_ctl[g_ctop].kind = OP_LOOP;
                g_ctl[g_ctop].target_pc = fr.ip;           // back to loop body start
                g_ctl[g_ctop].vstack_height = g_vtop;
                g_ctl[g_ctop].arity = 0;                    // loop params, not results
                g_ctop++;
            case OP_IF:
                uint ipc = fr.ip - 1;
                char iar = read_blocktype(fr);
                WBlock* ii = find_block(ipc);
                int cond = (int)vpop();
                if (g_ctop >= CTL_MAX) { die("control stack overflow"); }
                g_ctl[g_ctop].kind = OP_IF;
                g_ctl[g_ctop].target_pc = ii.end_pc + 1;
                g_ctl[g_ctop].vstack_height = g_vtop;
                g_ctl[g_ctop].arity = iar;
                g_ctop++;
                if (cond == 0)
                {
                    fr.ip = ii.else_pc != 0 ? ii.else_pc + 1 : ii.end_pc + 1;
                    if (ii.else_pc == 0) { g_ctop--; }     // no else: the if is done
                }
            case OP_ELSE:
                // reached by falling off the then-branch: skip to END
                WCtl* ec = &g_ctl[g_ctop - 1];
                fr.ip = ec.target_pc;                       // = end_pc + 1
                g_ctop--;
            case OP_BR:
                uint bd = imm_u32(fr);
                do_branch(fr, bd);
            case OP_BR_IF:
                uint bid = imm_u32(fr);
                if ((int)vpop() != 0) { do_branch(fr, bid); }
            case OP_BR_TABLE:
                uint tcnt = imm_u32(fr);
                uint chosen = 0;
                uint tsel_raw = (uint)(int)vpop();
                for (uint ti = 0; ti <= tcnt; ti++)
                {
                    uint d = imm_u32(fr);
                    if (ti == tsel_raw || (tsel_raw >= tcnt && ti == tcnt)) { chosen = d; }
                }
                do_branch(fr, chosen);
            case OP_CALL:
                uint callee = imm_u32(fr);
                if ((int)callee >= g_nfuncs) { die("call idx"); }
                if (g_funcs[callee].is_import) { host_call(g_funcs[callee].host_id); }
                else { push_frame((int)callee); }
            case OP_CALL_INDIRECT:
                uint ci_type = imm_u32(fr);
                imm_u32(fr);                        // tableidx (only table 0)
                int ci_slot = (int)vpop();
                if (ci_slot < 0 || ci_slot >= g_table_len) { die("call_indirect: index out of table bounds"); }
                int ci_fn = g_table[ci_slot];
                if (ci_fn < 0 || ci_fn >= g_nfuncs) { die("call_indirect: null/invalid table entry"); }
                if ((int)ci_type >= g_ntypes || g_funcs[ci_fn].type_idx != (int)ci_type) { die("call_indirect: signature mismatch"); }
                if (g_funcs[ci_fn].is_import) { host_call(g_funcs[ci_fn].host_id); }
                else { push_frame(ci_fn); }
            case OP_LOCAL_GET:
                uint li = imm_u32(fr);
                if ((int)li >= g_funcs[fr.func_idx].nlocals) { die("local idx"); }
                vpush(g_locals[fr.locals_base + (int)li]);
            case OP_LOCAL_SET:
                uint si = imm_u32(fr);
                if ((int)si >= g_funcs[fr.func_idx].nlocals) { die("local idx"); }
                g_locals[fr.locals_base + (int)si] = vpop();
            case OP_LOCAL_TEE:
                uint tti = imm_u32(fr);
                if ((int)tti >= g_funcs[fr.func_idx].nlocals) { die("local idx"); }
                g_locals[fr.locals_base + (int)tti] = g_vstack[g_vtop - 1];
            case OP_GLOBAL_GET:
                uint gi = imm_u32(fr);
                if ((int)gi >= g_nglobals) { die("global idx"); }
                vpush(g_globals[(int)gi]);
            case OP_GLOBAL_SET:
                uint gsi = imm_u32(fr);
                if ((int)gsi >= g_nglobals) { die("global idx"); }
                g_globals[(int)gsi] = vpop();
            case OP_I32_CONST: vpush((long)imm_i32(fr));
            case OP_I64_CONST: vpush(imm_i64(fr));
            case OP_F32_CONST:
                if (fr.ip + 4 > g_mod_len) { die("truncated f32.const"); }
                vpush((long)(*(uint*)&g_mod[fr.ip]));
                fr.ip += 4;
            case OP_F64_CONST:
                if (fr.ip + 8 > g_mod_len) { die("truncated f64.const"); }
                vpush(*(long*)&g_mod[fr.ip]);
                fr.ip += 8;

            // --- memory loads ---
            case OP_I32_LOAD:     uint e = mem_ea(fr, 4); vpush((long)*(int*)&g_mem[e]);
            case OP_I64_LOAD:     uint e = mem_ea(fr, 8); vpush(*(long*)&g_mem[e]);
            case OP_F32_LOAD:     uint e = mem_ea(fr, 4); vpush((long)(uint)*(uint*)&g_mem[e]);
            case OP_F64_LOAD:     uint e = mem_ea(fr, 8); vpush(*(long*)&g_mem[e]);
            case OP_I32_LOAD8_S:  uint e = mem_ea(fr, 1); vpush((long)(int)*(char*)&g_mem[e]);
            case OP_I32_LOAD8_U:  uint e = mem_ea(fr, 1); vpush((long)((uint)g_mem[e] & 0xff));
            case OP_I32_LOAD16_S: uint e = mem_ea(fr, 2); vpush((long)(int)*(short*)&g_mem[e]);
            case OP_I32_LOAD16_U: uint e = mem_ea(fr, 2); vpush((long)(uint)*(ushort*)&g_mem[e]);
            case OP_I64_LOAD8_S:  uint e = mem_ea(fr, 1); vpush((long)*(char*)&g_mem[e]);
            case OP_I64_LOAD8_U:  uint e = mem_ea(fr, 1); vpush((long)((ulong)g_mem[e] & 0xff));
            case OP_I64_LOAD16_S: uint e = mem_ea(fr, 2); vpush((long)*(short*)&g_mem[e]);
            case OP_I64_LOAD16_U: uint e = mem_ea(fr, 2); vpush((long)(ulong)*(ushort*)&g_mem[e]);
            case OP_I64_LOAD32_S: uint e = mem_ea(fr, 4); vpush((long)*(int*)&g_mem[e]);
            case OP_I64_LOAD32_U: uint e = mem_ea(fr, 4); vpush((long)(ulong)(uint)*(uint*)&g_mem[e]);

            // --- memory stores (value popped first, then address) ---
            case OP_I32_STORE:   long v = vpop(); uint e = mem_ea(fr, 4); *(int*)&g_mem[e] = (int)v;
            case OP_I64_STORE:   long v = vpop(); uint e = mem_ea(fr, 8); *(long*)&g_mem[e] = v;
            case OP_F32_STORE:   long v = vpop(); uint e = mem_ea(fr, 4); *(uint*)&g_mem[e] = (uint)v;
            case OP_F64_STORE:   long v = vpop(); uint e = mem_ea(fr, 8); *(long*)&g_mem[e] = v;
            case OP_I32_STORE8:  long v = vpop(); uint e = mem_ea(fr, 1); g_mem[e] = (char)v;
            case OP_I32_STORE16: long v = vpop(); uint e = mem_ea(fr, 2); *(ushort*)&g_mem[e] = (ushort)v;
            case OP_I64_STORE8:  long v = vpop(); uint e = mem_ea(fr, 1); g_mem[e] = (char)v;
            case OP_I64_STORE16: long v = vpop(); uint e = mem_ea(fr, 2); *(ushort*)&g_mem[e] = (ushort)v;
            case OP_I64_STORE32: long v = vpop(); uint e = mem_ea(fr, 4); *(uint*)&g_mem[e] = (uint)v;

            case OP_MEMORY_SIZE: imm_u32(fr); vpush((long)g_mem_pages);
            case OP_MEMORY_GROW: imm_u32(fr); int d = (int)vpop(); vpush((long)wasm_mem_grow(d));

            // --- i32 comparisons (result i32 0/1) ---
            case OP_I32_EQZ:  vpush((int)vpop() == 0 ? 1 : 0);
            case OP_I32_EQ:   int b = (int)vpop(); int a = (int)vpop(); vpush(a == b ? 1 : 0);
            case OP_I32_NE:   int b = (int)vpop(); int a = (int)vpop(); vpush(a != b ? 1 : 0);
            case OP_I32_LT_S: int b = (int)vpop(); int a = (int)vpop(); vpush(a < b ? 1 : 0);
            case OP_I32_LT_U: uint b = (uint)vpop(); uint a = (uint)vpop(); vpush(a < b ? 1 : 0);
            case OP_I32_GT_S: int b = (int)vpop(); int a = (int)vpop(); vpush(a > b ? 1 : 0);
            case OP_I32_GT_U: uint b = (uint)vpop(); uint a = (uint)vpop(); vpush(a > b ? 1 : 0);
            case OP_I32_LE_S: int b = (int)vpop(); int a = (int)vpop(); vpush(a <= b ? 1 : 0);
            case OP_I32_LE_U: uint b = (uint)vpop(); uint a = (uint)vpop(); vpush(a <= b ? 1 : 0);
            case OP_I32_GE_S: int b = (int)vpop(); int a = (int)vpop(); vpush(a >= b ? 1 : 0);
            case OP_I32_GE_U: uint b = (uint)vpop(); uint a = (uint)vpop(); vpush(a >= b ? 1 : 0);

            // --- i64 comparisons ---
            case OP_I64_EQZ:  vpush(vpop() == 0 ? 1 : 0);
            case OP_I64_EQ:   long b = vpop(); long a = vpop(); vpush(a == b ? 1 : 0);
            case OP_I64_NE:   long b = vpop(); long a = vpop(); vpush(a != b ? 1 : 0);
            case OP_I64_LT_S: long b = vpop(); long a = vpop(); vpush(a < b ? 1 : 0);
            case OP_I64_LT_U: ulong b = (ulong)vpop(); ulong a = (ulong)vpop(); vpush(a < b ? 1 : 0);
            case OP_I64_GT_S: long b = vpop(); long a = vpop(); vpush(a > b ? 1 : 0);
            case OP_I64_GT_U: ulong b = (ulong)vpop(); ulong a = (ulong)vpop(); vpush(a > b ? 1 : 0);
            case OP_I64_LE_S: long b = vpop(); long a = vpop(); vpush(a <= b ? 1 : 0);
            case OP_I64_LE_U: ulong b = (ulong)vpop(); ulong a = (ulong)vpop(); vpush(a <= b ? 1 : 0);
            case OP_I64_GE_S: long b = vpop(); long a = vpop(); vpush(a >= b ? 1 : 0);
            case OP_I64_GE_U: ulong b = (ulong)vpop(); ulong a = (ulong)vpop(); vpush(a >= b ? 1 : 0);

            // --- i32 numeric ---
            case OP_I32_CLZ:    vpush((long)clz32((uint)vpop()));
            case OP_I32_CTZ:    vpush((long)ctz32((uint)vpop()));
            case OP_I32_POPCNT: vpush((long)pop32((uint)vpop()));
            case OP_I32_ADD:    int b = (int)vpop(); int a = (int)vpop(); vpush((long)(a + b));
            case OP_I32_SUB:    int b = (int)vpop(); int a = (int)vpop(); vpush((long)(a - b));
            case OP_I32_MUL:    int b = (int)vpop(); int a = (int)vpop(); vpush((long)(a * b));
            case OP_I32_DIV_S:  int b = (int)vpop(); int a = (int)vpop();
                if (b == 0) { die("i32.div_s by zero"); }
                if (a == -2147483648 && b == -1) { die("i32.div_s overflow"); }
                vpush((long)(a / b));
            case OP_I32_DIV_U:  uint b = (uint)vpop(); uint a = (uint)vpop();
                if (b == 0) { die("i32.div_u by zero"); }
                vpush((long)(a / b));
            case OP_I32_REM_S:  int b = (int)vpop(); int a = (int)vpop();
                if (b == 0) { die("i32.rem_s by zero"); }
                vpush((long)(a == -2147483648 && b == -1 ? 0 : a % b));
            case OP_I32_REM_U:  uint b = (uint)vpop(); uint a = (uint)vpop();
                if (b == 0) { die("i32.rem_u by zero"); }
                vpush((long)(a % b));
            case OP_I32_AND:   int b = (int)vpop(); int a = (int)vpop(); vpush((long)(a & b));
            case OP_I32_OR:    int b = (int)vpop(); int a = (int)vpop(); vpush((long)(a | b));
            case OP_I32_XOR:   int b = (int)vpop(); int a = (int)vpop(); vpush((long)(a ^ b));
            case OP_I32_SHL:   uint b = (uint)vpop() & 31; uint a = (uint)vpop(); vpush((long)(int)(a << b));
            case OP_I32_SHR_S: uint b = (uint)vpop() & 31; int a = (int)vpop(); vpush((long)(a >> b));
            case OP_I32_SHR_U: uint b = (uint)vpop() & 31; uint a = (uint)vpop(); vpush((long)(int)(a >> b));
            case OP_I32_ROTL:  uint b = (uint)vpop() & 31; uint a = (uint)vpop();
                vpush((long)(int)(b == 0 ? a : (a << b) | (a >> (32 - b))));
            case OP_I32_ROTR:  uint b = (uint)vpop() & 31; uint a = (uint)vpop();
                vpush((long)(int)(b == 0 ? a : (a >> b) | (a << (32 - b))));

            // --- i64 numeric ---
            case OP_I64_CLZ:    vpush((long)clz64((ulong)vpop()));
            case OP_I64_CTZ:    vpush((long)ctz64((ulong)vpop()));
            case OP_I64_POPCNT: vpush((long)pop64((ulong)vpop()));
            case OP_I64_ADD:    long b = vpop(); long a = vpop(); vpush(a + b);
            case OP_I64_SUB:    long b = vpop(); long a = vpop(); vpush(a - b);
            case OP_I64_MUL:    long b = vpop(); long a = vpop(); vpush(a * b);
            case OP_I64_DIV_S:  long b = vpop(); long a = vpop();
                if (b == 0) { die("i64.div_s by zero"); }
                if (a == (long)0x8000000000000000 && b == -1) { die("i64.div_s overflow"); }
                vpush(a / b);
            case OP_I64_DIV_U:  ulong b = (ulong)vpop(); ulong a = (ulong)vpop();
                if (b == 0) { die("i64.div_u by zero"); }
                vpush((long)(a / b));
            case OP_I64_REM_S:  long b = vpop(); long a = vpop();
                if (b == 0) { die("i64.rem_s by zero"); }
                vpush(a == (long)0x8000000000000000 && b == -1 ? 0 : a % b);
            case OP_I64_REM_U:  ulong b = (ulong)vpop(); ulong a = (ulong)vpop();
                if (b == 0) { die("i64.rem_u by zero"); }
                vpush((long)(a % b));
            case OP_I64_AND:   long b = vpop(); long a = vpop(); vpush(a & b);
            case OP_I64_OR:    long b = vpop(); long a = vpop(); vpush(a | b);
            case OP_I64_XOR:   long b = vpop(); long a = vpop(); vpush(a ^ b);
            case OP_I64_SHL:   ulong b = (ulong)vpop() & 63; ulong a = (ulong)vpop(); vpush((long)(a << b));
            case OP_I64_SHR_S: ulong b = (ulong)vpop() & 63; long a = vpop(); vpush(a >> b);
            case OP_I64_SHR_U: ulong b = (ulong)vpop() & 63; ulong a = (ulong)vpop(); vpush((long)(a >> b));
            case OP_I64_ROTL:  ulong b = (ulong)vpop() & 63; ulong a = (ulong)vpop();
                vpush((long)(b == 0 ? a : (a << b) | (a >> (64 - b))));
            case OP_I64_ROTR:  ulong b = (ulong)vpop() & 63; ulong a = (ulong)vpop();
                vpush((long)(b == 0 ? a : (a >> b) | (a << (64 - b))));

            // --- conversions ---
            case OP_I32_WRAP_I64:     vpush((long)(int)vpop());
            case OP_I64_EXTEND_I32_S: vpush((long)(int)vpop());
            case OP_I64_EXTEND_I32_U: vpush((long)((ulong)(uint)vpop()));
            case OP_I32_EXTEND8_S:    vpush((long)(int)(char)(int)vpop());
            case OP_I32_EXTEND16_S:   vpush((long)(int)(short)(int)vpop());
            case OP_I64_EXTEND8_S:    vpush((long)(char)vpop());
            case OP_I64_EXTEND16_S:   vpush((long)(short)vpop());
            case OP_I64_EXTEND32_S:   vpush((long)(int)vpop());

            // --- f32/f64 comparisons (result i32 0/1) ---
            case OP_F32_EQ: float b = vpop_f32(); float a = vpop_f32(); vpush(a == b ? 1 : 0);
            case OP_F32_NE: float b = vpop_f32(); float a = vpop_f32(); vpush(a != b ? 1 : 0);
            case OP_F32_LT: float b = vpop_f32(); float a = vpop_f32(); vpush(a < b ? 1 : 0);
            case OP_F32_GT: float b = vpop_f32(); float a = vpop_f32(); vpush(a > b ? 1 : 0);
            case OP_F32_LE: float b = vpop_f32(); float a = vpop_f32(); vpush(a <= b ? 1 : 0);
            case OP_F32_GE: float b = vpop_f32(); float a = vpop_f32(); vpush(a >= b ? 1 : 0);
            case OP_F64_EQ: double b = vpop_f64(); double a = vpop_f64(); vpush(a == b ? 1 : 0);
            case OP_F64_NE: double b = vpop_f64(); double a = vpop_f64(); vpush(a != b ? 1 : 0);
            case OP_F64_LT: double b = vpop_f64(); double a = vpop_f64(); vpush(a < b ? 1 : 0);
            case OP_F64_GT: double b = vpop_f64(); double a = vpop_f64(); vpush(a > b ? 1 : 0);
            case OP_F64_LE: double b = vpop_f64(); double a = vpop_f64(); vpush(a <= b ? 1 : 0);
            case OP_F64_GE: double b = vpop_f64(); double a = vpop_f64(); vpush(a >= b ? 1 : 0);

            // --- f32 numeric ---
            case OP_F32_ABS:  uint u = (uint)vpop() & 0x7FFFFFFFu; vpush((long)u);
            case OP_F32_NEG:  uint u = (uint)vpop() ^ 0x80000000u; vpush((long)u);
            case OP_F32_CEIL:    vpush_f32((float)f_round_d((double)vpop_f32(), 1));
            case OP_F32_FLOOR:   vpush_f32((float)f_round_d((double)vpop_f32(), 2));
            case OP_F32_TRUNC:   vpush_f32((float)f_round_d((double)vpop_f32(), 3));
            case OP_F32_NEAREST: vpush_f32((float)f_round_d((double)vpop_f32(), 0));
            case OP_F32_SQRT: vpush_f32(f_sqrt_s(vpop_f32()));
            case OP_F32_ADD:  float b = vpop_f32(); float a = vpop_f32(); vpush_f32(a + b);
            case OP_F32_SUB:  float b = vpop_f32(); float a = vpop_f32(); vpush_f32(a - b);
            case OP_F32_MUL:  float b = vpop_f32(); float a = vpop_f32(); vpush_f32(a * b);
            case OP_F32_DIV:  float b = vpop_f32(); float a = vpop_f32(); vpush_f32(a / b);
            case OP_F32_MIN:  float b = vpop_f32(); float a = vpop_f32(); vpush_f32((float)f_min_d((double)a, (double)b));
            case OP_F32_MAX:  float b = vpop_f32(); float a = vpop_f32(); vpush_f32((float)f_max_d((double)a, (double)b));
            case OP_F32_COPYSIGN: uint sb = (uint)vpop(); uint sa = (uint)vpop();
                vpush((long)((sa & 0x7FFFFFFFu) | (sb & 0x80000000u)));

            // --- f64 numeric ---
            case OP_F64_ABS:  ulong u = (ulong)vpop() & 0x7FFFFFFFFFFFFFFFu; vpush((long)u);
            case OP_F64_NEG:  ulong u = (ulong)vpop() ^ 0x8000000000000000u; vpush((long)u);
            case OP_F64_CEIL:    vpush_f64(f_round_d(vpop_f64(), 1));
            case OP_F64_FLOOR:   vpush_f64(f_round_d(vpop_f64(), 2));
            case OP_F64_TRUNC:   vpush_f64(f_round_d(vpop_f64(), 3));
            case OP_F64_NEAREST: vpush_f64(f_round_d(vpop_f64(), 0));
            case OP_F64_SQRT: vpush_f64(f_sqrt_d(vpop_f64()));
            case OP_F64_ADD:  double b = vpop_f64(); double a = vpop_f64(); vpush_f64(a + b);
            case OP_F64_SUB:  double b = vpop_f64(); double a = vpop_f64(); vpush_f64(a - b);
            case OP_F64_MUL:  double b = vpop_f64(); double a = vpop_f64(); vpush_f64(a * b);
            case OP_F64_DIV:  double b = vpop_f64(); double a = vpop_f64(); vpush_f64(a / b);
            case OP_F64_MIN:  double b = vpop_f64(); double a = vpop_f64(); vpush_f64(f_min_d(a, b));
            case OP_F64_MAX:  double b = vpop_f64(); double a = vpop_f64(); vpush_f64(f_max_d(a, b));
            case OP_F64_COPYSIGN: ulong sb = (ulong)vpop(); ulong sa = (ulong)vpop();
                vpush((long)((sa & 0x7FFFFFFFFFFFFFFFu) | (sb & 0x8000000000000000u)));

            // --- float conversions ---
            case OP_I32_TRUNC_F32_S: vpush((long)f_trunc_to_i32((double)vpop_f32(), true));
            case OP_I32_TRUNC_F32_U: vpush((long)(uint)f_trunc_to_i32((double)vpop_f32(), false));
            case OP_I32_TRUNC_F64_S: vpush((long)f_trunc_to_i32(vpop_f64(), true));
            case OP_I32_TRUNC_F64_U: vpush((long)(uint)f_trunc_to_i32(vpop_f64(), false));
            case OP_I64_TRUNC_F32_S: vpush(f_trunc_to_i64((double)vpop_f32(), true));
            case OP_I64_TRUNC_F32_U: vpush(f_trunc_to_i64((double)vpop_f32(), false));
            case OP_I64_TRUNC_F64_S: vpush(f_trunc_to_i64(vpop_f64(), true));
            case OP_I64_TRUNC_F64_U: vpush(f_trunc_to_i64(vpop_f64(), false));
            case OP_F32_CONVERT_I32_S: vpush_f32((float)(int)vpop());
            case OP_F32_CONVERT_I32_U: vpush_f32((float)(uint)vpop());
            case OP_F32_CONVERT_I64_S: vpush_f32((float)vpop());
            case OP_F32_CONVERT_I64_U: vpush_f32((float)(ulong)vpop());
            case OP_F32_DEMOTE_F64:    vpush_f32((float)vpop_f64());
            case OP_F64_CONVERT_I32_S: vpush_f64((double)(int)vpop());
            case OP_F64_CONVERT_I32_U: vpush_f64((double)(uint)vpop());
            case OP_F64_CONVERT_I64_S: vpush_f64((double)vpop());
            case OP_F64_CONVERT_I64_U: vpush_f64((double)(ulong)vpop());
            case OP_F64_PROMOTE_F32:   vpush_f64((double)vpop_f32());
            case OP_I32_REINTERPRET_F32: vpush((long)((uint)vpop()));
            case OP_I64_REINTERPRET_F64: break;   // bits already there
            case OP_F32_REINTERPRET_I32: vpush((long)((uint)vpop()));
            case OP_F64_REINTERPRET_I64: break;   // bits already there

            case OP_PREFIX_FC:
                uint sub = imm_u32(fr);
                switch (sub)
                {
                    case FC_I32_TRUNC_SAT_F32_S: vpush((long)f_trunc_sat_i32((double)vpop_f32(), true));
                    case FC_I32_TRUNC_SAT_F32_U: vpush((long)(uint)f_trunc_sat_i32((double)vpop_f32(), false));
                    case FC_I32_TRUNC_SAT_F64_S: vpush((long)f_trunc_sat_i32(vpop_f64(), true));
                    case FC_I32_TRUNC_SAT_F64_U: vpush((long)(uint)f_trunc_sat_i32(vpop_f64(), false));
                    case FC_I64_TRUNC_SAT_F32_S: vpush(f_trunc_sat_i64((double)vpop_f32(), true));
                    case FC_I64_TRUNC_SAT_F32_U: vpush(f_trunc_sat_i64((double)vpop_f32(), false));
                    case FC_I64_TRUNC_SAT_F64_S: vpush(f_trunc_sat_i64(vpop_f64(), true));
                    case FC_I64_TRUNC_SAT_F64_U: vpush(f_trunc_sat_i64(vpop_f64(), false));
                    // memory.copy: stack (bottom->top) is [d, s, n]; pop
                    // order is n, s, d. Overlap-safe (memmove, not
                    // memcpy) — std::nolibc::mem::copy() explicitly
                    // doesn't guarantee that, and wasm programs are
                    // free to pass overlapping ranges.
                    case FC_MEMORY_COPY:
                        imm_u32(fr); imm_u32(fr);   // reserved dst/src memidx (always 0)
                        uint cn = (uint)vpop();
                        uint cs = (uint)vpop();
                        uint cd = (uint)vpop();
                        char* cdst = mem_ptr(cd, cn);
                        char* csrc = mem_ptr(cs, cn);
                        if (cd <= cs)
                        {
                            for (uint i = 0; i < cn; i++) { cdst[i] = csrc[i]; }
                        }
                        else
                        {
                            for (uint i = cn; i > 0; i--) { cdst[i - 1] = csrc[i - 1]; }
                        }
                    // memory.fill: stack is [d, val, n]; pop order n, val, d.
                    case FC_MEMORY_FILL:
                        imm_u32(fr);                // reserved memidx (always 0)
                        uint fn_ = (uint)vpop();
                        char fval = (char)(uint)vpop();
                        uint fd = (uint)vpop();
                        char* fdst = mem_ptr(fd, fn_);
                        for (uint i = 0; i < fn_; i++) { fdst[i] = fval; }
                    default: die("unimplemented 0xfc subop");
                }

            default:
                print("wasm: unimplemented opcode 0x");
                print_hex8((uint)(char)op & 0xff);
                putchar('\n');
                exitcode(1);
        }
    }
}

fn int find_export_func(char* nm)
{
    for (int i = 0; i < g_nexports; i++)
    {
        if (g_exports[i].kind == EXT_FUNC && strcmp(&g_exports[i].name[0], nm) == 0)
        {
            return g_exports[i].index;
        }
    }
    return -1;
}

fn void main(String[] args)
{
    if (args.len < 1) { die("usage: wasm <file.wasm> [args]"); }
    char* path = args[0].ptr;

    uint fsize = 0;
    int ftype = 0;
    if (fs_stat(path, &fsize, &ftype) != 0) { die("no such file"); }
    if (ftype != 0) { die("not a file"); }
    if (fsize == 0 || fsize > MODULE_MAX) { die("module size out of range"); }

    // one map_pages for the module + all the tables/stacks
    g_mod = wasm_alloc(fsize);
    g_mod_len = fsize;
    g_types    = (WType*)wasm_alloc((uint)(TYPES_MAX * WType::size));
    g_funcs    = (WFunc*)wasm_alloc((uint)(FUNCS_MAX * WFunc::size));
    g_exports  = (WExport*)wasm_alloc((uint)(EXPORTS_MAX * WExport::size));
    g_globals  = (long*)wasm_alloc((uint)(GLOBALS_MAX * 8));
    g_vstack   = (long*)wasm_alloc((uint)(VSTACK_MAX * 8));
    g_locals   = (long*)wasm_alloc((uint)(LOCALS_MAX * 8));
    g_frames   = (WFrame*)wasm_alloc((uint)(FRAMES_MAX * WFrame::size));
    g_blocks   = (WBlock*)wasm_alloc((uint)(BLOCKS_MAX * WBlock::size));
    g_ctl      = (WCtl*)wasm_alloc((uint)(CTL_MAX * WCtl::size));
    g_table    = (int*)wasm_alloc((uint)(TABLE_MAX * 4));

    // args after the .wasm path are the guest program's argv (host `arg`)
    g_args = args[1..];

    // read the whole file
    uint total = 0;
    while (total < fsize)
    {
        int chunk = (int)(fsize - total);
        if (chunk > 1024) { chunk = 1024; }
        int got = fs_read_at(path, &g_mod[total], chunk, total);
        if (got < 0) { die("read failed"); }
        if (got == 0) { break; }
        total += (uint)got;
    }
    if (total != fsize) { die("short read"); }

    decode_module();

    // SEC_START: run the module's start function to completion first
    if (g_start_func >= 0)
    {
        if (g_funcs[g_start_func].is_import) { die("start is an import"); }
        if (g_types[g_funcs[g_start_func].type_idx].nparams != 0) { die("start takes params"); }
        push_frame(g_start_func);
        interp();
        g_vtop = 0;
    }

    int start = find_export_func("_start");
    if (start < 0) { start = find_export_func("main"); }
    if (start < 0) { die("no _start or main export"); }
    if (g_funcs[start].is_import) { die("_start is an import"); }
    if (g_types[g_funcs[start].type_idx].nparams != 0) { die("_start takes params"); }

    push_frame(start);
    interp();

    // _start's result (if any) is the exit code
    int code = 0;
    if (g_vtop > 0) { code = (int)g_vstack[g_vtop - 1]; }
    exitcode(code);
}
