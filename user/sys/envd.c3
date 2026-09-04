module user;

import std::nolibc::main_stub;
import std::nolibc::mem;

// /env: per-process environment variables, real Plan 9 idea (there
// #e, a private per-process kernel device). Racccoon has no per-process
// device concept and doesn't need one for this: every request reaches
// this server via ipc_recv_type_gen() (src/entry.c3's SYS_IPC_RECV_GEN),
// carrying the sender's own kernel-verified (pid, generation) —
// unforgeable by the requester. Keying env_table by (pid, generation,
// name) and only ever matching a request's own (from, from_gen) gives
// genuine per-process isolation for free: no new kernel mechanism,
// just the same generation-safety discipline Mount.server_generation/
// Srv_entry.generation already established elsewhere (src/process.c3).
//
// Reuses all four existing FS_* verbs (user.c3) — no new syscalls, no
// new wire format. fs_read()/fs_write()/fs_list()/fs_delete() reach
// this with zero client-side changes, the same design insight procd.c3
// already proved for FS_READ/FS_LIST and /proc/<pid>/ctl proved for
// FS_WRITE.
//
// Crash policy (docs/roadmap.md §5.4): a supervisor-respawned envd comes
// up with an empty env_table, and that's deliberately fine — the table
// is keyed by (pid, generation), which is meaningless after a respawn,
// and the shell's own $user/$cwd/$home/$status are computed there, not
// stored here. "The env server crashed, your vars are gone" is the
// correct outcome; there's nothing worth persisting.
//
// Path shape, after "/env/" is already stripped by the caller's own
// namespace resolution: a single flat namespace per process (no
// subdirectories/groups — see this feature's own devlog entry for what
// that leaves out).
//   FS_READ("<name>")    -> the caller's own var value, -1 if unset
//   FS_WRITE("<name>", v) -> create-or-overwrite the caller's own var
//   FS_LIST("")           -> every var belonging to the caller
//   FS_DELETE("<name>")   -> remove the caller's own var

const int ENV_MAX = 64;        // flat table across all processes — PROCS_MAX (16) * ~4 vars/process
const int ENV_NAME_MAX = 32;   // matches FS_LIST_NAME_MAX (user.c3) exactly — a name IS a list-record name
const int ENV_VALUE_MAX = 64;  // short values, same order as procd's own status fields

// pid == 0 marks an unused slot. generation is captured at write time
// and re-checked on every match (env_find below) — an entry whose
// owning pid has since been reused by an unrelated process simply never
// matches again, the same "treat a stale binding as gone" discipline
// SYS_NS_RESOLVE/SYS_NS_MOUNT already apply to Mount/Srv_entry.
struct Env_entry
{
    int  pid;
    uint generation;
    char[ENV_NAME_MAX] name;
    char[ENV_VALUE_MAX] value;
}
Env_entry[ENV_MAX] env_table;

fn int env_strlen(char* s)
{
    int n = 0;
    while (s[n] != 0) n++;
    return n;
}

// Bounded copy into a fixed ENV_NAME_MAX field — truncates rather than
// overflowing, same discipline procd's own ctl command-buffer copy uses.
fn void env_copy_name(char* dst, char* src)
{
    int i = 0;
    while (src[i] != 0 && i < ENV_NAME_MAX - 1)
    {
        dst[i] = src[i];
        i++;
    }
    dst[i] = 0;
}

// Finds the caller's own entry by exact name — pid AND generation must
// both match this request's own (pid, gen), never just pid alone (see
// this file's own header comment for why). Returns -1 if not found.
fn int env_find(int pid, uint gen, char* name)
{
    for (int i = 0; i < ENV_MAX; i++)
    {
        if (env_table[i].pid != pid) continue;
        if (env_table[i].generation != gen) continue;
        if (strcmp(&env_table[i].name, name) == 0) return i;
    }
    return -1;
}

// Finds a slot for a brand-new entry: a genuinely free one first, else
// one whose owning process is no longer live (proc_info() — already
// used by procd.c3 — returning -1, or a live generation that no longer
// matches what's stored). Without this second pass, a long-running
// system where many processes set-then-discard vars over time would
// exhaust ENV_MAX with dead entries that can never be matched again but
// still occupy a slot forever — the same "don't silently degrade after
// N operations" gap the ext2 directory-slot-reuse fix closed earlier
// this session, applied here before it could ever bite. Returns -1 only
// if every slot's owner is still genuinely alive.
fn int env_find_free_or_reclaim()
{
    for (int i = 0; i < ENV_MAX; i++)
    {
        if (env_table[i].pid == 0) return i;
    }
    for (int i = 0; i < ENV_MAX; i++)
    {
        uint live_state = 0;
        uint live_gen = 0;
        if (proc_info(env_table[i].pid, &live_state, &live_gen, null) != 0 || live_gen != env_table[i].generation)
        {
            return i;
        }
    }
    return -1;
}

// Reserved marker name — a leading '.' establishes a real reserved-name
// convention (mirrors Unix dotfiles): FS_READ/FS_WRITE/FS_DELETE all
// refuse any name starting with '.', and FS_LIST filters it out of what
// it shows the caller. This specific one records "already ran (or
// deliberately skipped) inheritance for this exact process instance" —
// see env_maybe_inherit's own comment — without needing a second
// parallel table just to track that one bit per (pid, generation).
const char* ENV_INHERITED_MARKER = ".inherited";

// Lazy inherit-on-first-touch: called once per request, right after
// (from, from_gen) is known, before any verb-specific handling. envd
// has no way to be proactively notified when a fork happens (no
// precedent anywhere in this codebase for the kernel initiating an IPC
// send to a server from inside another process's syscall handling, and
// building one would be a much bigger mechanism than this needs) — so
// instead, the first time this process instance ever touches /env at
// all, ask the kernel who its parent is (SYS_PARENT_INFO, src/entry.c3
// — built for exactly this) and copy that parent's *current* vars once.
// A one-time snapshot, not a live link — matches real Plan 9's own
// copy-on-fork semantics, not an ongoing connection: neither side's
// later writes propagate to the other, same as env_table's existing
// per-(pid, generation) isolation already guarantees regardless.
fn void env_maybe_inherit(int pid, uint gen)
{
    if (env_find(pid, gen, ENV_INHERITED_MARKER) >= 0) return;

    uint parent_gen = 0;
    int parent_pid = parent_info(pid, &parent_gen);
    if (parent_pid > 0)
    {
        for (int i = 0; i < ENV_MAX; i++)
        {
            if (env_table[i].pid != parent_pid) continue;
            if (env_table[i].generation != parent_gen) continue;
            if (strcmp(&env_table[i].name, ENV_INHERITED_MARKER) == 0) continue;

            int slot = env_find_free_or_reclaim();
            if (slot < 0) break; // table genuinely full — best-effort, stop copying rather than fail the whole request

            env_table[slot].pid = pid;
            env_table[slot].generation = gen;
            env_copy_name(&env_table[slot].name, &env_table[i].name);
            mem::copy(&env_table[slot].value, &env_table[i].value, ENV_VALUE_MAX);
        }
    }

    // Marked regardless of whether there was a parent or copying fully
    // succeeded, so this never re-runs for this process instance.
    int marker_slot = env_find_free_or_reclaim();
    if (marker_slot >= 0)
    {
        env_table[marker_slot].pid = pid;
        env_table[marker_slot].generation = gen;
        env_copy_name(&env_table[marker_slot].name, ENV_INHERITED_MARKER);
        env_table[marker_slot].value[0] = 0;
    }
}

fn void main() {
    for (;;) {
        char[FS_MSG_MAX] buf @noinit;
        uint verb = 0;
        uint from_gen = 0;
        int from = ipc_recv_type_gen(&buf, FS_MSG_MAX, &verb, &from_gen);
        if (from <= 0) continue;
        if (verb != FS_READ && verb != FS_WRITE && verb != FS_WRITE_AT && verb != FS_LIST && verb != FS_DELETE)
        {
            // Any other fs verb (FS_STAT above all, plus FS_MKDIR /
            // FS_RENAME / FS_READ_AT / FS_CHMOD/CHOWN): /env doesn't
            // implement it, but we MUST still reply or the caller's
            // SYS_IPC_CALL blocks forever. A bare `continue` here hung
            // stat()/access() of any /env path — hit by ported tools
            // that scan the cwd (c3c's resolve_libraries stats every
            // entry in "/"). -1 reads as "nothing resolves there".
            int* rf = (int*)&buf;
            *rf = -1;
            ipc_reply(from, verb, &buf, FS_MSG_MAX, from_gen);
            continue;
        }

        env_maybe_inherit(from, from_gen);

        char[100] path @noinit;
        mem::copy(&path, &buf, 100);

        if (verb == FS_READ)
        {
            int idx = path[0] == '.' ? -1 : env_find(from, from_gen, &path);
            int* result_len_field = (int*)&buf;
            if (idx < 0)
            {
                *result_len_field = -1;
            }
            else
            {
                int vlen = env_strlen(&env_table[idx].value);
                for (int j = 0; j < vlen; j++) buf[4 + j] = env_table[idx].value[j];
                *result_len_field = vlen;
            }
            ipc_reply(from, verb, &buf, FS_MSG_MAX, from_gen);
            continue;
        }

        if (verb == FS_WRITE)
        {
            uint* len_field = (uint*)&buf[100];
            uint write_len = *len_field;
            if (write_len > ENV_VALUE_MAX - 1) write_len = ENV_VALUE_MAX - 1;

            // Reserved-name guard — see ENV_INHERITED_MARKER's own
            // comment. A '.'-prefixed name is never user-writable, so no
            // fallback to env_find_free_or_reclaim() either.
            int idx = -1;
            if (path[0] != '.')
            {
                idx = env_find(from, from_gen, &path);
                if (idx < 0) idx = env_find_free_or_reclaim();
            }

            int* result_field = (int*)&buf;
            if (idx < 0)
            {
                *result_field = -1;
            }
            else
            {
                env_table[idx].pid = from;
                env_table[idx].generation = from_gen;
                env_copy_name(&env_table[idx].name, &path);
                for (uint j = 0; j < write_len; j++) env_table[idx].value[j] = buf[104 + j];
                env_table[idx].value[write_len] = 0;
                *result_field = (int)write_len;
            }
            ipc_reply(from, verb, &buf, FS_MSG_MAX, from_gen);
            continue;
        }

        if (verb == FS_WRITE_AT)
        {
            // Offset-aware write. Env values are tiny (ENV_VALUE_MAX),
            // so this only really matters for offset 0 — that's the
            // `echo x > /env/NAME` path (the shell's `>` redirect first
            // does an FS_WRITE(len 0) to create, then streams the data
            // with FS_WRITE_AT). offset 0 == overwrite; a later chunk
            // past the value cap is clamped away, not an error.
            uint w_len = *(uint*)&buf[100];
            uint w_off = *(uint*)&buf[104];
            int* wa_result = (int*)&buf;

            int idx = -1;
            if (path[0] != '.')
            {
                idx = env_find(from, from_gen, &path);
                if (idx < 0 && w_off == 0) idx = env_find_free_or_reclaim();
            }
            if (idx < 0)
            {
                *wa_result = -1;
            }
            else
            {
                if (w_off == 0)
                {
                    env_table[idx].pid = from;
                    env_table[idx].generation = from_gen;
                    env_copy_name(&env_table[idx].name, &path);
                }
                uint wrote = 0;
                for (uint j = 0; j < w_len && w_off + j < ENV_VALUE_MAX - 1; j++)
                {
                    env_table[idx].value[w_off + j] = buf[108 + j];
                    wrote++;
                }
                if (w_off + wrote > 0) env_table[idx].value[w_off + wrote] = 0;
                // Report the whole request as written even when the tail
                // was clamped, so the shell's `>` pump doesn't error out.
                *wa_result = (int)w_len;
            }
            ipc_reply(from, verb, &buf, FS_MSG_MAX, from_gen);
            continue;
        }

        if (verb == FS_LIST)
        {
            // fsd's fs_list pages via a start index at wire byte 104 —
            // honour it so a caller with > 31 vars doesn't re-fetch the
            // same page forever (see user.c3's fs_list).
            uint list_start = *(uint*)&buf[104];
            uint list_seen = 0;
            int* count_field = (int*)&buf;
            int count = 0;
            for (int i = 0; i < ENV_MAX && count < 31; i++)
            {
                if (env_table[i].pid != from) continue;
                if (env_table[i].generation != from_gen) continue;
                if (env_table[i].name[0] == '.') continue; // reserved names, e.g. ENV_INHERITED_MARKER, never shown
                if (list_seen++ < list_start) continue;
                char* rec = &buf[4 + count * 36];
                int n = 0;
                while (env_table[i].name[n] != 0)
                {
                    rec[n] = env_table[i].name[n];
                    n++;
                }
                rec[n] = 0;
                rec[32] = 0; // file
                count++;
            }
            *count_field = count;
            ipc_reply(from, verb, &buf, FS_MSG_MAX, from_gen);
            continue;
        }

        // FS_DELETE — same reserved-name guard as FS_READ/FS_WRITE above.
        int didx = path[0] == '.' ? -1 : env_find(from, from_gen, &path);
        int* del_result_field = (int*)&buf;
        if (didx < 0)
        {
            *del_result_field = -1;
        }
        else
        {
            env_table[didx].pid = 0;
            *del_result_field = 0;
        }
        ipc_reply(from, verb, &buf, FS_MSG_MAX, from_gen);
    }
}
