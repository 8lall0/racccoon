module user;

// netd: the virtio-net driver — QEMU only (the board's "virtio-net" device;
// the real Duo has an actual Ethernet MAC instead, see user/net/ethd.c3).
// Same virtio-mmio legacy register layout and virtqueue shapes as
// diskd.c3.
//
// A pure link driver: it moves Ethernet frames between the device and the
// "ether0" link rings (user/net/link.c3) and knows nothing about IP —
// ARP, ICMP, DHCP and everything above live in ipd (user/net/ipd.c3).
// NETD_RING_N receive buffers stay posted to the RX queue (each re-posted
// as soon as its frame is copied out); up to NETD_RING_N transmits can be
// in flight. Interrupt-driven: the virtio-net used-ring interrupt (RX or
// TX completion) and ipd's doorbell both wake one await_any.

import std::nolibc::main_stub;
import std::nolibc::mem;

// QEMU virt's own confirmed timebase frequency (netd is QEMU-only —
// see board::TIMEBASE_HZ's own comment, boards/qemu/board.c3, for how
// this was originally extracted via `-machine virt,dumpdtb=...`).
const uint NETD_TIMEBASE_HZ = 10000000;

fn ulong netd_us_to_ticks(ulong us)
{
    return us * NETD_TIMEBASE_HZ / 1000000;
}

const uint VIRTIO_NET_DEVICE_ID = 1; // per virtio spec — 1 = network card (2 = block device, matching diskd's own check)

// VIRTIO_NET_F_STATUS (bit 16) — the device-specific config space's
// own `status` field (link-up bit) is only valid once this feature is
// negotiated; see usb_control_transfer's own "don't trust a field the
// spec says is conditional" lesson from this same session, applied
// here in advance instead of found the hard way.
const uint VIRTIO_NET_F_STATUS = 1 << 16;
const uint VIRTIO_NET_S_LINK_UP = 1 << 0;

const uint VIRTIO_NET_PADDR = 0x10002000; // board::VIRTIO_NET_PADDR duplicated locally — board is kernel-only, unreachable from user-mode code, same convention every other driver here already follows

// Thin wrappers around user/virtio.c3's own base-address-parameterized
// helpers, bound to this device's own VIRTIO_NET_PADDR — every other
// call site in this file keeps calling plain reg_read32(offset) etc.,
// unchanged.
fn uint reg_read32(uint offset) { return virtio_reg_read32(VIRTIO_NET_PADDR, offset); }
fn void reg_write32(uint offset, uint v) { virtio_reg_write32(VIRTIO_NET_PADDR, offset, v); }
fn void reg_fetch_or32(uint offset, uint v) { virtio_reg_fetch_or32(VIRTIO_NET_PADDR, offset, v); }
fn ushort reg_read16(uint offset) { return virtio_reg_read16(VIRTIO_NET_PADDR, offset); }

// print_hex8 / panic: user/user.c3 (shared).

fn void netd_setup_queue(Virtio_virtq* vq, uptr vq_paddr, int queue_index)
{
    reg_write32(VIRTIO_REG_QUEUE_SEL, (uint)queue_index);
    reg_write32(VIRTIO_REG_QUEUE_NUM, VIRTQ_ENTRY_NUM);
    reg_write32(VIRTIO_REG_QUEUE_PFN, (uint)(vq_paddr / PAGE_SIZE));
    vq.queue_index = queue_index;
    vq.used_index  = &vq.used.index;
}

// --- Packet buffers. Legacy virtio-net header — 10 bytes, all zero (no
// offload features negotiated), prepended before the Ethernet frame in
// both TX and RX buffers.
const uint NETD_HDR_LEN  = 10;
const uint NETD_SLOT     = 2048;          // one buffer per 2 KiB, 2 per page
const uint NETD_RING_N   = 16;            // <= VIRTQ_ENTRY_NUM; 8 DMA pages each way
const uint NETD_BUF_SIZE = NETD_HDR_LEN + 1600;

Virtio_virtq* netd_rxq;
Virtio_virtq* netd_txq;
uptr netd_rx_bufs;   // NETD_RING_N x NETD_SLOT, identity-mapped (paddr == vaddr)
uptr netd_tx_bufs;
uint netd_tx_inflight;

// Post RX buffer `i` (descriptor i) to the device.
fn void netd_post_rx(uint i)
{
    netd_rxq.descs[i].addr  = (ulong)(netd_rx_bufs + (uptr)i * NETD_SLOT);
    netd_rxq.descs[i].len   = NETD_BUF_SIZE;
    netd_rxq.descs[i].flags = VIRTQ_DESC_F_WRITE;
    netd_rxq.descs[i].next  = 0;
    netd_rxq.avail.ring[netd_rxq.avail.index % VIRTQ_ENTRY_NUM] = (ushort)i;
    asm("fence");
    netd_rxq.avail.index++;
}

// Move every received frame into the link's RX ring. Returns how many.
fn uint netd_drain_rx(Link* l)
{
    uint n = 0;
    while (*netd_rxq.used_index != netd_rxq.last_used_index)
    {
        Virtq_used_elem* e = &netd_rxq.used.ring[netd_rxq.last_used_index % VIRTQ_ENTRY_NUM];
        uint id = e.id;
        uint used_len = e.len;
        netd_rxq.last_used_index++;
        if (id < NETD_RING_N)
        {
            if (used_len > NETD_HDR_LEN)
            {
                char* buf = (char*)(netd_rx_bufs + (uptr)id * NETD_SLOT);
                link_put(l, buf + NETD_HDR_LEN, used_len - NETD_HDR_LEN);
                n++;
            }
            netd_post_rx(id);
        }
    }
    if (n > 0) { reg_write32(VIRTIO_REG_QUEUE_NOTIFY, (uint)netd_rxq.queue_index); }
    return n;
}

// Reclaim completed transmits, then hand the device whatever ipd queued.
fn void netd_pump_tx(Link* l)
{
    while (*netd_txq.used_index != netd_txq.last_used_index)
    {
        netd_txq.last_used_index++;
        netd_tx_inflight--;
    }
    bool posted = false;
    while (netd_tx_inflight < NETD_RING_N && link_pending(l))
    {
        // Slot by position in the avail ring: completions are in order for
        // virtio-net TX, so the oldest in-flight buffer is the next reused.
        uint slot = netd_txq.avail.index % NETD_RING_N;
        char* buf = (char*)(netd_tx_bufs + (uptr)slot * NETD_SLOT);
        int len = link_get(l, buf + NETD_HDR_LEN);
        if (len <= 0) { continue; }
        mem::set(buf, 0, (sz)NETD_HDR_LEN);
        netd_txq.descs[slot].addr  = (ulong)(uptr)buf;
        netd_txq.descs[slot].len   = NETD_HDR_LEN + (uint)len;
        netd_txq.descs[slot].flags = 0;
        netd_txq.descs[slot].next  = 0;
        netd_txq.avail.ring[netd_txq.avail.index % VIRTQ_ENTRY_NUM] = (ushort)slot;
        asm("fence");
        netd_txq.avail.index++;
        netd_tx_inflight++;
        posted = true;
    }
    if (posted) { reg_write32(VIRTIO_REG_QUEUE_NOTIFY, (uint)netd_txq.queue_index); }
}

fn void main()
{
    uptr[4] dma;
    if (dev_info(&dma[0], 4) < 4) { panic("netd: ", "missing DMA regions"); }
    netd_rxq = (Virtio_virtq*)dma[0];
    netd_txq = (Virtio_virtq*)dma[1];
    netd_rx_bufs = dma[2];
    netd_tx_bufs = dma[3];

    if (reg_read32(VIRTIO_REG_MAGIC) != 0x74726976) { panic("netd: ", "invalid magic value"); }
    if (reg_read32(VIRTIO_REG_VERSION) != 1) { panic("netd: ", "invalid version"); }
    if (reg_read32(VIRTIO_REG_DEVICE_ID) != VIRTIO_NET_DEVICE_ID) { panic("netd: ", "invalid device id"); }

    reg_write32(VIRTIO_REG_DEVICE_STATUS, 0);
    reg_fetch_or32(VIRTIO_REG_DEVICE_STATUS, VIRTIO_STATUS_ACK);
    reg_fetch_or32(VIRTIO_REG_DEVICE_STATUS, VIRTIO_STATUS_DRIVER);

    // VIRTIO_NET_F_STATUS only: the config space's link-status field is
    // valid only once it's accepted. No offloads, no merged RX buffers.
    uint host_features = reg_read32(VIRTIO_REG_HOST_FEATURES);
    uint have_status_feature = host_features & VIRTIO_NET_F_STATUS;
    reg_write32(VIRTIO_REG_GUEST_FEATURES, have_status_feature);

    reg_write32(VIRTIO_REG_PAGE_SIZE, PAGE_SIZE);
    netd_setup_queue(netd_rxq, dma[0], 0);
    netd_setup_queue(netd_txq, dma[1], 1);
    reg_write32(VIRTIO_REG_DEVICE_STATUS, VIRTIO_STATUS_DRIVER_OK);

    char[6] mac;
    print("netd: mac=");
    for (int i = 0; i < 6; i++)
    {
        uint b = mmio_read32((uptr)(VIRTIO_NET_PADDR + VIRTIO_REG_DEVICE_CONFIG + (uint)i)) & 0xFF;
        mac[i] = (char)b;
        print_hex8(b);
        if (i < 5) { putchar(':'); }
    }
    print("\n");

    Link link;
    if (!link_create(&link, "ether0", &mac[0], 1500)) { panic("netd: ", "can't create link ether0"); }

    for (uint i = 0; i < NETD_RING_N; i++) { netd_post_rx(i); }
    reg_write32(VIRTIO_REG_QUEUE_NOTIFY, (uint)netd_rxq.queue_index);

    srv_post("netd");   // netdkilltest's handle on us
    print("netd: link ether0 up\n");

    ulong hz = timebase_hz();
    for (;;)
    {
        uint up = 1;   // no VIRTIO_NET_F_STATUS = always up, per the spec
        if (have_status_feature)
        {
            up = (reg_read16(VIRTIO_REG_DEVICE_CONFIG + 6) & VIRTIO_NET_S_LINK_UP) != 0 ? 1 : 0;
        }
        link.h.link_up = up;

        // Ack the device first, then do the work: a completion that lands
        // after the ack re-raises the (edge) interrupt.
        uint isr = reg_read32(VIRTIO_REG_INTERRUPT_STATUS);
        if (isr != 0) { reg_write32(VIRTIO_REG_INTERRUPT_ACK, isr); }

        if (netd_drain_rx(&link) > 0) { link_kick(&link); }
        netd_pump_tx(&link);
        // The PLIC masked our (level) source when it fired; the ISR is
        // acked now, so let the next completion through.
        syscall(SYS_DRIVER_IRQ_ARM, 0, 0, 0);

        // Asleep until the device interrupts (RX or TX done), ipd rings
        // (TX queued), or a second passes (link-status refresh).
        await_any(AW_IRQ | AW_WAKE, hz, null, 0);
    }
}
