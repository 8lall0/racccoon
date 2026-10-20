module user;

import std::nolibc::main_stub;
import std::nolibc::mem;

// ipd — racccoon's IP stack, one user-space server mounted at /net/.
//
// Link drivers (netd, ethd, the Wi-Fi driver in usbd) only move Ethernet
// frames through "ether<N>" link rings (user/net/link.c3). ipd attaches
// every link that appears and does everything above that: ARP, IPv4,
// ICMP, a DHCP client per link, UDP and TCP, plus a loopback interface
// (127.0.0.1). Programs reach it through files (user/net/ipd_conv.c3):
// /net/udp/clone, /net/tcp/<n>/data, ... — see docs/manual.md,
// "Networking", and the dial()/announce() wrappers in user/user.c3.
//
// Single-threaded and never blocking: the main loop sleeps in one
// await_any on the IPC inbox (file requests), the link doorbells and a
// short timer, then drains everything that is ready. A read that has
// nothing to return yet is parked and answered later (or after ~1 s with
// "retry"), so a slow client never stalls the stack.
//
// Deliberately not done: IP fragmentation (fragments are dropped, DF is
// set), IP options, multicast, IPv6, routing beyond "on-link or the
// default gateway".

const int IF_MAX = 4;

const int DHCP_IDLE       = 0; // link down / not started
const int DHCP_SELECTING  = 1; // DISCOVER sent
const int DHCP_REQUESTING = 2; // REQUEST sent
const int DHCP_BOUND      = 3;
const int DHCP_WAIT       = 4; // gave up for now, retry at dhcp_due

struct Iface
{
	bool  used;
	Link  link;
	char[8] name;
	char[6] mac;
	uint  ip;
	uint  mask;
	uint  gw;
	uint  dns;
	int   dhcp;
	uint  xid;
	ulong dhcp_due;
	int   dhcp_tries;
	uint  offer_ip;
	uint  offer_server;
	ulong rx_frames;
	ulong tx_frames;
}

Iface[IF_MAX] g_if;
ulong g_hz;
ulong g_now;
ushort g_ip_id = 1;

const uint LOOPBACK_IP = 0x7F000001;

// --- small helpers ---------------------------------------------------

fn ulong ms_ticks(ulong ms) { return g_hz * ms / 1000; }

fn bool ip_on_link(Iface* f, uint ip)
{
	return f.ip != 0 && f.mask != 0 && (ip & f.mask) == (f.ip & f.mask);
}

// The interface a packet to `dst` leaves through, and the next hop's
// IP. null when there's no route (no configured interface).
fn Iface* route(uint dst, uint* nexthop)
{
	for (int i = 0; i < IF_MAX; i++)
	{
		Iface* f = &g_if[i];
		if (f.used && ip_on_link(f, dst)) { *nexthop = dst; return f; }
	}
	for (int i = 0; i < IF_MAX; i++)
	{
		Iface* f = &g_if[i];
		if (f.used && f.ip != 0 && f.gw != 0) { *nexthop = f.gw; return f; }
	}
	return null;
}

// Our address as seen by a peer at `dst` (for a socket's local address).
fn uint source_for(uint dst)
{
	if ((dst >> 24) == 127) { return LOOPBACK_IP; }
	uint nh;
	Iface* f = route(dst, &nh);
	return f != null ? f.ip : 0;
}

fn bool is_local_ip(uint ip)
{
	if ((ip >> 24) == 127) { return true; }
	for (int i = 0; i < IF_MAX; i++)
	{
		if (g_if[i].used && g_if[i].ip != 0 && g_if[i].ip == ip) { return true; }
	}
	return false;
}

fn bool is_broadcast_for(Iface* f, uint ip)
{
	if (ip == 0xFFFFFFFF) { return true; }
	return f != null && f.mask != 0 && ip == (f.ip | ~f.mask);
}

fn void ipd_send_frame(Iface* f, char* frame, uint len)
{
	if (link_put(&f.link, frame, len)) { f.tx_frames++; }
	link_kick(&f.link);
}

// --- ARP -------------------------------------------------------------

const int ARP_MAX = 32;
const int ARP_PEND_MAX = 8;

struct Arp_entry
{
	bool  valid;
	int   ifc;
	uint  ip;
	char[6] mac;
	ulong expires;
}

// A packet waiting for its next hop's MAC. Re-sends the ARP request
// every second, gives up after three.
struct Arp_pend
{
	bool  used;
	int   ifc;
	uint  nexthop;
	uint  len;
	int   tries;
	ulong due;
	char[1600] frame;   // full Ethernet frame, destination MAC filled in on resolve
}

Arp_entry[ARP_MAX] g_arp;
Arp_pend[ARP_PEND_MAX] g_arp_pend;

fn Arp_entry* arp_find(int ifc, uint ip)
{
	for (int i = 0; i < ARP_MAX; i++)
	{
		Arp_entry* e = &g_arp[i];
		if (e.valid && e.ifc == ifc && e.ip == ip && g_now < e.expires) { return e; }
	}
	return null;
}

fn void arp_learn(int ifc, uint ip, char* mac)
{
	if (ip == 0) { return; }
	Arp_entry* slot = null;
	for (int i = 0; i < ARP_MAX; i++)
	{
		Arp_entry* e = &g_arp[i];
		if (e.valid && e.ifc == ifc && e.ip == ip) { slot = e; break; }
		if (slot == null && (!e.valid || g_now >= e.expires)) { slot = e; }
	}
	if (slot == null) { slot = &g_arp[(int)(g_now % (ulong)ARP_MAX)]; }
	slot.valid = true;
	slot.ifc = ifc;
	slot.ip = ip;
	mac_copy(&slot.mac[0], mac);
	slot.expires = g_now + g_hz * 600;

	// Anything that was waiting for this MAC goes out now.
	for (int i = 0; i < ARP_PEND_MAX; i++)
	{
		Arp_pend* p = &g_arp_pend[i];
		if (p.used && p.ifc == ifc && p.nexthop == ip)
		{
			mac_copy(&p.frame[0], mac);
			ipd_send_frame(&g_if[ifc], &p.frame[0], p.len);
			p.used = false;
		}
	}
}

fn void arp_request(int ifc, uint ip)
{
	Iface* f = &g_if[ifc];
	char[64] req;
	uint n;
	eth_build_arp_request(&req[0], &n, &f.mac[0], f.ip, ip);
	ipd_send_frame(f, &req[0], n);
}

fn void arp_input(int ifc, char* frame, uint len)
{
	if (len < 42) { return; }
	Iface* f = &g_if[ifc];
	char* arp = &frame[14];
	uint oper = read_be16(&arp[6]);
	uint spa = read_be32(&arp[14]);
	uint tpa = read_be32(&arp[24]);
	// Learn the sender whenever it talks to us (or answers us).
	if (tpa == f.ip || arp_find(ifc, spa) != null || oper == ARP_OPER_REPLY) { arp_learn(ifc, spa, &arp[8]); }
	if (oper == ARP_OPER_REQUEST && f.ip != 0 && tpa == f.ip)
	{
		char[64] reply;
		uint n;
		if (eth_proto_respond(frame, len, &f.mac[0], f.ip, &reply[0], &n)) { ipd_send_frame(f, &reply[0], n); }
	}
}

fn void arp_timers()
{
	for (int i = 0; i < ARP_PEND_MAX; i++)
	{
		Arp_pend* p = &g_arp_pend[i];
		if (!p.used || g_now < p.due) { continue; }
		if (p.tries >= 3) { p.used = false; continue; }
		p.tries++;
		p.due = g_now + g_hz;
		arp_request(p.ifc, p.nexthop);
	}
}

// --- IPv4 ------------------------------------------------------------

// Loopback: packets to 127/8 (or to one of our own addresses) are queued
// here and handed back to ip_input from the main loop — never re-entered
// from inside ip_output, which can be several protocol layers deep.
const int LOOP_MAX = 16;
struct Loop_pkt { uint len; char[1600] data; }
Loop_pkt[LOOP_MAX] g_loop;
int g_loop_head;
int g_loop_count;

// Build and send one IPv4 packet carrying `payload`. `src` 0 = the
// outgoing interface's address. false if it couldn't be sent or queued.
fn bool ip_output(uint src, uint dst, uint proto, char* payload, uint plen)
{
	if (plen > 1480) { return false; }
	char[1600] frame @noinit;
	char* ip = &frame[14];
	ip[0] = (char)0x45;
	ip[1] = 0;
	write_be16(&ip[2], (ushort)(20 + plen));
	write_be16(&ip[4], g_ip_id++);
	write_be16(&ip[6], 0x4000); // DF — we never fragment
	ip[8] = (char)64;
	ip[9] = (char)proto;
	write_be16(&ip[10], 0);
	mem::copy(&ip[20], payload, (sz)plen);

	if (is_local_ip(dst))
	{
		write_be32(&ip[12], src != 0 ? src : dst);
		write_be32(&ip[16], dst);
		write_be16(&ip[10], ip_checksum(ip, 20));
		if (g_loop_count >= LOOP_MAX) { return false; }
		Loop_pkt* lp = &g_loop[(g_loop_head + g_loop_count) % LOOP_MAX];
		lp.len = 20 + plen;
		mem::copy(&lp.data[0], ip, (sz)lp.len);
		g_loop_count++;
		return true;
	}

	uint nexthop;
	Iface* f = route(dst, &nexthop);
	if (f == null) { return false; }
	int ifc = (int)(f - &g_if[0]);
	write_be32(&ip[12], src != 0 ? src : f.ip);
	write_be32(&ip[16], dst);
	write_be16(&ip[10], ip_checksum(ip, 20));

	mac_copy(&frame[6], &f.mac[0]);
	write_be16(&frame[12], (ushort)ETH_TYPE_IPV4);
	uint flen = 14 + 20 + plen;
	if (is_broadcast_for(f, dst))
	{
		for (int i = 0; i < 6; i++) { frame[i] = (char)0xFF; }
		ipd_send_frame(f, &frame[0], flen);
		return true;
	}
	Arp_entry* e = arp_find(ifc, nexthop);
	if (e != null)
	{
		mac_copy(&frame[0], &e.mac[0]);
		ipd_send_frame(f, &frame[0], flen);
		return true;
	}
	// Park it and ask who has the next hop.
	for (int i = 0; i < ARP_PEND_MAX; i++)
	{
		Arp_pend* p = &g_arp_pend[i];
		if (p.used) { continue; }
		p.used = true;
		p.ifc = ifc;
		p.nexthop = nexthop;
		p.len = flen;
		p.tries = 1;
		p.due = g_now + g_hz;
		mem::copy(&p.frame[0], &frame[0], (sz)flen);
		arp_request(ifc, nexthop);
		return true;
	}
	return false;
}

// One received IPv4 packet (`ip` points at its header). `f` is the
// interface it arrived on, null for loopback.
fn void ip_input(Iface* f, char* ip, uint len)
{
	if (len < 20 || ((uint)ip[0] & 0xF0) != 0x40) { return; }
	uint ihl = ((uint)ip[0] & 0x0F) * 4;
	uint total = read_be16(&ip[2]);
	if (ihl < 20 || total < ihl || total > len) { return; }
	if (ip_checksum(ip, ihl) != 0) { return; }
	uint frag = read_be16(&ip[6]);
	if ((frag & 0x2000) != 0 || (frag & 0x1FFF) != 0) { return; } // fragments: not supported
	uint src = read_be32(&ip[12]);
	uint dst = read_be32(&ip[16]);
	if (f != null && !is_local_ip(dst) && !is_broadcast_for(f, dst)) { return; }
	uint proto = (uint)ip[9] & 0xFF;
	char* payload = &ip[ihl];
	uint plen = total - ihl;
	if (proto == IP_PROTO_ICMP) { icmp_input(src, dst, payload, plen); }
	else if (proto == IP_PROTO_UDP) { udp_input(src, dst, payload, plen); }
	else if (proto == IP_PROTO_TCP) { tcp_input(src, dst, payload, plen); }
}

// --- ICMP ------------------------------------------------------------

fn void icmp_input(uint src, uint dst, char* icmp, uint len)
{
	if (len < 8 || ip_checksum(icmp, len) != 0) { return; }
	uint type = (uint)icmp[0] & 0xFF;
	if (type == ICMP_TYPE_ECHO_REQUEST)
	{
		char[1480] reply @noinit;
		mem::copy(&reply[0], icmp, (sz)len);
		reply[0] = (char)ICMP_TYPE_ECHO_REPLY;
		write_be16(&reply[2], 0);
		write_be16(&reply[2], ip_checksum(&reply[0], len));
		ip_output(is_local_ip(dst) ? dst : 0, src, IP_PROTO_ICMP, &reply[0], len);
	}
	else if (type == ICMP_TYPE_ECHO_REPLY)
	{
		icmp_echo_reply(src, read_be16(&icmp[4]), &icmp[8], len - 8);
	}
}

// --- DHCP (one client per interface) -----------------------------------

fn void dhcp_start(Iface* f)
{
	f.xid = (uint)rdtime() ^ (uint)(f - &g_if[0]);
	char[600] msg @noinit;
	uint n;
	dhcp_build_discover(&msg[0], &n, &f.mac[0], f.xid);
	ipd_send_frame(f, &msg[0], n);
	f.dhcp = DHCP_SELECTING;
	f.dhcp_due = g_now + g_hz * 2;
}

fn void dhcp_input(Iface* f, char* frame, uint len)
{
	uint type;
	uint yiaddr;
	uint server;
	uint router;
	uint mask;
	uint dns;
	if (!dhcp_parse_message(frame, len, f.xid, &type, &yiaddr, &server, &router, &mask, &dns)) { return; }
	if (f.dhcp == DHCP_SELECTING && type == DHCP_MSG_OFFER)
	{
		f.offer_ip = yiaddr;
		f.offer_server = server;
		char[600] msg @noinit;
		uint n;
		dhcp_build_request(&msg[0], &n, &f.mac[0], f.xid, yiaddr, server);
		ipd_send_frame(f, &msg[0], n);
		f.dhcp = DHCP_REQUESTING;
		f.dhcp_due = g_now + g_hz * 2;
	}
	else if (f.dhcp == DHCP_REQUESTING && type == DHCP_MSG_ACK)
	{
		f.ip = yiaddr;
		f.mask = mask != 0 ? mask : 0xFFFFFF00;
		f.gw = router;
		f.dns = dns;
		f.dhcp = DHCP_BOUND;
		print("ipd: ");
		print(&f.name[0]);
		print(" bound ");
		print_ip(f.ip);
		print(" gw ");
		print_ip(f.gw);
		print(" dns ");
		print_ip(f.dns);
		print("\n");
	}
	else if (f.dhcp == DHCP_REQUESTING && type == DHCP_MSG_NAK)
	{
		f.dhcp = DHCP_WAIT;
		f.dhcp_due = g_now + g_hz;
	}
}

fn void dhcp_timers(Iface* f)
{
	bool up = f.link.h.link_up != 0;
	if (!up)
	{
		if (f.dhcp != DHCP_IDLE)
		{
			// Lost the link: drop the address, start over when it's back.
			f.dhcp = DHCP_IDLE;
			f.ip = 0;
			f.gw = 0;
		}
		return;
	}
	if (f.dhcp == DHCP_IDLE) { f.dhcp_tries = 0; dhcp_start(f); return; }
	if (f.dhcp == DHCP_BOUND || g_now < f.dhcp_due) { return; }
	if (f.dhcp == DHCP_WAIT) { f.dhcp_tries = 0; dhcp_start(f); return; }
	// SELECTING / REQUESTING timed out.
	f.dhcp_tries++;
	if (f.dhcp_tries >= 3)
	{
		print("ipd: ");
		print(&f.name[0]);
		print(" DHCP: no answer, retrying in 10 s\n");
		f.dhcp = DHCP_WAIT;
		f.dhcp_due = g_now + g_hz * 10;
		return;
	}
	dhcp_start(f);
}

// --- links -----------------------------------------------------------

fn void links_scan()
{
	for (int i = 0; i < IF_MAX; i++)
	{
		Iface* f = &g_if[i];
		if (f.used) { continue; }
		char[8] nm;
		nm[0] = 'e'; nm[1] = 't'; nm[2] = 'h'; nm[3] = 'e'; nm[4] = 'r';
		nm[5] = (char)('0' + i); nm[6] = 0;
		if (!link_attach(&f.link, &nm[0])) { continue; }
		f.used = true;
		for (int k = 0; k < 7; k++) { f.name[k] = nm[k]; }
		for (int k = 0; k < 6; k++) { f.mac[k] = f.link.h.mac[k]; }
		f.dhcp = DHCP_IDLE;
		print("ipd: attached ");
		print(&nm[0]);
		print("\n");
	}
}

fn void eth_input(int ifc, char* frame, uint len)
{
	Iface* f = &g_if[ifc];
	if (len < 14) { return; }
	f.rx_frames++;
	uint type = read_be16(&frame[12]);
	if (type == ETH_TYPE_ARP) { arp_input(ifc, frame, len); return; }
	if (type != ETH_TYPE_IPV4) { return; }
	if (f.dhcp == DHCP_SELECTING || f.dhcp == DHCP_REQUESTING) { dhcp_input(f, frame, len); }
	ip_input(f, &frame[14], len - 14);
}

fn bool drain_links()
{
	bool got = false;
	char[LINK_FRAME_MAX] frame @noinit;
	for (int i = 0; i < IF_MAX; i++)
	{
		if (!g_if[i].used) { continue; }
		for (int k = 0; k < (int)LINK_SLOTS; k++)
		{
			int n = link_get(&g_if[i].link, &frame[0]);
			if (n < 0) { break; }
			eth_input(i, &frame[0], (uint)n);
			got = true;
		}
	}
	while (g_loop_count > 0)
	{
		Loop_pkt* lp = &g_loop[g_loop_head];
		char[1600] pkt @noinit;
		uint n = lp.len;
		mem::copy(&pkt[0], &lp.data[0], (sz)n);
		g_loop_head = (g_loop_head + 1) % LOOP_MAX;
		g_loop_count--;
		ip_input(null, &pkt[0], n);
		got = true;
	}
	return got;
}

fn void main()
{
	g_hz = timebase_hz();
	g_now = rdtime();
	conv_init();
	srv_post("ipd");
	print("ipd: up, serving /net\n");

	ulong next_scan = 0;
	ulong next_slow = 0;
	for (;;)
	{
		g_now = rdtime();
		if (g_now >= next_scan)
		{
			next_scan = g_now + g_hz;
			links_scan();
		}
		// Requests first (each may queue output), then frames, then
		// whatever timers are due, then any parked reads that can now
		// be answered.
		for (int k = 0; k < 16; k++)
		{
			if (!net_serve_one()) { break; }
		}
		drain_links();
		g_now = rdtime();
		arp_timers();
		for (int i = 0; i < IF_MAX; i++) { if (g_if[i].used) { dhcp_timers(&g_if[i]); } }
		tcp_timers();
		if (g_now >= next_slow)
		{
			next_slow = g_now + g_hz * 2;
			conv_reap_dead_owners();
		}
		pend_service();
		if (g_loop_count > 0) { continue; }
		await_any(AW_MSG | AW_WAKE, ms_ticks(20), null, 0);
	}
}
