module kernel;

// Kernel-side keystroke queue. Lets usbd (user/usb/usbd.c3, via
// SYS_KBD_PUSH) feed decoded USB-keyboard bytes into the same input
// stream SYS_GETCHAR serves from the serial console — the shell and
// every other getchar() caller are unchanged, and a byte from a USB
// keyboard is indistinguishable from one typed on the serial line.
//
// Single producer (usbd, via SYS_KBD_PUSH), single consumer (whoever
// calls getchar, in practice the shell, via SYS_GETCHAR). A full queue
// drops the newest byte: a lost keystroke under an extreme backlog beats
// blocking usbd's poll loop or a torn buffer.
//
// SMP scheduler, Stage B (spinlock.c3, docs/roadmap.md §8): producer and
// consumer are separate syscall paths, so on one hart they already can't
// interleave, but the timer tick can land between any two statements
// here and Stage C runs them on different harts. kbd_lock makes the
// head/tail update atomic w.r.t. the other side.

const uint KBD_QUEUE_SIZE = 64;

char[KBD_QUEUE_SIZE] kbd_queue;
uint kbd_queue_head; // next slot to write
uint kbd_queue_tail; // next slot to read
Spinlock kbd_lock;

// Returns false (byte dropped) if the queue is full.
fn bool kbd_queue_push(char c)
{
    kbd_lock.acquire();
    uint next = (kbd_queue_head + 1) % KBD_QUEUE_SIZE;
    if (next == kbd_queue_tail) { kbd_lock.release(); return false; }
    kbd_queue[kbd_queue_head] = c;
    kbd_queue_head = next;
    kbd_lock.release();
    return true;
}

// Returns -1 if the queue is empty, otherwise the next byte (0..255).
fn int kbd_queue_pop()
{
    kbd_lock.acquire();
    if (kbd_queue_head == kbd_queue_tail) { kbd_lock.release(); return -1; }
    char c = kbd_queue[kbd_queue_tail];
    kbd_queue_tail = (kbd_queue_tail + 1) % KBD_QUEUE_SIZE;
    kbd_lock.release();
    return (int)((uint)c & 0xFF);
}
