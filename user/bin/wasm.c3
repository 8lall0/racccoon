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
// Milestone 1a: the module skeleton + a minimal integer opcode set
// (const / local / global / call / add-sub-mul / return). Enough to run
// a hand-built module that computes 2+3 and prints 5. Later milestones
// grow the opcode table, control flow, memory, floats, more host
// functions.
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
const char OP_END         = 0x0b;
const char OP_RETURN      = 0x0f;
const char OP_CALL        = 0x10;
const char OP_DROP        = 0x1a;
const char OP_SELECT      = 0x1b;
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

// conversions
const char OP_I32_WRAP_I64    = 0xa7;
const char OP_I64_EXTEND_I32_S = 0xac; const char OP_I64_EXTEND_I32_U = 0xad;
const char OP_I32_EXTEND8_S  = 0xc0; const char OP_I32_EXTEND16_S = 0xc1;
const char OP_I64_EXTEND8_S  = 0xc2; const char OP_I64_EXTEND16_S = 0xc3;
const char OP_I64_EXTEND32_S = 0xc4;

const int WPAGE = 65536;             // wasm linear-memory page size
const int MEM_HARD_CAP_PAGES = 240;  // ~15 MiB — under HEAP_MAX_BYTES with room for the other allocs

// host function ids (module "racccoon")
const int HOST_PRINT_I32 = 0;
const int HOST_PROC_EXIT = 1;
const int HOST_COUNT     = 2;

// --- limits (grow as real modules need) -------------------------------
const int TYPES_MAX    = 128;
const int FUNCS_MAX    = 512;
const int EXPORTS_MAX  = 128;
const int GLOBALS_MAX  = 128;
const int PARAMS_MAX   = 16;
const int VSTACK_MAX   = 8192;   // 64 KiB
const int LOCALS_MAX   = 8192;   // 64 KiB
const int FRAMES_MAX   = 512;
const int MODULE_MAX   = 512 * 1024;

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
    if (strcmp(fld, "print_i32") == 0) { return HOST_PRINT_I32; }
    if (strcmp(fld, "proc_exit") == 0) { return HOST_PROC_EXIT; }
    return -1;
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
        // init expr — a single const opcode then END, this milestone
        char op = cur_byte(c);
        if (op == OP_I32_CONST) { g_globals[i] = (long)read_i32(c); }
        else if (op == OP_I64_CONST) { g_globals[i] = read_i64(c); }
        else { die("global init expr unsupported"); }
        if (cur_byte(c) != OP_END) { die("global init not END-terminated"); }
    }
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
                case SEC_TABLE:  break; // 1d
                case SEC_MEM:    decode_mem(&sc);
                case SEC_GLOBAL: decode_globals(&sc);
                case SEC_EXPORT: decode_exports(&sc);
                case SEC_START:  break; // 1d
                case SEC_ELEM:   break; // 1d
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

fn void host_call(int host_id)
{
    switch (host_id)
    {
        case HOST_PRINT_I32:
            int v = (int)vpop();
            print_int32(v);
            putchar('\n');
        case HOST_PROC_EXIT:
            exitcode((int)vpop());
        default:
            die("unresolved host import");
    }
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
    g_fcount--;
    if (nres == 1) { vpush(r0); }
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
            case OP_END:      frame_return();     // no blocks yet -> function end
            case OP_RETURN:   frame_return();
            case OP_DROP:     vpop();
            case OP_SELECT:
                long sc = vpop(); long sv2 = vpop(); long sv1 = vpop();
                vpush((int)sc != 0 ? sv1 : sv2);
            case OP_CALL:
                uint callee = imm_u32(fr);
                if ((int)callee >= g_nfuncs) { die("call idx"); }
                if (g_funcs[callee].is_import) { host_call(g_funcs[callee].host_id); }
                else { push_frame((int)callee); }
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
