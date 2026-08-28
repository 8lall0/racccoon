module user;

import std::nolibc::atomic;
import std::nolibc::fmt;

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
const int SYS_PARENT_INFO  = 23; // returns a process's parent pid/generation, if it has one — see src/entry.c3's case
const int SYS_EXEC         = 24; // replaces the calling process's own image in place — see src/entry.c3's case
const int SYS_SETUID       = 25; // sets the caller's own uid, only while still root — see src/entry.c3's case
const int SYS_NS_MOUNT_WAIT = 26; // SYS_NS_MOUNT, but blocks (bounded by a retry count) until the target actually posts — see src/entry.c3's case
const int SYS_YIELD         = 27; // voluntarily gives up the rest of this process's timeslice once — see src/entry.c3's case
const int SYS_USBD_INFO     = 28; // usbd-only: returns its DMA buffer physical address — see src/entry.c3's case
const int SYS_NETD_INFO     = 29; // netd-only: returns its RX/TX virtqueue physical addresses, plus its packet-buffer page — see src/entry.c3's case
const int SYS_ETHD_INFO     = 30; // ethd-only: returns its DMA region's physical address — see src/entry.c3's case
const int SYS_KBD_PUSH      = 31; // usbd-only: pushes one decoded USB-keyboard byte into the kernel keystroke queue SYS_GETCHAR drains — see src/entry.c3's case
const int SYS_DRIVER_IRQ_ARM = 32; // usbd/sdd: re-enable this driver's PLIC source (handle_trap disables it on each fire — level-triggered); dispatched by caller pid — see src/entry.c3's case
const int SYS_SDD_INFO      = 33; // sdd-only: returns its SDMA staging buffer's physical address — same shape as SYS_USBD_INFO
const int SYS_IPC_CALL      = 34; // one-shot RPC: deliver a request and block for the reply, all in the kernel — reply can't be pre-empted by a stray sender, aborts -1 if the server dies at any point — see src/entry.c3's case

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

// Real exec(): replaces THIS process's own image in place — same pid,
// same page table, same namespace (and by extension /env's own vars,
// user/envd.c3 — nothing about "which process this is" changes, only
// what it's running), matching real Plan 9's/Unix's own exec()
// semantics. Composes with rfork() the way Unix fork()+exec() do: to
// run a program without replacing yourself, rfork(RFPROC) first, then
// exec() inside the child.
//
// buf/buf_max are caller-owned, not a global here: user.c3 is compiled
// into every binary (scripts/build_user.sh), so a large static buffer
// here would bloat every server's own image — and, via
// --set-section-flags .bss=alloc,contents already forcing real zero-
// byte backing in every flat binary, the kernel's own embedded image
// size too — whether or not that binary ever calls exec(). Loops
// fs_read_at() (below) until a short read (clean EOF) or buf_max is
// exhausted, then installs the complete image in one SYS_EXEC call —
// the syscall itself never touches disk, so a read failure partway
// through never risks leaving this process's own current image half-
// replaced.
//
// notify_pid (0 = none) gets a single untyped message right before the
// point of no return — after every fs_read_at() this needed is done, so
// no more traffic to fsd will ever happen, but before SYS_EXEC actually
// touches this process's image. A caller that wants to talk to the
// child right after exec() succeeds (its pid is unaffected, so it's
// still reachable) has no other way to know when that's actually safe.
// This process's single inbox slot has no per-sender filtering, so an
// outside message sent too early used to be able to land while a
// fs_read_at() call was still waiting on fsd's reply and get mistaken
// for it — the whole reason for the notify. That race is now closed at
// the source: SYS_IPC_CALL (which p9_call rides) reserves the inbox for
// the server's reply, so a too-early notify just waits its turn. The
// notify still matters for ordering (the caller shouldn't race the
// child's own first ipc_recv), it's just no longer load-bearing for
// correctness. Found debugging exec()'s runtest — see docs/devlog.md.
//
// argv (argc entries, null/0 for none) rides in the same buf, packed
// right after the image content as NUL-separated strings ("foo\0bar\0"
// for argc=2) — the simplest encoding that survives being copied as a
// flat byte blob into the new process's own address space; real
// pointers wouldn't survive that copy. SYS_EXEC (src/entry.c3) stages
// this blob as its own pages, mapped right after the image's own last
// page, and hands the new process argc/its base address via a0/a1 at
// entry — start() below passes them straight through as real
// `main(int, char**)` parameters (the standard C-ABI shape); the
// compiler's own generated main wrapper (std::nolibc::main_stub's
// @main_args, invoked for any `fn void main(String[] args)`) is what
// reinterprets that pointer as this blob's base address and walks it,
// not a real array of `char*`.
//
// Only ever returns on failure (-1) — success means this process is
// now running path's code instead of this line.
fn int exec(char* path, char* buf, uint buf_max, int notify_pid, char** argv, int argc) @export("exec") {
    uint total = 0;
    for (;;) {
        if (total >= buf_max) return -1; // image bigger than the caller's own buffer
        int chunk = (int)(buf_max - total);
        if (chunk > (int)(FS_MSG_MAX - 4)) chunk = (int)(FS_MSG_MAX - 4);
        int got = fs_read_at(path, &buf[total], chunk, total);
        if (got < 0) return -1; // real error — not found, a directory
        if (got == 0) break; // clean EOF
        total += (uint)got;
    }
    if (total == 0) return -1; // empty/nonexistent file — nothing to run

    uint argv_len = 0;
    for (int i = 0; i < argc; i++) {
        char* arg = argv[i];
        uint j = 0;
        while (arg[j] != 0) {
            if (total + argv_len >= buf_max) return -1; // argv too big for this buffer
            buf[total + argv_len] = arg[j];
            argv_len++;
            j++;
        }
        if (total + argv_len >= buf_max) return -1;
        buf[total + argv_len] = 0;
        argv_len++;
    }

    if (notify_pid > 0) {
        ipc_send(notify_pid, 0, "ready", 6);
    }
    return syscall4(SYS_EXEC, (long)buf, (long)total, (long)argv_len, (long)argc);
}

// exec(), but resolves `name` against a real search list instead of
// requiring a full path — the way a shell actually looks up commands.
// A separate function, not a mode of exec() itself: exec() keeps its
// current, unambiguous meaning ("run exactly this file"), matching
// Unix's own split between execve() (exact path) and execvp()
// ($PATH-searched).
//
// The search list itself is /env/PATH (user/envd.c3) — a
// colon-separated list of directory prefixes ("bin/:/2/bin/"), reusing
// this session's own per-process configuration mechanism (including its
// lazy inheritance across rfork()) rather than inventing a second one.
// Real Plan 9 doesn't have $PATH at all — it uses namespace binds/union
// directories instead — but this kernel's filesystem backends don't
// support those, and $PATH-style search is what was actually asked for.
// No /env/PATH set means a single hardcoded default, "bin/" — matching
// every existing test fixture's own bin/echod path exactly, so callers
// that never touch /env/PATH see identical behavior for free.
//
// Only ever returns on failure (-1, every prefix in the search list
// failed) — same "only returns on failure" contract as exec() itself.
//
// PATH_VAR_MAX must match user/envd.c3's own ENV_VALUE_MAX (also 64) —
// can't share the real constant, envd.c3 is its own separate
// compilation (scripts/build_user.sh builds each server from its own
// source list; user.c3 is the only file every one of them shares).
const int PATH_VAR_MAX = 64;
fn int exec_path(char* name, char* buf, uint buf_max, int notify_pid, char** argv, int argc) @export("exec_path") {
    char[PATH_VAR_MAX] path_var @noinit;
    int path_len = fs_read("/env/PATH", &path_var, PATH_VAR_MAX - 1); // leave room for the NUL below
    char* search;
    if (path_len <= 0) {
        search = "bin/";
    } else {
        path_var[path_len] = 0;
        search = &path_var;
    }

    char[128] candidate @noinit;
    int start = 0;
    for (;;) {
        int i = start;
        while (search[i] != 0 && search[i] != ':') i++;

        if (i > start) {
            int ci = 0;
            for (int k = start; k < i && ci < 100; k++) {
                candidate[ci] = search[k];
                ci++;
            }
            int ni = 0;
            while (name[ni] != 0 && ci < 127) {
                candidate[ci] = name[ni];
                ci++;
                ni++;
            }
            candidate[ci] = 0;

            exec(&candidate, buf, buf_max, notify_pid, argv, argc);
            // exec() only returns on failure — try the next prefix.
        }

        if (search[i] == 0) break;
        start = i + 1;
    }
    return -1;
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

// One-shot RPC. `buf` holds `req_len` request bytes on entry and gets up
// to `buf_cap` reply bytes written back (in-place — the kernel copies the
// request out before it copies the reply in). `reply_type_out` (optional)
// receives the reply verb. Returns the replier's pid on success, -1 if
// the target never existed, exited, or was killed at any point during the
// call. Replaces the ipc_send + filtered-ipc_recv + P9_STRAY dance that
// p9_call used to open-code.
fn int ipc_call(int dest_pid, uint verb, char* buf, int req_len, int buf_cap, uint* reply_type_out) @export("ipc_call") {
    long packed = ((long)(req_len & 0xFFFF) << 16) | (long)(buf_cap & 0xFFFF);
    return syscall5(SYS_IPC_CALL, dest_pid, (long)verb, (long)buf, packed, (long)reply_type_out);
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

// Real 9P semantics — FIDs, an actual walk, open/read/clunk against a
// real (if small and synthetic) backing tree — echod's own sandbox
// (user/echod.c3), see docs/devlog.md for why this is new verbs rather
// than a change to P9_TWALK/P9_TREAD's own behavior above: those two
// still mean exactly what they always have (ping/runtest/argvtest/
// p9test all still depend on that), this is a separate, additional
// protocol layered alongside them, not a replacement. Numbering just
// picks up after P9_TREAD — different verb-number spaces (P9_*, FS_*,
// SYS_*) only ever need to be unique within whatever one process's own
// dispatch actually checks, never globally, so no collision risk with
// unrelated verbs a completely different server understands.
const uint P9_ATTACH = 3; // request: allocate a fid pointing at the tree's own root
const uint P9_WALK   = 4; // request: resolve one path element from an existing fid onto a new one
const uint P9_OPEN   = 5; // request: mark a fid ready for reading
const uint P9_READ   = 6; // request: real offset-based read from an opened fid
const uint P9_CLUNK  = 7; // request: release a fid

// Real writes against fsd (Tcreate/Tremove full, Twrite offset-0 only)
// — see docs/devlog.md. Same "different verb-number spaces never need
// global uniqueness" reasoning as the five verbs above; just the next
// free small ints after P9_CLUNK.
const uint P9_CREATE = 8;  // request: create a file (or, with P9_DMDIR set in perm, a directory) in a directory fid, transforming it into the new fid
const uint P9_WRITE  = 9;  // request: real pwrite()-style offset-aware write to an opened fid — no holes past the current end (see fsd.c3's own dispatch comment)
const uint P9_REMOVE = 10; // request: remove a fid's file — always consumes the fid (unless rejected outright by fsd's own dangling-fid safety check)

// The real Plan9 DMDIR bit (0x80000000) — set in P9_CREATE's own perm
// argument to create a directory instead of a regular file. Matches
// real 9P's own Tcreate exactly, rather than inventing a separate verb
// for what's really the same request with one bit different.
const uint P9_DMDIR = 0x80000000;

// Sends a 9P-lite request and blocks for the reply in one call — the
// pattern every client actually wants, matching 9P's own synchronous
// request/reply model. reply_verb (optional, pass null if unneeded) lets
// the caller confirm the reply actually answers the request it sent,
// rather than trusting the byte content alone.
//
// Now a thin shim over the kernel's SYS_IPC_CALL, which owns the whole
// round-trip: it reserves this process's inbox for dest_pid's reply
// (so a stray sender — e.g. exec()'s "ready" notify landing while a
// process is mid p9_call to fsd — just waits its turn instead of being
// mistaken for the reply and bounced), and it returns -1 if dest_pid
// exits or is killed at any point, including while we wait for the
// reply. SYS_IPC_CALL is in-place (request in `buf`, reply written
// back), so if the caller passed a separate `data` buffer, move it into
// `reply_buf` first — every real caller but p9_read already passes the
// same buffer for both.
fn int p9_call(int dest_pid, uint verb, char* data, int len, char* reply_buf, int reply_len, uint* reply_verb) {
    if (data != reply_buf) {
        int n = len < reply_len ? len : reply_len;
        for (int i = 0; i < n; i++) { reply_buf[i] = data[i]; }
    }
    uint rt = 0;
    int from = ipc_call(dest_pid, verb, reply_buf, len, reply_len, &rt);
    if (reply_verb != null) { *reply_verb = rt; }
    return from;
}

// --- Real 9P (P9_ATTACH/P9_WALK/P9_OPEN/P9_READ/P9_CLUNK) — thin
// wrappers, same shape every other syscall/IPC wrapper in this file
// already has: pack a fixed-offset request buffer, call p9_call(),
// unpack the reply. See user/echod.c3's own dispatch for the server
// side and the exact wire layout each of these matches.

fn int p9_attach(int dest_pid, uint fid) @export("p9_attach") {
    char[4] req @noinit;
    uint* fid_field = (uint*)&req[0];
    *fid_field = fid;
    uint reply_verb = 0;
    int from = p9_call(dest_pid, P9_ATTACH, &req, 4, &req, 4, &reply_verb);
    if (from <= 0 || reply_verb != P9_ATTACH) return -1;
    int* result_field = (int*)&req;
    return *result_field;
}

fn int p9_walk(int dest_pid, uint fid, uint newfid, char* name) @export("p9_walk") {
    char[40] req @noinit;
    uint* fid_field = (uint*)&req[0];
    uint* newfid_field = (uint*)&req[4];
    *fid_field = fid;
    *newfid_field = newfid;
    int i = 0;
    while (name[i] != 0 && i < 31) { req[8 + i] = name[i]; i++; }
    req[8 + i] = 0;
    uint reply_verb = 0;
    int from = p9_call(dest_pid, P9_WALK, &req, 40, &req, 40, &reply_verb);
    if (from <= 0 || reply_verb != P9_WALK) return -1;
    int* result_field = (int*)&req;
    return *result_field;
}

fn int p9_open(int dest_pid, uint fid) @export("p9_open") {
    char[4] req @noinit;
    uint* fid_field = (uint*)&req[0];
    *fid_field = fid;
    uint reply_verb = 0;
    int from = p9_call(dest_pid, P9_OPEN, &req, 4, &req, 4, &reply_verb);
    if (from <= 0 || reply_verb != P9_OPEN) return -1;
    int* result_field = (int*)&req;
    return *result_field;
}

// buf_out receives up to `count` bytes — same "clamp to what the
// caller actually asked for" discipline fs_read()'s own reply-unpacking
// already uses, in case the server ever returned more than requested.
fn int p9_read(int dest_pid, uint fid, uint offset, uint count, char* buf_out) @export("p9_read") {
    char[12] req @noinit;
    uint* fid_field = (uint*)&req[0];
    uint* offset_field = (uint*)&req[4];
    uint* count_field = (uint*)&req[8];
    *fid_field = fid;
    *offset_field = offset;
    *count_field = count;
    char[64] reply @noinit;
    uint reply_verb = 0;
    int from = p9_call(dest_pid, P9_READ, &req, 12, &reply, 64, &reply_verb);
    if (from <= 0 || reply_verb != P9_READ) return -1;
    int* result_len_field = (int*)&reply;
    int result_len = *result_len_field;
    if (result_len < 0) return result_len;
    if ((uint)result_len > count) result_len = (int)count;
    for (int j = 0; j < result_len; j++) buf_out[j] = reply[4 + j];
    return result_len;
}

fn int p9_clunk(int dest_pid, uint fid) @export("p9_clunk") {
    char[4] req @noinit;
    uint* fid_field = (uint*)&req[0];
    *fid_field = fid;
    uint reply_verb = 0;
    int from = p9_call(dest_pid, P9_CLUNK, &req, 4, &req, 4, &reply_verb);
    if (from <= 0 || reply_verb != P9_CLUNK) return -1;
    int* result_field = (int*)&req;
    return *result_field;
}

// P9_CREATE/P9_WRITE/P9_REMOVE — same thin-wrapper shape as the five
// above. See fsd.c3's own dispatch for the exact wire layout each
// matches.

// perm: 0 for a regular file, P9_DMDIR to create a directory instead
// — matches real 9P's own Tcreate argument exactly.
fn int p9_create(int dest_pid, uint fid, char* name, uint perm) @export("p9_create") {
    char[40] req @noinit;
    uint* fid_field = (uint*)&req[0];
    uint* perm_field = (uint*)&req[4];
    *fid_field = fid;
    *perm_field = perm;
    int i = 0;
    while (name[i] != 0 && i < 31) { req[8 + i] = name[i]; i++; }
    req[8 + i] = 0;
    uint reply_verb = 0;
    int from = p9_call(dest_pid, P9_CREATE, &req, 40, &req, 40, &reply_verb);
    if (from <= 0 || reply_verb != P9_CREATE) return -1;
    int* result_field = (int*)&req;
    return *result_field;
}

fn int p9_write(int dest_pid, uint fid, uint offset, char* data, uint count) @export("p9_write") {
    char[FS_MSG_MAX] req @noinit;
    uint* fid_field = (uint*)&req[0];
    uint* offset_field = (uint*)&req[4];
    uint* count_field = (uint*)&req[8];
    *fid_field = fid;
    *offset_field = offset;
    uint write_len = count;
    if (write_len > FS_MSG_MAX - 12) write_len = FS_MSG_MAX - 12;
    *count_field = write_len;
    for (uint i = 0; i < write_len; i++) req[12 + i] = data[i];
    uint reply_verb = 0;
    int from = p9_call(dest_pid, P9_WRITE, &req, FS_MSG_MAX, &req, FS_MSG_MAX, &reply_verb);
    if (from <= 0 || reply_verb != P9_WRITE) return -1;
    int* result_field = (int*)&req;
    return *result_field;
}

fn int p9_remove(int dest_pid, uint fid) @export("p9_remove") {
    char[4] req @noinit;
    uint* fid_field = (uint*)&req[0];
    *fid_field = fid;
    uint reply_verb = 0;
    int from = p9_call(dest_pid, P9_REMOVE, &req, 4, &req, 4, &reply_verb);
    if (from <= 0 || reply_verb != P9_REMOVE) return -1;
    int* result_field = (int*)&req;
    return *result_field;
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

// Same as ns_mount() above, but blocks — retrying up to max_attempts
// times (yielding between each) — for a server that hasn't posted
// itself yet but is expected to soon (a dynamically-spawned driver
// still finishing its own hardware init, for instance). A plain retry
// count, not a wall-clock timeout — see SYS_NS_MOUNT_WAIT's own case
// (src/entry.c3) for why: a real time-CSR deadline crashed here,
// combining read_reg("time") with other locals surviving across
// repeated calls inside a loop. Returns 0 once bound, -1 if every
// attempt failed — same convention every other ns_*/srv_* wrapper
// already uses.
fn int ns_mount_wait(char* prefix, char* srv_name, ulong max_attempts) @export("ns_mount_wait") {
    return syscall(SYS_NS_MOUNT_WAIT, (long)prefix, (long)srv_name, (long)max_attempts);
}

// Voluntarily gives up the rest of this process's timeslice once —
// there's no general-purpose sleep()/yield() in this kernel otherwise
// (every other blocking syscall needs a real condition to wait for).
// For a process busy-waiting on something with no syscall of its own
// (a hardware register poll, a real-time delay via rdtime()) so it
// stays cooperatively preemptible instead of a syscall-free spin —
// see SYS_YIELD's own case (src/entry.c3) for why that matters: this
// kernel's own design means a genuinely syscall-free loop can never be
// preempted once some other process is idling in SYS_GETCHAR (the
// shell's own normal resting state), a real deadlock, not just an
// inefficiency.
fn void yield() @export("yield") {
    syscall(SYS_YIELD, 0, 0, 0);
}

// usbd-only, called once at its own startup — see process.c3's
// usbd_dma_paddr for why this address can't be known at compile time.
fn uptr usbd_info() @export("usbd_info") {
    uptr dma_paddr;
    syscall(SYS_USBD_INFO, (long)&dma_paddr, 0, 0);
    return dma_paddr;
}

// netd-only, called once at its own startup — see process.c3's
// netd_rxq_paddr/netd_txq_paddr/netd_pktbuf_paddr for why these
// addresses can't be known at compile time.
fn void netd_info(uptr* rxq_paddr_out, uptr* txq_paddr_out, uptr* pktbuf_paddr_out) @export("netd_info") {
    syscall(SYS_NETD_INFO, (long)rxq_paddr_out, (long)txq_paddr_out, (long)pktbuf_paddr_out);
}

// ethd-only, called once at its own startup — see process.c3's
// ethd_dma_paddr for why this address can't be known at compile time.
fn uptr ethd_info() @export("ethd_info") {
    uptr dma_paddr;
    syscall(SYS_ETHD_INFO, (long)&dma_paddr, 0, 0);
    return dma_paddr;
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

// Returns 0 and fills *state_out/*generation_out/*uid_out if pid is
// currently live, -1 otherwise (any out-pointer may be null if
// unneeded, same convention as ns_resolve's own out_prefix_len). state
// is src/process.c3's PROC_RUNNABLE (1) or PROC_BLOCKED (2) — never
// PROC_UNUSED (0), since the kernel's own proc_by_pid() already filters
// that case out before this can return success. uid_out (new, syscall4
// for the extra argument — see src/entry.c3's SYS_PROC_INFO case for
// why widening the wrapper directly is safe here) is what lets a
// server like procd (user/procd.c3) look up the real requester's uid
// before acting on their behalf with its own, always-root privilege.
fn int proc_info(int pid, uint* state_out, uint* generation_out, int* uid_out) @export("proc_info") {
    return syscall4(SYS_PROC_INFO, pid, (long)state_out, (long)generation_out, (long)uid_out);
}

// Sets the caller's own uid — never another process's — and only
// while still root (uid 0); once dropped, permanent. The only
// privilege primitive this kernel has: no login, no credentials, just
// "a root process can voluntarily drop itself (or a freshly-rforked
// child, which inherits root too) to a lower, permanent privilege
// level" — the standard fork() + child-calls-setuid() idiom. Gates
// kill() (root or same-uid target only) and srv_post()'s
// reclaim-an-existing-name case (root or same-uid as the live holder)
// — see both their own comments, src/entry.c3.
fn int setuid(int new_uid) @export("setuid") {
    return syscall(SYS_SETUID, new_uid, 0, 0);
}

// Returns pid's parent pid, filling *parent_generation_out (may be null
// if unneeded) with the parent's own generation — everything needed to
// confirm that parent is still the exact instance pid was forked from
// before trusting anything copied from it. Returns -1 if pid doesn't
// exist or genuinely has no parent (create_process()'d directly rather
// than forked — echod, fsd, a respawned shell, ...).
fn int parent_info(int pid, uint* parent_generation_out) @export("parent_info") {
    return syscall(SYS_PARENT_INFO, pid, (long)parent_generation_out, 0);
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

// fsd-only. start_sector_out: board::FS_PARTITION_START_SECTOR (board is
// kernel-only — this is fsd's only way to learn it). is_secondary_out
// (optional): whether this is the second simultaneously-mounted fsd
// instance (see src/process.c3's Process.is_secondary_fs).
// storage_pid_out (optional): which pid runs the block-storage driver
// (diskd/sdd), so fsd doesn't hardcode it; 0 if the board has no block
// device.
fn int fs_partition_info(uint* start_sector_out, bool* is_secondary_out, int* storage_pid_out) @export("fs_partition_info") {
    return syscall(SYS_FS_PARTITION_INFO, (long)start_sector_out, (long)is_secondary_out, (long)storage_pid_out);
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
    char[10] digits @noinit; // uint::max is 10 digits
    int count = fmt::format_uint(n, &digits);
    for (int i = 0; i < count; i++) {
        putchar(digits[i]);
    }
}

// --- Hex printing + raw MMIO -----------------------------------------
// Every device-register driver (dwc2, sdhci, dwmac, gpiod, virtio, ...)
// wants these and had its own byte-identical copy; they live here now
// since user.c3 is linked into every user program.
const char[16] HEX_DIGITS = "0123456789abcdef";

fn void print_hex8(uint v) @export("print_hex8") {
    putchar(HEX_DIGITS[(v >> 4) & 0xF]);
    putchar(HEX_DIGITS[v & 0xF]);
}

fn void print_hex32(uint v) @export("print_hex32") {
    for (int shift = 28; shift >= 0; shift -= 4) {
        putchar(HEX_DIGITS[(v >> shift) & 0xF]);
    }
}

// Plain 32-bit MMIO load/store. Block-form `asm {}` (not the opaque-
// string form rdtime() needs): `lw`/`sw` are ordinary instructions the
// compiler models, and the memory operand carries the side effect.
// `addr` and the bound locals must be `uptr`/`ulong` — a 32-bit `uint`
// in that binding position is rejected by c3c on a 64-bit target. `lw`
// sign-extends into the full 64-bit register; harmless for mmio_read32
// since the `(uint)` truncation discards the upper word (a 64-bit MMIO
// read would need explicit masking — see user/virtio.c3's mmio_read64).
// `lwu` would be the direct fix but block-form asm doesn't recognise it.
fn uint mmio_read32(uptr addr) @export("mmio_read32") {
    ulong v;
    asm {
        lw v, [addr];
    }
    return (uint)v;
}

fn void mmio_write32(uptr addr, uint v) @export("mmio_write32") {
    ulong vv = (ulong)v;
    asm {
        sw vv, [addr];
    }
}

// Fatal error from a driver: print "<prefix><msg>" and exit(). NOT an
// empty for(;;){} — that's UB by LLVM's rules and a real optimizer
// target (it got silently dropped under -O2 once, falling through into
// a half-initialized caller; see docs/devlog.md). exit() is a real
// syscall with a side effect the optimizer can't reason away.
fn void panic(char* prefix, char* msg) @export("user_panic") {
    print(prefix);
    print(msg);
    print("\n");
    exit();
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
// for a read, 4.. for the data. The offset-aware verbs each carry their
// own layout, documented at their own const below: FS_READ_AT and
// FS_WRITE_AT add a uint offset (data at 108 for FS_WRITE_AT so offset
// and data don't collide), FS_STAT returns size + type.
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
// FS_READ_AT: same request shape as FS_READ (byte 0..99 = path, byte
// 100..103 = max length) plus byte 104..107 = uint offset — chunked
// reads for files bigger than one FS_MSG_MAX message, built for exec()
// below (real binaries are 70-105KB; FS_READ alone can only ever
// return ~1124 bytes in one call). Reply: same as FS_READ (byte 0..3 =
// result length, byte 4.. = data) — 0 signals clean EOF (offset at or
// past the file's end), -1 is a real error (not found, a directory).
// A new verb rather than widening FS_READ itself: every existing
// FS_READ caller only ever sets byte 0..103, so treating byte
// 104..107 as a live offset on the *same* verb would mean reading
// uninitialized stack garbage as an offset for every caller not
// updated to know about it — same reasoning SYS_IPC_RECV_GEN
// (src/entry.c3) used over widening SYS_IPC_RECV.
const uint FS_READ_AT = 26;
// FS_WRITE_AT: byte 0..99 = path, 100..103 = uint length, 104..107 =
// uint offset, 108.. = data (so <= FS_MSG_MAX-108 = 1020 bytes/call —
// chunked, like FS_READ_AT). Offset-aware write: overwrite bytes
// anywhere in the file, or append exactly at the current end to grow
// it. No holes — a backend rejects (-1) an offset past the file's
// current size, same rule the P9_WRITE path already follows (devlog
// 2026-08-21 entry 61). offset == FS_OFFSET_APPEND is resolved by fsd
// to the file's current size, so a caller can append without a prior
// FS_STAT. Creates the file if missing (offset must then be 0). Reply:
// byte 0..3 = bytes written or -1. A separate verb from FS_WRITE, not a
// widening, for the same reason FS_READ_AT is separate from FS_READ.
const uint FS_WRITE_AT = 27;
// FS_STAT: byte 0..99 = path ("" = the root). Reply: byte 0..3 = 0 or
// -1 (nothing resolves there), byte 4..7 = uint size (0 for a
// directory), byte 8 = type (0 = file, 1 = directory).
const uint FS_STAT = 28;
// Sentinel offset for FS_WRITE_AT meaning "append at the file's current
// end" — fsd resolves it per-backend before dispatching.
const uint FS_OFFSET_APPEND = 0xFFFFFFFF;
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

// Same shape as fs_read() above, plus offset — chunked reads for files
// bigger than one FS_MSG_MAX message (see FS_READ_AT's own wire-format
// comment). Returns 0 at clean EOF (offset at or past the file's end),
// same as a plain fs_read() past the end would, not -1 — exec() below
// relies on this to know when to stop looping.
fn int fs_read_at(char* filename, char* buf, int len, uint offset) @export("fs_read_at") {
    uint prefix_len = 0;
    int fsd_pid = ns_resolve(filename, &prefix_len);
    if (fsd_pid < 0) return -1;
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
    uint* offset_field = (uint*)&req[104];
    *offset_field = offset;

    uint reply_verb = 0;
    int from = p9_call(fsd_pid, FS_READ_AT, &req, FS_MSG_MAX, &req, FS_MSG_MAX, &reply_verb);
    if (from <= 0 || reply_verb != FS_READ_AT) return -1;

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

// Offset-aware write — overwrite bytes anywhere in the file, or append
// at the current end (pass offset == FS_OFFSET_APPEND for "wherever the
// end currently is"). Chunked: a single call carries at most
// FS_MSG_MAX-108 bytes, so writing a larger buffer means calling this in
// a loop advancing `offset`, the mirror image of fs_read_at. Returns
// bytes actually written this call, or -1 (not found + a nonzero
// offset, a hole, a directory, permission). See FS_WRITE_AT's own
// wire-format comment.
fn int fs_write_at(char* filename, char* buf, int len, uint offset) @export("fs_write_at") {
    uint prefix_len = 0;
    int fsd_pid = ns_resolve(filename, &prefix_len);
    if (fsd_pid < 0) return -1;
    char* stripped = &filename[prefix_len];

    char[FS_MSG_MAX] req @noinit;
    int i = 0;
    while (stripped[i] != 0 && i < 99) {
        req[i] = stripped[i];
        i++;
    }
    req[i] = 0;

    int write_len = len;
    if (write_len < 0) write_len = 0;
    if (write_len > (int)(FS_MSG_MAX - 108)) write_len = (int)(FS_MSG_MAX - 108);
    uint* len_field = (uint*)&req[100];
    *len_field = (uint)write_len;
    uint* offset_field = (uint*)&req[104];
    *offset_field = offset;
    for (int j = 0; j < write_len; j++) {
        req[108 + j] = buf[j];
    }

    uint reply_verb = 0;
    int from = p9_call(fsd_pid, FS_WRITE_AT, &req, FS_MSG_MAX, &req, FS_MSG_MAX, &reply_verb);
    if (from <= 0 || reply_verb != FS_WRITE_AT) return -1;

    int* result_field = (int*)&req;
    return *result_field;
}

// Size + type of `filename` ("" = the root directory). On success
// returns 0 and fills *out_size (0 for a directory) and *out_type
// (0 = file, 1 = directory), either of which may be null. Returns -1 if
// nothing resolves there. See FS_STAT's own wire-format comment.
fn int fs_stat(char* filename, uint* out_size, int* out_type) @export("fs_stat") {
    uint prefix_len = 0;
    int fsd_pid = ns_resolve(filename, &prefix_len);
    if (fsd_pid < 0) return -1;
    char* stripped = &filename[prefix_len];

    char[FS_MSG_MAX] req @noinit;
    int i = 0;
    while (stripped[i] != 0 && i < 99) {
        req[i] = stripped[i];
        i++;
    }
    req[i] = 0;

    uint reply_verb = 0;
    int from = p9_call(fsd_pid, FS_STAT, &req, FS_MSG_MAX, &req, FS_MSG_MAX, &reply_verb);
    if (from <= 0 || reply_verb != FS_STAT) return -1;

    int* result_field = (int*)&req;
    if (*result_field < 0) return -1;
    uint* size_field = (uint*)&req[4];
    if (out_size != null) *out_size = *size_field;
    if (out_type != null) *out_type = (int)((uint)req[8] & 0xFF);
    return 0;
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
