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
const int SYS_READFILE  = 4;
const int SYS_WRITEFILE = 5;
const int SYS_IPC_SEND  = 6;
const int SYS_IPC_RECV  = 7;
const int SYS_NS_RESOLVE = 8;

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

fn int readfile(char* filename, char* buf, int len) @export("readfile") {
    return syscall(SYS_READFILE, (int)filename, (int)buf, len);
}

fn int writefile(char* filename, char* buf, int len) @export("writefile") {
    return syscall(SYS_WRITEFILE, (int)filename, (int)buf, len);
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
