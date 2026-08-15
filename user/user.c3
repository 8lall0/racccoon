module user;

// Linker script symbol - declared as extern so C3 knows about it,
// @cname ensures no mangling
extern char[] __stack_top @cname("__stack_top");

// Syscall numbers. Must be kept in sync by hand with the SYS_* consts in
// src/entry.c3 — kernel and user are separate c3c compilations with no
// shared header.
const int SYS_PUTCHAR   = 1;
const int SYS_GETCHAR   = 2;
const int SYS_EXIT      = 3;
// 4 and 5 were SYS_READFILE/SYS_WRITEFILE — removed once fsd (user/fsd.c3,
// via fs_read/fs_write below) took over file access entirely. Left
// unused rather than renumbered, so every other syscall number here
// stays stable.
const int SYS_IPC_SEND  = 6;
const int SYS_IPC_RECV  = 7;
const int SYS_NS_RESOLVE = 8;
const int SYS_DISKD_INFO = 9;
const int SYS_IPC_POLL   = 10;

// @export gives these functions C-compatible names so asm can call them
fn void exit() @noreturn @export("exit") {
    syscall(SYS_EXIT, 0, 0, 0);
    // Unreachable in practice — the kernel frees this process and switches
    // away permanently on SYS_EXIT, it never returns here. Kept as a
    // fallback so this still satisfies @noreturn if that ever changes.
    for (;;);
}

fn int syscall(int sysno, int arg0, int arg1, int arg2) {
    int result;
    asm {
        mv $a0, arg0;
        mv $a1, arg1;
        mv $a2, arg2;
        mv $a3, sysno;
        ecall;
        mv result, $a0;
    }
    return result;
}

fn int syscall4(int sysno, int arg0, int arg1, int arg2, int arg3) {
    // Same shape as syscall(), one more argument in a4 — a3 is always the
    // syscall number, so a 4th real argument needs a register beyond the
    // 3-arg ABI. Only SYS_IPC_SEND needs this so far (dest_pid, type,
    // data_ptr, len).
    int result;
    asm {
        mv $a0, arg0;
        mv $a1, arg1;
        mv $a2, arg2;
        mv $a3, sysno;
        mv $a4, arg3;
        ecall;
        mv result, $a0;
    }
    return result;
}

fn int ipc_send(int dest_pid, uint type, char* data, int len) @export("ipc_send") {
    return syscall4(SYS_IPC_SEND, dest_pid, (int)type, (int)data, len);
}

fn int ipc_recv_type(char* buf, int len, uint* out_type) @export("ipc_recv_type") {
    return syscall(SYS_IPC_RECV, (int)buf, len, (int)out_type);
}

fn int ipc_recv(char* buf, int len) @export("ipc_recv") {
    return ipc_recv_type(buf, len, null);
}

// Non-blocking: returns -1 immediately if nothing's waiting, instead of
// parking this process until a message arrives. See src/entry.c3's
// SYS_IPC_POLL case for why this exists (diskd's completion-wait needs
// it specifically — a blocking recv there is unsafe).
fn int ipc_poll_type(char* buf, int len, uint* out_type) @export("ipc_poll_type") {
    return syscall(SYS_IPC_POLL, (int)buf, len, (int)out_type);
}

// --- 9P-lite: a tiny message-oriented protocol layered directly on top
// of ipc_send/ipc_recv — the kernel never interprets any of this, msg_type
// is already an opaque passthrough. See docs/devlog.md and the
// microkernel plan for the full picture.
const uint P9_TWALK = 1; // request: resolve a path
const uint P9_TREAD = 2; // request: read data

// Sends a 9P-lite request and blocks for the reply in one call — the
// pattern every client actually wants, matching 9P's own synchronous
// request/reply model. reply_verb (optional, pass null if unneeded) lets
// the caller confirm the reply actually answers the request it sent,
// rather than trusting the byte content alone.
fn int p9_call(int dest_pid, uint verb, char* data, int len, char* reply_buf, int reply_len, uint* reply_verb) {
    int sent = ipc_send(dest_pid, verb, data, len);
    if (sent < 0) return sent;
    return ipc_recv_type(reply_buf, reply_len, reply_verb);
}

// --- Namespace: turns a path into "send to this pid", per this caller's
// own per-process mount table (src/process.c3's Process.namespace,
// resolved kernel-side since user code can't read another process's
// memory). -1 means no mount matched.
fn int ns_resolve(char* path) @export("ns_resolve") {
    return syscall(SYS_NS_RESOLVE, (int)path, 0, 0);
}

// Same as p9_call, but addresses the server by path (resolved through the
// caller's namespace) instead of a raw pid — the whole point of having a
// namespace: callers stop hardcoding server pids.
fn int p9_call_path(char* path, uint verb, char* data, int len, char* reply_buf, int reply_len, uint* reply_verb) {
    int pid = ns_resolve(path);
    if (pid < 0) return pid;
    return p9_call(pid, verb, data, len, reply_buf, reply_len, reply_verb);
}

// diskd-only: learns the physical addresses of its virtqueue and request
// buffer, allocated (and identity-mapped into diskd's own page table) by
// the kernel at process-creation time — see setup_diskd_mappings in
// src/process.c3 for why diskd can't know or derive these itself.
fn int diskd_info(uint* vq_paddr_out, uint* req_paddr_out) @export("diskd_info") {
    return syscall(SYS_DISKD_INFO, (int)vq_paddr_out, (int)req_paddr_out, 0);
}

fn void putchar(char ch) @export("putchar") {
    syscall(SYS_PUTCHAR, (int)ch, 0, 0);
}

fn int getchar() @export("getchar") {
    return syscall(SYS_GETCHAR, 0, 0, 0);
}

fn void print(char* s) {
    while (*s != 0) {
        putchar(*s);
        s++;
    }
}

// --- File access via fsd (user/fsd.c3) — the only way to touch a file
// now that SYS_READFILE/SYS_WRITEFILE are gone from the kernel. Both
// resolve `filename` through this process's own namespace (the ""
// catch-all mount, src/process.c3's create_process — plain filenames
// like "hello.txt" never start with "/", so they fall through to it)
// rather than needing to know fsd's pid. Wire format (kept in sync by
// hand with user/fsd.c3): byte 0..99 = filename, 100..103 = length
// (uint), 104.. = file data — reply reuses 0..3 for the result length
// (or -1) and, for a read, 4.. for the data.
const uint FS_READ  = 20;
const uint FS_WRITE = 21;
const uint FS_MSG_MAX = 1128;

fn int fs_read(char* filename, char* buf, int len) @export("fs_read") {
    int fsd_pid = ns_resolve(filename);
    if (fsd_pid < 0) return -1;

    char[FS_MSG_MAX] req @noinit;
    int i = 0;
    while (filename[i] != 0 && i < 99) {
        req[i] = filename[i];
        i++;
    }
    req[i] = 0;
    uint* len_field = (uint*)&req[100];
    *len_field = (uint)len;

    uint reply_verb = 0;
    int from = p9_call(fsd_pid, FS_READ, &req, FS_MSG_MAX, &req, FS_MSG_MAX, &reply_verb);
    if (from <= 0 || reply_verb != FS_READ) return -1;

    int* result_len_field = (int*)&req;
    int result_len = *result_len_field;
    if (result_len < 0) return result_len;
    if (result_len > len) result_len = len;
    for (int j = 0; j < result_len; j++) {
        buf[j] = req[4 + j];
    }
    return result_len;
}

fn int fs_write(char* filename, char* buf, int len) @export("fs_write") {
    int fsd_pid = ns_resolve(filename);
    if (fsd_pid < 0) return -1;

    char[FS_MSG_MAX] req @noinit;
    int i = 0;
    while (filename[i] != 0 && i < 99) {
        req[i] = filename[i];
        i++;
    }
    req[i] = 0;

    int write_len = len;
    if (write_len > (int)(FS_MSG_MAX - 104)) write_len = (int)(FS_MSG_MAX - 104);
    uint* len_field = (uint*)&req[100];
    *len_field = (uint)write_len;
    for (int j = 0; j < write_len; j++) {
        req[104 + j] = buf[j];
    }

    uint reply_verb = 0;
    int from = p9_call(fsd_pid, FS_WRITE, &req, FS_MSG_MAX, &req, FS_MSG_MAX, &reply_verb);
    if (from <= 0 || reply_verb != FS_WRITE) return -1;

    int* result_len_field = (int*)&req;
    return *result_len_field;
}

fn int strcmp(char* a, char* b) {
    while (*a != 0 && *a == *b) {
        a++;
        b++;
    }
    return (int)(char)*a - (int)(char)*b;
}

fn void start() @section(".text.start") @naked @nostrip @used @export("start") {
    asm(`
        la sp, __stack_top
        call main
        call exit
    `);
}
