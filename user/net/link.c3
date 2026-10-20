module user;

import std::nolibc::mem;

// Network link rings — how a link driver (netd, ethd, the Wi-Fi driver in
// usbd) and the IP stack (ipd) exchange Ethernet frames.
//
// Each link is a named shared segment, "ether<N>" (src/segment.c3): a
// header page, then two single-producer/single-consumer rings of
// LINK_SLOTS fixed slots. RX carries frames driver -> ipd, TX ipd ->
// driver. A producer fills the slot at `head`, publishes it by bumping
// `head`, and rings the consumer's doorbell (wake(), SYS_WAKE); the
// consumer drains from `tail` and bumps it. Neither side ever blocks on
// the other — plain IPC both ways would deadlock the moment ipd sends a
// TX frame while the driver sends an RX frame — and the frames never
// pass through the kernel.
//
// The driver creates the segment and fills in the MAC / link state /
// its own pid; ipd attaches by name and fills in its pid. A respawned
// driver re-attaches the same segment (ipd's attachment keeps it alive)
// and just writes its new pid. Indices only ever grow; a slot is
// `index % LINK_SLOTS`. Both sides run on one hart today; the fences
// order the slot write before the index publish for when they don't.

const uint LINK_MAGIC     = 0x4b4e494c; // "LINK"
const uint LINK_SLOTS     = 32;
const uint LINK_SLOT_SIZE = 2048;
const uint LINK_FRAME_MAX = LINK_SLOT_SIZE - 8;
const uint LINK_HDR_SIZE  = 4096;
const uint LINK_SEG_SIZE  = LINK_HDR_SIZE + 2 * LINK_SLOTS * LINK_SLOT_SIZE;

struct Link_hdr
{
	uint magic;
	uint mtu;
	char[8] mac;          // 6 used
	uint link_up;         // driver: 1 = carrier / associated
	int  driver_pid;
	uint driver_gen;
	int  ipd_pid;
	uint ipd_gen;
	uint rx_head;         // RX: driver produces
	uint rx_tail;         //     ipd consumes
	uint tx_head;         // TX: ipd produces
	uint tx_tail;         //     driver consumes
	uint rx_drops;        // RX ring full when the driver had a frame
	uint tx_drops;        // TX ring full when ipd had a frame
	char[16] name;        // "ether0" — for status files
}

struct Link_slot
{
	uint len;
	uint pad;
	char[LINK_FRAME_MAX] data;
}

struct Link
{
	Link_hdr*  h;
	Link_slot* rx;
	Link_slot* tx;
	bool       is_driver;
}

fn void link_bind(Link* l, char* base, bool is_driver)
{
	l.h = (Link_hdr*)base;
	l.rx = (Link_slot*)(base + LINK_HDR_SIZE);
	l.tx = (Link_slot*)(base + LINK_HDR_SIZE + LINK_SLOTS * LINK_SLOT_SIZE);
	l.is_driver = is_driver;
}

// Driver side: create (or, after a respawn, re-attach) segment `name`
// and publish this driver in it. Ring contents left by a previous
// driver instance are dropped.
fn bool link_create(Link* l, char* name, char* mac, uint mtu)
{
	char* base = segattach(name, LINK_SEG_SIZE);
	if (base == null) { return false; }
	link_bind(l, base, true);
	Link_hdr* h = l.h;
	h.mtu = mtu;
	for (int i = 0; i < 6; i++) { h.mac[i] = mac[i]; }
	int k = 0;
	for (; k < 15 && name[k] != 0; k++) { h.name[k] = name[k]; }
	h.name[k] = 0;
	h.rx_tail = h.rx_head;     // nothing pending from a previous life
	h.tx_tail = h.tx_head;
	uint g = 0;
	h.driver_pid = getpid();
	proc_info(h.driver_pid, null, &g, null);
	h.driver_gen = g;
	asm("fence");
	h.magic = LINK_MAGIC;
	return true;
}

// ipd side: attach an existing link segment. false if there's no such
// link (yet) or it isn't initialised.
fn bool link_attach(Link* l, char* name)
{
	char* base = segattach(name, 0);
	if (base == null) { return false; }
	link_bind(l, base, false);
	if (l.h.magic != LINK_MAGIC)
	{
		segdetach(base);
		return false;
	}
	uint g = 0;
	l.h.ipd_pid = getpid();
	proc_info(l.h.ipd_pid, null, &g, null);
	l.h.ipd_gen = g;
	return true;
}

// Queue one frame toward the peer: RX for a driver, TX for ipd. false =
// ring full (frame dropped, counted). Doesn't ring the doorbell — call
// link_kick once after a batch.
fn bool link_put(Link* l, char* frame, uint len)
{
	if (len > LINK_FRAME_MAX) { return false; }
	Link_hdr* h = l.h;
	uint* head = l.is_driver ? &h.rx_head : &h.tx_head;
	uint* tail = l.is_driver ? &h.rx_tail : &h.tx_tail;
	Link_slot* ring = l.is_driver ? l.rx : l.tx;
	if (*head - *tail >= LINK_SLOTS)
	{
		if (l.is_driver) { h.rx_drops++; } else { h.tx_drops++; }
		return false;
	}
	Link_slot* s = &ring[*head % LINK_SLOTS];
	mem::copy(&s.data[0], frame, (sz)len);
	s.len = len;
	asm("fence");
	*head = *head + 1;
	return true;
}

// Take one frame from the peer (TX for a driver, RX for ipd) into `out`
// (>= LINK_FRAME_MAX bytes). Returns its length, or -1 if none waiting.
fn int link_get(Link* l, char* out)
{
	Link_hdr* h = l.h;
	uint* head = l.is_driver ? &h.tx_head : &h.rx_head;
	uint* tail = l.is_driver ? &h.tx_tail : &h.rx_tail;
	Link_slot* ring = l.is_driver ? l.tx : l.rx;
	if (*tail == *head) { return -1; }
	asm("fence");
	Link_slot* s = &ring[*tail % LINK_SLOTS];
	uint len = s.len;
	if (len > LINK_FRAME_MAX) { len = 0; }
	mem::copy(out, &s.data[0], (sz)len);
	*tail = *tail + 1;
	return (int)len;
}

// Ring the peer's doorbell (no-op until the peer has attached).
fn void link_kick(Link* l)
{
	Link_hdr* h = l.h;
	if (l.is_driver)
	{
		if (h.ipd_pid > 0) { wake(h.ipd_pid, h.ipd_gen); }
	}
	else
	{
		if (h.driver_pid > 0) { wake(h.driver_pid, h.driver_gen); }
	}
}

fn bool link_pending(Link* l)
{
	Link_hdr* h = l.h;
	return l.is_driver ? h.tx_tail != h.tx_head : h.rx_tail != h.rx_head;
}
