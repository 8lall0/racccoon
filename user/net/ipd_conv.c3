module user;

import std::nolibc::mem;
import std::nolibc::fmt;

// ipd's conversations and the /net file tree (see user/net/ipd.c3).
//
//   /net/ipifc/<n>/status       one line per interface: name mac ip mask gw dns state counters
//   /net/arp                    the ARP cache
//   /net/<proto>/clone          read: allocate a conversation, returns "<n>"
//   /net/<proto>/<n>/ctl        write commands (below); read returns "<n>"
//   /net/<proto>/<n>/data       read/write the payload stream / datagrams
//   /net/<proto>/<n>/local      "a.b.c.d!port"
//   /net/<proto>/<n>/remote     "a.b.c.d!port"
//   /net/<proto>/<n>/status     "<proto> <n> <state> ..."
//   /net/tcp/<n>/listen         read: wait for a connection, returns its "<m>"
//
// <proto> is udp, tcp or icmp. ctl commands:
//   connect a.b.c.d!port   (icmp: connect a.b.c.d)
//   announce [*!]port      listen on a local port (tcp: accept connections)
//   bind port              pick the local port before connect
//   headers                udp: every data read/write carries a 6-byte
//                          header — peer address (4) and port (2) — so one
//                          announced conversation can talk to many peers
//   own                    take over ownership (a forked child, say)
//   close                  tcp: half-close — send FIN, keep reading
//   hangup                 close and free the conversation
//
// A conversation belongs to the process that read its clone (or listen)
// file: only that uid (or root) may use it, and it is freed once the
// owning process is gone — the closest thing to "the last fd closed"
// without file descriptors. Reads that have nothing yet are parked
// (Pend) and answered when data arrives, or after PEND_WAIT_MS with -2
// ("try again"), which user.c3's net_read() loops on.

const uint IP_PROTO_TCP = 6;

const int CONV_MAX = 32;
const int DGRAM_N  = 8;          // datagrams queued per udp/icmp conversation
// NET_RETRY (-2, "nothing yet, ask again") is user.c3's, shared with the client side.
const ulong PEND_WAIT_MS = 1000;

const int C_FREE      = 0;
const int C_OPEN      = 1;       // cloned, nothing configured
const int C_CONNECTED = 2;
const int C_ANNOUNCED = 3;
const int C_CLOSED    = 4;       // tcp: closed normally — reads return 0 (EOF)
const int C_RESET     = 5;       // tcp: reset / refused / timed out — reads return -1

struct Dgram
{
	uint addr;    // the peer
	uint port;
	uint len;
	char[1480] data;
}

struct Conv
{
	int   state;
	uint  proto;      // IP_PROTO_UDP / _TCP / _ICMP
	int   owner_pid;
	uint  owner_gen;
	int   owner_uid;
	uint  laddr;
	uint  lport;
	uint  raddr;
	uint  rport;
	bool  headers;
	ushort icmp_seq;
	Dgram* q;         // DGRAM_N slots (udp/icmp)
	int   qhead;
	int   qcount;
	int   tcb;        // tcp: index into the TCP control blocks, -1 none
	ulong rx_pkts;
	ulong tx_pkts;
}

Conv[CONV_MAX] g_conv;
uint g_next_port = 49152;


// Little-endian 32-bit fields of the FS wire format, byte by byte. Not
// `*(int*)&buf[k] = v`: c3c 0.8.x hits an internal codegen assert
// ("alignment <= LLVMGetAlignment(pointer)") on that pattern in this file.
fn void put_le32(char* p, uint v)
{
	p[0] = (char)v; p[1] = (char)(v >> 8); p[2] = (char)(v >> 16); p[3] = (char)(v >> 24);
}

fn uint get_le32(char* p)
{
	return (uint)p[0] | ((uint)p[1] << 8) | ((uint)p[2] << 16) | ((uint)p[3] << 24);
}

// --- conversations ---------------------------------------------------

fn void conv_init()
{
	// The datagram queues are big (CONV_MAX * DGRAM_N * 1.5 KiB); SYS_MAP
	// is demand-paged, so an idle queue costs no RAM.
	char* pool = (char*)map_pages((ulong)CONV_MAX * (ulong)DGRAM_N * Dgram::size);
	for (int i = 0; i < CONV_MAX; i++)
	{
		g_conv[i].state = C_FREE;
		g_conv[i].tcb = -1;
		g_conv[i].q = (Dgram*)(pool + (uptr)i * (uptr)DGRAM_N * Dgram::size);
	}
	tcp_init();
}

fn char* proto_name(uint p)
{
	if (p == IP_PROTO_UDP) { return "udp"; }
	if (p == IP_PROTO_TCP) { return "tcp"; }
	return "icmp";
}

fn int conv_alloc(uint proto, int pid)
{
	for (int i = 0; i < CONV_MAX; i++)
	{
		Conv* c = &g_conv[i];
		if (c.state != C_FREE) { continue; }
		c.state = C_OPEN;
		c.proto = proto;
		c.owner_pid = pid;
		uint g = 0;
		int u = 0;
		proc_info(pid, null, &g, &u);
		c.owner_gen = g;
		c.owner_uid = u;
		c.laddr = 0;
		c.lport = 0;
		c.raddr = 0;
		c.rport = 0;
		c.headers = false;
		c.icmp_seq = 0;
		c.qhead = 0;
		c.qcount = 0;
		c.tcb = -1;
		c.rx_pkts = 0;
		c.tx_pkts = 0;
		return i;
	}
	return -1;
}

fn void conv_free(int i)
{
	Conv* c = &g_conv[i];
	if (c.proto == IP_PROTO_TCP && c.tcb >= 0) { tcp_abort(c.tcb); }
	c.tcb = -1;
	c.state = C_FREE;
	pend_drop_conv(i);
}

fn bool port_in_use(uint proto, uint port)
{
	for (int i = 0; i < CONV_MAX; i++)
	{
		Conv* c = &g_conv[i];
		if (c.state != C_FREE && c.proto == proto && c.lport == port) { return true; }
	}
	return false;
}

fn uint ephemeral_port(uint proto)
{
	for (int tries = 0; tries < 16384; tries++)
	{
		uint p = g_next_port;
		g_next_port = g_next_port >= 65535 ? 49152 : g_next_port + 1;
		if (!port_in_use(proto, p)) { return p; }
	}
	return 0;
}

// Owners that have exited lose their conversations.
fn void conv_reap_dead_owners()
{
	for (int i = 0; i < CONV_MAX; i++)
	{
		Conv* c = &g_conv[i];
		if (c.state == C_FREE || c.owner_pid <= 0) { continue; }
		uint g = 0;
		if (proc_info(c.owner_pid, null, &g, null) != 0 || g != c.owner_gen) { conv_free(i); }
	}
}

fn bool dgram_push(Conv* c, uint addr, uint port, char* data, uint len)
{
	if (c.qcount >= DGRAM_N) { return false; }
	if (len > 1480) { len = 1480; }
	Dgram* d = &c.q[(c.qhead + c.qcount) % DGRAM_N];
	d.addr = addr;
	d.port = port;
	d.len = len;
	mem::copy(&d.data[0], data, (sz)len);
	c.qcount++;
	c.rx_pkts++;
	return true;
}

// --- UDP -------------------------------------------------------------

fn void udp_input(uint src, uint dst, char* udp, uint len)
{
	if (len < 8) { return; }
	uint sport = read_be16(&udp[0]);
	uint dport = read_be16(&udp[2]);
	uint ulen = read_be16(&udp[4]);
	if (ulen < 8 || ulen > len) { return; }
	if (read_be16(&udp[6]) != 0 && udp_checksum(src, dst, udp, ulen) != 0) { return; }
	// A connected conversation matching the peer exactly wins over an
	// announced one on the same port.
	int best = -1;
	for (int i = 0; i < CONV_MAX; i++)
	{
		Conv* c = &g_conv[i];
		if (c.state == C_FREE || c.proto != IP_PROTO_UDP || c.lport != dport) { continue; }
		if (c.state == C_CONNECTED)
		{
			if (c.raddr == src && c.rport == sport) { best = i; break; }
		}
		else if ((c.state == C_ANNOUNCED || c.state == C_OPEN) && best < 0)
		{
			// Bound but not connected — announced, or just given a port
			// by bind / its first headers-mode send: takes datagrams from
			// anyone (BSD semantics for an unconnected UDP socket).
			best = i;
		}
	}
	if (best < 0) { return; }
	dgram_push(&g_conv[best], src, sport, &udp[8], ulen - 8);
}

fn bool udp_output(Conv* c, uint dst, uint dport, char* data, uint len)
{
	if (len > 1472) { return false; }
	char[1480] seg @noinit;
	uint src = c.laddr != 0 ? c.laddr : source_for(dst);
	mem::copy(&seg[8], data, (sz)len);
	build_udp_header(&seg[0], len, src, dst, (ushort)c.lport, (ushort)dport);
	c.tx_pkts++;
	return ip_output(src, dst, IP_PROTO_UDP, &seg[0], 8 + len);
}

// --- ICMP echo conversations ------------------------------------------

fn void icmp_echo_reply(uint src, uint id, char* data, uint len)
{
	if ((id & 0xFF00) != 0x5200) { return; }
	int i = (int)(id & 0xFF);
	if (i >= CONV_MAX) { return; }
	Conv* c = &g_conv[i];
	if (c.state == C_FREE || c.proto != IP_PROTO_ICMP) { return; }
	dgram_push(c, src, 0, data, len);
}

fn bool icmp_output(Conv* c, int idx, char* data, uint len)
{
	if (len > 1472 || c.raddr == 0) { return false; }
	char[1480] pkt @noinit;
	pkt[0] = (char)ICMP_TYPE_ECHO_REQUEST;
	pkt[1] = 0;
	write_be16(&pkt[2], 0);
	write_be16(&pkt[4], (ushort)(0x5200 | idx));
	write_be16(&pkt[6], ++c.icmp_seq);
	mem::copy(&pkt[8], data, (sz)len);
	write_be16(&pkt[2], ip_checksum(&pkt[0], 8 + len));
	c.tx_pkts++;
	return ip_output(0, c.raddr, IP_PROTO_ICMP, &pkt[0], 8 + len);
}

// --- parsing ---------------------------------------------------------

fn bool parse_uint(char* s, int* at, uint* out)
{
	int i = *at;
	if (s[i] < '0' || s[i] > '9') { return false; }
	uint v = 0;
	while (s[i] >= '0' && s[i] <= '9') { v = v * 10 + (uint)(s[i] - '0'); i++; if (v > 0xFFFFFFF) { return false; } }
	*at = i;
	*out = v;
	return true;
}

fn bool parse_ip(char* s, int* at, uint* out)
{
	uint ip = 0;
	for (int k = 0; k < 4; k++)
	{
		uint b;
		if (!parse_uint(s, at, &b) || b > 255) { return false; }
		ip = (ip << 8) | b;
		if (k < 3)
		{
			if (s[*at] != '.') { return false; }
			*at = *at + 1;
		}
	}
	*out = ip;
	return true;
}

fn bool str_has_prefix(char* s, char* p)
{
	for (int i = 0; p[i] != 0; i++) { if (s[i] != p[i]) { return false; } }
	return true;
}

fn int fmt_ip(char* out, uint ip)
{
	int n = 0;
	for (int k = 3; k >= 0; k--)
	{
		n += fmt::format_uint((ip >> (k * 8)) & 0xFF, &out[n]);
		if (k > 0) { out[n] = '.'; n++; }
	}
	return n;
}

fn int fmt_str(char* out, char* s)
{
	int n = 0;
	while (s[n] != 0) { out[n] = s[n]; n++; }
	return n;
}

fn int fmt_hostport(char* out, uint ip, uint port)
{
	int n = fmt_ip(out, ip);
	out[n] = '!';
	n++;
	n += fmt::format_uint(port, &out[n]);
	out[n] = '\n';
	return n + 1;
}

// --- ctl -------------------------------------------------------------

fn int conv_ctl(int idx, char* cmd, uint len)
{
	Conv* c = &g_conv[idx];
	char[128] s;
	uint n = len < 127 ? len : 127;
	mem::copy(&s[0], cmd, (sz)n);
	s[n] = 0;
	while (n > 0 && (s[n - 1] == '\n' || s[n - 1] == ' ')) { n--; s[n] = 0; }

	if (str_has_prefix(&s[0], "connect "))
	{
		int at = 8;
		uint ip;
		if (!parse_ip(&s[0], &at, &ip)) { return -1; }
		uint port = 0;
		if (c.proto != IP_PROTO_ICMP)
		{
			if (s[at] != '!') { return -1; }
			at++;
			if (!parse_uint(&s[0], &at, &port) || port == 0 || port > 65535) { return -1; }
		}
		c.raddr = ip;
		c.rport = port;
		c.laddr = source_for(ip);
		if (c.proto != IP_PROTO_ICMP && c.lport == 0) { c.lport = ephemeral_port(c.proto); }
		if (c.proto == IP_PROTO_TCP) { return tcp_connect(idx); }
		c.state = C_CONNECTED;
		return 0;
	}
	if (str_has_prefix(&s[0], "announce ") || str_has_prefix(&s[0], "bind "))
	{
		bool ann = s[0] == 'a';
		int at = ann ? 9 : 5;
		if (s[at] == '*' && s[at + 1] == '!') { at += 2; }
		uint port;
		if (!parse_uint(&s[0], &at, &port) || port == 0 || port > 65535) { return -1; }
		if (port_in_use(c.proto, port) && c.lport != port) { return -1; }
		c.lport = port;
		if (ann)
		{
			c.state = C_ANNOUNCED;
			if (c.proto == IP_PROTO_TCP) { return tcp_listen(idx); }
		}
		return 0;
	}
	if (str_has_prefix(&s[0], "headers")) { c.headers = true; return 0; }
	if (str_has_prefix(&s[0], "close") && c.proto == IP_PROTO_TCP) { return tcp_shutdown(idx); }
	if (str_has_prefix(&s[0], "hangup")) { conv_free(idx); return 0; }
	return -1;
}

// --- the /net file tree -------------------------------------------------

const int F_NONE = 0;
const int F_ROOTDIR = 1;
const int F_PROTODIR = 2;
const int F_CONVDIR = 3;
const int F_CLONE = 4;
const int F_CTL = 5;
const int F_DATA = 6;
const int F_LOCAL = 7;
const int F_REMOTE = 8;
const int F_STATUS = 9;
const int F_LISTEN = 10;
const int F_IPIFCDIR = 11;
const int F_IFDIR = 12;
const int F_IFSTATUS = 13;
const int F_ARP = 14;

struct Npath { int kind; uint proto; int conv; int ifc; }

fn bool path_seg(char* p, int* at, char* name)
{
	int i = *at;
	int k = 0;
	while (name[k] != 0) { if (p[i + k] != name[k]) { return false; } k++; }
	if (p[i + k] != 0 && p[i + k] != '/') { return false; }
	*at = i + k;
	return true;
}

fn Npath net_parse(char* p)
{
	Npath r = { F_NONE, 0, -1, -1 };
	int at = 0;
	if (p[0] == '/') { at = 1; }
	if (p[at] == 0) { r.kind = F_ROOTDIR; return r; }
	if (path_seg(p, &at, "arp")) { if (p[at] == 0) { r.kind = F_ARP; } return r; }
	if (path_seg(p, &at, "ipifc"))
	{
		if (p[at] == 0) { r.kind = F_IPIFCDIR; return r; }
		at++;
		uint n;
		if (!parse_uint(p, &at, &n) || n >= (uint)IF_MAX || !g_if[n].used) { return r; }
		r.ifc = (int)n;
		if (p[at] == 0) { r.kind = F_IFDIR; return r; }
		at++;
		if (path_seg(p, &at, "status") && p[at] == 0) { r.kind = F_IFSTATUS; }
		return r;
	}
	uint proto = 0;
	if (path_seg(p, &at, "udp")) { proto = IP_PROTO_UDP; }
	else if (path_seg(p, &at, "tcp")) { proto = IP_PROTO_TCP; }
	else if (path_seg(p, &at, "icmp")) { proto = IP_PROTO_ICMP; }
	else { return r; }
	r.proto = proto;
	if (p[at] == 0) { r.kind = F_PROTODIR; return r; }
	at++;
	if (path_seg(p, &at, "clone")) { if (p[at] == 0) { r.kind = F_CLONE; } return r; }
	uint n;
	if (!parse_uint(p, &at, &n) || n >= (uint)CONV_MAX) { return r; }
	Conv* c = &g_conv[n];
	if (c.state == C_FREE || c.proto != proto) { return r; }
	r.conv = (int)n;
	if (p[at] == 0) { r.kind = F_CONVDIR; return r; }
	at++;
	if (path_seg(p, &at, "ctl")) { r.kind = F_CTL; }
	else if (path_seg(p, &at, "data")) { r.kind = F_DATA; }
	else if (path_seg(p, &at, "local")) { r.kind = F_LOCAL; }
	else if (path_seg(p, &at, "remote")) { r.kind = F_REMOTE; }
	else if (path_seg(p, &at, "status")) { r.kind = F_STATUS; }
	else if (path_seg(p, &at, "listen") && proto == IP_PROTO_TCP) { r.kind = F_LISTEN; }
	if (p[at] != 0) { r.kind = F_NONE; }
	return r;
}

fn char* conv_state_name(Conv* c)
{
	if (c.proto == IP_PROTO_TCP && c.tcb >= 0) { return tcp_state_name(c.tcb); }
	if (c.state == C_OPEN) { return "Open"; }
	if (c.state == C_CONNECTED) { return "Connected"; }
	if (c.state == C_ANNOUNCED) { return "Announced"; }
	if (c.state == C_RESET) { return "Reset"; }
	return "Closed";
}

// The contents of a small text file, into `out` (>= 1024 bytes).
fn int text_file(Npath* np, char* out)
{
	int n = 0;
	if (np.kind == F_IFSTATUS)
	{
		Iface* f = &g_if[np.ifc];
		n += fmt_str(&out[n], &f.name[0]);
		n += fmt_str(&out[n], " mac ");
		for (int k = 0; k < 6; k++)
		{
			char* hx = "0123456789abcdef";
			out[n] = hx[((uint)f.mac[k] >> 4) & 0xF]; out[n + 1] = hx[(uint)f.mac[k] & 0xF]; n += 2;
			if (k < 5) { out[n] = ':'; n++; }
		}
		n += fmt_str(&out[n], " ip ");   n += fmt_ip(&out[n], f.ip);
		n += fmt_str(&out[n], " mask "); n += fmt_ip(&out[n], f.mask);
		n += fmt_str(&out[n], " gw ");   n += fmt_ip(&out[n], f.gw);
		n += fmt_str(&out[n], " dns ");  n += fmt_ip(&out[n], f.dns);
		n += fmt_str(&out[n], f.link.h.link_up != 0 ? " link up" : " link down");
		n += fmt_str(&out[n], f.dhcp == DHCP_BOUND ? " dhcp bound" : " dhcp waiting");
		n += fmt_str(&out[n], " rx ");   n += fmt::format_uint((uint)f.rx_frames, &out[n]);
		n += fmt_str(&out[n], " tx ");   n += fmt::format_uint((uint)f.tx_frames, &out[n]);
		n += fmt_str(&out[n], " drops ");
		n += fmt::format_uint(f.link.h.rx_drops + f.link.h.tx_drops, &out[n]);
		out[n] = '\n';
		return n + 1;
	}
	if (np.kind == F_ARP)
	{
		for (int i = 0; i < ARP_MAX && n < 900; i++)
		{
			Arp_entry* e = &g_arp[i];
			if (!e.valid || g_now >= e.expires) { continue; }
			n += fmt_str(&out[n], &g_if[e.ifc].name[0]);
			out[n] = ' '; n++;
			n += fmt_ip(&out[n], e.ip);
			out[n] = ' '; n++;
			for (int k = 0; k < 6; k++)
			{
				char* hx = "0123456789abcdef";
				out[n] = hx[((uint)e.mac[k] >> 4) & 0xF]; out[n + 1] = hx[(uint)e.mac[k] & 0xF]; n += 2;
				if (k < 5) { out[n] = ':'; n++; }
			}
			out[n] = '\n'; n++;
		}
		return n;
	}
	Conv* c = &g_conv[np.conv];
	if (np.kind == F_CTL) { n = fmt::format_uint((uint)np.conv, out); out[n] = '\n'; return n + 1; }
	if (np.kind == F_LOCAL) { return fmt_hostport(out, c.laddr, c.lport); }
	if (np.kind == F_REMOTE) { return fmt_hostport(out, c.raddr, c.rport); }
	if (np.kind == F_STATUS)
	{
		n += fmt_str(&out[n], proto_name(c.proto));
		out[n] = ' '; n++;
		n += fmt::format_uint((uint)np.conv, &out[n]);
		out[n] = ' '; n++;
		n += fmt_str(&out[n], conv_state_name(c));
		n += fmt_str(&out[n], " rx ");
		n += fmt::format_uint((uint)c.rx_pkts, &out[n]);
		n += fmt_str(&out[n], " tx ");
		n += fmt::format_uint((uint)c.tx_pkts, &out[n]);
		out[n] = '\n';
		return n + 1;
	}
	return -1;
}

// --- parked reads ----------------------------------------------------

const int PEND_MAX = 32;
const int PEND_DATA = 1;
const int PEND_LISTEN = 2;

struct Pend
{
	bool  used;
	int   kind;
	int   from;
	uint  gen;
	uint  verb;
	int   conv;
	uint  maxlen;
	ulong deadline;
}

Pend[PEND_MAX] g_pend;
char[FS_MSG_MAX] g_reply;

fn void reply_int(int to, uint gen, uint verb, int v, uint datalen)
{
	put_le32(&g_reply[0], (uint)(v));
	ipc_reply(to, verb, &g_reply[0], (int)(4 + datalen), gen);
}

// Try to produce data for a parked or fresh read of conversation `idx`.
// Returns bytes written to g_reply[4..], 0 = EOF, -1 = error, NET_RETRY
// = nothing yet (keep waiting).
fn int conv_read_now(int idx, uint maxlen)
{
	Conv* c = &g_conv[idx];
	if (maxlen > FS_MSG_MAX - 4) { maxlen = FS_MSG_MAX - 4; }
	if (c.proto == IP_PROTO_TCP) { return tcp_read(idx, &g_reply[4], maxlen); }
	if (c.qcount == 0) { return NET_RETRY; }
	Dgram* d = &c.q[c.qhead];
	c.qhead = (c.qhead + 1) % DGRAM_N;
	c.qcount--;
	uint off = 0;
	if (c.headers)
	{
		write_be32(&g_reply[4], d.addr);
		write_be16(&g_reply[8], (ushort)d.port);
		off = 6;
	}
	uint n = d.len;
	if (n + off > maxlen) { n = maxlen > off ? maxlen - off : 0; }
	mem::copy(&g_reply[4 + off], &d.data[0], (sz)n);
	return (int)(n + off);
}

fn void pend_add(int kind, int from, uint gen, uint verb, int conv, uint maxlen)
{
	for (int i = 0; i < PEND_MAX; i++)
	{
		Pend* p = &g_pend[i];
		if (p.used) { continue; }
		p.used = true;
		p.kind = kind;
		p.from = from;
		p.gen = gen;
		p.verb = verb;
		p.conv = conv;
		p.maxlen = maxlen;
		p.deadline = g_now + ms_ticks(PEND_WAIT_MS);
		return;
	}
	reply_int(from, gen, verb, NET_RETRY, 0);   // table full: client retries
}

fn void pend_drop_conv(int conv)
{
	for (int i = 0; i < PEND_MAX; i++)
	{
		Pend* p = &g_pend[i];
		if (p.used && p.conv == conv)
		{
			p.used = false;
			reply_int(p.from, p.gen, p.verb, p.kind == PEND_DATA ? 0 : -1, 0);
		}
	}
}

// Answer every parked read that has something now, and time out the rest.
fn void pend_service()
{
	for (int i = 0; i < PEND_MAX; i++)
	{
		Pend* p = &g_pend[i];
		if (!p.used) { continue; }
		int r;
		if (p.kind == PEND_DATA) { r = conv_read_now(p.conv, p.maxlen); }
		else { r = tcp_accept(p.conv, p.from); }
		if (r == NET_RETRY && g_now < p.deadline) { continue; }
		p.used = false;
		if (p.kind == PEND_LISTEN && r >= 0)
		{
			int n = fmt::format_uint((uint)r, &g_reply[4]);
			g_reply[4 + n] = '\n';
			reply_int(p.from, p.gen, p.verb, n + 1, (uint)(n + 1));
		}
		else
		{
			reply_int(p.from, p.gen, p.verb, r, r > 0 ? (uint)r : 0);
		}
	}
}

// --- request dispatch ----------------------------------------------------

char[FS_MSG_MAX] g_req;

fn bool may_use(Conv* c, int uid)
{
	return uid == 0 || uid == c.owner_uid;
}

fn void list_add(char* buf, int* count, char* name, bool dir)
{
	char* rec = &buf[4 + *count * (int)FS_LIST_ENTRY_SIZE];
	int k = 0;
	while (name[k] != 0 && k < 31) { rec[k] = name[k]; k++; }
	rec[k] = 0;
	rec[32] = dir ? 1 : 0;
	*count = *count + 1;
}

fn void net_list(Npath* np, uint start, int to, uint gen, uint verb)
{
	char[FS_MSG_MAX] buf;
	int count = 0;
	char[16] nm;
	if (np.kind == F_ROOTDIR)
	{
		list_add(&buf[0], &count, "arp", false);
		list_add(&buf[0], &count, "ipifc", true);
		list_add(&buf[0], &count, "udp", true);
		list_add(&buf[0], &count, "tcp", true);
		list_add(&buf[0], &count, "icmp", true);
	}
	else if (np.kind == F_IPIFCDIR)
	{
		for (int i = 0; i < IF_MAX; i++)
		{
			if (!g_if[i].used) { continue; }
			int n = fmt::format_uint((uint)i, &nm[0]);
			nm[n] = 0;
			list_add(&buf[0], &count, &nm[0], true);
		}
	}
	else if (np.kind == F_IFDIR)
	{
		list_add(&buf[0], &count, "status", false);
	}
	else if (np.kind == F_PROTODIR)
	{
		list_add(&buf[0], &count, "clone", false);
		for (int i = 0; i < CONV_MAX; i++)
		{
			if (g_conv[i].state == C_FREE || g_conv[i].proto != np.proto) { continue; }
			int n = fmt::format_uint((uint)i, &nm[0]);
			nm[n] = 0;
			list_add(&buf[0], &count, &nm[0], true);
		}
	}
	else if (np.kind == F_CONVDIR)
	{
		list_add(&buf[0], &count, "ctl", false);
		list_add(&buf[0], &count, "data", false);
		list_add(&buf[0], &count, "local", false);
		list_add(&buf[0], &count, "remote", false);
		list_add(&buf[0], &count, "status", false);
		if (np.proto == IP_PROTO_TCP) { list_add(&buf[0], &count, "listen", false); }
	}
	else
	{
		put_le32(&buf[0], (uint)(-1));
		ipc_reply(to, verb, &buf[0], 4, gen);
		return;
	}
	// One page always holds everything here; honour the start index.
	if (start > 0)
	{
		int keep = count > (int)start ? count - (int)start : 0;
		// Overlapping, destination below source: a forward copy is safe.
		for (int b = 0; b < keep * (int)FS_LIST_ENTRY_SIZE; b++) { buf[4 + b] = buf[4 + (int)(start * FS_LIST_ENTRY_SIZE) + b]; }
		count = keep;
	}
	put_le32(&buf[0], (uint)(count));
	ipc_reply(to, verb, &buf[0], 4 + count * (int)FS_LIST_ENTRY_SIZE, gen);
}

// Take one file request off the inbox, if there is one. false = none.
fn bool net_serve_one()
{
	uint verb = 0;
	int from = ipc_poll_type(&g_req[0], FS_MSG_MAX, &verb);
	if (from <= 0) { return false; }
	uint gen = 0;
	int uid = 0;
	proc_info(from, null, &gen, &uid);
	g_now = rdtime();

	char[100] path;
	mem::copy(&path[0], &g_req[0], 100);
	path[99] = 0;
	uint len = get_le32(&g_req[100]);
	uint off = get_le32(&g_req[104]);
	Npath np = net_parse(&path[0]);

	if (verb == FS_LIST) { net_list(&np, off, from, gen, verb); return true; }

	if (verb == FS_STAT)
	{
		int r = np.kind == F_NONE ? -1 : 0;
		bool dir = np.kind == F_ROOTDIR || np.kind == F_PROTODIR || np.kind == F_CONVDIR
			|| np.kind == F_IPIFCDIR || np.kind == F_IFDIR;
		put_le32(&g_reply[4], (uint)(0));
		g_reply[8] = dir ? 1 : 0;
		g_reply[9] = 0;
		reply_int(from, gen, verb, r, 6);
		return true;
	}

	if (verb == FS_READ || verb == FS_READ_AT)
	{
		if (verb == FS_READ) { off = 0; }
		if (np.kind == F_CLONE)
		{
			if (off > 0) { reply_int(from, gen, verb, 0, 0); return true; }
			int c = conv_alloc(np.proto, from);
			if (c < 0) { reply_int(from, gen, verb, -1, 0); return true; }
			int n = fmt::format_uint((uint)c, &g_reply[4]);
			g_reply[4 + n] = '\n';
			reply_int(from, gen, verb, n + 1, (uint)(n + 1));
			return true;
		}
		if (np.conv >= 0 && !may_use(&g_conv[np.conv], uid)) { reply_int(from, gen, verb, -1, 0); return true; }
		if (np.kind == F_DATA)
		{
			int r = conv_read_now(np.conv, len);
			if (r == NET_RETRY) { pend_add(PEND_DATA, from, gen, verb, np.conv, len); return true; }
			reply_int(from, gen, verb, r, r > 0 ? (uint)r : 0);
			return true;
		}
		if (np.kind == F_LISTEN)
		{
			int r = tcp_accept(np.conv, from);
			if (r == NET_RETRY) { pend_add(PEND_LISTEN, from, gen, verb, np.conv, 0); return true; }
			if (r < 0) { reply_int(from, gen, verb, -1, 0); return true; }
			int n = fmt::format_uint((uint)r, &g_reply[4]);
			g_reply[4 + n] = '\n';
			reply_int(from, gen, verb, n + 1, (uint)(n + 1));
			return true;
		}
		char[1024] txt;
		int tn = np.kind == F_NONE ? -1 : text_file(&np, &txt[0]);
		if (tn < 0) { reply_int(from, gen, verb, -1, 0); return true; }
		uint avail = off < (uint)tn ? (uint)tn - off : 0;
		if (avail > len) { avail = len; }
		mem::copy(&g_reply[4], &txt[off], (sz)avail);
		reply_int(from, gen, verb, (int)avail, avail);
		return true;
	}

	if (verb == FS_WRITE || verb == FS_WRITE_AT)
	{
		char* data = verb == FS_WRITE ? &g_req[104] : &g_req[108];
		if (len > FS_MSG_MAX - 108) { len = FS_MSG_MAX - 108; }
		if (np.conv < 0 || !may_use(&g_conv[np.conv], uid)) { reply_int(from, gen, verb, -1, 0); return true; }
		Conv* c = &g_conv[np.conv];
		int r = -1;
		if (np.kind == F_CTL)
		{
			if (len >= 3 && data[0] == 'o' && data[1] == 'w' && data[2] == 'n')
			{
				c.owner_pid = from;
				c.owner_gen = gen;
				c.owner_uid = uid;
				r = 0;
			}
			else
			{
				r = conv_ctl(np.conv, data, len);
			}
			if (r == 0) { r = (int)len; }
		}
		else if (np.kind == F_DATA)
		{
			if (c.proto == IP_PROTO_TCP)
			{
				r = tcp_write(np.conv, data, len);
			}
			else if (c.proto == IP_PROTO_ICMP)
			{
				r = icmp_output(c, np.conv, data, len) ? (int)len : -1;
			}
			else if (c.headers)
			{
				if (len >= 6)
				{
					uint to_ip = read_be32(&data[0]);
					uint to_port = read_be16(&data[4]);
					if (c.lport == 0) { c.lport = ephemeral_port(IP_PROTO_UDP); }
					r = udp_output(c, to_ip, to_port, &data[6], len - 6) ? (int)len : -1;
				}
			}
			else if (c.state == C_CONNECTED)
			{
				r = udp_output(c, c.raddr, c.rport, data, len) ? (int)len : -1;
			}
		}
		reply_int(from, gen, verb, r, 0);
		return true;
	}

	reply_int(from, gen, verb, -1, 0);
	return true;
}
