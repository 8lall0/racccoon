module user;

// dhcp: a minimal DHCP client (RFC 2131), transport-agnostic — builds
// and parses raw Ethernet frame bytes only, same shape as
// user/net/eth_proto.c3 itself (whose UDP/checksum/big-endian helpers
// this file builds on directly — same module, no import needed).
// Used by both user/net/netd.c3 (QEMU) and user/net/ethd.c3 (real
// Duo), same "generic core, transport stays in the caller" pattern
// every shared layer in this project already follows.
//
// Scope, deliberately narrow (see docs/devlog.md): DHCPDISCOVER ->
// DHCPOFFER -> DHCPREQUEST -> DHCPACK, once at startup. No lease
// renewal, no DHCPRELEASE/DECLINE, no RFC-5227 ARP probe of the
// offered address before use — the same phased-scope discipline every
// earlier feature here used. Added specifically because a static IP
// hit a real router-side wall: a live tcpdump capture (Ethernet Phase
// 2's own real-hardware round) confirmed this board's own ARP
// requests reach the wire perfectly formed, but the user's router
// never replies to them — the classic signature of IP-MAC-binding/
// ARP-defense silently dropping traffic from a device using a static
// IP it never itself assigned. A real DHCP lease is exactly how every
// other device on that same LAN already gets treated as legitimate.

const uint DHCP_SERVER_PORT = 67;
const uint DHCP_CLIENT_PORT = 68;

const uint DHCP_OP_BOOTREQUEST = 1;
const uint DHCP_OP_BOOTREPLY   = 2;
const uint DHCP_HTYPE_ETHERNET = 1;
const uint DHCP_HLEN_ETHERNET  = 6;

const uint DHCP_MSG_DISCOVER = 1;
const uint DHCP_MSG_OFFER    = 2;
const uint DHCP_MSG_REQUEST  = 3;
const uint DHCP_MSG_ACK      = 5;
const uint DHCP_MSG_NAK      = 6;

const uint DHCP_OPT_SUBNET_MASK    = 1;
const uint DHCP_OPT_ROUTER         = 3;
const uint DHCP_OPT_REQUESTED_IP   = 50;
const uint DHCP_OPT_MSG_TYPE       = 53;
const uint DHCP_OPT_SERVER_ID      = 54;
const uint DHCP_OPT_PARAM_REQUEST  = 55;
const uint DHCP_OPT_END            = 255;

// Fixed-size portion of a DHCP message (RFC 2131 section 2), before
// the magic cookie + variable options. Field offsets within this
// block, all big-endian on the wire:
//   op(1) htype(1) hlen(1) hops(1)      @ 0
//   xid(4)                              @ 4
//   secs(2) flags(2)                    @ 8
//   ciaddr(4)                           @ 12
//   yiaddr(4)                           @ 16
//   siaddr(4)                           @ 20
//   giaddr(4)                           @ 24
//   chaddr(16)                          @ 28
//   sname(64)                           @ 44
//   file(128)                           @ 108
// total = 236 bytes, then a 4-byte magic cookie, then options.
const uint DHCP_FIXED_LEN = 236;
const char[4] DHCP_MAGIC_COOKIE = { (char)99, (char)130, (char)83, (char)99 };

const uint DHCP_FLAG_BROADCAST = 0x8000; // set so the server replies as broadcast too — this driver has no way to receive a real unicast IP frame before it has a working address configured, same reasoning every minimal embedded DHCP client sets this

// Writes the fixed DHCP header + magic cookie into `out`, returns the
// byte offset options should start being written at (DHCP_FIXED_LEN +
// 4). Shared by both build functions below.
fn uint dhcp_write_fixed_header(char* out, char* our_mac, uint xid, uint ciaddr)
{
    out[0] = (char)DHCP_OP_BOOTREQUEST;
    out[1] = (char)DHCP_HTYPE_ETHERNET;
    out[2] = (char)DHCP_HLEN_ETHERNET;
    out[3] = (char)0; // hops
    write_be32(&out[4], xid);
    write_be16(&out[8], 0);  // secs
    write_be16(&out[10], (ushort)DHCP_FLAG_BROADCAST);
    write_be32(&out[12], ciaddr); // 0.0.0.0 unless renewing (never the case in this driver's own scope)
    write_be32(&out[16], 0);  // yiaddr — server fills this in on reply, unused in a request
    write_be32(&out[20], 0);  // siaddr
    write_be32(&out[24], 0);  // giaddr — no relay agent
    mac_copy(&out[28], our_mac);
    for (uint i = 6; i < 16; i++) { out[28 + i] = 0; } // rest of chaddr, padding
    for (uint i = 0; i < 64; i++) { out[44 + i] = 0; }  // sname, unused
    for (uint i = 0; i < 128; i++) { out[108 + i] = 0; } // file, unused
    out[236] = DHCP_MAGIC_COOKIE[0];
    out[237] = DHCP_MAGIC_COOKIE[1];
    out[238] = DHCP_MAGIC_COOKIE[2];
    out[239] = DHCP_MAGIC_COOKIE[3];
    return 240;
}

// Builds a full Ethernet+IP+UDP+DHCP DHCPDISCOVER frame into `out`
// (must have room for ~300 bytes) and sets *out_len. Broadcast dst
// MAC/IP, src IP 0.0.0.0 — this process has no address yet, that's
// the whole point of this exchange.
fn void dhcp_build_discover(char* out, uint* out_len, char* our_mac, uint xid)
{
    for (int i = 0; i < 6; i++) { out[i] = (char)0xFF; } // broadcast dst
    mac_copy(&out[6], our_mac);
    write_be16(&out[12], (ushort)ETH_TYPE_IPV4);

    char* ip = &out[14];
    char* udp = &ip[20];
    char* dhcp = &udp[8];

    uint options_end = dhcp_write_fixed_header(dhcp, our_mac, xid, 0);
    dhcp[options_end]     = (char)DHCP_OPT_MSG_TYPE;
    dhcp[options_end + 1] = (char)1;
    dhcp[options_end + 2] = (char)DHCP_MSG_DISCOVER;
    dhcp[options_end + 3] = (char)DHCP_OPT_PARAM_REQUEST;
    dhcp[options_end + 4] = (char)2;
    dhcp[options_end + 5] = (char)DHCP_OPT_SUBNET_MASK;
    dhcp[options_end + 6] = (char)DHCP_OPT_ROUTER;
    dhcp[options_end + 7] = (char)DHCP_OPT_END;
    uint dhcp_len = options_end + 8;

    build_udp_header(udp, dhcp_len, 0, 0xFFFFFFFF, (ushort)DHCP_CLIENT_PORT, (ushort)DHCP_SERVER_PORT);

    uint udp_len = 8 + dhcp_len;
    ip[0] = (char)0x45;
    ip[1] = 0;
    write_be16(&ip[2], (ushort)(20 + udp_len));
    write_be16(&ip[4], 0);
    write_be16(&ip[6], 0);
    ip[8] = (char)64;
    ip[9] = (char)IP_PROTO_UDP;
    write_be16(&ip[10], 0);
    write_be32(&ip[12], 0);          // src = 0.0.0.0
    write_be32(&ip[16], 0xFFFFFFFF); // dst = 255.255.255.255
    write_be16(&ip[10], ip_checksum(ip, 20));

    *out_len = 14 + 20 + udp_len;
}

// Builds a full Ethernet+IP+UDP+DHCP DHCPREQUEST frame — same
// broadcast shape as DISCOVER (still no working address until the
// server ACKs), explicitly naming the offered IP (option 50) and
// which server this request is answering (option 54), per RFC 2131 —
// required so every OTHER server that also sent an OFFER knows this
// client picked someone else's.
fn void dhcp_build_request(char* out, uint* out_len, char* our_mac, uint xid, uint requested_ip, uint server_ip)
{
    for (int i = 0; i < 6; i++) { out[i] = (char)0xFF; }
    mac_copy(&out[6], our_mac);
    write_be16(&out[12], (ushort)ETH_TYPE_IPV4);

    char* ip = &out[14];
    char* udp = &ip[20];
    char* dhcp = &udp[8];

    uint options_end = dhcp_write_fixed_header(dhcp, our_mac, xid, 0);
    dhcp[options_end]     = (char)DHCP_OPT_MSG_TYPE;
    dhcp[options_end + 1] = (char)1;
    dhcp[options_end + 2] = (char)DHCP_MSG_REQUEST;
    dhcp[options_end + 3] = (char)DHCP_OPT_REQUESTED_IP;
    dhcp[options_end + 4] = (char)4;
    write_be32(&dhcp[options_end + 5], requested_ip);
    dhcp[options_end + 9]  = (char)DHCP_OPT_SERVER_ID;
    dhcp[options_end + 10] = (char)4;
    write_be32(&dhcp[options_end + 11], server_ip);
    dhcp[options_end + 15] = (char)DHCP_OPT_END;
    uint dhcp_len = options_end + 16;

    build_udp_header(udp, dhcp_len, 0, 0xFFFFFFFF, (ushort)DHCP_CLIENT_PORT, (ushort)DHCP_SERVER_PORT);

    uint udp_len = 8 + dhcp_len;
    ip[0] = (char)0x45;
    ip[1] = 0;
    write_be16(&ip[2], (ushort)(20 + udp_len));
    write_be16(&ip[4], 0);
    write_be16(&ip[6], 0);
    ip[8] = (char)64;
    ip[9] = (char)IP_PROTO_UDP;
    write_be16(&ip[10], 0);
    write_be32(&ip[12], 0);
    write_be32(&ip[16], 0xFFFFFFFF);
    write_be16(&ip[10], ip_checksum(ip, 20));

    *out_len = 14 + 20 + udp_len;
}

// Parses a received frame as a DHCP server reply matching expect_xid
// (OFFER or ACK/NAK — the caller branches on *msg_type_out). Fills
// yiaddr_out (offered/assigned IP, from the fixed header, not an
// option), server_id_out and router_out from whichever options are
// present (0 if absent — router is optional per spec, though every
// real server sends it; server_id is required by spec, always
// present on a real OFFER/ACK). Returns false for anything that isn't
// a UDP:67->68 DHCP reply with a matching transaction ID.
fn bool dhcp_parse_message(char* frame, uint len, uint expect_xid, uint* msg_type_out, uint* yiaddr_out, uint* server_id_out, uint* router_out)
{
    if (len < 14 + 20 + 8 + DHCP_FIXED_LEN + 4) { return false; }
    if (read_be16(&frame[12]) != (ushort)ETH_TYPE_IPV4) { return false; }
    char* ip = &frame[14];
    if (((uint)ip[0] & 0xF0) != 0x40) { return false; }
    if (((uint)ip[9] & 0xFF) != IP_PROTO_UDP) { return false; }
    uint ihl_bytes = (((uint)ip[0]) & 0x0F) * 4;
    char* udp = &ip[ihl_bytes];
    if (read_be16(&udp[0]) != (ushort)DHCP_SERVER_PORT) { return false; }
    if (read_be16(&udp[2]) != (ushort)DHCP_CLIENT_PORT) { return false; }

    char* dhcp = &udp[8];
    uint total_len = (uint)read_be16(&ip[2]);
    uint udp_len = total_len - ihl_bytes;
    uint dhcp_len = udp_len - 8;
    if (dhcp_len < DHCP_FIXED_LEN + 4) { return false; }

    if ((uint)dhcp[0] != DHCP_OP_BOOTREPLY) { return false; }
    if (read_be32(&dhcp[4]) != expect_xid) { return false; }
    if (dhcp[236] != DHCP_MAGIC_COOKIE[0] || dhcp[237] != DHCP_MAGIC_COOKIE[1]
        || dhcp[238] != DHCP_MAGIC_COOKIE[2] || dhcp[239] != DHCP_MAGIC_COOKIE[3])
    {
        return false;
    }

    *yiaddr_out = read_be32(&dhcp[16]);
    *msg_type_out = 0;
    *server_id_out = 0;
    *router_out = 0;

    // Walk the TLV option list (starts right after the magic cookie,
    // at fixed offset 240) until DHCP_OPT_END or the message runs
    // out — standard DHCP option encoding: type(1) len(1) value(len),
    // except DHCP_OPT_END/PAD (0) which have no length/value at all.
    uint i = 240;
    while (i < dhcp_len)
    {
        uint opt = (uint)dhcp[i] & 0xFF;
        if (opt == DHCP_OPT_END) { break; }
        if (opt == 0) { i++; continue; } // pad
        if (i + 1 >= dhcp_len) { break; }
        uint opt_len = (uint)dhcp[i + 1] & 0xFF;
        if (i + 2 + opt_len > dhcp_len) { break; }
        if (opt == DHCP_OPT_MSG_TYPE && opt_len >= 1)
        {
            *msg_type_out = (uint)dhcp[i + 2] & 0xFF;
        }
        else if (opt == DHCP_OPT_SERVER_ID && opt_len >= 4)
        {
            *server_id_out = read_be32(&dhcp[i + 2]);
        }
        else if (opt == DHCP_OPT_ROUTER && opt_len >= 4)
        {
            *router_out = read_be32(&dhcp[i + 2]); // first router if the server offered more than one
        }
        i += 2 + opt_len;
    }

    return *msg_type_out != 0;
}
