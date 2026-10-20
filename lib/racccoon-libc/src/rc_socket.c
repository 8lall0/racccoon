/* BSD sockets over racccoon's /net (ipd, user/net/ipd.c3).
 *
 * A socket is a /net conversation: socket() reads /net/<tcp|udp>/clone,
 * the fd remembers the conversation directory ("/net/tcp/3"), and the
 * calls below become ctl commands and data reads/writes on its files —
 * the same protocol user/user.c3's dial()/announce() speak:
 *
 *   bind      ctl "bind <port>"          listen  ctl "announce <port>"
 *   connect   ctl "connect a.b.c.d!port" (tcp: then wait for Established)
 *   accept    read <dir>/listen -> "<n>", a new conversation
 *   send/recv <dir>/data                 shutdown(SHUT_WR)  ctl "close"
 *   close     ctl "hangup"
 *
 * ipd answers a data read that has nothing yet with -2 after ~1 s; the
 * reads below just ask again. UDP sendto/recvfrom switch the socket to
 * ipd's "headers" mode: each datagram then carries the peer's address
 * (4 bytes) and port (2) in front. IPv4 only. getaddrinfo resolves
 * names with one DNS query to the server ipd learned over DHCP. */
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <racccoon/syscall.h>
#include <racccoon/fs.h>

#define NETF_TCP      0x1
#define NETF_HEADERS  0x2
#define NET_RETRY     (-2)

int   __rc_fd_new_net(const char *dir, int flags);
char *__rc_fd_net_dir(int fd, int **flags, unsigned long **port);
unsigned long __rc_timebase_hz(void);

static void sleep_ticks(unsigned long t)
{
	__rc_syscall5(0, (long)t, 0, 0, 0, 65 /* SYS_AWAIT */);
}

static void netpath(char *out, const char *dir, const char *file)
{
	int o = 0;
	for (int i = 0; dir[i] && o < 100; i++) out[o++] = dir[i];
	out[o++] = '/';
	for (int i = 0; file[i] && o < 126; i++) out[o++] = file[i];
	out[o] = 0;
}

static int ctl(const char *dir, const char *cmd)
{
	char p[128];
	netpath(p, dir, "ctl");
	return __rc_fs_write(p, cmd, (long)strlen(cmd)) < 0 ? -1 : 0;
}

static int read_status(const char *dir, char *out, int cap)
{
	char p[128];
	netpath(p, dir, "status");
	long n = __rc_fs_read(p, out, cap - 1);
	if (n < 0) return -1;
	out[n] = 0;
	return (int)n;
}

/* The third word of "tcp 3 Established rx ..." */
static const char *status_state(char *st)
{
	int sp = 0;
	char *p = st;
	while (*p && sp < 2) { if (*p == ' ') sp++; p++; }
	return p;
}

static int fmt_ip(char *out, uint32_t ip)   /* ip in host order */
{
	return sprintf(out, "%u.%u.%u.%u", (ip >> 24) & 255, (ip >> 16) & 255, (ip >> 8) & 255, ip & 255);
}

/* Dotted quad at *s (advanced past it), host order. The libc has no
 * sscanf. */
static int parse_quad(const char **s, uint32_t *ip)
{
	uint32_t v = 0;
	const char *p = *s;
	for (int k = 0; k < 4; k++) {
		if (*p < '0' || *p > '9') return -1;
		unsigned b = 0;
		while (*p >= '0' && *p <= '9') { b = b * 10 + (unsigned)(*p - '0'); p++; if (b > 255) return -1; }
		v = (v << 8) | b;
		if (k < 3) { if (*p != '.') return -1; p++; }
	}
	*s = p;
	*ip = v;
	return 0;
}

static int parse_hostport(const char *s, uint32_t *ip, unsigned *port)
{
	if (parse_quad(&s, ip) < 0 || *s != '!') return -1;
	s++;
	unsigned p = 0;
	if (*s < '0' || *s > '9') return -1;
	while (*s >= '0' && *s <= '9') { p = p * 10 + (unsigned)(*s - '0'); s++; }
	*port = p;
	return 0;
}

static int sock(int fd, char **dir, int **flags, unsigned long **port)
{
	*dir = __rc_fd_net_dir(fd, flags, port);
	if (!*dir) { errno = ENOTSOCK; return -1; }
	return 0;
}

int socket(int domain, int type, int protocol)
{
	(void)protocol;
	if (domain != AF_INET) { errno = EAFNOSUPPORT; return -1; }
	type &= 0xF;   /* ignore SOCK_NONBLOCK / SOCK_CLOEXEC bits */
	if (type != SOCK_STREAM && type != SOCK_DGRAM) { errno = EPROTONOSUPPORT; return -1; }
	const char *proto = type == SOCK_STREAM ? "tcp" : "udp";
	char clone[32], num[16], dir[32];
	sprintf(clone, "/net/%s/clone", proto);
	long n = __rc_fs_read(clone, num, 15);
	if (n <= 0) { errno = ENFILE; return -1; }
	num[n] = 0;
	sprintf(dir, "/net/%s/%d", proto, atoi(num));
	int fd = __rc_fd_new_net(dir, type == SOCK_STREAM ? NETF_TCP : 0);
	if (fd < 0) { ctl(dir, "hangup"); return -1; }
	return fd;
}

int bind(int fd, const struct sockaddr *addr, socklen_t len)
{
	char *dir; int *fl; unsigned long *port;
	if (sock(fd, &dir, &fl, &port) < 0) return -1;
	if (len < sizeof(struct sockaddr_in) || addr->sa_family != AF_INET) { errno = EINVAL; return -1; }
	unsigned p = ntohs(((const struct sockaddr_in *)addr)->sin_port);
	*port = p;
	if (p == 0) return 0;                  /* any port: picked at connect/listen */
	char cmd[32];
	sprintf(cmd, "bind %u", p);
	if (ctl(dir, cmd) < 0) { errno = EADDRINUSE; return -1; }
	return 0;
}

int listen(int fd, int backlog)
{
	(void)backlog;
	char *dir; int *fl; unsigned long *port;
	if (sock(fd, &dir, &fl, &port) < 0) return -1;
	char cmd[32];
	sprintf(cmd, "announce %lu", *port);
	if (*port == 0 || ctl(dir, cmd) < 0) { errno = EADDRINUSE; return -1; }
	return 0;
}

static void fill_addr(struct sockaddr *addr, socklen_t *len, uint32_t ip, unsigned port)
{
	if (!addr || !len) return;
	struct sockaddr_in sin;
	memset(&sin, 0, sizeof sin);
	sin.sin_family = AF_INET;
	sin.sin_port = htons((uint16_t)port);
	sin.sin_addr.s_addr = htonl(ip);
	socklen_t n = *len < sizeof sin ? *len : sizeof sin;
	memcpy(addr, &sin, n);
	*len = sizeof sin;
}

static int read_addr(const char *dir, const char *file, uint32_t *ip, unsigned *port)
{
	char p[128], buf[48];
	netpath(p, dir, file);
	long n = __rc_fs_read(p, buf, 47);
	if (n <= 0) return -1;
	buf[n] = 0;
	return parse_hostport(buf, ip, port);
}

int accept(int fd, struct sockaddr *addr, socklen_t *len)
{
	char *dir; int *fl; unsigned long *port;
	if (sock(fd, &dir, &fl, &port) < 0) return -1;
	char p[128], num[16];
	netpath(p, dir, "listen");
	long n;
	do { n = __rc_fs_read(p, num, 15); } while (n == NET_RETRY);
	if (n <= 0) { errno = EINVAL; return -1; }
	num[n] = 0;
	char ndir[32];
	sprintf(ndir, "/net/tcp/%d", atoi(num));
	int nfd = __rc_fd_new_net(ndir, NETF_TCP);
	if (nfd < 0) { ctl(ndir, "hangup"); return -1; }
	uint32_t ip; unsigned rport;
	if (read_addr(ndir, "remote", &ip, &rport) == 0) fill_addr(addr, len, ip, rport);
	return nfd;
}

int connect(int fd, const struct sockaddr *addr, socklen_t len)
{
	char *dir; int *fl; unsigned long *port;
	if (sock(fd, &dir, &fl, &port) < 0) return -1;
	if (len < sizeof(struct sockaddr_in) || addr->sa_family != AF_INET) { errno = EAFNOSUPPORT; return -1; }
	const struct sockaddr_in *sin = (const struct sockaddr_in *)addr;
	char cmd[48];
	int o = sprintf(cmd, "connect ");
	o += fmt_ip(cmd + o, ntohl(sin->sin_addr.s_addr));
	sprintf(cmd + o, "!%u", ntohs(sin->sin_port));
	if (ctl(dir, cmd) < 0) { errno = ECONNREFUSED; return -1; }
	if (!(*fl & NETF_TCP)) return 0;
	unsigned long hz = __rc_timebase_hz();
	for (int i = 0; i < 1000; i++) {               /* ~10 s */
		char st[96];
		if (read_status(dir, st, sizeof st) < 0) break;
		const char *s = status_state(st);
		if (s[0] == 'E') return 0;                  /* Established */
		if (s[0] == 'R' || (s[0] == 'C' && s[1] == 'l')) { errno = ECONNREFUSED; return -1; }
		sleep_ticks(hz / 100);
	}
	errno = ETIMEDOUT;
	return -1;
}

/* One datagram / some stream bytes, waiting as long as it takes. In
 * headers mode the 6-byte peer header is returned through hdr (if not
 * NULL) and stripped. */
static ssize_t net_recv(const char *dir, int flags, void *buf, size_t n, unsigned char *hdr)
{
	char p[128];
	netpath(p, dir, "data");
	char tmp[RC_FS_MSG_MAX];
	size_t want = n + ((flags & NETF_HEADERS) ? 6 : 0);
	if (want > RC_FS_MSG_MAX - 8) want = RC_FS_MSG_MAX - 8;
	long r;
	do { r = __rc_fs_read(p, tmp, (long)want); } while (r == NET_RETRY);
	if (r < 0) { errno = ECONNRESET; return -1; }
	if (flags & NETF_HEADERS) {
		if (r < 6) return 0;
		if (hdr) memcpy(hdr, tmp, 6);
		r -= 6;
		memcpy(buf, tmp + 6, (size_t)r);
	} else {
		memcpy(buf, tmp, (size_t)r);
	}
	return (ssize_t)r;
}

static ssize_t net_send(const char *dir, int flags, const void *buf, size_t n)
{
	char p[128];
	netpath(p, dir, "data");
	const char *b = buf;
	size_t done = 0;
	unsigned long hz = __rc_timebase_hz();
	while (done < n) {
		long chunk = (long)(n - done);
		if (chunk > RC_FS_MSG_MAX - 120) chunk = RC_FS_MSG_MAX - 120;
		long w = __rc_fs_write(p, b + done, chunk);
		if (w < 0) { if (done) break; errno = (flags & NETF_TCP) ? ECONNRESET : EINVAL; return -1; }
		if (w == 0) { sleep_ticks(hz / 200); continue; }   /* tcp send buffer full */
		done += (size_t)w;
		if (!(flags & NETF_TCP)) break;                    /* one datagram */
	}
	return (ssize_t)done;
}

ssize_t __rc_net_read(int fd, void *buf, size_t n)
{
	char *dir; int *fl; unsigned long *port;
	if (sock(fd, &dir, &fl, &port) < 0) return -1;
	return net_recv(dir, *fl, buf, n, NULL);
}

ssize_t __rc_net_write(int fd, const void *buf, size_t n)
{
	char *dir; int *fl; unsigned long *port;
	if (sock(fd, &dir, &fl, &port) < 0) return -1;
	return net_send(dir, *fl, buf, n);
}

void __rc_net_close(int fd)
{
	char *dir = __rc_fd_net_dir(fd, NULL, NULL);
	if (dir) ctl(dir, "hangup");
}

ssize_t send(int fd, const void *buf, size_t n, int flags) { (void)flags; return __rc_net_write(fd, buf, n); }
ssize_t recv(int fd, void *buf, size_t n, int flags) { (void)flags; return __rc_net_read(fd, buf, n); }

static int ensure_headers(const char *dir, int *fl)
{
	if (*fl & NETF_HEADERS) return 0;
	if (ctl(dir, "headers") < 0) return -1;
	*fl |= NETF_HEADERS;
	return 0;
}

ssize_t sendto(int fd, const void *buf, size_t n, int flags, const struct sockaddr *to, socklen_t tolen)
{
	(void)flags;
	char *dir; int *fl; unsigned long *port;
	if (sock(fd, &dir, &fl, &port) < 0) return -1;
	if (!to || (*fl & NETF_TCP)) return net_send(dir, *fl, buf, n);
	if (tolen < sizeof(struct sockaddr_in)) { errno = EINVAL; return -1; }
	if (ensure_headers(dir, fl) < 0) { errno = EINVAL; return -1; }
	const struct sockaddr_in *sin = (const struct sockaddr_in *)to;
	char pkt[1480];
	if (n > sizeof pkt - 6) n = sizeof pkt - 6;
	memcpy(pkt, &sin->sin_addr.s_addr, 4);   /* already network order */
	memcpy(pkt + 4, &sin->sin_port, 2);
	memcpy(pkt + 6, buf, n);
	ssize_t r = net_send(dir, *fl, pkt, n + 6);
	return r < 0 ? -1 : (ssize_t)n;
}

ssize_t recvfrom(int fd, void *buf, size_t n, int flags, struct sockaddr *from, socklen_t *fromlen)
{
	(void)flags;
	char *dir; int *fl; unsigned long *port;
	if (sock(fd, &dir, &fl, &port) < 0) return -1;
	if (*fl & NETF_TCP) return net_recv(dir, *fl, buf, n, NULL);
	if (ensure_headers(dir, fl) < 0) { errno = EINVAL; return -1; }
	unsigned char hdr[6];
	ssize_t r = net_recv(dir, *fl, buf, n, hdr);
	if (r >= 0 && from && fromlen) {
		uint32_t ip = ((uint32_t)hdr[0] << 24) | ((uint32_t)hdr[1] << 16) | ((uint32_t)hdr[2] << 8) | hdr[3];
		fill_addr(from, fromlen, ip, ((unsigned)hdr[4] << 8) | hdr[5]);
	}
	return r;
}

int shutdown(int fd, int how)
{
	char *dir; int *fl; unsigned long *port;
	if (sock(fd, &dir, &fl, &port) < 0) return -1;
	if ((how == SHUT_WR || how == SHUT_RDWR) && (*fl & NETF_TCP)) ctl(dir, "close");
	return 0;
}

int setsockopt(int fd, int level, int name, const void *val, socklen_t len)
{
	(void)level; (void)name; (void)val; (void)len;
	return __rc_fd_net_dir(fd, NULL, NULL) ? 0 : (errno = ENOTSOCK, -1);
}

int getsockopt(int fd, int level, int name, void *val, socklen_t *len)
{
	(void)level; (void)name;
	if (!__rc_fd_net_dir(fd, NULL, NULL)) { errno = ENOTSOCK; return -1; }
	if (val && len && *len >= sizeof(int)) { *(int *)val = 0; *len = sizeof(int); }
	return 0;
}

int getsockname(int fd, struct sockaddr *addr, socklen_t *len)
{
	char *dir; int *fl; unsigned long *port;
	if (sock(fd, &dir, &fl, &port) < 0) return -1;
	uint32_t ip; unsigned p;
	if (read_addr(dir, "local", &ip, &p) < 0) { errno = EINVAL; return -1; }
	fill_addr(addr, len, ip, p);
	return 0;
}

int getpeername(int fd, struct sockaddr *addr, socklen_t *len)
{
	char *dir; int *fl; unsigned long *port;
	if (sock(fd, &dir, &fl, &port) < 0) return -1;
	uint32_t ip; unsigned p;
	if (read_addr(dir, "remote", &ip, &p) < 0 || ip == 0) { errno = ENOTCONN; return -1; }
	fill_addr(addr, len, ip, p);
	return 0;
}

/* --- addresses -------------------------------------------------------- */

int inet_aton(const char *cp, struct in_addr *inp)
{
	uint32_t ip;
	if (parse_quad(&cp, &ip) < 0 || *cp != 0) return 0;
	inp->s_addr = htonl(ip);
	return 1;
}

int inet_pton(int af, const char *src, void *dst)
{
	if (af != AF_INET) { errno = EAFNOSUPPORT; return -1; }
	return inet_aton(src, dst);
}

in_addr_t inet_addr(const char *cp)
{
	struct in_addr a;
	return inet_aton(cp, &a) ? a.s_addr : INADDR_NONE;
}

const char *inet_ntop(int af, const void *src, char *dst, socklen_t size)
{
	if (af != AF_INET) { errno = EAFNOSUPPORT; return NULL; }
	char tmp[16];
	fmt_ip(tmp, ntohl(((const struct in_addr *)src)->s_addr));
	if (strlen(tmp) + 1 > size) { errno = ENOSPC; return NULL; }
	strcpy(dst, tmp);
	return dst;
}

char *inet_ntoa(struct in_addr in)
{
	static char buf[16];
	fmt_ip(buf, ntohl(in.s_addr));
	return buf;
}

/* --- names ------------------------------------------------------------- */

static uint32_t dns_server(void)
{
	for (int i = 0; i < 4; i++) {
		char p[32], st[256];
		sprintf(p, "/net/ipifc/%d/status", i);
		long n = __rc_fs_read(p, st, 255);
		if (n <= 0) continue;
		st[n] = 0;
		char *d = strstr(st, " dns ");
		uint32_t ip;
		const char *q = d ? d + 5 : NULL;
		if (q && parse_quad(&q, &ip) == 0 && ip != 0) return ip;
	}
	return 0;
}

static int dns_skip(const unsigned char *m, int len, int at)
{
	while (at < len) {
		unsigned l = m[at];
		if (l == 0) return at + 1;
		if ((l & 0xC0) == 0xC0) return at + 2;
		at += (int)l + 1;
	}
	return -1;
}

/* One A-record lookup, host order result. 0 = found. */
static int dns_query(const char *name, uint32_t *out)
{
	uint32_t server = dns_server();
	if (!server) return -1;
	unsigned char q[300];
	unsigned id = (unsigned)__rc_syscall3(0, 0, 0, RC_SYS_GETPID) * 7919u ^ 0x5a5a;
	q[0] = (unsigned char)(id >> 8); q[1] = (unsigned char)id;
	q[2] = 1; q[3] = 0; q[4] = 0; q[5] = 1;
	memset(q + 6, 0, 6);
	int qn = 12;
	const char *s = name;
	while (*s) {
		const char *dot = strchr(s, '.');
		int l = dot ? (int)(dot - s) : (int)strlen(s);
		if (l <= 0 || l > 63 || qn + l + 6 > 290) return -1;
		q[qn++] = (unsigned char)l;
		memcpy(q + qn, s, (size_t)l); qn += l;
		s += l;
		if (*s == '.') s++;
	}
	q[qn++] = 0; q[qn++] = 0; q[qn++] = 1; q[qn++] = 0; q[qn++] = 1;

	int fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0) return -1;
	struct sockaddr_in sa;
	memset(&sa, 0, sizeof sa);
	sa.sin_family = AF_INET;
	sa.sin_port = htons(53);
	sa.sin_addr.s_addr = htonl(server);
	int found = -1;
	if (connect(fd, (struct sockaddr *)&sa, sizeof sa) == 0) {
		char *dir = __rc_fd_net_dir(fd, NULL, NULL);
		char p[128];
		netpath(p, dir, "data");
		for (int attempt = 0; attempt < 2 && found < 0; attempt++) {
			__rc_fs_write(p, q, qn);
			unsigned char r[1024];
			long rn = __rc_fs_read(p, r, sizeof r);      /* one try: -2 after ~1 s */
			if (rn < 12 || r[0] != q[0] || r[1] != q[1]) continue;
			if (r[3] & 0x0F) break;
			int an = (r[6] << 8) | r[7];
			int at = dns_skip(r, (int)rn, 12);
			if (at < 0) break;
			at += 4;
			for (int a = 0; a < an && at > 0 && at + 10 <= rn; a++) {
				at = dns_skip(r, (int)rn, at);
				if (at < 0 || at + 10 > rn) break;
				int type = (r[at] << 8) | r[at + 1];
				int rdlen = (r[at + 8] << 8) | r[at + 9];
				at += 10;
				if (type == 1 && rdlen == 4 && at + 4 <= rn) {
					*out = ((uint32_t)r[at] << 24) | ((uint32_t)r[at + 1] << 16) | ((uint32_t)r[at + 2] << 8) | r[at + 3];
					found = 0;
					break;
				}
				at += rdlen;
			}
		}
	}
	close(fd);
	return found;
}

int getaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res)
{
	int family = hints ? hints->ai_family : AF_UNSPEC;
	if (family != AF_UNSPEC && family != AF_INET) return EAI_FAMILY;
	int socktype = hints ? hints->ai_socktype : 0;
	int flags = hints ? hints->ai_flags : 0;
	unsigned port = 0;
	if (service) {
		char *end;
		long v = strtol(service, &end, 10);
		if (*end != 0 || v < 0 || v > 65535) {
			if (strcmp(service, "http") == 0) v = 80;
			else if (strcmp(service, "https") == 0) v = 443;
			else if (strcmp(service, "domain") == 0) v = 53;
			else if (strcmp(service, "telnet") == 0) v = 23;
			else return EAI_SERVICE;
		}
		port = (unsigned)v;
	}
	uint32_t ip;
	struct in_addr a;
	if (!node) ip = (flags & AI_PASSIVE) ? 0 : 0x7f000001;
	else if (inet_aton(node, &a)) ip = ntohl(a.s_addr);
	else if (strcmp(node, "localhost") == 0) ip = 0x7f000001;
	else if (flags & AI_NUMERICHOST) return EAI_NONAME;
	else if (dns_query(node, &ip) < 0) return EAI_NONAME;

	struct addrinfo *ai = calloc(1, sizeof *ai + sizeof(struct sockaddr_in));
	if (!ai) return EAI_MEMORY;
	struct sockaddr_in *sin = (struct sockaddr_in *)(ai + 1);
	sin->sin_family = AF_INET;
	sin->sin_port = htons((uint16_t)port);
	sin->sin_addr.s_addr = htonl(ip);
	ai->ai_family = AF_INET;
	ai->ai_socktype = socktype ? socktype : SOCK_STREAM;
	ai->ai_protocol = ai->ai_socktype == SOCK_DGRAM ? IPPROTO_UDP : IPPROTO_TCP;
	ai->ai_addrlen = sizeof *sin;
	ai->ai_addr = (struct sockaddr *)sin;
	*res = ai;
	return 0;
}

void freeaddrinfo(struct addrinfo *res)
{
	while (res) { struct addrinfo *n = res->ai_next; free(res); res = n; }
}

const char *gai_strerror(int err)
{
	switch (err) {
	case EAI_NONAME:  return "name does not resolve";
	case EAI_FAMILY:  return "address family not supported";
	case EAI_SERVICE: return "unknown service";
	case EAI_MEMORY:  return "out of memory";
	default:          return "lookup failed";
	}
}

struct hostent *gethostbyname(const char *name)
{
	static struct hostent he;
	static uint32_t addr;
	static char *list[2];
	static char hname[256];
	struct addrinfo *ai;
	if (getaddrinfo(name, NULL, NULL, &ai) != 0) return NULL;
	addr = ((struct sockaddr_in *)ai->ai_addr)->sin_addr.s_addr;
	freeaddrinfo(ai);
	strncpy(hname, name, sizeof hname - 1);
	list[0] = (char *)&addr;
	list[1] = NULL;
	he.h_name = hname;
	he.h_aliases = list + 1;
	he.h_addrtype = AF_INET;
	he.h_length = 4;
	he.h_addr_list = list;
	return &he;
}
