module user;

// The crypto a WPA2-PSK supplicant needs, no more (docs/manual.md,
// Wi-Fi): SHA-1, HMAC-SHA1, PBKDF2-HMAC-SHA1 (passphrase + SSID -> PMK),
// the IEEE 802.11i PRF (PMK -> PTK), AES-128 block encryption and the
// RFC 3394 key unwrap (the GTK in EAPOL message 3). Data frames are
// CCMP-encrypted by the Wi-Fi chip itself, so no CCM here. Checked
// against the published test vectors by `cryptotest` (shell_test_net.c3).
// Not constant-time; none of this protects long-lived secrets on a
// shared machine.

// --- SHA-1 (FIPS 180-4) -------------------------------------------------

struct Sha1
{
	uint[5] h;
	char[64] block;
	uint blen;
	ulong total;
}

fn uint rol32(uint x, uint n) { return (x << n) | (x >> (32 - n)); }

fn void sha1_init(Sha1* s)
{
	s.h[0] = 0x67452301; s.h[1] = 0xEFCDAB89; s.h[2] = 0x98BADCFE; s.h[3] = 0x10325476; s.h[4] = 0xC3D2E1F0;
	s.blen = 0;
	s.total = 0;
}

fn void sha1_block(Sha1* s, char* p)
{
	uint[80] w;
	for (int i = 0; i < 16; i++)
	{
		w[i] = ((uint)p[i * 4] << 24) | ((uint)p[i * 4 + 1] << 16) | ((uint)p[i * 4 + 2] << 8) | (uint)p[i * 4 + 3];
	}
	for (int i = 16; i < 80; i++) { w[i] = rol32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1); }
	uint a = s.h[0];
	uint b = s.h[1];
	uint c = s.h[2];
	uint d = s.h[3];
	uint e = s.h[4];
	for (int i = 0; i < 80; i++)
	{
		uint f;
		uint k;
		if (i < 20)      { f = (b & c) | (~b & d);          k = 0x5A827999; }
		else if (i < 40) { f = b ^ c ^ d;                   k = 0x6ED9EBA1; }
		else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC; }
		else             { f = b ^ c ^ d;                   k = 0xCA62C1D6; }
		uint t = rol32(a, 5) + f + e + k + w[i];
		e = d;
		d = c;
		c = rol32(b, 30);
		b = a;
		a = t;
	}
	s.h[0] += a; s.h[1] += b; s.h[2] += c; s.h[3] += d; s.h[4] += e;
}

fn void sha1_update(Sha1* s, char* data, uint len)
{
	s.total += len;
	for (uint i = 0; i < len; i++)
	{
		s.block[s.blen] = data[i];
		s.blen++;
		if (s.blen == 64) { sha1_block(s, &s.block[0]); s.blen = 0; }
	}
}

fn void sha1_final(Sha1* s, char* out20)
{
	ulong bits = s.total * 8;
	char pad = (char)0x80;
	sha1_update(s, &pad, 1);
	char zero = 0;
	while (s.blen != 56) { sha1_update(s, &zero, 1); }
	char[8] lenb;
	for (int i = 0; i < 8; i++) { lenb[i] = (char)(bits >> (56 - i * 8)); }
	sha1_update(s, &lenb[0], 8);
	for (int i = 0; i < 5; i++)
	{
		out20[i * 4]     = (char)(s.h[i] >> 24);
		out20[i * 4 + 1] = (char)(s.h[i] >> 16);
		out20[i * 4 + 2] = (char)(s.h[i] >> 8);
		out20[i * 4 + 3] = (char)s.h[i];
	}
}

fn void sha1(char* data, uint len, char* out20)
{
	Sha1 s;
	sha1_init(&s);
	sha1_update(&s, data, len);
	sha1_final(&s, out20);
}

// --- HMAC-SHA1 (RFC 2104) -----------------------------------------------
// Two data parts (either may be empty), so the PRF and PBKDF2 needn't
// build a joined buffer.
fn void hmac_sha1_2(char* key, uint klen, char* d1, uint l1, char* d2, uint l2, char* out20)
{
	char[64] k0;
	for (int i = 0; i < 64; i++) { k0[i] = 0; }
	if (klen > 64)
	{
		sha1(key, klen, &k0[0]);
	}
	else
	{
		for (uint i = 0; i < klen; i++) { k0[i] = key[i]; }
	}
	char[64] pad;
	Sha1 s;
	for (int i = 0; i < 64; i++) { pad[i] = k0[i] ^ (char)0x36; }
	sha1_init(&s);
	sha1_update(&s, &pad[0], 64);
	if (l1 > 0) { sha1_update(&s, d1, l1); }
	if (l2 > 0) { sha1_update(&s, d2, l2); }
	char[20] inner;
	sha1_final(&s, &inner[0]);
	for (int i = 0; i < 64; i++) { pad[i] = k0[i] ^ (char)0x5c; }
	sha1_init(&s);
	sha1_update(&s, &pad[0], 64);
	sha1_update(&s, &inner[0], 20);
	sha1_final(&s, out20);
}

fn void hmac_sha1(char* key, uint klen, char* data, uint len, char* out20)
{
	hmac_sha1_2(key, klen, data, len, null, 0, out20);
}

// --- PBKDF2-HMAC-SHA1 (RFC 8018) ------------------------------------------
// WPA2: PMK = PBKDF2(passphrase, SSID, 4096 iterations, 32 bytes).
fn void pbkdf2_sha1(char* pass, uint plen, char* salt, uint slen, uint iters, char* out, uint outlen)
{
	uint done = 0;
	for (uint blk = 1; done < outlen; blk++)
	{
		char[4] ib;
		ib[0] = (char)(blk >> 24); ib[1] = (char)(blk >> 16); ib[2] = (char)(blk >> 8); ib[3] = (char)blk;
		char[20] u;
		char[20] t;
		hmac_sha1_2(pass, plen, salt, slen, &ib[0], 4, &u[0]);
		for (int i = 0; i < 20; i++) { t[i] = u[i]; }
		for (uint it = 1; it < iters; it++)
		{
			char[20] un;
			hmac_sha1(pass, plen, &u[0], 20, &un[0]);
			for (int i = 0; i < 20; i++) { u[i] = un[i]; t[i] ^= un[i]; }
		}
		for (uint i = 0; i < 20 && done < outlen; i++) { out[done] = t[i]; done++; }
	}
}

// --- 802.11i PRF (IEEE 802.11-2016 12.7.1.2) -------------------------------
// PRF-n(K, A, B) = first n bytes of HMAC-SHA1(K, A || 0 || B || i), i = 0..
fn void prf_sha1(char* key, uint klen, char* label, char* data, uint dlen, char* out, uint outlen)
{
	uint llen = 0;
	while (label[llen] != 0) { llen++; }
	char[160] buf;   // label + 0 + data + counter; PTK derivation needs 22 + 1 + 76 + 1
	uint n = 0;
	for (uint i = 0; i < llen; i++) { buf[n] = label[i]; n++; }
	buf[n] = 0; n++;
	for (uint i = 0; i < dlen; i++) { buf[n] = data[i]; n++; }
	uint ci = n;
	n++;
	uint done = 0;
	for (uint i = 0; done < outlen; i++)
	{
		buf[ci] = (char)i;
		char[20] h;
		hmac_sha1(key, klen, &buf[0], n, &h[0]);
		for (uint k = 0; k < 20 && done < outlen; k++) { out[done] = h[k]; done++; }
	}
}

// --- AES-128 (FIPS 197), encryption and decryption of one block ------------

char[256] g_aes_sbox;
char[256] g_aes_inv;
bool g_aes_ready;

fn char aes_xtime(char x) { return (char)((x << 1) ^ (((uint)x & 0x80) != 0 ? 0x1b : 0)); }

fn char aes_mul(char a, char b)
{
	char r = 0;
	for (int i = 0; i < 8; i++)
	{
		if (((uint)b & 1) != 0) { r ^= a; }
		a = aes_xtime(a);
		b = (char)((uint)b >> 1);
	}
	return r;
}

// The S-box from its definition (inverse in GF(2^8), then the affine map)
// rather than a 512-byte table in the source.
fn void aes_tables()
{
	if (g_aes_ready) { return; }
	for (int x = 0; x < 256; x++)
	{
		char inv = 0;
		if (x != 0)
		{
			for (int y = 1; y < 256; y++)
			{
				if (aes_mul((char)x, (char)y) == 1) { inv = (char)y; break; }
			}
		}
		uint b = (uint)inv;
		uint s = b ^ ((b << 1) | (b >> 7)) ^ ((b << 2) | (b >> 6)) ^ ((b << 3) | (b >> 5)) ^ ((b << 4) | (b >> 4));
		s = (s ^ 0x63) & 0xFF;
		g_aes_sbox[x] = (char)s;
		g_aes_inv[s] = (char)x;
	}
	g_aes_ready = true;
}

struct Aes128 { char[176] rk; }

fn void aes128_key(Aes128* a, char* key)
{
	aes_tables();
	for (int i = 0; i < 16; i++) { a.rk[i] = key[i]; }
	char rcon = 1;
	for (int i = 16; i < 176; i += 4)
	{
		char[4] t;
		for (int k = 0; k < 4; k++) { t[k] = a.rk[i - 4 + k]; }
		if (i % 16 == 0)
		{
			char t0 = t[0];
			t[0] = g_aes_sbox[(uint)t[1]] ^ rcon;
			t[1] = g_aes_sbox[(uint)t[2]];
			t[2] = g_aes_sbox[(uint)t[3]];
			t[3] = g_aes_sbox[(uint)t0];
			rcon = aes_xtime(rcon);
		}
		for (int k = 0; k < 4; k++) { a.rk[i + k] = a.rk[i - 16 + k] ^ t[k]; }
	}
}

fn void aes128_encrypt(Aes128* a, char* in, char* out)
{
	char[16] s;
	for (int i = 0; i < 16; i++) { s[i] = in[i] ^ a.rk[i]; }
	for (int r = 1; r <= 10; r++)
	{
		char[16] t;
		for (int i = 0; i < 16; i++) { t[i] = g_aes_sbox[(uint)s[i]]; }
		// ShiftRows (column-major state: byte i = row i%4, column i/4)
		for (int c = 0; c < 4; c++)
		{
			for (int rr = 0; rr < 4; rr++) { s[c * 4 + rr] = t[((c + rr) % 4) * 4 + rr]; }
		}
		if (r < 10)
		{
			for (int c = 0; c < 4; c++)
			{
				char a0 = s[c * 4]; char a1 = s[c * 4 + 1]; char a2 = s[c * 4 + 2]; char a3 = s[c * 4 + 3];
				s[c * 4]     = aes_xtime(a0) ^ (aes_xtime(a1) ^ a1) ^ a2 ^ a3;
				s[c * 4 + 1] = a0 ^ aes_xtime(a1) ^ (aes_xtime(a2) ^ a2) ^ a3;
				s[c * 4 + 2] = a0 ^ a1 ^ aes_xtime(a2) ^ (aes_xtime(a3) ^ a3);
				s[c * 4 + 3] = (aes_xtime(a0) ^ a0) ^ a1 ^ a2 ^ aes_xtime(a3);
			}
		}
		for (int i = 0; i < 16; i++) { s[i] ^= a.rk[r * 16 + i]; }
	}
	for (int i = 0; i < 16; i++) { out[i] = s[i]; }
}

fn void aes128_decrypt(Aes128* a, char* in, char* out)
{
	char[16] s;
	for (int i = 0; i < 16; i++) { s[i] = in[i] ^ a.rk[160 + i]; }
	for (int r = 9; r >= 0; r--)
	{
		char[16] t;
		// InvShiftRows then InvSubBytes
		for (int c = 0; c < 4; c++)
		{
			for (int rr = 0; rr < 4; rr++) { t[((c + rr) % 4) * 4 + rr] = s[c * 4 + rr]; }
		}
		for (int i = 0; i < 16; i++) { s[i] = g_aes_inv[(uint)t[i]] ^ a.rk[r * 16 + i]; }
		if (r > 0)
		{
			for (int c = 0; c < 4; c++)
			{
				char a0 = s[c * 4]; char a1 = s[c * 4 + 1]; char a2 = s[c * 4 + 2]; char a3 = s[c * 4 + 3];
				s[c * 4]     = aes_mul(a0, 14) ^ aes_mul(a1, 11) ^ aes_mul(a2, 13) ^ aes_mul(a3, 9);
				s[c * 4 + 1] = aes_mul(a0, 9) ^ aes_mul(a1, 14) ^ aes_mul(a2, 11) ^ aes_mul(a3, 13);
				s[c * 4 + 2] = aes_mul(a0, 13) ^ aes_mul(a1, 9) ^ aes_mul(a2, 14) ^ aes_mul(a3, 11);
				s[c * 4 + 3] = aes_mul(a0, 11) ^ aes_mul(a1, 13) ^ aes_mul(a2, 9) ^ aes_mul(a3, 14);
			}
		}
	}
	for (int i = 0; i < 16; i++) { out[i] = s[i]; }
}

// --- AES key unwrap (RFC 3394) -----------------------------------------------
// `in` is (n + 1) * 8 bytes; `out` gets n * 8. false if the integrity check
// (the 0xA6A6... IV) fails — a wrong KEK or a corrupted key.
fn bool aes_key_unwrap(char* kek, char* in, uint inlen, char* out)
{
	if (inlen < 24 || inlen % 8 != 0) { return false; }
	uint n = inlen / 8 - 1;
	Aes128 a;
	aes128_key(&a, kek);
	char[8] iv;
	for (int i = 0; i < 8; i++) { iv[i] = in[i]; }
	for (uint i = 0; i < n * 8; i++) { out[i] = in[8 + i]; }
	for (int j = 5; j >= 0; j--)
	{
		for (uint i = n; i >= 1; i--)
		{
			ulong t = (ulong)n * (ulong)j + i;
			char[16] b;
			for (int k = 0; k < 8; k++) { b[k] = iv[k] ^ (char)(t >> (56 - k * 8)); }
			for (uint k = 0; k < 8; k++) { b[8 + k] = out[(i - 1) * 8 + k]; }
			char[16] r;
			aes128_decrypt(&a, &b[0], &r[0]);
			for (uint k = 0; k < 8; k++) { iv[k] = r[k]; out[(i - 1) * 8 + k] = r[8 + k]; }
		}
	}
	for (int i = 0; i < 8; i++) { if ((uint)iv[i] != 0xA6) { return false; } }
	return true;
}
