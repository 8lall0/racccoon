module board;

import kernel;
import sbi;

// QEMU `-machine sifive_u` implementation of the `board` contract — a
// pre-hardware *verification harness* for the Orange Pi RV port, NOT a
// shipping target.
//
// WHY THIS EXISTS
// ---------------
// The real Orange Pi RV (StarFive JH7110) bring-up is Stage-1 blocked on
// a flaky vendor U-Boot SD probe (docs/opi-rv-plan.md), so racccoon's own
// boot output has never been seen on that board. QEMU's `sifive_u`
// machine is the closest emulated proxy: a SiFive core complex with a
// monitor hart 0 that has *no S-mode* and application harts 1..N, exactly
// the JH7110's S7-monitor + U74-application split. That makes it the only
// target that actually exercises the two things `virt` cannot:
//
//   1. Boot hart != 0. OpenSBI must hand the S-mode payload to hart 1
//      (hart 0 is the E51 monitor, S-mode-less), just as it does on the
//      JH7110. If racccoon's boot path has any latent assumption that it
//      runs on hart 0, it surfaces here.
//   2. PLIC S-mode context = 2. sifive_u's PLIC `interrupts-extended`
//      enumerates context 0 = hart0 M, context 1 = hart1 M, context 2 =
//      hart1 S — the same `2 * hartid` layout the JH7110 devicetree has,
//      and the same PLIC_S_CONTEXT = 2 that boards/opi-rv/board.c3 sets
//      and flags as "THE #1 THING TO CHECK ON FIRST HARDWARE BOOT".
//
// So a green boot here retires open questions 1 (boot hart / context), 2
// (`rdtime` in S-mode) and 3 (SBI console) from docs/opi-rv-plan.md
// before the board is even unblocked, and lets Stage 2 (timer + traps
// under load, faulttest, supervisor respawn) be shaken out in emulation.
//
// WHAT IT DOES *NOT* validate: every actual JH7110 peripheral (DW-MSHC
// SD, Cadence USB, StarFive DWMAC) — sifive_u has none of them, and this
// board declares no devices (an empty DEVICES table), same as the
// opi-rv Stage-1 scaffold. It also runs at DRAM base 0x80000000 (see kernel.ld), not the
// JH7110's 0x40000000 — irrelevant to the boot/trap/PLIC machinery under
// test, but it means kernel_opi_qemu.elf is not loadable on real hardware.
//
// KEEP IN SYNC: this file is a deliberate near-duplicate of
// boards/opi-rv/board.c3. Every value below that is NOT called out with
// a "sifive_u:" comment is copied verbatim from there and must stay that
// way — if you change a PLIC formula, a PTE bit, or a size ceiling in the
// opi-rv board, mirror it here or the harness stops being a faithful
// proxy. The intentional differences are exactly two: TIMEBASE_HZ (the
// sifive_u devicetree says 1 MHz, the JH7110 says 4 MHz) and the kernel
// link address (kernel.ld).

// sifive_u PLIC: "sifive,plic-1.0.0", reg = <0x0c000000 0x04000000>,
// riscv,ndev = 53. Stock SiFive layout at the same base QEMU virt and the
// JH7110 both use — identical register math to boards/opi-rv/board.c3.
const uptr PLIC_BASE = 0x0c000000;

// SiFive U54 (sifive_u's application hart) is a plain RV64GC core — no
// T-Head MAEE PTE-attribute quirk, same as the JH7110's U74 and QEMU's
// generic core. Device MMIO works with ordinary PTEs.
const ulong PTE_EXTRA_BITS  = 0;
const ulong PTE_DEVICE_BITS = 0;

// No virtio-mmio block device on sifive_u (nor on real JH7110). 0 = "not
// applicable" — cannot spuriously match plic_claim()'s "nothing pending".
const uint IRQ_VIRTIO_BLK = 0;

// PLIC context = (hart, privilege) pair the interrupt targets. sifive_u's
// PLIC `interrupts-extended` (confirmed via `-machine sifive_u,dumpdtb`
// + dtc) enumerates:
//   context 0 : hart 0 (E51 monitor) M-mode
//   context 1 : hart 1 (U54)         M-mode
//   context 2 : hart 1 (U54)         S-mode   <-- racccoon runs here
// i.e. the same `2 * hartid` rule as the JH7110. OpenSBI hands the S-mode
// payload to hart 1 (hart 0 has no S-mode), giving S-context 2 — the
// exact value boards/opi-rv/board.c3 assumes for the real board. If
// interrupts never fire here, that assumption is wrong and this is where
// it shows up.
const uptr PLIC_S_CONTEXT = 2;

const uptr PLIC_PRIORITY_BASE = PLIC_BASE;                                     // + 4*irq
const uptr PLIC_ENABLE_BASE   = PLIC_BASE + 0x2000 + PLIC_S_CONTEXT * 0x80;     // + (irq/32)*4, bit irq%32
const uptr PLIC_THRESHOLD     = PLIC_BASE + 0x200000 + PLIC_S_CONTEXT * 0x1000;
const uptr PLIC_CLAIM         = PLIC_BASE + 0x200004 + PLIC_S_CONTEXT * 0x1000;

const uptr PLIC_PRIORITY_PAGE = PLIC_PRIORITY_BASE & (uptr)~(kernel::PAGE_SIZE - 1);
const uptr PLIC_ENABLE_PAGE   = PLIC_ENABLE_BASE & (uptr)~(kernel::PAGE_SIZE - 1);
const uptr PLIC_CLAIM_PAGE    = PLIC_CLAIM & (uptr)~(kernel::PAGE_SIZE - 1);

// PLIC_BASE IS the physical address (0x0c000000, well below DRAM's
// 0x80000000 base here, so no QEMU-`virt`-style aliasing is needed).
// Identity-mapped, same stance as boards/opi-rv/board.c3.
const uptr PLIC_PHYS_BASE = PLIC_BASE;
const uptr PLIC_PRIORITY_PHYS_PAGE = PLIC_PRIORITY_PAGE;
const uptr PLIC_ENABLE_PHYS_PAGE   = PLIC_ENABLE_PAGE;
const uptr PLIC_CLAIM_PHYS_PAGE    = PLIC_CLAIM_PAGE;

// Kept at 1 for the Stage-1 boot-to-shell harness: racccoon runs on
// whichever single U54 OpenSBI hands it. Launch with `-smp 2` (the
// default) — that already gives the "boot hart is 1, not 0" split that is
// the whole point. `-smp 5` (a full 1 monitor + 4 U54) also boots; the
// secondaries just announce and park (no SMP scheduler — non-goal).
const uint SMP_MAX_HARTS = 1;

// --- Devices ---------------------------------------------------------
// sifive_u has no virtio-mmio and racccoon has no SPI-SD driver, so this
// harness declares no boot-driver hardware (DEVICES is empty) and boots with
// no filesystem — exactly the opi-rv Stage-1 state. diskd / sdd / fsd /
// usbd / ethd / netd / gpiod never spawn; the shell's file commands fail
// cleanly.
const Device[] DEVICES = {};

const uint FS_PARTITION_START_SECTOR = 0;
const bool HAS_SECOND_FS_PARTITION  = false;
const uint FS_PARTITION_2_START_SECTOR = 0;

// sifive_u: rdtime()'s tick rate. The sifive_u devicetree says
// `timebase-frequency = <1000000>` (1 MHz) — DIFFERENT from the JH7110's
// 4 MHz (boards/opi-rv/board.c3). Only affects how arm_timer() scales a
// tick period and the SYS_TIMEBASE syscall's seconds conversion; not a
// correctness variable for the trap/scheduler machinery under test. The
// forced-preemption tick just lands every real second here (arm_timer is
// passed TIMEBASE_HZ = "one second of ticks").
const ulong TIMEBASE_HZ = 1000000;

// Only the block-device IRQ would ever be armed here, and this harness
// has no block device — QEMU-shaped minimum: threshold 0, nothing else.
fn void plic_init()
{
	uint* threshold = (uint*)PLIC_THRESHOLD;
	mem::store(threshold, 0u, 4, true);
}

fn void plic_set_enabled(uint irq, bool on)
{
	uint* word = (uint*)(PLIC_ENABLE_BASE + (uptr)((irq / 32) * 4));
	uint cur = mem::load(word, 4, true);
	uint bit = 1u << (irq % 32);
	mem::store(word, on ? (cur | bit) : (cur & ~bit), 4, true);
}

fn uint plic_claim()
{
	uint* claim = (uint*)PLIC_CLAIM;
	return mem::load(claim, 4, true);
}

fn void plic_complete(uint irq)
{
	uint* complete = (uint*)PLIC_CLAIM;
	mem::store(complete, irq, 4, true);
}

// QEMU's OpenSBI for sifive_u wires the SBI console (DBCN + legacy
// putchar/getchar) to the SiFive UART at 0x10010000. Same ecall path as
// QEMU virt and the Duo — open question 3 (is the SBI console actually
// wired?) is answered the moment "1: BSS cleared" appears.
fn int console_putchar(int ch)
{
	return sbi::__putchar(ch);
}

fn int console_getchar()
{
	return sbi::__getchar();
}

// Copied verbatim from boards/opi-rv/board.c3 — the flat 64 MiB free_ram
// window in kernel.ld is the same scale on both.
const EXEC_MAX_IMAGE_SIZE = 1048576;
const uptr HEAP_MAX_BYTES = 16 * 1024 * 1024;
