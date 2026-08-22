module user;

// netd: the virtio-net driver — QEMU only (board::HAS_VIRTIO_NET;
// the real Duo has an actual Ethernet MAC instead, see user/ethd.c3),
// mirroring diskd.c3's own structure closely (same virtio-mmio legacy
// register layout, same virtqueue struct shapes) since both are
// virtio-mmio devices on the same QEMU virt board.
//
// Phase 1 scope, deliberately narrow (mirrors user/usbd.c3's and
// user/ethd.c3's own Phase 1 scope): bring the device up, negotiate
// VIRTIO_NET_F_STATUS, configure the RX/TX virtqueues virtio-net's own
// spec requires before DRIVER_OK (even though nothing is pushed
// through them yet), and poll the device-specific config space's
// link-status field. NOT in scope yet: actual packet TX/RX.
//
// Legacy virtio-mmio (version 1) register offsets — same layout
// diskd.c3 already uses, confirmed working there.

import std::nolibc::mem;

const uint VIRTQ_ENTRY_NUM   = 16;
const uint PAGE_SIZE         = 4096;

// QEMU virt's own confirmed timebase frequency (netd is QEMU-only —
// see board::TIMEBASE_HZ's own comment, boards/qemu/board.c3, for how
// this was originally extracted via `-machine virt,dumpdtb=...`).
const uint NETD_TIMEBASE_HZ = 10000000;

fn ulong netd_us_to_ticks(ulong us)
{
    return us * NETD_TIMEBASE_HZ / 1000000;
}

const uint VIRTIO_REG_MAGIC          = 0x00;
const uint VIRTIO_REG_VERSION        = 0x04;
const uint VIRTIO_REG_DEVICE_ID      = 0x08;
const uint VIRTIO_REG_HOST_FEATURES  = 0x10;
const uint VIRTIO_REG_GUEST_FEATURES = 0x20;
const uint VIRTIO_REG_PAGE_SIZE      = 0x28;
const uint VIRTIO_REG_QUEUE_SEL      = 0x30;
const uint VIRTIO_REG_QUEUE_NUM      = 0x38;
const uint VIRTIO_REG_QUEUE_PFN      = 0x40;
const uint VIRTIO_REG_DEVICE_STATUS  = 0x70;
const uint VIRTIO_REG_DEVICE_CONFIG  = 0x100;

const uint VIRTIO_STATUS_ACK       = 1;
const uint VIRTIO_STATUS_DRIVER    = 2;
const uint VIRTIO_STATUS_DRIVER_OK = 4;

const uint VIRTIO_NET_DEVICE_ID = 1; // per virtio spec — 1 = network card (2 = block device, matching diskd's own check)

// VIRTIO_NET_F_STATUS (bit 16) — the device-specific config space's
// own `status` field (link-up bit) is only valid once this feature is
// negotiated; see usb_control_transfer's own "don't trust a field the
// spec says is conditional" lesson from this same session, applied
// here in advance instead of found the hard way.
const uint VIRTIO_NET_F_STATUS = 1 << 16;
const uint VIRTIO_NET_S_LINK_UP = 1 << 0;

struct Virtq_desc @packed
{
    ulong  addr;
    uint   len;
    ushort flags;
    ushort next;
}

struct Virtq_avail @packed
{
    ushort flags;
    ushort index;
    ushort[VIRTQ_ENTRY_NUM] ring;
}

struct Virtq_used_elem @packed
{
    uint id;
    uint len;
}

struct Virtq_used @packed
{
    ushort flags;
    ushort index;
    Virtq_used_elem[VIRTQ_ENTRY_NUM] ring;
}

struct Virtio_virtq @packed
{
    Virtq_desc[VIRTQ_ENTRY_NUM] descs;
    Virtq_avail avail;
    Virtq_used used @align(PAGE_SIZE);
    int queue_index;
    ushort* used_index;
    ushort last_used_index;
}

// Same raw-asm MMIO access pattern as diskd.c3/usbd.c3 — see either's
// own comment for why a plain pointer load/store isn't trustworthy for
// device registers.
fn uint mmio_read32(uptr addr)
{
    ulong v;
    asm
    {
        lw v, [addr];
    }
    return (uint)v;
}

fn void mmio_write32(uptr addr, uint v)
{
    ulong vv = (ulong)v;
    asm
    {
        sw vv, [addr];
    }
}

fn ushort mmio_read16(uptr addr)
{
    ulong v;
    asm
    {
        lhu v, [addr];
    }
    return (ushort)v;
}

const uint VIRTIO_NET_PADDR = 0x10002000; // board::VIRTIO_NET_PADDR duplicated locally — board is kernel-only, unreachable from user-mode code, same convention every other driver here already follows

fn uint reg_read32(uint offset) { return mmio_read32((uptr)(VIRTIO_NET_PADDR + offset)); }
fn void reg_write32(uint offset, uint v) { mmio_write32((uptr)(VIRTIO_NET_PADDR + offset), v); }
fn void reg_fetch_or32(uint offset, uint v) { reg_write32(offset, reg_read32(offset) | v); }
fn ushort reg_read16(uint offset) { return mmio_read16((uptr)(VIRTIO_NET_PADDR + offset)); }

const char[16] HEX_DIGITS = "0123456789abcdef";

fn void print_hex8(uint v)
{
    putchar(HEX_DIGITS[(v >> 4) & 0xF]);
    putchar(HEX_DIGITS[v & 0xF]);
}

fn void netd_panic(char* msg)
{
    print("netd: ");
    print(msg);
    print("\n");
    // Same UB/optimizer hazard as diskd_panic's own comment — exit(),
    // not an empty for(;;){} loop.
    exit();
}

fn void netd_setup_queue(Virtio_virtq* vq, uptr vq_paddr, int queue_index)
{
    reg_write32(VIRTIO_REG_QUEUE_SEL, (uint)queue_index);
    reg_write32(VIRTIO_REG_QUEUE_NUM, VIRTQ_ENTRY_NUM);
    reg_write32(VIRTIO_REG_QUEUE_PFN, (uint)(vq_paddr / PAGE_SIZE));
    vq.queue_index = queue_index;
    vq.used_index  = &vq.used.index;
}

fn void main() @export("main")
{
    uptr rxq_paddr;
    uptr txq_paddr;
    netd_info(&rxq_paddr, &txq_paddr);
    Virtio_virtq* rxq = (Virtio_virtq*)rxq_paddr;
    Virtio_virtq* txq = (Virtio_virtq*)txq_paddr;

    if (reg_read32(VIRTIO_REG_MAGIC) != 0x74726976)
    {
        netd_panic("invalid magic value");
    }
    if (reg_read32(VIRTIO_REG_VERSION) != 1)
    {
        netd_panic("invalid version");
    }
    if (reg_read32(VIRTIO_REG_DEVICE_ID) != VIRTIO_NET_DEVICE_ID)
    {
        netd_panic("invalid device id");
    }

    reg_write32(VIRTIO_REG_DEVICE_STATUS, 0);
    reg_fetch_or32(VIRTIO_REG_DEVICE_STATUS, VIRTIO_STATUS_ACK);
    reg_fetch_or32(VIRTIO_REG_DEVICE_STATUS, VIRTIO_STATUS_DRIVER);

    // Negotiate VIRTIO_NET_F_STATUS only — the one feature Phase 1
    // needs (link-status polling). Real feature negotiation, unlike
    // diskd's own simplified skip-it-entirely approach: the device
    // config space's `status` field is only meaningful once this bit
    // is actually accepted, not just offered.
    uint host_features = reg_read32(VIRTIO_REG_HOST_FEATURES);
    uint have_status_feature = host_features & VIRTIO_NET_F_STATUS;
    reg_write32(VIRTIO_REG_GUEST_FEATURES, have_status_feature);
    print("netd: VIRTIO_NET_F_STATUS ");
    print(have_status_feature ? "offered, negotiated\n" : "NOT offered by this device\n");

    reg_write32(VIRTIO_REG_PAGE_SIZE, PAGE_SIZE);
    netd_setup_queue(rxq, rxq_paddr, 0);
    netd_setup_queue(txq, txq_paddr, 1);

    reg_write32(VIRTIO_REG_DEVICE_STATUS, VIRTIO_STATUS_DRIVER_OK);

    // MAC address — device config space bytes 0-5, always valid
    // regardless of feature negotiation.
    print("netd: mac=");
    for (int i = 0; i < 6; i++)
    {
        uint b = mmio_read32((uptr)(VIRTIO_NET_PADDR + VIRTIO_REG_DEVICE_CONFIG + (uint)i)) & 0xFF;
        print_hex8(b);
        if (i < 5) { putchar(':'); }
    }
    print("\n");

    print("netd: init done, polling link status\n");

    bool last_up = false;
    bool first = true;
    for (;;)
    {
        bool up = true; // devices that never offered the feature are treated as always-up — nothing to poll, matches virtio-net's own "no VIRTIO_NET_F_STATUS = assume link up" spec language
        if (have_status_feature)
        {
            ushort status = reg_read16(VIRTIO_REG_DEVICE_CONFIG + 6);
            up = (status & VIRTIO_NET_S_LINK_UP) != 0;
        }
        if (up != last_up || first)
        {
            print(up ? "netd: link up\n" : "netd: link down\n");
            last_up = up;
            first = false;
        }

        // yield()-paced, not a bare spin — see user/usbd.c3's own
        // SYS_YIELD comment for why a genuinely syscall-free poll here
        // is a real deadlock risk on this kernel, not just wasted CPU.
        ulong poll_start = rdtime();
        while (rdtime() - poll_start < netd_us_to_ticks(250000)) { yield(); }
    }
}
