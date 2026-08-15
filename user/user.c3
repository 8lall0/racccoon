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
const int SYS_RFORK      = 11;
const int SYS_NS_UNMOUNT = 12;
const int SYS_JOIN       = 13;

// rfork flags — see src/entry.c3's SYS_RFORK case for the full design.
const int RFPROC = 1 << 0; // required — create a new process
const int RFMEM  = 1 << 1; // share the parent's address space instead of copying it

// @export gives these functions C-compatible names so asm can call them
fn void exit() @noreturn @export("exit") {
    syscall(SYS_EXIT, 0, 0, 0);
    // Unreachable in practice — the kernel frees this process and switches
    // away permanently on SYS_EXIT, it never returns here. Kept as a
    // fallback so this still satisfies @noreturn if that ever changes.
    for (;;);
}

// Returns the child's pid (>0) to the parent, 0 to the child, or -1 on
// failure (no free process slot, or RFPROC not set) — same convention
// as Plan 9's rfork(2). See src/entry.c3's SYS_RFORK case and
// process.c3's fork_entry() for the actual mechanism: both halves
// resume from this exact call site, not a fresh entry point.
//
// generation_out (optional, pass null if unneeded): the child's own
// generation counter at creation time — capture this if you intend to
// join() the child later, so join can tell "it exited" apart from "its
// pid got reused by something unrelated" (see src/process.c3's
// Process.generation and SYS_JOIN's case in src/entry.c3).
fn int rfork(int flags, uint* generation_out) @export("rfork") {
    return syscall(SYS_RFORK, flags, (long)generation_out, 0);
}

// Stack-aware wrapper around rfork(RFPROC|RFMEM): unlike calling rfork()
// directly, this is actually safe to use for "spawn a thread." Bare
// RFMEM shares the live user stack, not just the address space — the
// child's saved resume point sits mid-call inside rfork()'s and
// syscall()'s own stack frames, and those wrappers' own return
// addresses get spilled onto that now-shared stack at typical
// optimization levels. The parent's very next function call overwrites
// exactly that memory before the child is ever scheduled (this is not
// hypothetical — see docs/devlog.md and rforkmemtest's own history).
// Real Plan 9 code never calls rfork(RFMEM) bare for this reason either
// — libthread's threadcreate() is a userland trampoline built the same
// way this one is: give the child a fresh stack and a fresh entry point
// before anything resembling normal C-level control flow ever touches
// the shared stack.
//
// Hand-written, @naked, string-form asm rather than syscall()'s usual
// block form: from the moment execution resumes right after `ecall`
// (both parent and child land there, exactly like any rfork call)
// through the branch and the stack switch, nothing touches memory at
// all — the branch test and the three saved values (fn/arg/stack_top)
// live purely in registers, which the kernel's own trap-frame
// save/restore (src/process.c3's fork_entry, unchanged) already
// guarantees survive the round trip. By the time the child would
// otherwise need to read anything through sp, sp already points at its
// own private buffer — the parent's subsequent use of the old shared
// stack is irrelevant to the child from that point on, not just briefly
// avoided.
//
// The leading save/restore of s1-s4/ra around the ecall is a separate,
// ABI-compliance concern: as a @naked function, nothing else guarantees
// this doesn't clobber whatever threadcreate's own *caller* had live in
// those callee-saved registers. Restored before the parent-side return;
// never needed by the child, which doesn't return through this frame at
// all.
//
// func is expected to call exit() itself when done, matching every other
// process entry point in this codebase — the trailing `j .` is a safety
// net, not the intended path, in case it ever doesn't.
//
// Returns the same thing rfork() does: the new thread's pid to the
// caller, or -1 on failure. Never returns 0 — the "child" branch here
// never comes back to this call site at all.
//
// generation_out (optional, pass null if unneeded): same purpose as
// rfork()'s own — capture it if you intend to join() this thread later.
// Threaded through in s4 (alongside s1-s3) rather than directly, since
// it arrives in a3 — the same register this function needs for the
// SYS_RFORK syscall number moments later — so it has to be saved off
// before that overwrite, exactly like func/arg/stack_top already are.
//
// RV64 port: sd/ld and 8*N offsets, not sw/lw and 4*N — every saved
// register is a full 64-bit value now (s1-s4 and ra are always native
// register width regardless of XLEN, so the save area just got wider,
// same shape as every other hand-written asm block in this port).
fn int threadcreate(void* func, void* arg, void* stack_top, uint* generation_out) @naked @noinline @export("threadcreate") {
    asm(`
        addi sp, sp, -40
        sd s1, 0(sp)
        sd s2, 8(sp)
        sd s3, 16(sp)
        sd s4, 24(sp)
        sd ra, 32(sp)

        mv s1, a0
        mv s2, a1
        mv s3, a2
        mv s4, a3
        li a0, 3
        mv a1, s4
        li a3, 11
        ecall
        bnez a0, 1f

        mv sp, s3
        mv a0, s2
        jalr s1
        j .

    1:
        ld s1, 0(sp)
        ld s2, 8(sp)
        ld s3, 16(sp)
        ld s4, 24(sp)
        ld ra, 32(sp)
        addi sp, sp, 40
        ret
    `);
}

// RV64 port: all four params are `long` (not `int`) — c3c's block-form
// asm (the `$a0`-style pseudo-register bindings below) requires locals
// bound into a register position to be native register width; a 32-bit
// `int` is rejected outright on a 64-bit target (the same restriction
// that forced src/kernel/sbi.c3's sbi_call to widen its own params —
// see docs/devlog.md). This also happens to be exactly the width
// needed for pointer-valued arguments (buffers, out-pointers) to
// survive the round trip without truncation, so callers that used to
// cast a pointer through `(int)` now go through `(long)` instead.
fn int syscall(long sysno, long arg0, long arg1, long arg2) {
    long result;
    asm {
        mv $a0, arg0;
        mv $a1, arg1;
        mv $a2, arg2;
        mv $a3, sysno;
        ecall;
        mv result, $a0;
    }
    return (int)result;
}

fn int syscall4(long sysno, long arg0, long arg1, long arg2, long arg3) {
    // Same shape as syscall(), one more argument in a4 — a3 is always the
    // syscall number, so a 4th real argument needs a register beyond the
    // 3-arg ABI. Only SYS_IPC_SEND needs this so far (dest_pid, type,
    // data_ptr, len).
    long result;
    asm {
        mv $a0, arg0;
        mv $a1, arg1;
        mv $a2, arg2;
        mv $a3, sysno;
        mv $a4, arg3;
        ecall;
        mv result, $a0;
    }
    return (int)result;
}

fn int ipc_send(int dest_pid, uint type, char* data, int len) @export("ipc_send") {
    return syscall4(SYS_IPC_SEND, dest_pid, (long)type, (long)data, len);
}

fn int ipc_recv_type(char* buf, int len, uint* out_type) @export("ipc_recv_type") {
    return syscall(SYS_IPC_RECV, (long)buf, len, (long)out_type);
}

fn int ipc_recv(char* buf, int len) @export("ipc_recv") {
    return ipc_recv_type(buf, len, null);
}

// Non-blocking: returns -1 immediately if nothing's waiting, instead of
// parking this process until a message arrives. See src/entry.c3's
// SYS_IPC_POLL case for why this exists (diskd's completion-wait needs
// it specifically — a blocking recv there is unsafe).
fn int ipc_poll_type(char* buf, int len, uint* out_type) @export("ipc_poll_type") {
    return syscall(SYS_IPC_POLL, (long)buf, len, (long)out_type);
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
    return syscall(SYS_NS_RESOLVE, (long)path, 0, 0);
}

// Removes one of *this process's own* namespace mounts, matched by
// exact prefix (not the longest-prefix match ns_resolve/SYS_NS_RESOLVE
// use). Returns 0 if found and removed, -1 if no mount had that exact
// prefix. A process that rfork(RFPROC)'d (a real, independent copy of
// the namespace — see src/entry.c3's SYS_RFORK case) can use this to
// sandbox itself without affecting its parent or siblings.
fn int ns_unmount(char* prefix) @export("ns_unmount") {
    return syscall(SYS_NS_UNMOUNT, (long)prefix, 0, 0);
}

// Blocks until the process with this pid no longer exists — e.g. a
// child from rfork() or a thread from threadcreate(). Replaces "call
// something that happens to block for a while, then hope the target
// has run by now" with an actual, correct wait. Returns -1 immediately
// if pid is the caller's own (always a self-deadlock, rejected rather
// than hung) or 0 once the target is gone.
//
// generation must be the value rfork()/threadcreate() wrote into their
// own generation_out when this pid was created — without it, join
// can't tell "this process exited" apart from "this pid got reused by
// an unrelated process" (pids are slot-indexed and do get reused; see
// src/process.c3's Process.generation and SYS_JOIN's case in
// src/entry.c3 for the full reasoning).
fn int join(int pid, uint generation) @export("join") {
    return syscall(SYS_JOIN, pid, (long)generation, 0);
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
// uptr* (not uint*): the kernel writes full pointer-sized physical
// addresses into these out-params (src/entry.c3's SYS_DISKD_INFO case) —
// a uint* here would only reserve 4 bytes for what the kernel's 8-byte
// store actually writes, corrupting whatever's next on diskd's stack.
fn int diskd_info(uptr* vq_paddr_out, uptr* req_paddr_out) @export("diskd_info") {
    return syscall(SYS_DISKD_INFO, (long)vq_paddr_out, (long)req_paddr_out, 0);
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
