module user;

import std::nolibc::mem;

// ipd's TCP (RFC 793 / 1122 / 6298, kept small).
//
// One control block per connection or listener, 8 KiB send and receive
// buffers each. In-order receive only (an out-of-order segment is dropped
// and re-ACKed — the peer's retransmit fills the hole); go-back-N
// retransmission from snd_una on an RTO; RTO from Jacobson/Karels with
// Karn's rule, 200 ms floor, doubled per timeout, the connection reset
// after TCP_MAX_RETRIES. No SACK, no window scaling, no Nagle, no delayed
// ACK (every data segment is ACKed at once), no urgent data. MSS 1460
// advertised; the peer's MSS option is honoured.
//
// A listener's incoming connections get their own conversations at SYN
// time (owned, at first, by the listener's owner) and wait in its accept
// queue until established and read from /net/tcp/<n>/listen. Hanging up
// (or the owner dying) sends a FIN and lets the control block finish the
// close on its own; the conversation is free at once.

const int TCB_MAX = 32;
const uint TCP_BUF = 8192;
const uint TCP_MSS = 1460;
const int TCP_MAX_RETRIES = 8;
const int ACCEPT_Q = 8;

const int T_CLOSED      = 0;
const int T_LISTEN      = 1;
const int T_SYN_SENT    = 2;
const int T_SYN_RCVD    = 3;
const int T_ESTABLISHED = 4;
const int T_FIN_WAIT1   = 5;
const int T_FIN_WAIT2   = 6;
const int T_CLOSE_WAIT  = 7;
const int T_CLOSING     = 8;
const int T_LAST_ACK    = 9;
const int T_TIME_WAIT   = 10;

const uint TH_FIN = 0x01;
const uint TH_SYN = 0x02;
const uint TH_RST = 0x04;
const uint TH_PSH = 0x08;
const uint TH_ACK = 0x10;

struct Tcb
{
	bool  used;
	int   state;
	int   conv;          // -1 once the conversation hung up (finishing the close alone)
	int   listener;      // conv of the listener a SYN_RCVD/accepted connection came from, -1
	uint  laddr;
	uint  lport;
	uint  raddr;
	uint  rport;
	uint  iss;
	uint  snd_una;
	uint  snd_nxt;
	uint  snd_wnd;
	uint  rcv_nxt;
	uint  mss;
	char* sbuf;          // bytes from snd_una on, slen of them
	uint  slen;
	char* rbuf;          // ring
	uint  rhead;
	uint  rlen;
	bool  fin_rcvd;
	bool  want_fin;      // close requested: send FIN after the buffered data
	bool  fin_sent;
	bool  reset;         // ended by RST / retry exhaustion: reads fail
	bool  accepted;      // handed out through listen already
	ulong rto;
	ulong srtt;
	ulong rttvar;
	bool  rtt_valid;
	bool  timing;
	uint  rtt_seq;
	ulong rtt_start;
	ulong rtx_due;       // 0 = timer off
	int   retries;
	ulong tw_due;
	int[ACCEPT_Q] aq;    // listener: accepted-to-be conversations
	int   aq_n;
	ulong segs_in;
	ulong segs_out;
	ulong retransmits;
}

Tcb[TCB_MAX] g_tcb;

fn bool seq_lt(uint a, uint b) { return (int)(a - b) < 0; }
fn bool seq_le(uint a, uint b) { return (int)(a - b) <= 0; }

fn void tcp_init()
{
	char* pool = (char*)map_pages((ulong)TCB_MAX * (ulong)TCP_BUF * 2);
	for (int i = 0; i < TCB_MAX; i++)
	{
		g_tcb[i].used = false;
		g_tcb[i].sbuf = pool + (uptr)i * TCP_BUF * 2;
		g_tcb[i].rbuf = pool + (uptr)i * TCP_BUF * 2 + TCP_BUF;
	}
}

fn char* tcp_state_name(int t)
{
	switch (g_tcb[t].state)
	{
		case T_LISTEN:      return "Listen";
		case T_SYN_SENT:    return "Syn_sent";
		case T_SYN_RCVD:    return "Syn_received";
		case T_ESTABLISHED: return "Established";
		case T_FIN_WAIT1:   return "Finwait1";
		case T_FIN_WAIT2:   return "Finwait2";
		case T_CLOSE_WAIT:  return "Close_wait";
		case T_CLOSING:     return "Closing";
		case T_LAST_ACK:    return "Last_ack";
		case T_TIME_WAIT:   return "Time_wait";
		default:            return "Closed";
	}
}

fn int tcb_alloc()
{
	for (int i = 0; i < TCB_MAX; i++)
	{
		Tcb* t = &g_tcb[i];
		if (t.used) { continue; }
		char* sb = t.sbuf;
		char* rb = t.rbuf;
		mem::set(t, 0, Tcb::size);
		t.sbuf = sb;
		t.rbuf = rb;
		t.used = true;
		t.conv = -1;
		t.listener = -1;
		t.mss = 536;
		t.rto = g_hz;          // 1 s until the first RTT sample
		t.snd_wnd = TCP_BUF;
		return i;
	}
	return -1;
}

fn void tcb_free(int i)
{
	Tcb* t = &g_tcb[i];
	if (t.conv >= 0)
	{
		Conv* c = &g_conv[t.conv];
		if (c.tcb == i)
		{
			c.tcb = -1;
			if (c.state != C_RESET) { c.state = C_CLOSED; }
		}
	}
	t.used = false;
}

// The connection is over (TIME_WAIT done, our FIN acknowledged in
// LAST_ACK). Received bytes nobody has read yet must survive that: keep
// the block, CLOSED, until tcp_read has drained it. Freeing it here was
// a real bug — a slow reader (nc writing one byte at a time into a pipe)
// lost the tail of a transfer when TIME_WAIT expired under it.
fn void tcb_finish(int ti)
{
	Tcb* t = &g_tcb[ti];
	t.state = T_CLOSED;
	t.rtx_due = 0;
	if (t.conv >= 0 && t.rlen > 0) { return; }
	tcb_free(ti);
}

fn ushort tcp_checksum(uint src, uint dst, char* seg, uint len)
{
	char[12] pseudo;
	write_be32(&pseudo[0], src);
	write_be32(&pseudo[4], dst);
	pseudo[8] = 0;
	pseudo[9] = (char)IP_PROTO_TCP;
	write_be16(&pseudo[10], (ushort)len);
	return checksum_finalize(checksum_partial_sum(&pseudo[0], 12) + checksum_partial_sum(seg, len));
}

fn uint tcp_rwnd(Tcb* t) { return TCP_BUF - t.rlen; }

// Send one segment. `data` may be null for a bare control segment.
fn void tcp_send(Tcb* t, uint flags, uint seq, char* data, uint len)
{
	char[1500] seg @noinit;
	uint hl = 20;
	if (flags & TH_SYN)
	{
		seg[20] = 2; seg[21] = 4;        // MSS option
		write_be16(&seg[22], (ushort)TCP_MSS);
		hl = 24;
	}
	write_be16(&seg[0], (ushort)t.lport);
	write_be16(&seg[2], (ushort)t.rport);
	write_be32(&seg[4], seq);
	write_be32(&seg[8], (flags & TH_ACK) ? t.rcv_nxt : 0);
	seg[12] = (char)((hl / 4) << 4);
	seg[13] = (char)flags;
	uint w = tcp_rwnd(t);
	write_be16(&seg[14], (ushort)(w > 65535 ? 65535 : w));
	write_be16(&seg[16], 0);
	write_be16(&seg[18], 0);
	if (len > 0) { mem::copy(&seg[hl], data, (sz)len); }
	write_be16(&seg[16], tcp_checksum(t.laddr, t.raddr, &seg[0], hl + len));
	t.segs_out++;
	ip_output(t.laddr, t.raddr, IP_PROTO_TCP, &seg[0], hl + len);
}

// A reset in answer to a segment that matches no connection.
fn void tcp_send_rst_for(uint src, uint dst, uint sport, uint dport, uint seq, uint ack, uint flags, uint seglen)
{
	if (flags & TH_RST) { return; }
	Tcb tmp;
	mem::set(&tmp, 0, Tcb::size);
	tmp.laddr = dst; tmp.lport = dport; tmp.raddr = src; tmp.rport = sport;
	if (flags & TH_ACK)
	{
		tcp_send(&tmp, TH_RST, ack, null, 0);
	}
	else
	{
		tmp.rcv_nxt = seq + seglen + ((flags & TH_SYN) ? 1 : 0) + ((flags & TH_FIN) ? 1 : 0);
		tcp_send(&tmp, TH_RST | TH_ACK, 0, null, 0);
	}
}

// An abnormal end (reset received or sent, retries exhausted): say so —
// it lands in the console / dmesg, which is how a dropped connection
// gets diagnosed.
fn void tcp_died(int ti, char* why)
{
	Tcb* t = &g_tcb[ti];
	print("ipd: tcp ");
	print_uint(t.lport);
	print(" <-> ");
	print_ip(t.raddr);
	print("!");
	print_uint(t.rport);
	print(" ");
	print(why);
	print("\n");
	t.reset = true;
	t.state = T_CLOSED;
	if (t.conv >= 0) { g_conv[t.conv].state = C_RESET; }
	tcb_free(ti);
}

fn void tcp_arm_rtx(Tcb* t)
{
	t.rtx_due = g_now + t.rto;
}

// Send whatever the window and the buffer allow, then the FIN if one is
// due.
fn void tcp_output(int ti)
{
	Tcb* t = &g_tcb[ti];
	if (t.state != T_ESTABLISHED && t.state != T_CLOSE_WAIT && t.state != T_FIN_WAIT1
		&& t.state != T_CLOSING && t.state != T_LAST_ACK) { return; }
	for (;;)
	{
		uint sent = t.snd_nxt - t.snd_una;           // includes a sent FIN
		uint data_sent = t.fin_sent ? sent - 1 : sent;
		if (data_sent >= t.slen) { break; }
		uint wnd = t.snd_wnd;
		if (sent >= wnd) { break; }
		uint n = t.slen - data_sent;
		if (n > wnd - sent) { n = wnd - sent; }
		if (n > t.mss) { n = t.mss; }
		if (n == 0) { break; }
		if (!t.timing) { t.timing = true; t.rtt_seq = t.snd_nxt + n; t.rtt_start = g_now; }
		tcp_send(t, TH_ACK | TH_PSH, t.snd_nxt, &t.sbuf[data_sent], n);
		t.snd_nxt += n;
		if (t.rtx_due == 0) { tcp_arm_rtx(t); }
	}
	if (t.want_fin && !t.fin_sent && t.snd_nxt - t.snd_una == t.slen)
	{
		tcp_send(t, TH_FIN | TH_ACK, t.snd_nxt, null, 0);
		t.snd_nxt++;
		t.fin_sent = true;
		if (t.state == T_ESTABLISHED) { t.state = T_FIN_WAIT1; }
		else if (t.state == T_CLOSE_WAIT) { t.state = T_LAST_ACK; }
		if (t.rtx_due == 0) { tcp_arm_rtx(t); }
	}
}

fn void tcp_rtt_sample(Tcb* t, ulong r)
{
	if (!t.rtt_valid)
	{
		t.srtt = r;
		t.rttvar = r / 2;
		t.rtt_valid = true;
	}
	else
	{
		ulong d = r > t.srtt ? r - t.srtt : t.srtt - r;
		t.rttvar = (3 * t.rttvar + d) / 4;
		t.srtt = (7 * t.srtt + r) / 8;
	}
	t.rto = t.srtt + 4 * t.rttvar;
	if (t.rto < ms_ticks(200)) { t.rto = ms_ticks(200); }
	if (t.rto > g_hz * 60) { t.rto = g_hz * 60; }
}

// Our data (and/or SYN/FIN) up to `ack` reached the peer.
fn void tcp_acked(Tcb* t, uint ack)
{
	uint n = ack - t.snd_una;
	if (n == 0) { return; }
	// A SYN or FIN takes a sequence number but no buffer byte.
	uint bytes = n;
	if (t.state == T_SYN_SENT || t.state == T_SYN_RCVD) { bytes = bytes > 0 ? bytes - 1 : 0; }
	if (t.fin_sent && ack == t.snd_nxt && bytes > 0) { bytes--; }
	if (bytes > t.slen) { bytes = t.slen; }
	if (bytes > 0)
	{
		for (uint i = 0; i + bytes < t.slen; i++) { t.sbuf[i] = t.sbuf[i + bytes]; }
		t.slen -= bytes;
	}
	t.snd_una = ack;
	if (t.timing && seq_le(t.rtt_seq, ack))
	{
		t.timing = false;
		if (t.retries == 0) { tcp_rtt_sample(t, g_now - t.rtt_start); } // Karn: no sample from a retransmit
	}
	t.retries = 0;
	t.rtx_due = t.snd_una == t.snd_nxt ? 0 : g_now + t.rto;
}

fn int tcb_lookup(uint src, uint dst, uint sport, uint dport)
{
	int listener = -1;
	for (int i = 0; i < TCB_MAX; i++)
	{
		Tcb* t = &g_tcb[i];
		if (!t.used || t.lport != dport || t.state == T_CLOSED) { continue; }
		if (t.state == T_LISTEN) { if (listener < 0) { listener = i; } continue; }
		if (t.rport == sport && t.raddr == src && (t.laddr == dst || t.laddr == 0)) { return i; }
	}
	return listener;
}

fn void tcp_input(uint src, uint dst, char* seg, uint len)
{
	if (len < 20 || tcp_checksum(src, dst, seg, len) != 0) { return; }
	uint sport = read_be16(&seg[0]);
	uint dport = read_be16(&seg[2]);
	uint seq = read_be32(&seg[4]);
	uint ack = read_be32(&seg[8]);
	uint hl = (((uint)seg[12] >> 4) & 0xF) * 4;
	uint flags = (uint)seg[13] & 0x3F;
	uint wnd = read_be16(&seg[14]);
	if (hl < 20 || hl > len) { return; }
	char* data = &seg[hl];
	uint dlen = len - hl;
	uint peer_mss = 0;
	for (uint o = 20; o + 1 < hl; )
	{
		uint kind = (uint)seg[o] & 0xFF;
		if (kind == 0) { break; }
		if (kind == 1) { o++; continue; }
		uint olen = (uint)seg[o + 1] & 0xFF;
		if (olen < 2 || o + olen > hl) { break; }
		if (kind == 2 && olen == 4) { peer_mss = read_be16(&seg[o + 2]); }
		o += olen;
	}

	int ti = tcb_lookup(src, dst, sport, dport);
	if (ti < 0) { tcp_send_rst_for(src, dst, sport, dport, seq, ack, flags, dlen); return; }
	Tcb* t = &g_tcb[ti];
	t.segs_in++;

	if (t.state == T_LISTEN)
	{
		if (flags & TH_RST) { return; }
		if (flags & TH_ACK) { tcp_send_rst_for(src, dst, sport, dport, seq, ack, flags, dlen); return; }
		if ((flags & TH_SYN) == 0) { return; }
		Tcb* lt = t;
		if (lt.aq_n >= ACCEPT_Q) { return; }      // backlog full: let the peer retry the SYN
		int lconv = lt.conv;
		if (lconv < 0) { return; }
		int ci = conv_alloc(IP_PROTO_TCP, g_conv[lconv].owner_pid);
		if (ci < 0) { return; }
		int ni = tcb_alloc();
		if (ni < 0) { g_conv[ci].state = C_FREE; return; }
		Tcb* nt = &g_tcb[ni];
		Conv* nc = &g_conv[ci];
		nc.owner_uid = g_conv[lconv].owner_uid;
		nc.state = C_CONNECTED;
		nc.tcb = ni;
		nc.laddr = dst; nc.lport = dport; nc.raddr = src; nc.rport = sport;
		nt.conv = ci;
		nt.listener = lconv;
		nt.laddr = dst; nt.lport = dport; nt.raddr = src; nt.rport = sport;
		nt.rcv_nxt = seq + 1;
		nt.iss = (uint)rdtime() ^ 0x5bd1e995;
		nt.snd_una = nt.iss;
		nt.snd_nxt = nt.iss + 1;
		nt.snd_wnd = wnd;
		if (peer_mss != 0) { nt.mss = peer_mss < TCP_MSS ? peer_mss : TCP_MSS; }
		nt.state = T_SYN_RCVD;
		tcp_send(nt, TH_SYN | TH_ACK, nt.iss, null, 0);
		tcp_arm_rtx(nt);
		lt.aq[lt.aq_n] = ci;
		lt.aq_n++;
		return;
	}

	if (t.state == T_SYN_SENT)
	{
		if ((flags & TH_ACK) && (seq_le(ack, t.iss) || seq_lt(t.snd_nxt, ack)))
		{
			if ((flags & TH_RST) == 0) { tcp_send_rst_for(src, dst, sport, dport, seq, ack, flags, dlen); }
			return;
		}
		if (flags & TH_RST)
		{
			if (flags & TH_ACK) { tcp_died(ti, "refused"); }
			return;
		}
		if ((flags & TH_SYN) == 0) { return; }
		t.rcv_nxt = seq + 1;
		t.snd_wnd = wnd;
		if (peer_mss != 0) { t.mss = peer_mss < TCP_MSS ? peer_mss : TCP_MSS; }
		if (flags & TH_ACK)
		{
			tcp_acked(t, ack);
			t.state = T_ESTABLISHED;
			tcp_send(t, TH_ACK, t.snd_nxt, null, 0);
			tcp_output(ti);
		}
		else
		{
			t.state = T_SYN_RCVD;                     // simultaneous open
			tcp_send(t, TH_SYN | TH_ACK, t.iss, null, 0);
		}
		return;
	}

	// Synchronized states. Acceptability: the segment must start at (or
	// overlap) rcv_nxt; anything else is answered with an ACK and dropped.
	if (t.state == T_TIME_WAIT && (flags & TH_FIN)) { tcp_send(t, TH_ACK, t.snd_nxt, null, 0); t.tw_due = g_now + g_hz * 2; return; }
	bool in_window = seq == t.rcv_nxt || (dlen > 0 && seq_lt(seq, t.rcv_nxt) && seq_lt(t.rcv_nxt, seq + dlen));
	if (!in_window && !(dlen == 0 && seq_le(seq, t.rcv_nxt)))
	{
		if ((flags & TH_RST) == 0) { tcp_send(t, TH_ACK, t.snd_nxt, null, 0); }
		return;
	}
	if (flags & TH_RST)
	{
		tcp_died(ti, "reset by peer");
		return;
	}
	if (flags & TH_SYN)
	{
		tcp_send(t, TH_RST, t.snd_nxt, null, 0);      // a SYN inside a connection: reset it
		tcp_died(ti, "reset: SYN inside the connection");
		return;
	}
	if ((flags & TH_ACK) == 0) { return; }

	if (t.state == T_SYN_RCVD)
	{
		if (seq_lt(t.snd_una, ack) && seq_le(ack, t.snd_nxt))
		{
			tcp_acked(t, ack);
			t.state = T_ESTABLISHED;
		}
		else
		{
			tcp_send_rst_for(src, dst, sport, dport, seq, ack, flags, dlen);
			return;
		}
	}
	else if (seq_lt(t.snd_una, ack) && seq_le(ack, t.snd_nxt))
	{
		tcp_acked(t, ack);
	}
	t.snd_wnd = wnd;

	// Our FIN acknowledged?
	if (t.fin_sent && t.snd_una == t.snd_nxt)
	{
		if (t.state == T_FIN_WAIT1) { t.state = T_FIN_WAIT2; }
		else if (t.state == T_CLOSING) { t.state = T_TIME_WAIT; t.tw_due = g_now + g_hz * 2; }
		else if (t.state == T_LAST_ACK) { tcb_finish(ti); return; }
	}

	// Payload (in order only; trim what we already have).
	bool ack_now = false;
	if (dlen > 0 && (t.state == T_ESTABLISHED || t.state == T_FIN_WAIT1 || t.state == T_FIN_WAIT2))
	{
		uint skip = t.rcv_nxt - seq;
		if (skip < dlen)
		{
			uint n = dlen - skip;
			uint room = tcp_rwnd(t);
			if (n > room) { n = room; }
			for (uint i = 0; i < n; i++) { t.rbuf[(t.rhead + t.rlen + i) % TCP_BUF] = data[skip + i]; }
			t.rlen += n;
			t.rcv_nxt += n;
			if (t.conv >= 0) { g_conv[t.conv].rx_pkts++; }
			if (skip + n < dlen) { flags &= ~TH_FIN; }   // a FIN beyond what we kept isn't ours yet
		}
		ack_now = true;
	}
	if ((flags & TH_FIN) && seq + dlen == t.rcv_nxt)
	{
		t.rcv_nxt++;
		t.fin_rcvd = true;
		ack_now = true;
		if (t.state == T_ESTABLISHED || t.state == T_SYN_RCVD) { t.state = T_CLOSE_WAIT; }
		else if (t.state == T_FIN_WAIT1) { t.state = t.snd_una == t.snd_nxt ? T_TIME_WAIT : T_CLOSING; t.tw_due = g_now + g_hz * 2; }
		else if (t.state == T_FIN_WAIT2) { t.state = T_TIME_WAIT; t.tw_due = g_now + g_hz * 2; }
	}
	if (t.conv < 0 && dlen > 0)
	{
		// Nobody will read this any more: refuse it.
		tcp_send(t, TH_RST, t.snd_nxt, null, 0);
		tcp_died(ti, "reset: data after hangup");
		return;
	}
	if (ack_now) { tcp_send(t, TH_ACK, t.snd_nxt, null, 0); }
	tcp_output(ti);
}

fn void tcp_timers()
{
	for (int i = 0; i < TCB_MAX; i++)
	{
		Tcb* t = &g_tcb[i];
		if (!t.used) { continue; }
		if (t.state == T_TIME_WAIT)
		{
			if (g_now >= t.tw_due) { tcb_finish(i); }
			continue;
		}
		if (t.state == T_CLOSED)
		{
			// Finished, waiting for its reader to drain it (tcb_finish);
			// gone once the reader is too.
			if (t.conv < 0 || t.rlen == 0) { tcb_free(i); }
			continue;
		}
		if (t.rtx_due == 0 || g_now < t.rtx_due) { continue; }
		t.retries++;
		t.retransmits++;
		if (t.retries > TCP_MAX_RETRIES)
		{
			if (t.state != T_SYN_SENT) { tcp_send(t, TH_RST, t.snd_nxt, null, 0); }
			tcp_died(i, "timed out");
			continue;
		}
		t.rto = t.rto * 2;
		if (t.rto > g_hz * 60) { t.rto = g_hz * 60; }
		t.timing = false;
		if (t.state == T_SYN_SENT)
		{
			tcp_send(t, TH_SYN, t.iss, null, 0);
		}
		else if (t.state == T_SYN_RCVD)
		{
			tcp_send(t, TH_SYN | TH_ACK, t.iss, null, 0);
		}
		else
		{
			// Go back to the oldest unacknowledged byte and resend from there.
			// A closed window gets a one-byte probe.
			t.snd_nxt = t.snd_una;
			if (t.fin_sent) { t.fin_sent = false; }
			uint saved = t.snd_wnd;
			if (t.snd_wnd == 0) { t.snd_wnd = 1; }
			tcp_output(i);
			t.snd_wnd = saved;
		}
		t.rtx_due = g_now + t.rto;
	}
}

// --- the conversation side -------------------------------------------

fn int tcp_connect(int ci)
{
	Conv* c = &g_conv[ci];
	if (c.tcb >= 0) { return -1; }
	int ti = tcb_alloc();
	if (ti < 0) { return -1; }
	Tcb* t = &g_tcb[ti];
	t.conv = ci;
	t.laddr = c.laddr;
	t.lport = c.lport;
	t.raddr = c.raddr;
	t.rport = c.rport;
	t.iss = (uint)rdtime() ^ 0x5bd1e995;
	t.snd_una = t.iss;
	t.snd_nxt = t.iss + 1;
	t.state = T_SYN_SENT;
	c.tcb = ti;
	c.state = C_CONNECTED;
	tcp_send(t, TH_SYN, t.iss, null, 0);
	tcp_arm_rtx(t);
	return 0;
}

fn int tcp_listen(int ci)
{
	Conv* c = &g_conv[ci];
	if (c.tcb >= 0) { return -1; }
	int ti = tcb_alloc();
	if (ti < 0) { return -1; }
	Tcb* t = &g_tcb[ti];
	t.conv = ci;
	t.lport = c.lport;
	t.state = T_LISTEN;
	c.tcb = ti;
	return 0;
}

// Hand out an established connection from listener `ci`'s queue, now
// owned by `pid`. NET_RETRY if none is ready yet, -1 if `ci` isn't
// listening.
fn int tcp_accept(int ci, int pid)
{
	Conv* c = &g_conv[ci];
	if (c.tcb < 0 || g_tcb[c.tcb].state != T_LISTEN) { return -1; }
	Tcb* lt = &g_tcb[c.tcb];
	for (int k = 0; k < lt.aq_n; k++)
	{
		int nc = lt.aq[k];
		Conv* x = &g_conv[nc];
		bool ready = x.state != C_FREE && x.tcb >= 0 && g_tcb[x.tcb].state != T_SYN_RCVD;
		bool dead = x.state == C_FREE || x.tcb < 0;
		if (!ready && !dead) { continue; }
		for (int j = k; j + 1 < lt.aq_n; j++) { lt.aq[j] = lt.aq[j + 1]; }
		lt.aq_n--;
		if (dead) { k--; continue; }
		uint g = 0;
		int u = 0;
		proc_info(pid, null, &g, &u);
		x.owner_pid = pid;
		x.owner_gen = g;
		x.owner_uid = u;
		g_tcb[x.tcb].accepted = true;
		return nc;
	}
	return NET_RETRY;
}

// Read up to `max` bytes. 0 = the peer closed (EOF), -1 = reset or not
// connected, NET_RETRY = nothing yet.
fn int tcp_read(int ci, char* out, uint max)
{
	Conv* c = &g_conv[ci];
	if (c.tcb < 0) { return c.state == C_CLOSED ? 0 : -1; }   // C_RESET: -1
	Tcb* t = &g_tcb[c.tcb];
	if (t.rlen == 0)
	{
		if (t.reset) { return -1; }
		if (t.state == T_CLOSED) { tcb_free(c.tcb); return 0; }
		if (t.fin_rcvd) { return 0; }
		return NET_RETRY;
	}
	bool was_small = tcp_rwnd(t) < t.mss;
	uint n = t.rlen < max ? t.rlen : max;
	for (uint i = 0; i < n; i++) { out[i] = t.rbuf[(t.rhead + i) % TCP_BUF]; }
	t.rhead = (t.rhead + n) % TCP_BUF;
	t.rlen -= n;
	// The window just reopened from almost shut: tell the peer.
	if (was_small && tcp_rwnd(t) >= t.mss && t.state != T_SYN_SENT) { tcp_send(t, TH_ACK, t.snd_nxt, null, 0); }
	return (int)n;
}

// Queue up to `len` bytes for sending. Returns how many were taken (0 =
// the send buffer is full — retry), -1 if the connection can't send.
fn int tcp_write(int ci, char* data, uint len)
{
	Conv* c = &g_conv[ci];
	if (c.tcb < 0) { return -1; }
	Tcb* t = &g_tcb[c.tcb];
	if (t.reset || t.want_fin) { return -1; }
	if (t.state != T_ESTABLISHED && t.state != T_CLOSE_WAIT && t.state != T_SYN_SENT && t.state != T_SYN_RCVD) { return -1; }
	uint room = TCP_BUF - t.slen;
	uint n = len < room ? len : room;
	mem::copy(&t.sbuf[t.slen], data, (sz)n);
	t.slen += n;
	tcp_output(c.tcb);
	return (int)n;
}

// The conversation is going away (hangup, or its owner died): finish the
// close in the background. A listener just stops.
fn void tcp_abort(int ti)
{
	Tcb* t = &g_tcb[ti];
	t.conv = -1;
	if (t.state == T_LISTEN || t.state == T_SYN_SENT) { t.state = T_CLOSED; tcb_free(ti); return; }
	if (t.state == T_SYN_RCVD || t.state == T_ESTABLISHED || t.state == T_CLOSE_WAIT)
	{
		t.want_fin = true;
		tcp_output(ti);
	}
}

// ctl "close": half-close — send FIN after the buffered data, keep reading.
fn int tcp_shutdown(int ci)
{
	Conv* c = &g_conv[ci];
	if (c.tcb < 0) { return -1; }
	g_tcb[c.tcb].want_fin = true;
	tcp_output(c.tcb);
	return 0;
}
