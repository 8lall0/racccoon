module user;

// Minimal IPC test server. Started out as a pure echo (proving two
// processes can exchange a message at all — see docs/devlog.md); then
// learned the first two 9P-lite verbs (P9_TWALK/P9_TREAD, defined in
// user.c3) as a fake/toy pair (P9_TWALK never actually walks anything,
// P9_TREAD ignores offset entirely) — those two are kept completely
// unchanged (ping/runtest/argvtest/p9test all still depend on that
// exact behavior). Real 9P semantics — FIDs, a genuine walk, open/
// offset-based-read/clunk against a real (if small and synthetic)
// backing tree — now live alongside them as a separate set of verbs
// (P9_ATTACH/P9_WALK/P9_OPEN/P9_READ/P9_CLUNK), see docs/devlog.md.
// Anything else — including the untyped (type 0) messages shell.c3's
// "ping"/"runtest" commands still send — falls through to the
// original raw echo, so those keep working unchanged too.

// A small, real (if synthetic), in-memory tree — genuinely
// hierarchical (root, two direct files, one subdirectory with its own
// file inside), enough to exercise real walk/open/read/clunk
// (multiple named nodes, real offset-based reads, real multi-element
// walk composed from repeated single-element P9_WALK calls, exactly
// how real 9P's own Twalk descends), without needing a real backing
// store (that's fsd's own job, a separate, much larger migration, not
// this).
struct P9_node
{
    char[32] name;
    char* content; // null for a directory — has no content of its own
    uint content_len;
    int parent;    // index into p9_tree; -1 for root, which has none
    bool is_dir;
}

const int P9_NODE_ROOT = 0;
P9_node[5] p9_tree;

// Populated via explicit field assignment, not a struct-array literal
// — this codebase has no precedent for that syntax anywhere; every
// existing struct gets populated this way (e.g. create_process()'s own
// Mount population, src/process.c3). hello/motd: two real files with
// distinct, known content, directly under root — enough to prove
// walk-by-name actually discriminates between them, and long enough to
// prove offset-based reads for real (reading from the middle, not just
// position 0). docs/readme: a real subdirectory with its own file
// inside, only reachable by walking root -> docs -> readme — proves
// P9_WALK is genuinely hierarchical, not just a flat one-level lookup.
fn void p9_init_tree()
{
    p9_tree[P9_NODE_ROOT].content = null;
    p9_tree[P9_NODE_ROOT].content_len = 0;
    p9_tree[P9_NODE_ROOT].parent = -1;
    p9_tree[P9_NODE_ROOT].is_dir = true;

    char* hello_name = "hello";
    int hi = 0;
    while (hello_name[hi] != 0) { p9_tree[1].name[hi] = hello_name[hi]; hi++; }
    p9_tree[1].name[hi] = 0;
    p9_tree[1].content = "hello from real 9p\n";
    p9_tree[1].content_len = 20;
    p9_tree[1].parent = P9_NODE_ROOT;
    p9_tree[1].is_dir = false;

    char* motd_name = "motd";
    int mi = 0;
    while (motd_name[mi] != 0) { p9_tree[2].name[mi] = motd_name[mi]; mi++; }
    p9_tree[2].name[mi] = 0;
    p9_tree[2].content = "welcome to racccoon's own 9p sandbox\n";
    p9_tree[2].content_len = 38;
    p9_tree[2].parent = P9_NODE_ROOT;
    p9_tree[2].is_dir = false;

    char* docs_name = "docs";
    int di = 0;
    while (docs_name[di] != 0) { p9_tree[3].name[di] = docs_name[di]; di++; }
    p9_tree[3].name[di] = 0;
    p9_tree[3].content = null;
    p9_tree[3].content_len = 0;
    p9_tree[3].parent = P9_NODE_ROOT;
    p9_tree[3].is_dir = true;

    char* readme_name = "readme";
    int ri = 0;
    while (readme_name[ri] != 0) { p9_tree[4].name[ri] = readme_name[ri]; ri++; }
    p9_tree[4].name[ri] = 0;
    p9_tree[4].content = "real 9p, genuinely hierarchical\n";
    p9_tree[4].content_len = 32;
    p9_tree[4].parent = 3;
    p9_tree[4].is_dir = false;
}

// Zero-initialized by default (used = false for every slot at boot) —
// same "no @noinit means zero-init" convention established elsewhere
// this session (e.g. ext2_cache_valid/fat32_cache_valid).
const int P9_FID_MAX = 8;
struct P9_fid_entry
{
    bool used;
    int node;    // index into p9_tree; meaningless if !used
    bool opened;
}
P9_fid_entry[P9_FID_MAX] p9_fids;

fn void main() @export("main") {
    p9_init_tree();

    // If exec()'d with an argument (user/shell.c3's argvtest), argv[0]
    // replaces the hardcoded P9_TREAD reply below — concrete, observable
    // proof argv actually reached this process, not just that exec()
    // itself returned success. Boot-time (pid 2, no argv) and runtest's
    // own no-args exec() both get argc=0 here, so the canned reply stays
    // exactly what it's always been for them.
    char** argv;
    int argc = get_argv(&argv);
    char* canned = "hello from 9p-lite\n";
    int canned_len = 21;
    if (argc > 0) {
        canned = argv[0];
        canned_len = 0;
        while (canned[canned_len] != 0) canned_len++;
    }

    char[64] buf @noinit;
    for (;;) {
        uint verb = 0;
        uint from_gen = 0;
        int from = ipc_recv_type_gen(&buf, 64, &verb, &from_gen);
        if (from <= 0) continue;

        if (verb == P9_TREAD) {
            ipc_reply(from, P9_TREAD, canned, canned_len, from_gen);
        } else if (verb == P9_TWALK) {
            // No real namespace yet (that's a later phase) — just prove
            // the path made it across by handing it straight back.
            ipc_reply(from, P9_TWALK, &buf, 64, from_gen);
        } else if (verb == P9_ATTACH) {
            uint* fid_field = (uint*)&buf[0];
            uint fid = *fid_field;
            int result = -1;
            if (fid < (uint)P9_FID_MAX && !p9_fids[fid].used) {
                p9_fids[fid].used = true;
                p9_fids[fid].node = P9_NODE_ROOT;
                p9_fids[fid].opened = false;
                result = 0;
            }
            int* result_field = (int*)&buf[0];
            *result_field = result;
            ipc_reply(from, P9_ATTACH, &buf, 4, from_gen);
        } else if (verb == P9_WALK) {
            uint* fid_field = (uint*)&buf[0];
            uint* newfid_field = (uint*)&buf[4];
            uint fid = *fid_field;
            uint newfid = *newfid_field;
            char* name = &buf[8];
            int result = -1;
            if (fid < (uint)P9_FID_MAX && p9_fids[fid].used
                && newfid < (uint)P9_FID_MAX && !p9_fids[newfid].used
                && p9_tree[p9_fids[fid].node].is_dir) {
                // Genuinely hierarchical: any node whose own parent is
                // fid's current node, matched by name — the same code
                // path already finds hello/motd under root also finds
                // readme under docs, just parameterized by fid's own
                // current node instead of hardcoded to root. Composing
                // repeated single-element walks (root -> docs, then
                // docs -> readme) is exactly how real 9P's own Twalk
                // descends.
                for (int n = 1; n < 5; n++) {
                    if (p9_tree[n].parent == p9_fids[fid].node && strcmp(name, &p9_tree[n].name[0]) == 0) {
                        p9_fids[newfid].used = true;
                        p9_fids[newfid].node = n;
                        p9_fids[newfid].opened = false;
                        result = 0;
                        break;
                    }
                }
            }
            int* result_field = (int*)&buf[0];
            *result_field = result;
            ipc_reply(from, P9_WALK, &buf, 4, from_gen);
        } else if (verb == P9_OPEN) {
            uint* fid_field = (uint*)&buf[0];
            uint fid = *fid_field;
            int result = -1;
            if (fid < (uint)P9_FID_MAX && p9_fids[fid].used && !p9_tree[p9_fids[fid].node].is_dir) {
                p9_fids[fid].opened = true;
                result = 0;
            }
            int* result_field = (int*)&buf[0];
            *result_field = result;
            ipc_reply(from, P9_OPEN, &buf, 4, from_gen);
        } else if (verb == P9_READ) {
            uint* fid_field = (uint*)&buf[0];
            uint* offset_field = (uint*)&buf[4];
            uint* count_field = (uint*)&buf[8];
            uint fid = *fid_field;
            uint offset = *offset_field;
            uint count = *count_field;
            int result_len = -1;
            uint reply_len = 4;
            if (fid < (uint)P9_FID_MAX && p9_fids[fid].used && p9_fids[fid].opened) {
                P9_node* node = &p9_tree[p9_fids[fid].node];
                if (offset >= node.content_len) {
                    result_len = 0;
                } else {
                    uint avail = node.content_len - offset;
                    uint chunk = count;
                    if (chunk > avail) chunk = avail;
                    if (chunk > 60) chunk = 60; // buf is 64 bytes, 4 reserved for result_len
                    for (uint i = 0; i < chunk; i++) buf[4 + i] = node.content[offset + i];
                    result_len = (int)chunk;
                    reply_len = 4 + chunk;
                }
            }
            int* result_len_field = (int*)&buf[0];
            *result_len_field = result_len;
            ipc_reply(from, P9_READ, &buf, (int)reply_len, from_gen);
        } else if (verb == P9_CLUNK) {
            uint* fid_field = (uint*)&buf[0];
            uint fid = *fid_field;
            int result = -1;
            if (fid < (uint)P9_FID_MAX && p9_fids[fid].used) {
                p9_fids[fid].used = false;
                result = 0;
            }
            int* result_field = (int*)&buf[0];
            *result_field = result;
            ipc_reply(from, P9_CLUNK, &buf, 4, from_gen);
        } else {
            ipc_reply(from, verb, &buf, 64, from_gen);
        }
    }
}
