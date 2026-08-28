module kernel;

// Kernel-side keystroke queue. Lets usbd (user/usb/usbd.c3, via
// SYS_KBD_PUSH) feed decoded USB-keyboard bytes into the same input
// stream SYS_GETCHAR serves from the serial console — the shell and
// every other getchar() caller are unchanged, and a byte from a USB
// keyboard is indistinguishable from one typed on the serial line.
//
// Single producer (usbd), single consumer (whoever calls getchar, in
// practice the shell). This kernel is single-hart and cooperative — a
// syscall runs to completion without preemption and SYS_KBD_PUSH never
// yields — so head/tail need no locking. A full queue drops the newest
// byte: a lost keystroke under an extreme backlog beats blocking usbd's
// poll loop or a torn buffer.

const uint KBD_QUEUE_SIZE = 64;

char[KBD_QUEUE_SIZE] kbd_queue;
uint kbd_queue_head; // next slot to write
uint kbd_queue_tail; // next slot to read

// Returns false (byte dropped) if the queue is full.
fn bool kbd_queue_push(char c)
{
    uint next = (kbd_queue_head + 1) % KBD_QUEUE_SIZE;
    if (next == kbd_queue_tail) { return false; }
    kbd_queue[kbd_queue_head] = c;
    kbd_queue_head = next;
    return true;
}

// Returns -1 if the queue is empty, otherwise the next byte (0..255).
fn int kbd_queue_pop()
{
    if (kbd_queue_head == kbd_queue_tail) { return -1; }
    char c = kbd_queue[kbd_queue_tail];
    kbd_queue_tail = (kbd_queue_tail + 1) % KBD_QUEUE_SIZE;
    return (int)((uint)c & 0xFF);
}
