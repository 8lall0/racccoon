module kernel;

import std::io;
import board;

// Plan 9 notes — racccoon's signals (docs/manual.md, "Notes").
//
// A note is a short string posted to a process: SYS_POSTNOTE, or the
// console's ^C, which posts "interrupt" to the console's note group. It
// is delivered the next time the process is about to return to user mode
// (note_deliver, called at the tail of handle_trap):
//  - no handler registered (SYS_NOTIFY), or the note is "kill": the
//    process is torn down exactly like a user fault (exit code -1);
//  - a handler: the interrupted user context (trap frame, sepc, FP
//    registers) is parked in the Process, the message is copied onto the
//    user stack, and the process resumes in handler(msg). The handler
//    must finish with SYS_NOTED: NCONT restores the parked context,
//    NDFLT kills the process.
//
// A process sleeping in an interruptible wait (getchar, join, futex,
// pipe read/write, ipc_recv, the queued first phase of ipc_send /
// ipc_call, await) is woken by a post and that syscall returns -1 with
// Process.note_intr set — readable once through SYS_INTERRUPTED, so a
// caller can tell "interrupted" from a real failure. Waits where a
// server already holds our request (ipc_call's later phases,
// ipc_reply) are not interrupted; the note lands right after they
// finish (they are bounded by the 15 s call timeout anyway).
//
// Note groups: every process belongs to one (Process.noteg). A
// create_process()'d process starts its own (noteg = pid); an rfork
// child shares its parent's unless rfork is given RFNOTEG. The console
// posts ^C to console_noteg, the shell's group — so the shell and its
// foreground children get it, background jobs (which the shell starts
// with RFNOTEG) and boot servers don't.

const int NNOTE    = 5;  // pending notes per process; a post beyond this is dropped
const int NOTE_MAX = 64; // bytes per note, NUL included

const int NCONT = 0; // SYS_NOTED: resume the interrupted context
const int NDFLT = 1; // SYS_NOTED: take the default action (die)

// Note group the console's ^C goes to. Set to the shell's own group each
// time the kernel spawns (or respawns) the shell.
int console_noteg;

// Kernel-side post. Queues `msg` on `p` and wakes it if it is asleep in
// an interruptible wait. No permission check — the SYS_POSTNOTE path does
// that per target. Returns false if the queue was full (note dropped).
fn bool note_post(Process* p, char* msg) @noinline
{
	if (p.note_count >= NNOTE) { return false; }
	int slot = (p.note_head + p.note_count) % NNOTE;
	int i = 0;
	for (; i < NOTE_MAX - 1 && msg[i] != 0; i++) { p.notes[slot][i] = msg[i]; }
	p.notes[slot][i] = 0;
	p.note_count++;
	if (p.state == PROC_BLOCKED) { p.state = PROC_RUNNABLE; }
	return true;
}

// Post to every live process in note group `g`. `uid` < 0 = kernel post
// (no permission check), else only targets that `uid` may signal (root,
// or the same uid — SYS_KILL's rule). Returns how many got it.
fn int note_post_group(int g, char* msg, int uid) @noinline
{
	int n = 0;
	for (int i = 0; i < PROCS_MAX; i++)
	{
		Process* p = &procs[i];
		if (p.state == PROC_UNUSED || p.state == PROC_RESERVED || p.pid == 0) { continue; }
		if (p == idle_proc || p.noteg != g) { continue; }
		if (uid > 0 && p.uid != uid) { continue; }
		if (note_post(p, msg)) { n++; }
	}
	return n;
}

// True when a note is waiting that would be delivered on the way back to
// user mode — what an interruptible wait checks each pass. While the
// process is already inside its handler, further notes just queue.
fn bool note_deliverable(Process* p)
{
	return p.note_count > 0 && !p.in_note;
}

// An interruptible wait bailing out because of a note: record it for
// SYS_INTERRUPTED and make sure the process is schedulable again.
fn void note_interrupted(Process* p)
{
	p.note_intr = true;
	p.state = PROC_RUNNABLE;
}

// Deliver the oldest pending note to current_proc, which is about to
// return to user mode through `f`. Called at the tail of handle_trap.
fn void note_deliver(Trap_frame* f) @noinline
{
	Process* p = current_proc;
	if (p.note_count == 0 || p.in_note) { return; }

	char[NOTE_MAX] msg;
	int h = p.note_head;
	for (int i = 0; i < NOTE_MAX; i++) { msg[i] = p.notes[h][i]; }
	p.note_head = (p.note_head + 1) % NNOTE;
	p.note_count--;

	bool kill_it = p.note_handler == 0 || str_eq(&msg[0], "kill");

	// The message goes just below the interrupted sp, 16-byte aligned,
	// and the handler's stack starts under it. user_range_valid also
	// demand-maps a lazily reserved stack page.
	uptr msg_at = ((uptr)f.sp - 128) & ~(uptr)15;
	if (!kill_it && !user_range_valid(p.page_table, msg_at, NOTE_MAX, true))
	{
		kill_it = true;
	}
	if (kill_it)
	{
		proc_destroy(p, -1);
		yield(); // never returns: the slot is PROC_UNUSED now
	}

	mem::copy((void*)msg_at, &msg[0], NOTE_MAX);
	p.note_frame = *f;
	p.note_sepc = p.saved_sepc;
	p.note_saved_intr = p.note_intr;
	fp_save((uptr)&p.note_fp);
	p.in_note = true;

	f.a0 = (ulong)msg_at;
	f.sp = (ulong)msg_at;
	f.ra = 0; // returning from the handler instead of calling noted() faults -> killed
	p.saved_sepc = (ulong)p.note_handler;
}

// SYS_NOTED: leave the handler. Returns true when the parked context was
// restored (handle_trap must then NOT advance sepc past the ecall — sepc
// is the interrupted context's own resume address).
fn bool note_noted(Trap_frame* f, int how) @noinline
{
	Process* p = current_proc;
	if (!p.in_note)
	{
		f.a0 = (ulong)(-1);
		return false;
	}
	if (how != NCONT)
	{
		proc_destroy(p, -1);
		yield(); // never returns
	}
	*f = p.note_frame;
	p.saved_sepc = p.note_sepc;
	p.note_intr = p.note_saved_intr;
	fp_restore((uptr)&p.note_fp);
	p.in_note = false;
	return true;
}

// SYS_POSTNOTE: a0 = pid (a1 == 0) or note group (a1 == 1), a2 = the
// message (NUL-terminated, truncated to NOTE_MAX - 1). Permission per
// target is SYS_KILL's: root, or the same uid. Returns how many
// processes got the note, or -1 if none did.
fn void sys_postnote(Trap_frame* f) @noinline
{
	char* umsg = (char*)(uptr)f.a2;
	char[NOTE_MAX] msg;
	int i = 0;
	for (; i < NOTE_MAX - 1; i++)
	{
		if (!user_range_valid(current_proc.page_table, (uptr)(umsg + i), 1, false))
		{
			f.a0 = (ulong)(-1);
			return;
		}
		msg[i] = umsg[i];
		if (msg[i] == 0) { break; }
	}
	msg[i] = 0;

	int n = 0;
	if (f.a1 == 1)
	{
		n = note_post_group((int)f.a0, &msg[0], current_proc.uid);
	}
	else
	{
		Process* t = proc_by_pid((int)f.a0);
		if (t != null && t != idle_proc && (current_proc.uid == 0 || current_proc.uid == t.uid))
		{
			if (note_post(t, &msg[0])) { n = 1; }
		}
	}
	f.a0 = n > 0 ? (ulong)n : (ulong)(-1);
}

// --- console input ---------------------------------------------------

// One console byte, from the serial line or a USB keyboard: ^C becomes
// an "interrupt" note to the console's group, everything else goes into
// the keystroke queue SYS_GETCHAR serves from (src/kbd.c3).
fn void console_input_byte(int ch) @noinline
{
	if (ch == 3)
	{
		note_post_group(console_noteg, "interrupt", -1);
		return;
	}
	kbd_queue_push((char)ch);
}

// Drain whatever the serial console has buffered into the keystroke
// queue, turning ^C into a note on the way. SYS_GETCHAR calls this every
// pass; the timer tick and other waits call console_poll_maybe so a ^C
// still lands while nobody is reading the console (a compute loop, the
// shell parked in join).
fn void console_poll() @noinline
{
	for (int i = 0; i < 64; i++)
	{
		int ch = board::console_getchar();
		if (ch < 0) { return; }
		console_input_byte(ch);
	}
}

ulong g_console_poll_next;

// The `time` CSR, behind a real call. read_reg's asm clobbers t0/t1
// without telling the compiler; inline in a loop that keeps locals live
// across it, that has corrupted them before (see SYS_NS_MOUNT_WAIT's
// comment). A call boundary makes the clobber an ordinary caller-saved one.
fn ulong time_now() @noinline
{
	return read_reg("time");
}

// console_poll at most every ~20 ms — for loops that spin a lot (join)
// where an SBI call per pass would be wasted work.
fn void console_poll_maybe() @noinline
{
	ulong now = time_now();
	if (now < g_console_poll_next) { return; }
	g_console_poll_next = now + board::TIMEBASE_HZ / 50;
	console_poll();
}
