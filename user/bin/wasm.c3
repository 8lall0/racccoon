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

// opcodes handled this milestone
const char OP_UNREACHABLE = 0x00;
const char OP_NOP         = 0x01;
const char OP_END         = 0x0b;
const char OP_RETURN      = 0x0f;
const char OP_CALL        = 0x10;
const char OP_DROP        = 0x1a;
const char OP_LOCAL_GET   = 0x20;
const char OP_LOCAL_SET   = 0x21;
const char OP_LOCAL_TEE   = 0x22;
const char OP_GLOBAL_GET  = 0x23;
const char OP_GLOBAL_SET  = 0x24;
const char OP_I32_CONST   = 0x41;
const char OP_I64_CONST   = 0x42;
const char OP_I32_ADD     = 0x6a;
const char OP_I32_SUB     = 0x6b;
const char OP_I32_MUL     = 0x6c;

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
                case SEC_MEM:    break; // 1b
                case SEC_GLOBAL: decode_globals(&sc);
                case SEC_EXPORT: decode_exports(&sc);
                case SEC_START:  break; // 1d
                case SEC_ELEM:   break; // 1d
                case SEC_CODE:   decode_code(&sc);
                case SEC_DATA:   break; // 1b
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
            case OP_NOP:
                break;
            case OP_UNREACHABLE:
                die("unreachable executed");
            case OP_END:
                // no blocks yet -> end of function
                frame_return();
            case OP_RETURN:
                frame_return();
            case OP_DROP:
                vpop();
            case OP_CALL:
                Cur cc; cc.p = fr.ip; cc.end = g_mod_len;
                uint callee = read_u32(&cc);
                fr.ip = cc.p;
                if ((int)callee >= g_nfuncs) { die("call idx"); }
                if (g_funcs[callee].is_import)
                {
                    host_call(g_funcs[callee].host_id);
                }
                else
                {
                    push_frame((int)callee);
                }
            case OP_LOCAL_GET:
                Cur lg; lg.p = fr.ip; lg.end = g_mod_len;
                uint li = read_u32(&lg);
                fr.ip = lg.p;
                if ((int)li >= g_funcs[fr.func_idx].nlocals) { die("local idx"); }
                vpush(g_locals[fr.locals_base + (int)li]);
            case OP_LOCAL_SET:
                Cur ls; ls.p = fr.ip; ls.end = g_mod_len;
                uint si = read_u32(&ls);
                fr.ip = ls.p;
                if ((int)si >= g_funcs[fr.func_idx].nlocals) { die("local idx"); }
                g_locals[fr.locals_base + (int)si] = vpop();
            case OP_LOCAL_TEE:
                Cur lt; lt.p = fr.ip; lt.end = g_mod_len;
                uint ti = read_u32(&lt);
                fr.ip = lt.p;
                if ((int)ti >= g_funcs[fr.func_idx].nlocals) { die("local idx"); }
                g_locals[fr.locals_base + (int)ti] = g_vstack[g_vtop - 1];
            case OP_GLOBAL_GET:
                Cur gg; gg.p = fr.ip; gg.end = g_mod_len;
                uint gi = read_u32(&gg);
                fr.ip = gg.p;
                if ((int)gi >= g_nglobals) { die("global idx"); }
                vpush(g_globals[(int)gi]);
            case OP_GLOBAL_SET:
                Cur gs; gs.p = fr.ip; gs.end = g_mod_len;
                uint gsi = read_u32(&gs);
                fr.ip = gs.p;
                if ((int)gsi >= g_nglobals) { die("global idx"); }
                g_globals[(int)gsi] = vpop();
            case OP_I32_CONST:
                Cur ic; ic.p = fr.ip; ic.end = g_mod_len;
                int iv = read_i32(&ic);
                fr.ip = ic.p;
                vpush((long)iv);
            case OP_I64_CONST:
                Cur jc; jc.p = fr.ip; jc.end = g_mod_len;
                long jv = read_i64(&jc);
                fr.ip = jc.p;
                vpush(jv);
            case OP_I32_ADD:
                int a2 = (int)vpop(); int a1 = (int)vpop();
                vpush((long)(a1 + a2));
            case OP_I32_SUB:
                int s2 = (int)vpop(); int s1 = (int)vpop();
                vpush((long)(s1 - s2));
            case OP_I32_MUL:
                int m2 = (int)vpop(); int m1 = (int)vpop();
                vpush((long)(m1 * m2));
            default:
                print("wasm: unimplemented opcode 0x");
                print_hex8((uint)(char)op);
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
