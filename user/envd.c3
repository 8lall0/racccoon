module user;

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
        if (proc_info(env_table[i].pid, &live_state, &live_gen) != 0 || live_gen != env_table[i].generation)
        {
            return i;
        }
    }
    return -1;
}

fn void main() @export("main") {
    for (;;) {
        char[FS_MSG_MAX] buf @noinit;
        uint verb = 0;
        uint from_gen = 0;
        int from = ipc_recv_type_gen(&buf, FS_MSG_MAX, &verb, &from_gen);
        if (from <= 0) continue;
        if (verb != FS_READ && verb != FS_WRITE && verb != FS_LIST && verb != FS_DELETE) continue;

        char[100] path @noinit;
        for (int i = 0; i < 100; i++)
        {
            path[i] = buf[i];
        }

        if (verb == FS_READ)
        {
            int idx = env_find(from, from_gen, &path);
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

            int idx = env_find(from, from_gen, &path);
            if (idx < 0) idx = env_find_free_or_reclaim();

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

        if (verb == FS_LIST)
        {
            int* count_field = (int*)&buf;
            int count = 0;
            for (int i = 0; i < ENV_MAX && count < 31; i++)
            {
                if (env_table[i].pid != from) continue;
                if (env_table[i].generation != from_gen) continue;
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

        // FS_DELETE
        int didx = env_find(from, from_gen, &path);
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
