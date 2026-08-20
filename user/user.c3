module user;

import std::atomic::types;

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
const int SYS_FS_PARTITION_INFO = 14;
const int SYS_FUTEX_WAIT = 15; // block while *addr == expected — see src/entry.c3's case
const int SYS_FUTEX_WAKE = 16; // wake every waiter blocked on addr in this address space
const int SYS_PROC_INFO  = 17; // returns another process's state/generation — see src/entry.c3's case
const int SYS_KILL       = 18; // kills another process by pid (+ optional generation check) — see src/entry.c3's case
const int SYS_IPC_RECV_GEN = 19; // same as SYS_IPC_RECV, plus the sender's generation — see src/entry.c3's case
const int SYS_IPC_REPLY    = 20; // same as SYS_IPC_SEND, plus an optional target-generation check — see src/entry.c3's case
const int SYS_SRV_POST     = 21; // posts current_proc under a short name in the global srv_table — see src/entry.c3's case
const int SYS_NS_MOUNT     = 22; // binds a posted srv_table name at a path prefix in the caller's own namespace — see src/entry.c3's case

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

fn int syscall5(long sysno, long arg0, long arg1, long arg2, long arg3, long arg4) {
    // Same shape as syscall4(), one more argument in a5 — a3 is still
    // always the syscall number. Only SYS_IPC_REPLY needs this so far
    // (dest_pid, type, data_ptr, len, expected_generation).
    long result;
    asm {
        mv $a0, arg0;
        mv $a1, arg1;
        mv $a2, arg2;
        mv $a3, sysno;
        mv $a4, arg3;
        mv $a5, arg4;
        ecall;
        mv result, $a0;
    }
    return (int)result;
}

fn int ipc_send(int dest_pid, uint type, char* data, int len) @export("ipc_send") {
    return syscall4(SYS_IPC_SEND, dest_pid, (long)type, (long)data, len);
}

// Same as ipc_send(), plus an optional expected_generation (0 =
// wildcard, same convention as kill()'s own) checked against the
// target's live Process.generation before delivery — the reply-side
// half of the stale-pid protection: pair with ipc_recv_type_gen()'s own
// out_from_generation to close the window where the original requester
// exits (or gets killed) and its pid gets reused before this reply
// arrives. See SYS_IPC_REPLY's case in src/entry.c3 for the full
// reasoning.
fn int ipc_reply(int dest_pid, uint type, char* data, int len, uint expected_generation) @export("ipc_reply") {
    return syscall5(SYS_IPC_REPLY, dest_pid, (long)type, (long)data, len, (long)expected_generation);
}

fn int ipc_recv_type(char* buf, int len, uint* out_type) @export("ipc_recv_type") {
    return syscall(SYS_IPC_RECV, (long)buf, len, (long)out_type);
}

// Same as ipc_recv_type(), plus the sender's own Process.generation
// captured at delivery time (out_from_generation) — feed this straight
// back into ipc_reply()'s own expected_generation to reply safely. A
// distinct syscall (SYS_IPC_RECV_GEN) rather than a widened
// SYS_IPC_RECV — see that case's own comment, src/entry.c3, for why.
fn int ipc_recv_type_gen(char* buf, int len, uint* out_type, uint* out_from_generation) @export("ipc_recv_type_gen") {
    return syscall4(SYS_IPC_RECV_GEN, (long)buf, len, (long)out_type, (long)out_from_generation);
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
// out_prefix_len (optional, null means don't care) gets the length of
// the matched mount's own prefix — callers that need to strip it before
// building a request to whatever server matched (see fs_read/fs_write
// below) don't have to re-derive it themselves.
fn int ns_resolve(char* path, uint* out_prefix_len) @export("ns_resolve") {
    return syscall(SYS_NS_RESOLVE, (long)path, (long)out_prefix_len, 0);
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

// Posts this process under name in the kernel's global srv_table
// (src/process.c3) — the "srv" half of the real Plan 9 post+mount
// two-step; pair with ns_mount() below. Always posts self (no pid
// argument). Idempotent: posting the same name again just rebinds the
// existing entry (e.g. after a restart) rather than failing. Returns 0
// on success, -1 if the table is genuinely full.
fn int srv_post(char* name) @export("srv_post") {
    return syscall(SYS_SRV_POST, (long)name, 0, 0);
}

// Looks srv_name up in the global srv_table and, if it names a still-live
// server, binds it at prefix in *this* process's own namespace — the
// "mount" half of the two-step, the dynamic counterpart to the static
// prefixes create_process() already populates every process with.
// Idempotent by exact prefix, same as ns_unmount()'s own matching.
// Returns 0 on success, -1 if srv_name isn't currently posted (or its
// poster has since exited) or this process's own namespace is full.
fn int ns_mount(char* prefix, char* srv_name) @export("ns_mount") {
    return syscall(SYS_NS_MOUNT, (long)prefix, (long)srv_name, 0);
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

// Returns 0 and fills *state_out/*generation_out if pid is currently
// live, -1 otherwise (either out-pointer may be null if unneeded, same
// convention as ns_resolve's own out_prefix_len). state is
// src/process.c3's PROC_RUNNABLE (1) or PROC_BLOCKED (2) — never
// PROC_UNUSED (0), since the kernel's own proc_by_pid() already
// filters that case out before this can return success.
fn int proc_info(int pid, uint* state_out, uint* generation_out) @export("proc_info") {
    return syscall(SYS_PROC_INFO, pid, (long)state_out, (long)generation_out);
}

// Kills pid. expected_generation is a wildcard when 0 ("kill whatever's
// at this pid right now"); any other value must match that pid's live
// Process.generation exactly or this fails, the same stale-pid
// protection join()'s own generation argument gives — see SYS_KILL's
// case in src/entry.c3 for the full reasoning. Returns 0 on success, -1
// if the pid doesn't exist, is the caller itself, or the generation
// didn't match.
fn int kill(int pid, uint expected_generation) @export("kill") {
    return syscall(SYS_KILL, pid, (long)expected_generation, 0);
}

// Blocks while *addr == expected, atomically with respect to any
// concurrent futex_wake on the same address (see src/entry.c3's
// SYS_FUTEX_WAIT case — the check-then-block sequence happens inside a
// single, non-preemptible trap, so no wake can be lost between the
// value check and actually parking this process). Returns immediately,
// without blocking, if *addr != expected — the caller re-checks
// whatever condition it was waiting on either way, same as a standard
// futex; this never claims to have "seen" the value change.
fn int futex_wait(int* addr, int expected) @export("futex_wait") {
    return syscall(SYS_FUTEX_WAIT, (long)addr, expected, 0);
}

// Wakes every process currently blocked (via futex_wait) on addr
// within this same address space (kernel matches by page_table, not
// just the numeric address — see src/entry.c3). Never fails, doesn't
// report how many were woken: callers don't need to know, same as a
// condition-variable broadcast.
fn int futex_wake(int* addr) @export("futex_wake") {
    return syscall(SYS_FUTEX_WAKE, (long)addr, 0, 0);
}

// A basic mutex: uncontended lock/unlock never leaves user mode (a
// single compare_exchange, lowering to a real lr.w/sc.w pair — see
// atomic.c3), matching the whole point of futexes over always trapping
// into the kernel. Only falls back to futex_wait when actually
// contended. locked is 0 (free) or 1 (held) — plain int, not bool:
// futex_wait/wake's own `int*` signature (matching the SYS_FUTEX_WAIT
// wire convention above) needs a 4-byte value to compare, and Atomic
// {int} is what atomic.c3 already provides tested lowering for.
struct Mutex
{
    Atomic{int} locked;
}

fn void Mutex.lock(&self) @export("mutex_lock") {
    int expected = 0;
    if (self.locked.compare_exchange(&expected, 1)) return;
    for (;;) {
        // The literal 1 here (not `expected`) is safe specifically
        // because locked only ever holds 0 or 1: reaching this line
        // means the compare_exchange below just failed to CAS 0->1,
        // which is only possible if the current value is the other
        // state, 1. futex_wait itself re-checks *addr == expected
        // right before blocking (see src/entry.c3), so a concurrent
        // unlock() between that failed compare_exchange and
        // futex_wait's own check can't be missed — it just makes
        // futex_wait return immediately instead of actually parking
        // this process, and the loop retries the compare_exchange
        // right away.
        futex_wait(&self.locked.data, 1);
        expected = 0;
        if (self.locked.compare_exchange(&expected, 1)) return;
    }
}

fn void Mutex.unlock(&self) @export("mutex_unlock") {
    self.locked.store(0);
    futex_wake(&self.locked.data);
}

// Same as p9_call, but addresses the server by path (resolved through the
// caller's namespace) instead of a raw pid — the whole point of having a
// namespace: callers stop hardcoding server pids.
fn int p9_call_path(char* path, uint verb, char* data, int len, char* reply_buf, int reply_len, uint* reply_verb) {
    int pid = ns_resolve(path, null);
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

// fsd-only: learns board::FS_PARTITION_START_SECTOR — board is a
// kernel-only module (see user/sdd.c3's own header comment), so this is
// fsd's only way to learn this board-specific fact despite being one
// board-agnostic user binary compiled identically for every target.
fn int fs_partition_info(uint* start_sector_out) @export("fs_partition_info") {
    return syscall(SYS_FS_PARTITION_INFO, (long)start_sector_out, 0, 0);
}

ulong rdtime_tmp @export("rdtime_tmp");

// Direct CSR read, no syscall — trap-free as long as the kernel has set
// scounteren.TM (see src/entry.c3's enable_user_timer_access(), called
// once at boot). Generic across any RISC-V hart (QEMU included), unlike
// board-specific facts like a real timebase frequency to convert ticks
// into real time — those stay wherever they're actually needed (e.g.
// user/sdd.c3's own SD_TIMEBASE_HZ), not here.
//
// Bridged through a memory temp, not returned straight out of a0 — the
// structured `asm { }` block form doesn't recognize `rdtime`/`csrr` as
// instructions at all (compile error), and src/entry.c3's read_reg
// macro already found the more direct fix (raw a0 via opaque asm()) to
// be a real hazard: the compiler can't see the side effect, so it can
// silently clobber a value it still thinks is live in a0. Same opaque-
// string asm() + memory-bridge pattern as that macro, not the
// structured block form sdd.c3's own mmio_read32 uses for plain
// loads/stores.
fn ulong rdtime() @export("rdtime") {
    asm(`
        csrr t0, time
        la t1, rdtime_tmp
        sd t0, 0(t1)
    `);
    return rdtime_tmp;
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

// Decimal, no leading zeros (except "0" itself) — every existing test
// command hand-unrolls two-digit printing instead (`'0' + n/10`,
// `'0' + n%10`), fine for values that never exceed 99, but not
// something worth repeating for mutextest's own counter, which needs
// more than two digits.
fn void print_uint(uint n) @export("print_uint") {
    if (n == 0) {
        putchar('0');
        return;
    }
    char[10] digits @noinit; // uint::max is 10 digits
    int count = 0;
    while (n > 0) {
        digits[count] = (char)('0' + n % 10);
        n /= 10;
        count++;
    }
    while (count > 0) {
        count--;
        putchar(digits[count]);
    }
}

// --- File access via fsd (user/fsd.c3) — the only way to touch a file
// now that SYS_READFILE/SYS_WRITEFILE are gone from the kernel. All
// three resolve `filename` through this process's own namespace (the
// "" catch-all mount, src/process.c3's create_process — plain
// filenames like "hello.txt" never start with "/", so they fall
// through to it) rather than needing to know fsd's pid. Wire format
// (kept in sync by hand with user/fsd.c3): byte 0..99 = filename,
// 100..103 = length (uint, FS_READ/FS_WRITE) or recursive flag
// (uint, 0 or 1, FS_DELETE only — a non-empty directory is emptied
// first instead of refused when set; see fat32_delete_recursive/
// ext2_delete_recursive), 104.. = file data — reply reuses 0..3 for
// the result (FS_READ/FS_WRITE: length or -1; FS_DELETE: 0 or -1) and,
// for a read, 4.. for the data.
const uint FS_READ   = 20;
const uint FS_WRITE  = 21;
const uint FS_DELETE = 22;
const uint FS_LIST   = 23;
const uint FS_MKDIR  = 24; // byte 0..99 = path, nothing else to send; reply reuses 0..3 for 0/-1, same as FS_DELETE
// FS_RENAME: the one verb here that needs two paths, so it's the one
// exception to "byte 0..99 = the path" — byte 0..99 = old path, byte
// 100..199 = new path (same "up to 99 chars, null-terminated"
// convention, just used twice). Refuses if new already exists (no
// silent overwrite, unlike POSIX rename(2)) or if old is the write-
// protected file. Reply reuses 0..3 for 0/-1, same as FS_DELETE/
// FS_MKDIR.
const uint FS_RENAME = 25;
const uint FS_MSG_MAX = 1128;

// FS_LIST: byte 0..99 = directory path ("" means the root), same as
// FS_READ/FS_WRITE/FS_DELETE's own filename field. Reply: byte 0..3 =
// int count (or -1 on error — not a directory, not found, etc), then
// `count` fixed-size FS_LIST_ENTRY_SIZE records starting at byte 4:
// FS_LIST_NAME_MAX bytes of null-terminated name, then 1 byte of type
// (0 = file, 1 = directory), then padding out to FS_LIST_ENTRY_SIZE.
// v1 scope, deliberately limited like everything else in this
// protocol: one reply, no continuation/pagination — a directory with
// more than fs_list()'s own max_entries worth of real entries is
// silently truncated, not reported as an error (matches how
// fat32_read_file/ext2 read short past their own block/indirect
// limits elsewhere in this codebase — "return however much fit" over
// a hard failure).
const uint FS_LIST_NAME_MAX   = 32;
const uint FS_LIST_ENTRY_SIZE = 36;

fn int fs_read(char* filename, char* buf, int len) @export("fs_read") {
    uint prefix_len = 0;
    int fsd_pid = ns_resolve(filename, &prefix_len);
    if (fsd_pid < 0) return -1;
    // Strip the matched mount's own prefix before it ever reaches the
    // wire — the "" catch-all's own prefix length is always 0 (a no-op
    // here, same behavior as before this existed), but a non-empty
    // prefix like the second fsd's "/2/" (src/process.c3) would
    // otherwise leak into the plain, bare filename fsd.c3's backends
    // expect (see user/fsd.c3's own header comment — every backend only
    // ever deals in bare names, this is the one place that guarantee
    // gets upheld).
    char* stripped = &filename[prefix_len];

    char[FS_MSG_MAX] req @noinit;
    int i = 0;
    while (stripped[i] != 0 && i < 99) {
        req[i] = stripped[i];
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
    uint prefix_len = 0;
    int fsd_pid = ns_resolve(filename, &prefix_len);
    if (fsd_pid < 0) return -1;
    // See fs_read's own comment on why this strips the matched prefix.
    char* stripped = &filename[prefix_len];

    char[FS_MSG_MAX] req @noinit;
    int i = 0;
    while (stripped[i] != 0 && i < 99) {
        req[i] = stripped[i];
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

fn int fs_delete_impl(char* filename, uint recursive) {
    uint prefix_len = 0;
    int fsd_pid = ns_resolve(filename, &prefix_len);
    if (fsd_pid < 0) return -1;
    // See fs_read's own comment on why this strips the matched prefix.
    char* stripped = &filename[prefix_len];

    char[FS_MSG_MAX] req @noinit;
    int i = 0;
    while (stripped[i] != 0 && i < 99) {
        req[i] = stripped[i];
        i++;
    }
    req[i] = 0;
    // Explicit, not left @noinit: fsd.c3 now reads this byte as the
    // recursive flag (see the wire-format comment above) — garbage
    // here would risk a plain fs_delete() being silently treated as
    // recursive.
    uint* recursive_field = (uint*)&req[100];
    *recursive_field = recursive;

    uint reply_verb = 0;
    int from = p9_call(fsd_pid, FS_DELETE, &req, FS_MSG_MAX, &req, FS_MSG_MAX, &reply_verb);
    if (from <= 0 || reply_verb != FS_DELETE) return -1;

    int* result_field = (int*)&req;
    return *result_field;
}

fn int fs_delete(char* filename) @export("fs_delete") {
    return fs_delete_impl(filename, 0);
}

// Same as fs_delete, but a non-empty directory is emptied first
// instead of refused — see fat32_delete_recursive/ext2_delete_recursive
// (user/fs/*.c3) for what that actually does. Real, separate,
// genuinely destructive from here on: no confirmation prompt, no undo.
fn int fs_delete_recursive(char* filename) @export("fs_delete_recursive") {
    return fs_delete_impl(filename, 1);
}

// Lists `dirname` ("" for the root) into out_buf, which must be at
// least FS_LIST_ENTRY_SIZE * max_entries bytes — same "caller owns the
// buffer, tells us its size" convention as fs_read. Returns the number
// of entries actually written (0..max_entries), or -1 on error (not
// found, not a directory). See user.c3's own FS_LIST wire-format
// comment for each record's layout.
fn int fs_list(char* dirname, char* out_buf, int max_entries) @export("fs_list") {
    uint prefix_len = 0;
    int fsd_pid = ns_resolve(dirname, &prefix_len);
    if (fsd_pid < 0) return -1;
    char* stripped = &dirname[prefix_len];

    char[FS_MSG_MAX] req @noinit;
    int i = 0;
    while (stripped[i] != 0 && i < 99) {
        req[i] = stripped[i];
        i++;
    }
    req[i] = 0;

    uint reply_verb = 0;
    int from = p9_call(fsd_pid, FS_LIST, &req, FS_MSG_MAX, &req, FS_MSG_MAX, &reply_verb);
    if (from <= 0 || reply_verb != FS_LIST) return -1;

    int* result_count_field = (int*)&req;
    int result_count = *result_count_field;
    if (result_count < 0) return result_count;
    if (result_count > max_entries) result_count = max_entries;
    int total_bytes = result_count * (int)FS_LIST_ENTRY_SIZE;
    for (int j = 0; j < total_bytes; j++) {
        out_buf[j] = req[4 + j];
    }
    return result_count;
}

// Creates an empty directory at `dirname` — refuses if anything
// already exists there, or if the parent doesn't (no "mkdir -p": the
// parent must already exist). Real, destructive-adjacent from here on
// the same way fs_delete_recursive is: creates real, persistent
// on-disk state, no undo besides a subsequent fs_delete.
fn int fs_mkdir(char* dirname) @export("fs_mkdir") {
    uint prefix_len = 0;
    int fsd_pid = ns_resolve(dirname, &prefix_len);
    if (fsd_pid < 0) return -1;
    char* stripped = &dirname[prefix_len];

    char[FS_MSG_MAX] req @noinit;
    int i = 0;
    while (stripped[i] != 0 && i < 99) {
        req[i] = stripped[i];
        i++;
    }
    req[i] = 0;

    uint reply_verb = 0;
    int from = p9_call(fsd_pid, FS_MKDIR, &req, FS_MSG_MAX, &req, FS_MSG_MAX, &reply_verb);
    if (from <= 0 || reply_verb != FS_MKDIR) return -1;

    int* result_field = (int*)&req;
    return *result_field;
}

// Renames/moves old_path to new_path — see FS_RENAME's own wire-format
// comment for the full scope (destination must not already exist, no
// cross-directory-cycle detection). Cross-filesystem moves (old and
// new resolving to different fsd instances, e.g. one on the default
// mount and one under "/2/") are refused outright rather than
// attempted — this driver has no copy-then-delete fallback the way a
// real OS's rename(2)-EXDEV caller would use, and silently doing that
// here would turn an atomic-looking rename into a non-atomic one
// without the caller ever being told.
fn int fs_rename(char* old_path, char* new_path) @export("fs_rename") {
    uint old_prefix_len = 0;
    int old_fsd_pid = ns_resolve(old_path, &old_prefix_len);
    if (old_fsd_pid < 0) return -1;
    uint new_prefix_len = 0;
    int new_fsd_pid = ns_resolve(new_path, &new_prefix_len);
    if (new_fsd_pid < 0) return -1;
    if (old_fsd_pid != new_fsd_pid) return -1;

    char* old_stripped = &old_path[old_prefix_len];
    char* new_stripped = &new_path[new_prefix_len];

    char[FS_MSG_MAX] req @noinit;
    int i = 0;
    while (old_stripped[i] != 0 && i < 99) {
        req[i] = old_stripped[i];
        i++;
    }
    req[i] = 0;
    int j = 0;
    while (new_stripped[j] != 0 && j < 99) {
        req[100 + j] = new_stripped[j];
        j++;
    }
    req[100 + j] = 0;

    uint reply_verb = 0;
    int from = p9_call(old_fsd_pid, FS_RENAME, &req, FS_MSG_MAX, &req, FS_MSG_MAX, &reply_verb);
    if (from <= 0 || reply_verb != FS_RENAME) return -1;

    int* result_field = (int*)&req;
    return *result_field;
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
