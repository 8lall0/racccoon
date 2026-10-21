module user;

import std::nolibc::mem;

// WPA2-PSK for the RTL8192EU station (rtl8192eu.c3): the EAPOL-Key 4-way
// and group-key handshakes, and installing the keys into the chip's key
// CAM, which then does CCMP itself — on TX it encrypts and appends the
// MIC once we've put the 8-byte CCMP header (the packet number) after the
// 802.11 header; on RX it decrypts and leaves header + MIC for us to drop.
//
// Only what a home router speaks: RSN, CCMP pairwise and group, AKM PSK
// (00-0F-AC:2), key descriptor version 2 (HMAC-SHA1 MIC, AES key wrap),
// no management frame protection. The PMK (PBKDF2 of the passphrase over
// the SSID, 4096 rounds) is computed by /bin/wifi and handed over in the
// join request, so usbd never spends seconds in PBKDF2.
// Crypto primitives: user/crypto/crypto.c3.

const uint EAPOL_KEY_HDR = 99;          // 4 (802.1X) + 95 (key descriptor, through key-data length)
const uint WPA_INFO_VER_MASK  = 0x0007;
const uint WPA_INFO_PAIRWISE  = 0x0008;
const uint WPA_INFO_INSTALL   = 0x0040;
const uint WPA_INFO_ACK       = 0x0080;
const uint WPA_INFO_MIC       = 0x0100;
const uint WPA_INFO_SECURE    = 0x0200;
const uint WPA_INFO_ENC_DATA  = 0x1000;

// Our RSN IE: version 1, group CCMP, 1 pairwise CCMP, 1 AKM PSK, caps 0.
const char[22] WPA_RSN_IE = { 0x30, 20, 1, 0, 0x00, 0x0F, 0xAC, 4, 1, 0, 0x00, 0x0F, 0xAC, 4, 1, 0, 0x00, 0x0F, 0xAC, 2, 0, 0 };

char[32] g_wpa_pmk;
bool g_wpa_have_pmk;
char[48] g_wpa_ptk;        // KCK 0..15, KEK 16..31, TK 32..47
bool g_wpa_ptk_ok;         // derived from message 1 (not installed yet)
char[32] g_wpa_anonce;
char[32] g_wpa_snonce;
bool g_wpa_keyed;          // PTK + GTK in the CAM: data is CCMP from here on
uint g_wpa_gtk_idx;
ulong g_wpa_pn;            // our TX packet number
uint g_wpa_rand_ctr;
ulong g_wpa_handshakes;    // completed 4-ways (status)
ulong g_wpa_rekeys;        // group rekeys
uint g_wpa_mic_fail;       // message 3 MIC mismatches since the last join (wrong passphrase)

// 0 = we can join this RSN BSS, else why not (rtl_rsn_why_text).
fn uint rtl_rsn_check(char* p, uint l)
{
	if (l < 8) { return 5; }
	if ((uint)p[5] != 4) { return 1; }           // group cipher isn't CCMP (TKIP: WPA/WPA2 mixed mode)
	uint at = 6;
	uint pc = (uint)p[at] | ((uint)p[at + 1] << 8);
	at += 2;
	bool ccmp = false;
	for (uint i = 0; i < pc && at + 4 <= l; i++) { if ((uint)p[at + 3] == 4) { ccmp = true; } at += 4; }
	if (!ccmp) { return 2; }
	if (at + 2 > l) { return 3; }
	uint ac = (uint)p[at] | ((uint)p[at + 1] << 8);
	at += 2;
	bool psk = false;
	for (uint i = 0; i < ac && at + 4 <= l; i++) { if ((uint)p[at + 3] == 2) { psk = true; } at += 4; }
	if (!psk) { return 3; }
	if (at + 2 <= l && ((uint)p[at] & 0x40) != 0) { return 4; }   // MFP required
	return 0;
}

fn char* rtl_rsn_why_text(uint why)
{
	switch (why)
	{
		case 1: return "its group cipher is TKIP (set the router to WPA2/AES only)";
		case 2: return "it doesn't offer CCMP/AES";
		case 3: return "it isn't WPA2-Personal (WPA3-only or Enterprise)";
		case 4: return "it requires management frame protection (WPA3)";
		case 5: return "its RSN element is malformed";
		default: return "it uses WEP or WPA1";
	}
}

fn uint be16(char* p) { return ((uint)p[0] << 8) | (uint)p[1]; }
fn void put_be16(char* p, uint v) { p[0] = (char)(v >> 8); p[1] = (char)v; }

fn void wpa_reset()
{
	g_wpa_ptk_ok = false;
	g_wpa_keyed = false;
	g_wpa_pn = 1;
}

// 32 bytes that aren't predictable from outside: the timer, our MAC, the
// AP's nonce and a counter through SHA-1. Not a CSPRNG; good enough for a
// nonce that only has to be fresh.
fn void wpa_random(char* out32)
{
	for (uint half = 0; half < 2; half++)
	{
		char[64] seed;
		ulong t = rdtime();
		for (uint i = 0; i < 8; i++) { seed[i] = (char)(t >> (i * 8)); }
		for (uint i = 0; i < 6; i++) { seed[8 + i] = g_rtl_mac[i]; }
		g_wpa_rand_ctr++;
		seed[14] = (char)g_wpa_rand_ctr; seed[15] = (char)(g_wpa_rand_ctr >> 8);
		for (uint i = 0; i < 32; i++) { seed[16 + i] = g_wpa_anonce[i]; }
		for (uint i = 0; i < 16; i++) { seed[48 + i] = g_wpa_ptk[i] ^ (char)rdtime(); }
		char[20] h;
		sha1(&seed[0], 64, &h[0]);
		for (uint i = 0; i < 16; i++) { out32[half * 16 + i] = h[i]; }
	}
}

fn bool bytes_less(char* a, char* b, uint n)
{
	for (uint i = 0; i < n; i++)
	{
		if ((uint)a[i] != (uint)b[i]) { return (uint)a[i] < (uint)b[i]; }
	}
	return false;
}

// PTK = PRF-384(PMK, "Pairwise key expansion", min(AA,SPA) || max(AA,SPA) || min(ANonce,SNonce) || max(...))
fn void wpa_derive_ptk()
{
	char[76] d;
	char* aa = &g_sta_bssid[0];
	char* spa = &g_rtl_mac[0];
	bool al = bytes_less(aa, spa, 6);
	mem::copy(&d[0], al ? aa : spa, 6);
	mem::copy(&d[6], al ? spa : aa, 6);
	bool nl = bytes_less(&g_wpa_anonce[0], &g_wpa_snonce[0], 32);
	mem::copy(&d[12], nl ? &g_wpa_anonce[0] : &g_wpa_snonce[0], 32);
	mem::copy(&d[44], nl ? &g_wpa_snonce[0] : &g_wpa_anonce[0], 32);
	prf_sha1(&g_wpa_pmk[0], 32, "Pairwise key expansion", &d[0], 76, &g_wpa_ptk[0], 48);
	g_wpa_ptk_ok = true;
}

// MIC over an EAPOL frame of `len` bytes whose MIC field is zero.
fn void wpa_mic(char* frame, uint len, char* out16)
{
	char[20] h;
	hmac_sha1(&g_wpa_ptk[0], 16, frame, len, &h[0]);
	for (uint i = 0; i < 16; i++) { out16[i] = h[i]; }
}

fn bool wpa_mic_ok(char* e, uint len)
{
	if (len > 1600) { return false; }
	char[1600] c @noinit;
	mem::copy(&c[0], e, (sz)len);
	for (uint i = 0; i < 16; i++) { c[4 + 77 + i] = 0; }
	char[16] m;
	wpa_mic(&c[0], len, &m[0]);
	for (uint i = 0; i < 16; i++) { if (m[i] != e[4 + 77 + i]) { return false; } }
	return true;
}

// Build and send one EAPOL-Key frame to the AP.
fn void wpa_send_key(uint ver, uint info, char* replay, char* nonce, char* kd, uint kdlen)
{
	char[256] e;
	uint blen = 95 + kdlen;
	if (4 + blen > 256) { return; }
	for (uint i = 0; i < 4 + blen; i++) { e[i] = 0; }
	e[0] = (char)ver;
	e[1] = 3;                       // EAPOL-Key
	put_be16(&e[2], blen);
	char* b = &e[4];
	b[0] = 2;                       // RSN key descriptor
	put_be16(&b[1], info);
	mem::copy(&b[5], replay, 8);
	if (nonce != null) { mem::copy(&b[13], nonce, 32); }
	put_be16(&b[93], kdlen);
	if (kdlen > 0) { mem::copy(&b[95], kd, (sz)kdlen); }
	wpa_mic(&e[0], 4 + blen, &b[77]);
	rtl_send_data(&g_sta_bssid[0], &g_rtl_mac[0], 0x888E, &e[0], 4 + blen);
}

// Find the GTK KDE (dd len 00-0F-AC 01 keyid rsvd GTK) in decrypted key data.
fn bool wpa_find_gtk(char* kd, uint len, uint* idx_out, char* gtk16)
{
	uint at = 0;
	while (at + 2 <= len)
	{
		uint id = (uint)kd[at];
		uint l = (uint)kd[at + 1];
		if (id == 0xDD && l == 0) { break; }     // padding
		if (at + 2 + l > len) { break; }
		char* p = &kd[at + 2];
		if (id == 0xDD && l >= 6 + 16 && (uint)p[0] == 0x00 && (uint)p[1] == 0x0F && (uint)p[2] == 0xAC && (uint)p[3] == 1)
		{
			*idx_out = (uint)p[4] & 3;
			mem::copy(gtk16, &p[6], 16);
			return true;
		}
		at += 2 + l;
	}
	return false;
}

// Encrypted key data -> plaintext (AES key unwrap with the KEK). Returns
// the plaintext length, or -1.
fn int wpa_unwrap(char* kd, uint kdlen, char* out)
{
	if (kdlen < 24 || kdlen % 8 != 0 || kdlen > 512) { return -1; }
	if (!aes_key_unwrap(&g_wpa_ptk[16], kd, kdlen, out)) { return -1; }
	return (int)kdlen - 8;
}

// --- the key CAM -------------------------------------------------------

fn void rtl_cam_write(uint slot, uint keyidx, bool group, char* mac, char* key16)
{
	uint ctrl = (4u << 2) | keyidx | RTL_CAM_WRITE_VALID | (group ? 0x40u : 0u);   // 4 = CCMP
	for (int j = 5; j >= 0; j--)
	{
		uint v;
		if (j == 0) { v = ctrl | ((uint)mac[0] << 16) | ((uint)mac[1] << 24); }
		else if (j == 1) { v = (uint)mac[2] | ((uint)mac[3] << 8) | ((uint)mac[4] << 16) | ((uint)mac[5] << 24); }
		else
		{
			uint i = (uint)(j - 2) * 4;
			v = (uint)key16[i] | ((uint)key16[i + 1] << 8) | ((uint)key16[i + 2] << 16) | ((uint)key16[i + 3] << 24);
		}
		rtl_w32(RTL_REG_CAM_WRITE, v);
		rtl_w32(RTL_REG_CAM_CMD, RTL_CAM_CMD_POLLING | RTL_CAM_CMD_WRITE | ((slot << RTL_CAM_CMD_KEY_SHIFT) + (uint)j));
		rtl_udelay(100);
	}
}

fn void rtl_sec_enable()
{
	rtl_w16(RTL_REG_CR, rtl_r16(RTL_REG_CR) | RTL_CR_SECURITY_ENABLE);
	rtl_w8(RTL_REG_SECURITY_CFG, RTL_SEC_CFG_TX_SEC_ENABLE | RTL_SEC_CFG_TXBC_USE_DEFKEY
		| RTL_SEC_CFG_RX_SEC_ENABLE | RTL_SEC_CFG_RXBC_USE_DEFKEY
		| RTL_SEC_CFG_TX_USE_DEFKEY | RTL_SEC_CFG_RX_USE_DEFKEY);
}

// Forget every key (leave / lost link / new join).
fn void rtl_keys_clear()
{
	rtl_w32(RTL_REG_CAM_CMD, RTL_CAM_CMD_POLLING | (1u << 30));
	rtl_w8(RTL_REG_SECURITY_CFG, 0);
	wpa_reset();
}

// The pairwise key lives in CAM slot 0 (key id 0); a group key in the
// slot of its key id (1..3), so the old GTK keeps working in the other
// slot while a rekey's new one goes in.
fn void wpa_install_gtk(uint idx, char* gtk)
{
	if (idx == 0) { idx = 1; }
	rtl_cam_write(idx, idx, true, &g_sta_bssid[0], gtk);
	g_wpa_gtk_idx = idx;
}

// --- EAPOL-Key in ------------------------------------------------------

// `e` is the 802.1X frame (from the LLC/SNAP payload), `len` its bytes.
fn void wpa_eapol_rx(char* e, uint len)
{
	if (!g_sta_secure || len < EAPOL_KEY_HDR || (uint)e[1] != 3) { return; }
	uint total = 4 + be16(&e[2]);
	if (total > len || total < EAPOL_KEY_HDR) { return; }
	char* b = &e[4];
	if ((uint)b[0] != 2) { return; }
	uint info = be16(&b[1]);
	if ((info & WPA_INFO_VER_MASK) != 2)
	{
		print("wifi: EAPOL key descriptor version ");
		print_uint(info & WPA_INFO_VER_MASK);
		print(" not supported\n");
		return;
	}
	if ((info & WPA_INFO_ACK) == 0) { return; }
	uint ver = (uint)e[0];
	char* replay = &b[5];
	uint kdlen = be16(&b[93]);
	if (EAPOL_KEY_HDR + kdlen > total) { return; }
	char* kd = &b[95];
	bool pairwise = (info & WPA_INFO_PAIRWISE) != 0;
	bool mic = (info & WPA_INFO_MIC) != 0;

	if (pairwise && !mic)
	{
		// message 1: ANonce -> our SNonce, the PTK, message 2 (with our RSN IE)
		mem::copy(&g_wpa_anonce[0], &b[13], 32);
		wpa_random(&g_wpa_snonce[0]);
		wpa_derive_ptk();
		wpa_send_key(ver, 2 | WPA_INFO_PAIRWISE | WPA_INFO_MIC, replay, &g_wpa_snonce[0], &WPA_RSN_IE[0], 22);
		return;
	}
	if (!g_wpa_ptk_ok) { return; }
	if (!wpa_mic_ok(e, total))
	{
		g_wpa_mic_fail++;
		print("wifi: EAPOL MIC mismatch — wrong passphrase?\n");
		return;
	}
	char[512] plain @noinit;
	int pl = -1;
	if ((info & WPA_INFO_ENC_DATA) != 0) { pl = wpa_unwrap(kd, kdlen, &plain[0]); }
	uint gidx = 0;
	char[16] gtk;
	bool have_gtk = pl > 0 && wpa_find_gtk(&plain[0], (uint)pl, &gidx, &gtk[0]);

	if (pairwise)
	{
		// message 3: install. Message 4 goes out in the clear, then the keys.
		if (!have_gtk) { print("wifi: message 3 without a GTK\n"); return; }
		wpa_send_key(ver, 2 | WPA_INFO_PAIRWISE | WPA_INFO_MIC | WPA_INFO_SECURE, replay, null, null, 0);
		rtl_sec_enable();
		rtl_cam_write(0, 0, false, &g_sta_bssid[0], &g_wpa_ptk[32]);
		wpa_install_gtk(gidx, &gtk[0]);
		g_wpa_keyed = true;
		g_wpa_pn = 1;
		g_wpa_handshakes++;
		rtl_sta_secured();
		return;
	}
	// group key message 1 (rekey): new GTK, answer with group message 2
	if (!have_gtk) { return; }
	wpa_send_key(ver, 2 | WPA_INFO_MIC | WPA_INFO_SECURE, replay, null, null, 0);
	wpa_install_gtk(gidx, &gtk[0]);
	g_wpa_rekeys++;
}
