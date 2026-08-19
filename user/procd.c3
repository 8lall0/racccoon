module user;

// /proc: a synthetic filesystem server (see docs/devlog.md) — speaks the
// same FS_READ/FS_LIST wire protocol fsd.c3 already does (verbs 20/23,
// user.c3), but backed by live process state instead of disk sectors.
// user.c3's fs_read()/fs_list() need zero changes to reach this: any
// server that responds to those two verbs sensibly is indistinguishable
// from a "real" filesystem to those callers, the same way fat32_list/
// ext2_list already are. Read-only in v1 — no FS_WRITE handling, so a
// future kill-via-/proc/<pid>/ctl is explicitly not attempted here.
//
// Path shape, after "/proc/" is already stripped by the caller's own
// namespace resolution (the same prefix-stripping every fsd client
// already relies on — see user.c3's fs_read/fs_list):
//   ""             -> FS_LIST: every live pid, one directory entry each
//   "<pid>"        -> FS_LIST: that pid's own files — just "status" in
//                     v1, not Plan 9's full ctl/mem/fd/ns set
//   "<pid>/status" -> FS_READ: "pid: N\nstate: RUNNABLE\ngeneration: N\n"

// Generous, hardcoded scan bound for listing "/proc" itself — not
// required to track the kernel's own PROCS_MAX (src/process.c3), a
// kernel-only constant unreachable from user code the same way `board`
// already is (see user/sdd.c3's own header comment). Scanning past the
// real max just finds nothing via proc_info's own -1; scanning under it
// would silently miss live processes, so this errs high.
const int PROCD_SCAN_MAX = 32;

fn int procd_format_uint(uint n, char* buf)
{
    if (n == 0)
    {
        buf[0] = '0';
        return 1;
    }
    char[10] digits @noinit;
    int count = 0;
    while (n > 0)
    {
        digits[count] = (char)('0' + n % 10);
        n /= 10;
        count++;
    }
    for (int k = 0; k < count; k++)
    {
        buf[k] = digits[count - 1 - k];
    }
    return count;
}

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

fn void main() @export("main") {
    for (;;) {
        char[FS_MSG_MAX] buf @noinit;
        uint verb = 0;
        int from = ipc_recv_type(&buf, FS_MSG_MAX, &verb);
        if (from <= 0) continue;
        if (verb != FS_READ && verb != FS_LIST) continue;

        char[100] path @noinit;
        for (int i = 0; i < 100; i++)
        {
            path[i] = buf[i];
        }

        if (verb == FS_LIST)
        {
            int* count_field = (int*)&buf;
            int count = 0;
            if (path[0] == 0)
            {
                // "/proc" itself — list every live pid as a directory.
                for (int pid = 1; pid <= PROCD_SCAN_MAX && count < 31; pid++)
                {
                    uint state = 0;
                    uint gen = 0;
                    if (proc_info(pid, &state, &gen) == 0)
                    {
                        char* rec = &buf[4 + count * 36];
                        int n = procd_format_uint((uint)pid, rec);
                        rec[n] = 0;
                        rec[32] = 1; // directory
                        count++;
                    }
                }
            }
            else
            {
                // "<pid>" — that pid's own files: just "status" in v1.
                uint pid_val = procd_parse_pid(&path);
                uint state = 0;
                uint gen = 0;
                if (proc_info((int)pid_val, &state, &gen) == 0)
                {
                    char* rec = &buf[4];
                    char* name = "status";
                    int n = 0;
                    while (name[n] != 0)
                    {
                        rec[n] = name[n];
                        n++;
                    }
                    rec[n] = 0;
                    rec[32] = 0; // file
                    count = 1;
                }
            }
            *count_field = count;
            ipc_send(from, verb, &buf, FS_MSG_MAX);
            continue;
        }

        // FS_READ: "<pid>/status" (the leading digits are all
        // procd_parse_pid needs — it stops at the first non-digit, so
        // the trailing "/status" is simply never consumed).
        uint pid_val = procd_parse_pid(&path);
        uint state = 0;
        uint gen = 0;
        int* result_len_field = (int*)&buf;
        if (proc_info((int)pid_val, &state, &gen) != 0)
        {
            *result_len_field = -1;
        }
        else
        {
            int pos = 4;
            pos = procd_append_str(&buf, pos, "pid: ");
            pos += procd_format_uint(pid_val, &buf[pos]);
            pos = procd_append_str(&buf, pos, "\nstate: ");
            pos = procd_append_str(&buf, pos, state == 1 ? "RUNNABLE" : "BLOCKED");
            pos = procd_append_str(&buf, pos, "\ngeneration: ");
            pos += procd_format_uint(gen, &buf[pos]);
            pos = procd_append_str(&buf, pos, "\n");
            *result_len_field = pos - 4;
        }
        ipc_send(from, verb, &buf, FS_MSG_MAX);
    }
}
