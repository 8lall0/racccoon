module user;

import std::nolibc::main_stub;

// find [dir] [-name PAT] [-type f|d] — walk a directory tree, print
// each path. PAT is a glob (`*` `?`, last component only, like the
// shell). No dir = cwd (".").

char[80] g_name_pat @noinit;
bool g_have_name;
char g_type;          // 0 = any, 'f', 'd'
int  g_depth_cap = 24;

fn bool glob_ok(char* pat, char* s) {
    // `*` any run, `?` one char — same as shell glob_match.
    int p = 0;
    int n = 0;
    int star_p = -1;
    int star_n = 0;
    while (s[n] != 0) {
        if (pat[p] == '?' || (pat[p] != 0 && pat[p] == s[n])) { p++; n++; }
        else if (pat[p] == '*') { star_p = p; star_n = n; p++; }
        else if (star_p >= 0) { p = star_p + 1; star_n++; n = star_n; }
        else { return false; }
    }
    while (pat[p] == '*') { p++; }
    return pat[p] == 0;
}

fn void cjoin(char* dir, char* name, char* out) {
    int o = 0;
    for (int i = 0; dir[i] != 0 && o < 199; i++) { out[o] = dir[i]; o++; }
    if (o > 0 && out[o - 1] != '/' && o < 199) { out[o] = '/'; o++; }
    for (int i = 0; name[i] != 0 && o < 199; i++) { out[o] = name[i]; o++; }
    out[o] = 0;
}

fn void emit(char* path, char* base, bool is_dir) {
    if (g_type == 'f' && is_dir) { return; }
    if (g_type == 'd' && !is_dir) { return; }
    if (g_have_name && !glob_ok(&g_name_pat[0], base)) { return; }
    print(path);
    putchar('\n');
}

fn void walk(char* dir, int depth) {
    if (depth > g_depth_cap) { return; }
    char[36 * 64] lb @noinit;
    int cnt = fs_list(dir, &lb[0], 64);
    if (cnt < 0) { return; }
    for (int e = 0; e < cnt; e++) {
        char* nm = &lb[e * 36];
        if (nm[0] == 0) { continue; }
        if (nm[0] == '.' && (nm[1] == 0 || (nm[1] == '.' && nm[2] == 0))) { continue; }
        bool is_dir = lb[e * 36 + 32] != 0;
        char[200] full @noinit;
        cjoin(dir, nm, &full[0]);
        emit(&full[0], nm, is_dir);
        if (is_dir) { walk(&full[0], depth + 1); }
    }
}

fn void main(String[] args) {
    char[200] root @noinit;
    root[0] = '.'; root[1] = 0;

    usz i = 0;
    if (i < args.len && args[i].len > 0 && args[i][0] != '-') {
        usz rn = args[i].len < 199 ? args[i].len : 199;
        for (usz k = 0; k < rn; k++) { root[k] = args[i][k]; }
        root[rn] = 0;
        i++;
    }
    while (i < args.len) {
        if (args[i].len == 5 && args[i][0] == '-' && args[i][1] == 'n' && args[i][4] == 'e') {
            i++;
            if (i >= args.len) { print("find: -name needs an argument\n"); exitcode(2); }
            usz pn = args[i].len < 79 ? args[i].len : 79;
            for (usz k = 0; k < pn; k++) { g_name_pat[k] = args[i][k]; }
            g_name_pat[pn] = 0;
            g_have_name = true;
            i++;
        } else if (args[i].len == 5 && args[i][1] == 't' && args[i][2] == 'y') {
            i++;
            if (i >= args.len || args[i].len != 1) { print("find: -type needs f or d\n"); exitcode(2); }
            g_type = args[i][0];
            i++;
        } else {
            print("find: bad argument\n");
            exitcode(2);
        }
    }

    // the root itself (unless it's ".")
    if (!(root[0] == '.' && root[1] == 0)) {
        uint fsz = 0; int fty = 0;
        if (fs_stat(&root[0], &fsz, &fty) == 0) {
            int b = 0;
            for (int k = 0; root[k] != 0; k++) { if (root[k] == '/') { b = k + 1; } }
            emit(&root[0], &root[b], fty != 0);
        }
    }
    walk(&root[0], 0);
}
