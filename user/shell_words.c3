module user;

// Word expansion for the shell — everything that turns one raw pipeline
// segment's text into a list of argv words. Split out of
// shell_common.c3; shell_run_pipeline drives it (shell_expand_q, then
// per-word shell_brace_expand, then shell_glob_into). shell_test.c3's
// dev-command path also uses the simpler shell_expand.

fn bool sh_name_start(char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'; }
fn bool sh_name_char(char c)  { return sh_name_start(c) || (c >= '0' && c <= '9'); }

// Positional parameters for `. script a b c` / `#!` scripts (§2.5 S2).
// $1..$9, $#, $* — set by shell_run_script (shell_common.c3), saved and
// restored around a nested source so `. inner` doesn't clobber the
// outer script's args.
const int SH_PARG_MAX = 9;
const int SH_PARG_LEN = 128;
char[SH_PARG_LEN][SH_PARG_MAX] g_shell_pargs;
int g_shell_pargc = 0;

// Shell-local variables (§2.5 S3): `NAME=value` sets one, `$NAME` reads
// it. Checked ahead of /env/<name> in shell_var_value, so a script can
// keep a loop counter without an envd round-trip per iteration. A small
// fixed table — scripts that need more are past what this shell is for.
const int SH_VAR_MAX  = 24;
const int SH_VNAME_MAX = 32;
const int SH_VVAL_MAX  = 192;
char[SH_VNAME_MAX][SH_VAR_MAX] g_shell_vnames;
char[SH_VVAL_MAX][SH_VAR_MAX]  g_shell_vvals;
int g_shell_nvars = 0;

// -1 if `name` isn't a set shell-local.
fn int shell_local_slot(char* name)
{
    for (int i = 0; i < g_shell_nvars; i++) {
        if (strcmp(&g_shell_vnames[i][0], name) == 0) { return i; }
    }
    return -1;
}

// Set (or replace) a shell-local. Silently ignored past SH_VAR_MAX.
fn void shell_local_set(char* name, char* value)
{
    int s = shell_local_slot(name);
    if (s < 0) {
        if (g_shell_nvars >= SH_VAR_MAX) { return; }
        s = g_shell_nvars;
        g_shell_nvars++;
        int k = 0;
        while (name[k] != 0 && k < SH_VNAME_MAX - 1) { g_shell_vnames[s][k] = name[k]; k++; }
        g_shell_vnames[s][k] = 0;
    }
    int k = 0;
    while (value[k] != 0 && k < SH_VVAL_MAX - 1) { g_shell_vvals[s][k] = value[k]; k++; }
    g_shell_vvals[s][k] = 0;
}

// Command substitution (§2.5 S5): `` `{cmd} `` (rc's form) or `` `cmd` ``
// (traditional). in[i] is the char right after the opening backtick.
// Copies the inner command into `inner` (cap incl. NUL) and returns the
// number of bytes consumed from in[i] *including* the closing delimiter,
// or 0 if it never closes.
fn int sh_read_cmdsub(char* in, int i, char* inner, int cap)
{
    int n = 0;
    if (in[i] == '{') {
        int depth = 0;
        int j = i;
        for (; in[j] != 0; j++) {
            if (in[j] == '{') { depth++; }
            else if (in[j] == '}') {
                depth--;
                if (depth == 0) {
                    int k0 = i + 1;
                    while (k0 < j && n < cap - 1) { inner[n] = in[k0]; n++; k0++; }
                    inner[n] = 0;
                    return (j - i) + 1;        // through the `}`
                }
            }
        }
        return 0;
    }
    // `...` form
    int j = i;
    while (in[j] != 0 && in[j] != '`') {
        if (in[j] == '\\' && in[j + 1] != 0) { j++; }
        if (n < cap - 1) { inner[n] = in[j]; n++; }
        j++;
    }
    if (in[j] != '`') { return 0; }
    inner[n] = 0;
    return (j - i) + 1;                        // through the closing backtick
}

// Read the variable name that follows a `$` (in[i] is the first char
// after it) into name (>= 32 bytes). Returns the number of chars
// consumed from in[i], or 0 if in[i] doesn't begin one. Handles the
// special one-char names `#` / `*` / `1`..`9` as well as ordinary
// [A-Za-z_][A-Za-z0-9_]* identifiers.
fn int sh_read_varname(char* in, int i, char* name)
{
    char c = in[i];
    if (c == '#' || c == '*' || (c >= '1' && c <= '9')) {
        name[0] = c; name[1] = 0;
        return 1;
    }
    if (!sh_name_start(c)) { return 0; }
    int n = 0;
    while (sh_name_char(in[i + n]) && n < 31) { name[n] = in[i + n]; n++; }
    name[n] = 0;
    return n;
}

// Value of $<name>, into out (cap includes the NUL). "user"/"cwd"
// (alias "PWD")/"home" are synthesised from the shell's own state;
// everything else reads /env/<name> (empty if unset — Plan 9 rc
// treats an unset variable as the empty list).
fn int shell_var_value(char* name, char* out, int cap)
{
    if (strcmp(name, "user") == 0) {
        int k = 0;
        while (g_shell_user[k] != 0 && k < cap - 1) { out[k] = g_shell_user[k]; k++; }
        out[k] = 0;
        return k;
    }
    if (strcmp(name, "cwd") == 0 || strcmp(name, "PWD") == 0) {
        int n = getcwd(out, cap);
        if (n <= 0) { out[0] = '/'; out[1] = 0; return 1; }
        return n;
    }
    if (strcmp(name, "status") == 0) {
        // Exit status of the last command (rc's $status). Decimal, and
        // negative codes (e.g. -1 for a killed command) print with a
        // leading '-'.
        int v = g_shell_status;
        int k = 0;
        if (v < 0) { if (k < cap - 1) { out[k] = '-'; k++; } v = -v; }
        char[12] digs @noinit;
        int d = 0;
        digs[d] = (char)('0' + v % 10); d++; v /= 10;
        while (v > 0) { digs[d] = (char)('0' + v % 10); d++; v /= 10; }
        while (d > 0 && k < cap - 1) { d--; out[k] = digs[d]; k++; }
        out[k] = 0;
        return k;
    }
    // Positional parameters. $# = count, $* = all joined by one space,
    // $1..$9 = one arg ("" past the end, rc's unset-is-empty rule).
    if (name[0] == '#' && name[1] == 0) {
        int v = g_shell_pargc;
        char[12] digs @noinit;
        int d = 0;
        digs[d] = (char)('0' + v % 10); d++; v /= 10;
        while (v > 0) { digs[d] = (char)('0' + v % 10); d++; v /= 10; }
        int k = 0;
        while (d > 0 && k < cap - 1) { d--; out[k] = digs[d]; k++; }
        out[k] = 0;
        return k;
    }
    if (name[0] == '*' && name[1] == 0) {
        int k = 0;
        for (int a = 0; a < g_shell_pargc; a++) {
            if (a > 0 && k < cap - 1) { out[k] = ' '; k++; }
            for (int j = 0; g_shell_pargs[a][j] != 0 && k < cap - 1; j++) { out[k] = g_shell_pargs[a][j]; k++; }
        }
        out[k] = 0;
        return k;
    }
    if (name[0] >= '1' && name[0] <= '9' && name[1] == 0) {
        int idx = name[0] - '1';
        int k = 0;
        if (idx < g_shell_pargc) {
            while (g_shell_pargs[idx][k] != 0 && k < cap - 1) { out[k] = g_shell_pargs[idx][k]; k++; }
        }
        out[k] = 0;
        return k;
    }
    if (strcmp(name, "home") == 0) {
        int k = 0;
        char* pfx = "/usr/";
        while (pfx[k] != 0 && k < cap - 1) { out[k] = pfx[k]; k++; }
        for (int j = 0; g_shell_user[j] != 0 && k < cap - 1; j++) { out[k] = g_shell_user[j]; k++; }
        out[k] = 0;
        return k;
    }
    // Shell-local (set by `NAME=value`, §2.5 S3) — ahead of /env.
    int ls = shell_local_slot(name);
    if (ls >= 0) {
        int k = 0;
        while (g_shell_vvals[ls][k] != 0 && k < cap - 1) { out[k] = g_shell_vvals[ls][k]; k++; }
        out[k] = 0;
        return k;
    }

    char[80] path @noinit;
    char* ep = "/env/";
    int p = 0;
    while (ep[p] != 0) { path[p] = ep[p]; p++; }
    for (int j = 0; name[j] != 0 && p < 79; j++) { path[p] = name[j]; p++; }
    path[p] = 0;
    int n = fs_read(&path[0], out, cap - 1);
    if (n < 0) n = 0;
    out[n] = 0;
    return n;
}

// Expand $<name> references in `in` into `out` (cap includes the NUL).
// A `$` not followed by a name character is left literal. No braces,
// no quotes yet.
fn void shell_expand(char* in, char* out, int cap)
{
    int o = 0;
    int i = 0;
    while (in[i] != 0 && o < cap - 1) {
        if (in[i] == '$') {
            char[32] name @noinit;
            int consumed = sh_read_varname(in, i + 1, &name[0]);
            if (consumed > 0) {
                i += 1 + consumed;
                char[256] val @noinit;
                int vl = shell_var_value(&name[0], &val[0], 256);
                for (int k = 0; k < vl && o < cap - 1; k++) { out[o] = val[k]; o++; }
                continue;
            }
        }
        if (in[i] == '`') {
            char[256] inner @noinit;
            int consumed = sh_read_cmdsub(in, i + 1, &inner[0], 256);
            if (consumed > 0) {
                i += 1 + consumed;
                char[512] cap_out @noinit;
                int cl = shell_capture(&inner[0], &cap_out[0], 512);
                for (int k = 0; k < cl && o < cap - 1; k++) { out[o] = cap_out[k]; o++; }
                continue;
            }
        }
        out[o] = in[i];
        o++;
        i++;
    }
    out[o] = 0;
}

// Quote-aware expansion for one pipeline segment. Copies `in` to `out`
// with the quote characters removed, expanding $name (via
// shell_var_value) except inside '...'. qmask[k] is 1 for every out[k]
// that came from inside quotes (or from a double-quoted expansion, or a
// backslash escape) — the tokeniser treats those bytes as ordinary
// text: never a word split, never an operator, never a glob metachar,
// never a $. Single quotes are fully literal, and '' is a literal '.
// Double quotes are literal except $name still expands (its bytes
// marked quoted, so "$x" stays one word) and \ escapes $ ` " \.
// Outside quotes, \<char> takes <char> literally (\  is an escaped
// space, \| an escaped pipe, …); a trailing \ is itself literal.
// Returns the out length, or -1 on an unterminated quote.
fn int shell_expand_q(char* in, char* out, char* qmask, int cap)
{
    int o = 0;
    int i = 0;
    while (in[i] != 0 && o < cap - 1) {
        char c = in[i];
        if (c == '\\') {
            char nx = in[i + 1];
            if (nx == 0) {
                if (o < cap - 1) { out[o] = '\\'; qmask[o] = 1; o++; }
                i++;
                continue;
            }
            if (o < cap - 1) { out[o] = nx; qmask[o] = 1; o++; }
            i += 2;
            continue;
        }
        if (c == '\'') {
            i++;
            for (;;) {
                if (in[i] == 0) { return -1; }
                if (in[i] == '\'') {
                    if (in[i + 1] == '\'') {
                        if (o < cap - 1) { out[o] = '\''; qmask[o] = 1; o++; }
                        i += 2; continue;
                    }
                    i++; break;
                }
                if (o < cap - 1) { out[o] = in[i]; qmask[o] = 1; o++; }
                i++;
            }
            continue;
        }
        if (c == '"') {
            i++;
            for (;;) {
                if (in[i] == 0) { return -1; }
                if (in[i] == '"') { i++; break; }
                if (in[i] == '\\' && (in[i + 1] == '"' || in[i + 1] == '\\' || in[i + 1] == '$' || in[i + 1] == '`')) {
                    if (o < cap - 1) { out[o] = in[i + 1]; qmask[o] = 1; o++; }
                    i += 2;
                    continue;
                }
                char[32] nm @noinit;
                int consumed = in[i] == '$' ? sh_read_varname(in, i + 1, &nm[0]) : 0;
                char[256] cin @noinit;
                int csub = (consumed == 0 && in[i] == '`') ? sh_read_cmdsub(in, i + 1, &cin[0], 256) : 0;
                if (consumed > 0) {
                    i += 1 + consumed;
                    char[256] val @noinit;
                    int vl = shell_var_value(&nm[0], &val[0], 256);
                    for (int k = 0; k < vl && o < cap - 1; k++) { out[o] = val[k]; qmask[o] = 1; o++; }
                } else if (csub > 0) {
                    i += 1 + csub;
                    char[512] cv @noinit;
                    int cl = shell_capture(&cin[0], &cv[0], 512);
                    for (int k = 0; k < cl && o < cap - 1; k++) { out[o] = cv[k]; qmask[o] = 1; o++; }
                } else {
                    if (o < cap - 1) { out[o] = in[i]; qmask[o] = 1; o++; }
                    i++;
                }
            }
            continue;
        }
        if (c == '$') {
            char[32] nm @noinit;
            int consumed = sh_read_varname(in, i + 1, &nm[0]);
            if (consumed > 0) {
                i += 1 + consumed;
                char[256] val @noinit;
                int vl = shell_var_value(&nm[0], &val[0], 256);
                for (int k = 0; k < vl && o < cap - 1; k++) { out[o] = val[k]; qmask[o] = 0; o++; }
                continue;
            }
        }
        if (c == '`') {
            char[256] cin @noinit;
            int csub = sh_read_cmdsub(in, i + 1, &cin[0], 256);
            if (csub > 0) {
                i += 1 + csub;
                char[512] cv @noinit;
                int cl = shell_capture(&cin[0], &cv[0], 512);
                for (int k = 0; k < cl && o < cap - 1; k++) { out[o] = cv[k]; qmask[o] = 0; o++; }
                continue;
            }
        }
        out[o] = c; qmask[o] = 0; o++;
        i++;
    }
    out[o] = 0;
    return o;
}

// Glob: does `name` match `pat`? `*` is any run (including empty), `?`
// is exactly one character; everything else is literal. Standard
// linear-time backtracking match. `pat` here is one path component —
// shell_glob_into() splits a pattern on its last '/' first.
fn bool glob_match(char* pat, char* name)
{
    int p = 0;
    int n = 0;
    int star_p = -1;
    int star_n = 0;
    while (name[n] != 0) {
        if (pat[p] == '?' || (pat[p] != 0 && pat[p] == name[n])) {
            p++; n++;
        } else if (pat[p] == '*') {
            star_p = p; star_n = n; p++;
        } else if (star_p >= 0) {
            p = star_p + 1; star_n++; n = star_n;
        } else {
            return false;
        }
    }
    while (pat[p] == '*') { p++; }
    return pat[p] == 0;
}

// Expand the glob pattern `pat` against the filesystem, appending each
// matching path to `words[*sw..]` (bounded by sw_cap) with the string
// bytes packed into `names[*nb..]` (bounded by nb_cap). Only the last
// path component may hold `*` / `?`; earlier components are literal.
// Returns the match count — 0 means "no match", and the caller keeps
// the pattern literal (rc's behaviour, not sh's).
fn int shell_glob_into(char* pat, char* names, int* nb, int nb_cap, char** words, int* sw, int sw_cap)
{
    int slash = -1;
    for (int k = 0; pat[k] != 0; k++) { if (pat[k] == '/') { slash = k; } }

    char[100] dir @noinit;
    char* base;
    if (slash < 0) {
        dir[0] = '.'; dir[1] = 0;
        base = pat;
    } else {
        int d = 0;
        while (d <= slash && d < 99) { dir[d] = pat[d]; d++; }
        dir[d] = 0;                 // keeps the trailing '/'
        base = &pat[slash + 1];
        if (base[0] == 0) { return 0; }
    }

    // FS_LIST_ENTRY_SIZE (36) * N. fs_list() pages fsd internally, so N
    // just caps how many matches one glob can yield — 16 was too few
    // (`tcc /src/*.c` on a 19-file dir silently dropped 3). 64 * 36 =
    // 2304 B on the stack, still modest.
    char[36 * 64] lb @noinit;
    int cnt = fs_list(&dir[0], &lb[0], 64);
    if (cnt < 0) { return 0; }

    int matched = 0;
    for (int e = 0; e < cnt; e++) {
        char* nm = &lb[e * 36];
        if (!glob_match(base, nm)) { continue; }
        if (*sw >= sw_cap) { break; }
        int start = *nb;
        int w = start;
        if (slash >= 0) {
            for (int k = 0; k <= slash && w < nb_cap - 1; k++) { names[w] = pat[k]; w++; }
        }
        for (int k = 0; nm[k] != 0 && w < nb_cap - 1; k++) { names[w] = nm[k]; w++; }
        if (w >= nb_cap - 1) { break; }
        names[w] = 0; w++;
        words[*sw] = &names[start];
        (*sw)++;
        *nb = w;
        matched++;
    }
    return matched;
}

// --- brace expansion --------------------------------------------------
// `{a,b}c` -> "ac" "bc"; `pre{x,y}post` and `{a,b}{c,d}` cartesian;
// nested `{a,{b,c}}` too. A brace group with no top-level comma (`{a}`,
// a leftover `${x}`) and an unmatched `{` are both left literal. Only
// unquoted `{ , }` play (qmask 0). Quoting is honoured at the token's
// first brace; deeper levels operate on the already-assembled string,
// so a quoted brace *inside* a brace alternative isn't re-protected —
// an obscure case real use never hits (`ls *.{c3,md}`, `mkdir {a,b}`).

const int BRACE_MAX     = 24;   // per-token expansion cap
const int BRACE_BUF     = 1024; // packed result storage (brace tokens only)
const int BRACE_DEPTH   = 8;

// Locate the token's first unquoted `{`, its matching `}`, and the
// top-level (depth 1) comma positions. `qm` may be null (recursion,
// where alignment is lost — then every brace counts). Returns the comma
// count; *open_out < 0 means "no expandable brace here".
fn int shell_brace_split(char* s, char* qm, int* open_out, int* close_out, int* commas, int commas_max)
{
    int open = -1;
    for (int k = 0; s[k] != 0; k++) {
        if (s[k] == '{' && (qm == null || qm[k] == 0)) { open = k; break; }
    }
    if (open < 0) { *open_out = -1; return 0; }

    int depth = 0;
    int nc = 0;
    for (int j = open; s[j] != 0; j++) {
        if (qm != null && qm[j] != 0) { continue; }
        char ch = s[j];
        if (ch == '{') { depth++; }
        else if (ch == '}') {
            depth--;
            if (depth == 0) { *open_out = open; *close_out = j; return nc; }
        }
        else if (ch == ',' && depth == 1) {
            if (nc < commas_max) { commas[nc] = j; }
            nc++;
        }
    }
    *open_out = -1;   // unmatched `{`
    return 0;
}

// Append `s` verbatim as one result.
fn int shell_brace_emit(char* s, char* buf, int* bo, int buf_cap, char** res, int* rn, int res_max)
{
    if (*rn >= res_max) { return 0; }
    int start = *bo;
    int w = start;
    for (int k = 0; s[k] != 0 && w < buf_cap - 1; k++) { buf[w] = s[k]; w++; }
    if (w >= buf_cap - 1) { return 0; }
    buf[w] = 0; w++;
    res[*rn] = &buf[start];
    (*rn)++;
    *bo = w;
    return 1;
}

fn int shell_brace_rec(char* s, char* qm, char* buf, int* bo, int buf_cap, char** res, int* rn, int res_max, int depth)
{
    int open = -1;
    int close = -1;
    int[BRACE_MAX] commas @noinit;
    int nc = shell_brace_split(s, qm, &open, &close, &commas[0], BRACE_MAX);

    if (open < 0 || nc == 0 || nc >= BRACE_MAX || depth >= BRACE_DEPTH || *rn >= res_max) {
        return shell_brace_emit(s, buf, bo, buf_cap, res, rn, res_max);
    }

    int total = 0;
    int seg_start = open + 1;
    for (int a = 0; a <= nc; a++) {
        int seg_end = a < nc ? commas[a] : close;
        char[256] combo @noinit;
        int w = 0;
        for (int k = 0; k < open && w < 255; k++) { combo[w] = s[k]; w++; }
        for (int k = seg_start; k < seg_end && w < 255; k++) { combo[w] = s[k]; w++; }
        for (int k = close + 1; s[k] != 0 && w < 255; k++) { combo[w] = s[k]; w++; }
        combo[w] = 0;
        total += shell_brace_rec(&combo[0], null, buf, bo, buf_cap, res, rn, res_max, depth + 1);
        seg_start = seg_end + 1;
    }
    return total;
}

// Expand `tok` (qmask slice `qm`) into `res[]`, strings packed into
// `buf[*bo..]`. Returns the result count (also left in *rn).
fn int shell_brace_expand(char* tok, char* qm, char* buf, int* bo, int buf_cap, char** res, int* rn, int res_max)
{
    *rn = 0;
    return shell_brace_rec(tok, qm, buf, bo, buf_cap, res, rn, res_max, 0);
}
