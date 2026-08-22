module user;

// eth_proto: a minimal, hand-rolled ARP + ICMP echo layer, completely
// transport-agnostic — works on raw Ethernet frame bytes only, with no
// knowledge of virtio-net vs. real DMA underneath. Shared by
// user/net/netd.c3 (QEMU) and user/net/ethd.c3 (real Duo), same
// "generic core, transport stays in the caller" shape user/virtio.c3
// already established for the virtio-mmio transport layer.
//
// Scope, deliberately narrow (Ethernet Phase 2 — see docs/devlog.md):
// answer ARP requests and ICMP echo requests addressed to this
// process's own configured IP, and build outbound ARP-request/ICMP-
// echo-request frames for the startup self-test each caller runs. No
// IP stack beyond that — no DHCP, no TCP/UDP, no routing, no ARP
// cache beyond the one reply each self-test waits for.
//
// Every multi-byte protocol field is read/written through explicit
// big-endian byte helpers below, never by casting to a wider integer
// type and dereferencing directly — this CPU (RV64) is little-endian,
// the wire is always big-endian, and an unaligned wide load/store
// through a misaligned char* is also its own separate hazard this
// sidesteps entirely. `char` is treated as signed throughout, matching
// this codebase's own established convention (mask with `& 0xFF`
// after any widening cast, e.g. usbd's own descriptor-byte parsing) —
// sign extension only ever affects bits above the original byte, so a
// mask taken from the low byte is always correct regardless.

fn ushort read_be16(char* p)
{
    return (ushort)((((uint)p[0] & 0xFF) << 8) | ((uint)p[1] & 0xFF));
}

fn void write_be16(char* p, ushort v)
{
    p[0] = (char)((v >> 8) & 0xFF);
    p[1] = (char)(v & 0xFF);
}

fn uint read_be32(char* p)
{
    return (((uint)p[0] & 0xFF) << 24) | (((uint)p[1] & 0xFF) << 16)
        | (((uint)p[2] & 0xFF) << 8) | ((uint)p[3] & 0xFF);
}

fn void write_be32(char* p, uint v)
{
    p[0] = (char)((v >> 24) & 0xFF);
    p[1] = (char)((v >> 16) & 0xFF);
    p[2] = (char)((v >> 8) & 0xFF);
    p[3] = (char)(v & 0xFF);
}

fn void mac_copy(char* dst, char* src)
{
    for (int i = 0; i < 6; i++) { dst[i] = src[i]; }
}

// Builds a 4-byte big-endian IP address value from its four dotted-
// decimal octets — a small readability helper for the static IP/
// gateway constants each caller (netd.c3/ethd.c3) defines for itself.
fn uint make_ip(uint a, uint b, uint c, uint d)
{
    return (a << 24) | (b << 16) | (c << 8) | d;
}

// Standard IPv4/ICMP one's-complement 16-bit checksum: sum all 16-bit
// big-endian words (the field being computed itself assumed already
// zeroed by the caller), fold any carry back in, then take the one's
// complement. Used for both the IPv4 header and the ICMP message.
fn ushort ip_checksum(char* data, uint len)
{
    uint sum = 0;
    uint i = 0;
    while (i + 1 < len)
    {
        sum += (uint)read_be16(&data[i]);
        i += 2;
    }
    if (i < len)
    {
        // Odd trailing byte — treated as the high byte of a final
        // 16-bit word whose low byte is implicitly zero, standard for
        // this checksum algorithm.
        sum += ((uint)data[i] & 0xFF) << 8;
    }
    while ((sum >> 16) != 0)
    {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return (ushort)(~sum & 0xFFFF);
}

const uint ETH_TYPE_ARP  = 0x0806;
const uint ETH_TYPE_IPV4 = 0x0800;
const uint ARP_OPER_REQUEST = 1;
const uint ARP_OPER_REPLY   = 2;
const uint IP_PROTO_ICMP = 1;
const uint ICMP_TYPE_ECHO_REQUEST = 8;
const uint ICMP_TYPE_ECHO_REPLY   = 0;

// Builds a broadcast ARP request ("who has target_ip? tell our_ip")
// into `out` (must have room for 42 bytes) and sets *out_len.
fn void eth_build_arp_request(char* out, uint* out_len, char* our_mac, uint our_ip, uint target_ip)
{
    for (int i = 0; i < 6; i++) { out[i] = (char)0xFF; } // broadcast dst
    mac_copy(&out[6], our_mac);
    write_be16(&out[12], (ushort)ETH_TYPE_ARP);

    char* arp = &out[14];
    write_be16(&arp[0], 1);    // htype = Ethernet
    write_be16(&arp[2], (ushort)ETH_TYPE_IPV4); // ptype = IPv4
    arp[4] = (char)6; // hlen
    arp[5] = (char)4; // plen
    write_be16(&arp[6], (ushort)ARP_OPER_REQUEST);
    mac_copy(&arp[8], our_mac);   // sha
    write_be32(&arp[14], our_ip); // spa
    for (int i = 0; i < 6; i++) { arp[18 + i] = 0; } // tha — unknown, this is what we're asking
    write_be32(&arp[24], target_ip); // tpa

    *out_len = 14 + 28;
}

// True if `frame` is an ARP reply answering a request for
// `expect_target_ip` — fills mac_out (6 bytes) with the replier's real
// MAC (the ARP header's own sha field) on success.
fn bool eth_parse_arp_reply(char* frame, uint len, uint expect_target_ip, char* mac_out)
{
    if (len < 42) { return false; }
    if (read_be16(&frame[12]) != (ushort)ETH_TYPE_ARP) { return false; }
    char* arp = &frame[14];
    if (read_be16(&arp[6]) != (ushort)ARP_OPER_REPLY) { return false; }
    if (read_be32(&arp[14]) != expect_target_ip) { return false; } // spa = the address we asked about
    mac_copy(mac_out, &arp[8]);
    return true;
}

// Builds an ICMP echo request (ping) addressed to dst_mac/dst_ip into
// `out` (must have room for at least 14+20+8+ICMP_ECHO_PAYLOAD_LEN
// bytes) and sets *out_len. id/seq are caller-chosen (used to match
// the eventual reply).
const uint ICMP_ECHO_PAYLOAD_LEN = 32;

fn void eth_build_icmp_echo_request(char* out, uint* out_len, char* our_mac, uint our_ip, char* dst_mac, uint dst_ip, ushort id, ushort seq)
{
    mac_copy(&out[0], dst_mac);
    mac_copy(&out[6], our_mac);
    write_be16(&out[12], (ushort)ETH_TYPE_IPV4);

    uint icmp_len = 8 + ICMP_ECHO_PAYLOAD_LEN;
    uint total_len = 20 + icmp_len;

    char* ip = &out[14];
    ip[0] = (char)0x45; // version 4, IHL 5 (20 bytes, no options)
    ip[1] = 0;           // TOS
    write_be16(&ip[2], (ushort)total_len);
    write_be16(&ip[4], 0); // identification
    write_be16(&ip[6], 0); // flags/fragment offset
    ip[8] = (char)64;      // TTL
    ip[9] = (char)IP_PROTO_ICMP;
    write_be16(&ip[10], 0); // checksum — filled in below, once the rest of the header is set
    write_be32(&ip[12], our_ip);
    write_be32(&ip[16], dst_ip);
    write_be16(&ip[10], ip_checksum(ip, 20));

    char* icmp = &ip[20];
    icmp[0] = (char)ICMP_TYPE_ECHO_REQUEST;
    icmp[1] = 0;
    write_be16(&icmp[2], 0); // checksum — filled in below
    write_be16(&icmp[4], id);
    write_be16(&icmp[6], seq);
    for (uint i = 0; i < ICMP_ECHO_PAYLOAD_LEN; i++)
    {
        icmp[8 + i] = (char)('a' + (i % 23)); // arbitrary fill pattern, matches typical ping payloads
    }
    write_be16(&icmp[2], ip_checksum(icmp, icmp_len));

    *out_len = 14 + total_len;
}

// True if `frame` is an ICMP echo reply matching expect_id/expect_seq
// (assumes a plain 20-byte IPv4 header, no options — matches every
// header this driver itself ever builds or expects to see, real or
// otherwise, for this narrow a protocol scope).
fn bool eth_parse_icmp_echo_reply(char* frame, uint len, ushort expect_id, ushort expect_seq)
{
    if (len < 14 + 20 + 8) { return false; }
    if (read_be16(&frame[12]) != (ushort)ETH_TYPE_IPV4) { return false; }
    char* ip = &frame[14];
    if (((uint)ip[0] & 0xF0) != 0x40) { return false; } // IPv4
    if (((uint)ip[9] & 0xFF) != IP_PROTO_ICMP) { return false; }
    uint ihl_bytes = (((uint)ip[0]) & 0x0F) * 4;
    char* icmp = &ip[ihl_bytes];
    if (((uint)icmp[0] & 0xFF) != ICMP_TYPE_ECHO_REPLY) { return false; }
    return read_be16(&icmp[4]) == expect_id && read_be16(&icmp[6]) == expect_seq;
}

// The passive responder: an ARP request for our_ip gets an ARP reply;
// an ICMP echo request to our_ip gets an echo reply (payload copied
// back verbatim, per ICMP spec). Builds the reply into tx_out (must
// have room for at least rx_len bytes — a reply is never larger than
// the request that prompted it) and sets *tx_len_out; returns false
// (nothing to send) for anything else, the same as any real stack
// silently dropping traffic it doesn't handle.
fn bool eth_proto_respond(char* rx, uint rx_len, char* our_mac, uint our_ip, char* tx_out, uint* tx_len_out)
{
    if (rx_len < 14) { return false; }
    ushort ethertype = read_be16(&rx[12]);

    if (ethertype == (ushort)ETH_TYPE_ARP)
    {
        if (rx_len < 42) { return false; }
        char* arp = &rx[14];
        if (read_be16(&arp[6]) != (ushort)ARP_OPER_REQUEST) { return false; }
        if (read_be32(&arp[24]) != our_ip) { return false; } // tpa — not asking about us

        mac_copy(&tx_out[0], &arp[8]); // dst = the original requester
        mac_copy(&tx_out[6], our_mac);
        write_be16(&tx_out[12], (ushort)ETH_TYPE_ARP);

        char* reply = &tx_out[14];
        write_be16(&reply[0], 1);
        write_be16(&reply[2], (ushort)ETH_TYPE_IPV4);
        reply[4] = (char)6;
        reply[5] = (char)4;
        write_be16(&reply[6], (ushort)ARP_OPER_REPLY);
        mac_copy(&reply[8], our_mac);   // sha = us
        write_be32(&reply[14], our_ip); // spa = us
        mac_copy(&reply[18], &arp[8]);  // tha = original requester
        write_be32(&reply[24], read_be32(&arp[14])); // tpa = original requester's IP

        *tx_len_out = 42;
        return true;
    }

    if (ethertype == (ushort)ETH_TYPE_IPV4)
    {
        if (rx_len < 14 + 20 + 8) { return false; }
        char* ip = &rx[14];
        if (((uint)ip[0] & 0xF0) != 0x40) { return false; }
        if (((uint)ip[9] & 0xFF) != IP_PROTO_ICMP) { return false; }
        if (read_be32(&ip[16]) != our_ip) { return false; } // not addressed to us

        uint ihl_bytes = (((uint)ip[0]) & 0x0F) * 4;
        char* icmp = &ip[ihl_bytes];
        if (((uint)icmp[0] & 0xFF) != ICMP_TYPE_ECHO_REQUEST) { return false; }

        uint total_len = (uint)read_be16(&ip[2]);
        if (total_len < ihl_bytes + 8 || total_len > rx_len - 14) { return false; }
        uint icmp_len = total_len - ihl_bytes;
        uint src_ip = read_be32(&ip[12]);

        mac_copy(&tx_out[0], &rx[6]); // dst = original sender
        mac_copy(&tx_out[6], our_mac);
        write_be16(&tx_out[12], (ushort)ETH_TYPE_IPV4);

        char* reply_ip = &tx_out[14];
        reply_ip[0] = (char)0x45;
        reply_ip[1] = 0;
        write_be16(&reply_ip[2], (ushort)(20 + icmp_len));
        write_be16(&reply_ip[4], 0);
        write_be16(&reply_ip[6], 0);
        reply_ip[8] = (char)64;
        reply_ip[9] = (char)IP_PROTO_ICMP;
        write_be16(&reply_ip[10], 0);
        write_be32(&reply_ip[12], our_ip);
        write_be32(&reply_ip[16], src_ip);
        write_be16(&reply_ip[10], ip_checksum(reply_ip, 20));

        char* reply_icmp = &reply_ip[20];
        for (uint i = 0; i < icmp_len; i++) { reply_icmp[i] = icmp[i]; } // copy id/seq/payload verbatim, per ICMP echo spec
        reply_icmp[0] = (char)ICMP_TYPE_ECHO_REPLY;
        reply_icmp[1] = 0;
        write_be16(&reply_icmp[2], 0);
        write_be16(&reply_icmp[2], ip_checksum(reply_icmp, icmp_len));

        *tx_len_out = 14 + 20 + icmp_len;
        return true;
    }

    return false;
}
