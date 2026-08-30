module user;

// netd: the virtio-net driver — QEMU only (board::HAS_VIRTIO_NET;
// the real Duo has an actual Ethernet MAC instead, see
// user/net/ethd.c3), mirroring diskd.c3's own structure closely (same
// virtio-mmio legacy register layout, same virtqueue struct shapes)
// since both are virtio-mmio devices on the same QEMU virt board.
//
// Phase 2 (real packet TX/RX + ARP/ICMP — see docs/devlog.md): the
// RX/TX virtqueues Phase 1 already configured now actually carry
// frames. A single RX buffer stays permanently posted to the RX
// queue, re-armed after every frame consumed; a single TX buffer is
// reused for whatever this process needs to send next — same one-
// outstanding-transfer discipline this codebase uses everywhere else
// (USB's single host channel, diskd/sdd's one request at a time,
// ethd's own single-descriptor DMA ring). No interrupt reliance: a
// virtio device processes descriptors and updates its used ring
// regardless of whether the driver ever handles the completion IRQ,
// so completion is detected by directly polling `used.index`, the
// same busy-polled style every other device driver in this codebase
// already uses.
//
// Legacy virtio-mmio (version 1) register offsets — same layout
// diskd.c3 already uses, confirmed working there.

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

// --- Phase 2: real packet TX/RX over the queues Phase 1 configured.
// Legacy virtio-net header — 10 bytes, all zero (no offload features
// negotiated: flags/gso_type/hdr_len/gso_size/csum_start/csum_offset),
// prepended before the actual Ethernet frame in both TX and RX
// buffers.
const uint NETD_HDR_LEN  = 10;
const uint NETD_BUF_SIZE = NETD_HDR_LEN + 1600; // matches ethd's own ETH_DMA_BUF_SIZE (1600, MAC_MAX_FRAME_SZ) plus this header

Virtio_virtq* netd_rxq;
Virtio_virtq* netd_txq;
char* netd_rx_buf;
char* netd_tx_buf;
uptr netd_tx_buf_paddr;

// Posts (or re-posts) the single RX buffer to the RX queue — must be
// called once at startup before anything can be received, and again
// after every frame consumed (netd_try_recv does this itself).
fn void netd_arm_rx()
{
    netd_rxq.descs[0].addr  = (ulong)((uptr)netd_rx_buf);
    netd_rxq.descs[0].len   = NETD_BUF_SIZE;
    netd_rxq.descs[0].flags = VIRTQ_DESC_F_WRITE;
    netd_rxq.descs[0].next  = 0;
    netd_rxq.avail.ring[netd_rxq.avail.index % VIRTQ_ENTRY_NUM] = 0;
    netd_rxq.avail.index++;
    asm("fence");
    reg_write32(VIRTIO_REG_QUEUE_NOTIFY, (uint)netd_rxq.queue_index);
}

// Non-blocking poll for a received frame — copies the Ethernet frame
// (header already stripped) into frame_out (must have room for
// NETD_BUF_SIZE - NETD_HDR_LEN bytes) and sets *frame_len_out, then
// re-arms the RX buffer for the next frame. Returns false if nothing
// new has arrived.
fn bool netd_try_recv(char* frame_out, uint* frame_len_out)
{
    if (*netd_rxq.used_index == netd_rxq.last_used_index) { return false; }

    uint used_len = netd_rxq.used.ring[netd_rxq.last_used_index % VIRTQ_ENTRY_NUM].len;
    netd_rxq.last_used_index++;

    if (used_len < NETD_HDR_LEN)
    {
        netd_arm_rx(); // malformed/too-short — drop and keep listening
        return false;
    }

    uint frame_len = used_len - NETD_HDR_LEN;
    mem::copy(frame_out, &netd_rx_buf[NETD_HDR_LEN], (sz)frame_len);
    *frame_len_out = frame_len;
    netd_arm_rx();
    return true;
}

// Sends one Ethernet frame, prepending the (zeroed) virtio-net header.
// Blocks (bounded, 1s) for the device to consume it — this driver
// only ever has one frame in flight, matching this codebase's own
// one-outstanding-transfer discipline throughout. Returns false on
// timeout.
fn bool netd_send(char* frame, uint frame_len)
{
    mem::set(netd_tx_buf, 0, (sz)NETD_HDR_LEN);
    mem::copy(&netd_tx_buf[NETD_HDR_LEN], frame, (sz)frame_len);

    netd_txq.descs[0].addr  = (ulong)netd_tx_buf_paddr;
    netd_txq.descs[0].len   = NETD_HDR_LEN + frame_len;
    netd_txq.descs[0].flags = 0;
    netd_txq.descs[0].next  = 0;
    netd_txq.avail.ring[netd_txq.avail.index % VIRTQ_ENTRY_NUM] = 0;
    netd_txq.avail.index++;
    asm("fence");
    reg_write32(VIRTIO_REG_QUEUE_NOTIFY, (uint)netd_txq.queue_index);

    ulong start = rdtime();
    ulong budget = netd_us_to_ticks(1000000);
    while (*netd_txq.used_index == netd_txq.last_used_index)
    {
        if (rdtime() - start > budget) { return false; }
        yield();
    }
    netd_txq.last_used_index++;
    return true;
}

// QEMU's own SLIRP virtual subnet default for `-netdev user` with no
// extra flags: guest 10.0.2.15/24, SLIRP's own virtual gateway at
// 10.0.2.2 — a real, always-ICMP-responsive endpoint SLIRP itself
// emulates, used below purely as a self-test peer (plain `-netdev
// user` can't easily deliver an *inbound* ping from the host to test
// the passive-responder path directly).

// Minimal DHCP client (RFC 2131): DISCOVER -> OFFER -> REQUEST -> ACK,
// once at startup, no lease renewal — see user/net/dhcp.c3's own
// header comment for full scope/rationale. Up to 3 DISCOVER attempts,
// each with a bounded (2s) wait for a matching OFFER; on a real OFFER,
// one REQUEST + a bounded (2s) wait for ACK/NAK. Returns false (caller
// falls back to its own static IP) on any timeout/NAK across all
// attempts.
fn bool netd_run_dhcp_client(char* our_mac, uint* our_ip_out, uint* gateway_ip_out)
{
    char[600] scratch @noinit;
    char[1600] rx_frame @noinit;

    for (int attempt = 0; attempt < 3; attempt++)
    {
        uint xid = (uint)rdtime() ^ (uint)attempt;

        uint discover_len;
        dhcp_build_discover(&scratch[0], &discover_len, our_mac, xid);
        if (!netd_send(&scratch[0], discover_len)) { continue; }

        uint offered_ip = 0;
        uint offer_server_ip = 0;
        bool got_offer = false;
        ulong offer_start = rdtime();
        ulong offer_budget = netd_us_to_ticks(2000000);
        while (rdtime() - offer_start < offer_budget)
        {
            uint rx_len;
            if (netd_try_recv(&rx_frame[0], &rx_len))
            {
                uint msg_type, yiaddr, server_id, router;
                if (dhcp_parse_message(&rx_frame[0], rx_len, xid, &msg_type, &yiaddr, &server_id, &router) && msg_type == DHCP_MSG_OFFER)
                {
                    offered_ip = yiaddr;
                    offer_server_ip = server_id;
                    got_offer = true;
                    break;
                }
            }
            yield();
        }
        if (!got_offer) { continue; }

        uint request_len;
        dhcp_build_request(&scratch[0], &request_len, our_mac, xid, offered_ip, offer_server_ip);
        if (!netd_send(&scratch[0], request_len)) { continue; }

        ulong ack_start = rdtime();
        ulong ack_budget = netd_us_to_ticks(2000000);
        while (rdtime() - ack_start < ack_budget)
        {
            uint rx_len;
            if (netd_try_recv(&rx_frame[0], &rx_len))
            {
                uint msg_type, yiaddr, server_id, router;
                if (dhcp_parse_message(&rx_frame[0], rx_len, xid, &msg_type, &yiaddr, &server_id, &router))
                {
                    if (msg_type == DHCP_MSG_ACK)
                    {
                        *our_ip_out = yiaddr;
                        *gateway_ip_out = router;
                        return true;
                    }
                    if (msg_type == DHCP_MSG_NAK) { break; }
                }
            }
            yield();
        }
    }
    return false;
}

// One-shot startup self-test: ARP-resolve the gateway, then ping it,
// printing the round-trip result either way. Diagnostic only — never
// panics on failure, since the real point of Phase 2 is the passive
// responder in main()'s own loop, not this self-test.
fn void netd_self_test(char* our_mac, uint our_ip, uint gateway_ip)
{
    char[1600] scratch @noinit;
    char[1600] rx_frame @noinit;
    char[6] gateway_mac;

    uint arp_len;
    eth_build_arp_request(&scratch[0], &arp_len, our_mac, our_ip, gateway_ip);
    if (!netd_send(&scratch[0], arp_len))
    {
        print("netd: self-test: ARP request send failed\n");
        return;
    }

    bool got_mac = false;
    ulong arp_start = rdtime();
    ulong arp_budget = netd_us_to_ticks(2000000);
    while (rdtime() - arp_start < arp_budget)
    {
        uint rx_len;
        if (netd_try_recv(&rx_frame[0], &rx_len))
        {
            if (eth_parse_arp_reply(&rx_frame[0], rx_len, gateway_ip, &gateway_mac[0]))
            {
                got_mac = true;
                break;
            }
        }
        yield();
    }
    print("netd: self-test: ARP resolve of gateway ");
    print(got_mac ? "ok\n" : "TIMED OUT\n");
    if (!got_mac) { return; }

    uint icmp_len;
    ushort ping_id = 0x1234;
    ushort ping_seq = 1;
    eth_build_icmp_echo_request(&scratch[0], &icmp_len, our_mac, our_ip, &gateway_mac[0], gateway_ip, ping_id, ping_seq);
    if (!netd_send(&scratch[0], icmp_len))
    {
        print("netd: self-test: ping send failed\n");
        return;
    }

    bool got_reply = false;
    ulong ping_start = rdtime();
    ulong ping_budget = netd_us_to_ticks(2000000);
    while (rdtime() - ping_start < ping_budget)
    {
        uint rx_len;
        if (netd_try_recv(&rx_frame[0], &rx_len))
        {
            if (eth_parse_icmp_echo_reply(&rx_frame[0], rx_len, ping_id, ping_seq))
            {
                got_reply = true;
                break;
            }
        }
        yield();
    }
    print("netd: self-test: ping to gateway ");
    print(got_reply ? "ok\n" : "TIMED OUT\n");
}

fn void main()
{
    uptr rxq_paddr;
    uptr txq_paddr;
    uptr pktbuf_paddr;
    netd_info(&rxq_paddr, &txq_paddr, &pktbuf_paddr);
    netd_rxq = (Virtio_virtq*)rxq_paddr;
    netd_txq = (Virtio_virtq*)txq_paddr;
    netd_rx_buf = (char*)pktbuf_paddr;
    netd_tx_buf = (char*)(pktbuf_paddr + NETD_BUF_SIZE);
    netd_tx_buf_paddr = pktbuf_paddr + NETD_BUF_SIZE;

    if (reg_read32(VIRTIO_REG_MAGIC) != 0x74726976)
    {
        panic("netd: ", "invalid magic value");
    }
    if (reg_read32(VIRTIO_REG_VERSION) != 1)
    {
        panic("netd: ", "invalid version");
    }
    if (reg_read32(VIRTIO_REG_DEVICE_ID) != VIRTIO_NET_DEVICE_ID)
    {
        panic("netd: ", "invalid device id");
    }

    reg_write32(VIRTIO_REG_DEVICE_STATUS, 0);
    reg_fetch_or32(VIRTIO_REG_DEVICE_STATUS, VIRTIO_STATUS_ACK);
    reg_fetch_or32(VIRTIO_REG_DEVICE_STATUS, VIRTIO_STATUS_DRIVER);

    // Negotiate VIRTIO_NET_F_STATUS only — the one feature Phase 1
    // needed (link-status polling). Real feature negotiation, unlike
    // diskd's own simplified skip-it-entirely approach: the device
    // config space's `status` field is only meaningful once this bit
    // is actually accepted, not just offered. Phase 2's own packet
    // TX/RX needs no additional features (no checksum/GSO offload, no
    // merged RX buffers) — the plain 10-byte legacy header is correct
    // either way.
    uint host_features = reg_read32(VIRTIO_REG_HOST_FEATURES);
    uint have_status_feature = host_features & VIRTIO_NET_F_STATUS;
    reg_write32(VIRTIO_REG_GUEST_FEATURES, have_status_feature);
    print("netd: VIRTIO_NET_F_STATUS ");
    print(have_status_feature ? "offered, negotiated\n" : "NOT offered by this device\n");

    reg_write32(VIRTIO_REG_PAGE_SIZE, PAGE_SIZE);
    netd_setup_queue(netd_rxq, rxq_paddr, 0);
    netd_setup_queue(netd_txq, txq_paddr, 1);

    reg_write32(VIRTIO_REG_DEVICE_STATUS, VIRTIO_STATUS_DRIVER_OK);

    // MAC address — device config space bytes 0-5, always valid
    // regardless of feature negotiation.
    char[6] our_mac;
    print("netd: mac=");
    for (int i = 0; i < 6; i++)
    {
        uint b = mmio_read32((uptr)(VIRTIO_NET_PADDR + VIRTIO_REG_DEVICE_CONFIG + (uint)i)) & 0xFF;
        our_mac[i] = (char)b;
        print_hex8(b);
        if (i < 5) { putchar(':'); }
    }
    print("\n");

    netd_arm_rx();

    // Static fallback — used as-is if the DHCP client below fails/
    // times out (e.g. no DHCP server on this network at all): SLIRP's
    // own default virtual subnet for `-netdev user`, see this file's
    // own header comment.
    uint our_ip = make_ip(10, 0, 2, 15);
    uint gateway_ip = make_ip(10, 0, 2, 2);

    uint dhcp_ip;
    uint dhcp_gateway;
    if (netd_run_dhcp_client(&our_mac[0], &dhcp_ip, &dhcp_gateway))
    {
        our_ip = dhcp_ip;
        gateway_ip = dhcp_gateway;
        print("netd: DHCP: bound, ip=");
        print_ip(our_ip);
        print(" gateway=");
        print_ip(gateway_ip);
        print("\n");
    }
    else
    {
        print("netd: DHCP: failed, falling back to static IP\n");
    }

    netd_self_test(&our_mac[0], our_ip, gateway_ip);

    // Posts under "netd" so a client (today just netdkilltest, which
    // needs a handle to kill it) can reach it by name — same
    // Plan-9-style srv_post the other drivers use. netd has no
    // request/reply clients yet otherwise.
    srv_post("netd");

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

        // Passive responder — answers ARP/ICMP-echo requests addressed
        // to our_ip, same as ethd's own main loop.
        char[1600] rx_frame @noinit;
        uint rx_len;
        if (netd_try_recv(&rx_frame[0], &rx_len))
        {
            char[1600] reply @noinit;
            uint reply_len;
            if (eth_proto_respond(&rx_frame[0], rx_len, &our_mac[0], our_ip, &reply[0], &reply_len))
            {
                netd_send(&reply[0], reply_len);
            }
        }

        // yield()-paced, not a bare spin — see user/usb/dwc2.c3's own
        // SYS_YIELD comment for why a genuinely syscall-free poll here
        // is a real deadlock risk on this kernel, not just wasted CPU.
        ulong poll_start = rdtime();
        while (rdtime() - poll_start < netd_us_to_ticks(250000)) { yield(); }
    }
}
