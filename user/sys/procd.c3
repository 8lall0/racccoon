module user;

import std::nolibc::main_stub;
import std::nolibc::mem;
import std::nolibc::fmt;

// /proc: a synthetic filesystem server (see docs/devlog.md) — speaks the
// same FS_READ/FS_LIST/FS_WRITE wire protocol fsd.c3 already does (verbs
// 20/21/23, user.c3), but backed by live process state instead of disk
// sectors. user.c3's fs_read()/fs_list()/fs_write() need zero changes to
// reach this: any server that responds to those verbs sensibly is
// indistinguishable from a "real" filesystem to those callers, the same
// way fat32_list/ext2_list already are.
//
// Path shape, after "/proc/" is already stripped by the caller's own
// namespace resolution (the same prefix-stripping every fsd client
// already relies on — see user.c3's fs_read/fs_list/fs_write):
//   ""             -> FS_LIST: every live pid, one directory entry each
//   "<pid>"        -> FS_LIST: that pid's own files — "status" and
//                     "ctl" in v1, not Plan 9's full ctl/mem/fd/ns set
//   "<pid>/status" -> FS_READ: "pid: N\nstate: RUNNABLE\ngeneration: N\n"
//   "<pid>/ctl"    -> FS_WRITE: the one write path /proc has, and the
//                     only command it accepts is "kill" — fetches the
//                     target's live generation via proc_info() right
//                     before calling kill() with it, closing the same
//                     stale-pid window Mount.server_generation/SYS_JOIN
//                     already close elsewhere (see kill()'s own comment,
//                     user.c3, and SYS_KILL's case, src/entry.c3).

// Generous, hardcoded scan bound for listing "/proc" itself — not
// required to track the kernel's own PROCS_MAX (src/process.c3), a
// kernel-only constant unreachable from user code the same way `board`
// already is (see user/sdd.c3's own header comment). Scanning past the
// real max just finds nothing via proc_info's own -1; scanning under it
// would silently miss live processes, so this errs high.
const int PROCD_SCAN_MAX = 32;

fn uint procd_parse_pid(char* path)
{
    uint n = 0;
    int i = 0;
    while (path[i] >= '0' && path[i] <= '9')
    {
        n = n * 10 + (uint)(path[i] - '0');
        i++;
    }
    return n;
}

// Inverse-ish of procd_parse_pid: skips the same leading digit run and
// returns a pointer to whatever comes right after (e.g. "/ctl",
// "/status", or the empty string), for suffix validation FS_WRITE's ctl
// handler needs but FS_READ's "<pid>/status" case never bothered with
// (it silently accepted any suffix after the digits).
fn char* procd_skip_pid(char* path)
{
    int i = 0;
    while (path[i] >= '0' && path[i] <= '9')
    {
        i++;
    }
    return &path[i];
}

fn int procd_append_str(char* dst, int pos, char* src)
{
    int i = 0;
    while (src[i] != 0)
    {
        dst[pos] = src[i];
        pos++;
        i++;
    }
    return pos;
}

fn void main() {
    for (;;) {
        char[FS_MSG_MAX] buf @noinit;
        uint verb = 0;
        uint from_gen = 0;
        int from = ipc_recv_type_gen(&buf, FS_MSG_MAX, &verb, &from_gen);
        if (from <= 0) continue;
        if (verb != FS_READ && verb != FS_LIST && verb != FS_WRITE)
        {
            // Any other fs verb (FS_STAT, FS_DELETE, FS_MKDIR, FS_RENAME,
            // the *_AT verbs, FS_CHMOD/CHOWN): /proc doesn't implement it,
            // but we MUST still reply — a bare `continue` here left the
            // caller's SYS_IPC_CALL blocked forever. That hung any
            // stat()/access() of a /proc path: e.g. a ported tool
            // (c3c's find_executable_path) walking /proc/self/exe.
            // -1 in the result field is what every fs client reads as
            // "nothing resolves there" / ENOENT.
            int* rf = (int*)&buf;
            *rf = -1;
            ipc_reply(from, verb, &buf, FS_MSG_MAX, from_gen);
            continue;
        }

        char[100] path @noinit;
        mem::copy(&path, &buf, 100);

        if (verb == FS_LIST)
        {
            // fsd's fs_list pages via a start index at wire byte 104.
            uint list_start = *(uint*)&buf[104];
            uint list_seen = 0;
            int* count_field = (int*)&buf;
            int count = 0;
            if (path[0] == 0)
            {
                // "/proc" itself — list every live pid as a directory.
                for (int pid = 1; pid <= PROCD_SCAN_MAX && count < 31; pid++)
                {
                    uint state = 0;
                    uint gen = 0;
                    if (proc_info(pid, &state, &gen, null) == 0)
                    {
                        if (list_seen++ < list_start) continue;
                        char* rec = &buf[4 + count * 36];
                        int n = fmt::format_uint((uint)pid, rec);
                        rec[n] = 0;
                        rec[32] = 1; // directory
                        count++;
                    }
                }
            }
            else
            {
                // "<pid>" — that pid's own files: "status" (read) and
                // "ctl" (write — see the FS_WRITE case below).
                uint pid_val = procd_parse_pid(&path);
                uint state = 0;
                uint gen = 0;
                if (proc_info((int)pid_val, &state, &gen, null) == 0)
                {
                    char* rec0 = &buf[4];
                    char* name0 = "status";
                    int n0 = 0;
                    while (name0[n0] != 0)
                    {
                        rec0[n0] = name0[n0];
                        n0++;
                    }
                    rec0[n0] = 0;
                    rec0[32] = 0; // file

                    char* rec1 = &buf[4 + 36];
                    char* name1 = "ctl";
                    int n1 = 0;
                    while (name1[n1] != 0)
                    {
                        rec1[n1] = name1[n1];
                        n1++;
                    }
                    rec1[n1] = 0;
                    rec1[32] = 0; // file

                    count = 2;
                }
            }
            *count_field = count;
            ipc_reply(from, verb, &buf, FS_MSG_MAX, from_gen);
            continue;
        }

        if (verb == FS_WRITE)
        {
            // "<pid>/ctl" only — the leading digits are procd_parse_pid's
            // own job, same as FS_READ's "<pid>/status" below; the
            // remainder (procd_skip_pid's return) must be exactly "/ctl".
            uint pid_val = procd_parse_pid(&path);
            char* suffix = procd_skip_pid(&path);
            uint* len_field = (uint*)&buf[100];
            uint write_len = *len_field;
            if (write_len > 15) write_len = 15; // "kill" plus headroom, not a real command language

            int* write_result_field = (int*)&buf;
            if (strcmp(suffix, "/ctl") != 0)
            {
                *write_result_field = -1;
            }
            else
            {
                char[16] cmd @noinit;
                for (uint ci = 0; ci < write_len; ci++) cmd[ci] = buf[104 + ci];
                cmd[write_len] = 0;

                uint state = 0;
                uint gen = 0;
                int target_uid = 0;
                int requester_uid = 0;
                // Fetch the live generation immediately before kill()
                // rather than trusting anything cached — see kill()'s
                // own comment (user.c3) for why this specific ordering
                // matters.
                //
                // procd itself is always root (create_process()'s own
                // default, src/process.c3) — kill() only ever sees
                // *this* process's own uid when procd is the one
                // calling it, never the real requester's, so the
                // kernel's own SYS_KILL check (root-or-same-uid,
                // src/entry.c3) can't enforce anything on this indirect
                // path unless checked here first. from (the real
                // requester's pid, captured by ipc_recv_type_gen at the
                // top of main()) is who this request is actually from,
                // not procd itself. Without this, /proc/<pid>/ctl would
                // be a complete, ungated root-kill-as-a-service
                // backdoor around the new permission model entirely.
                bool kill_authorized = strcmp(&cmd, "kill") == 0
                    && proc_info((int)pid_val, &state, &gen, &target_uid) == 0
                    && proc_info(from, null, null, &requester_uid) == 0
                    && (requester_uid == 0 || requester_uid == target_uid);
                if (kill_authorized && kill((int)pid_val, gen) == 0)
                {
                    *write_result_field = (int)write_len;
                }
                else
                {
                    *write_result_field = -1;
                }
            }
            ipc_reply(from, verb, &buf, FS_MSG_MAX, from_gen);
            continue;
        }

        // FS_READ: "<pid>/status" (the leading digits are all
        // procd_parse_pid needs — it stops at the first non-digit, so
        // the trailing "/status" is simply never consumed).
        uint pid_val = procd_parse_pid(&path);
        uint state = 0;
        uint gen = 0;
        int* result_len_field = (int*)&buf;
        if (proc_info((int)pid_val, &state, &gen, null) != 0)
        {
            *result_len_field = -1;
        }
        else
        {
            int pos = 4;
            pos = procd_append_str(&buf, pos, "pid: ");
            pos += fmt::format_uint(pid_val, &buf[pos]);
            pos = procd_append_str(&buf, pos, "\nstate: ");
            pos = procd_append_str(&buf, pos, state == 1 ? "RUNNABLE" : "BLOCKED");
            pos = procd_append_str(&buf, pos, "\ngeneration: ");
            pos += fmt::format_uint(gen, &buf[pos]);
            pos = procd_append_str(&buf, pos, "\n");
            *result_len_field = pos - 4;
        }
        ipc_reply(from, verb, &buf, FS_MSG_MAX, from_gen);
    }
}
