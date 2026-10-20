/* BSD sockets over /net (lib/racccoon-libc/src/rc_socket.c): TCP and UDP
 * over loopback, inet_*, getaddrinfo, getsockname/getpeername. Forks a
 * server child for each part. "socktest: ok" or "socktest: FAILED". */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>

static int bad;
static void check(const char *what, int ok)
{
	printf("socktest: %s: %s\n", what, ok ? "ok" : "FAILED");
	if (!ok) bad++;
}

static struct sockaddr_in loop_addr(int port)
{
	struct sockaddr_in a;
	memset(&a, 0, sizeof a);
	a.sin_family = AF_INET;
	a.sin_port = htons((uint16_t)port);
	a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	return a;
}

int main(void)
{
	/* inet helpers */
	struct in_addr ia;
	char txt[16];
	check("inet_pton/ntop", inet_pton(AF_INET, "10.0.2.15", &ia) == 1
		&& strcmp(inet_ntop(AF_INET, &ia, txt, sizeof txt), "10.0.2.15") == 0
		&& inet_addr("1.2.3") == INADDR_NONE);

	/* TCP: echo server child, client parent */
	int ls = socket(AF_INET, SOCK_STREAM, 0);
	struct sockaddr_in sa = loop_addr(7100);
	int ok = ls >= 0 && bind(ls, (struct sockaddr *)&sa, sizeof sa) == 0 && listen(ls, 4) == 0;
	check("tcp socket/bind/listen", ok);
	pid_t pid = fork();
	if (pid == 0) {
		struct sockaddr_in peer;
		socklen_t pl = sizeof peer;
		int c = accept(ls, (struct sockaddr *)&peer, &pl);
		char buf[256];
		ssize_t n;
		while ((n = recv(c, buf, sizeof buf, 0)) > 0) send(c, buf, (size_t)n, 0);
		close(c);
		_exit(peer.sin_addr.s_addr == htonl(INADDR_LOOPBACK) ? 0 : 3);
	}
	int c = socket(AF_INET, SOCK_STREAM, 0);
	struct sockaddr_in ca = loop_addr(7100);
	int conn = connect(c, (struct sockaddr *)&ca, sizeof ca) == 0;
	const char *msg = "hello over a socket";
	char back[64] = {0};
	ssize_t got = 0;
	if (conn) {
		send(c, msg, strlen(msg), 0);
		while (got < (ssize_t)strlen(msg)) {
			ssize_t n = recv(c, back + got, sizeof back - 1 - (size_t)got, 0);
			if (n <= 0) break;
			got += n;
		}
	}
	struct sockaddr_in me, them;
	socklen_t ml = sizeof me, tl = sizeof them;
	int names = getsockname(c, (struct sockaddr *)&me, &ml) == 0 && getpeername(c, (struct sockaddr *)&them, &tl) == 0
		&& ntohs(them.sin_port) == 7100 && ntohs(me.sin_port) >= 49152;
	shutdown(c, SHUT_WR);
	char eofb[4];
	int eof = recv(c, eofb, sizeof eofb, 0) == 0;
	close(c);
	int st = 0;
	waitpid(pid, &st, 0);
	close(ls);
	check("tcp connect/send/recv echo", conn && got == (ssize_t)strlen(msg) && memcmp(back, msg, strlen(msg)) == 0);
	check("getsockname/getpeername", names);
	check("shutdown -> peer closes -> recv 0", eof);
	check("server saw a loopback peer", WIFEXITED(st) && WEXITSTATUS(st) == 0);

	/* TCP refused */
	int r = socket(AF_INET, SOCK_STREAM, 0);
	struct sockaddr_in ra = loop_addr(7199);
	check("connect to a closed port fails", connect(r, (struct sockaddr *)&ra, sizeof ra) < 0);
	close(r);

	/* UDP: sendto/recvfrom with a reply to the sender's address */
	int us = socket(AF_INET, SOCK_DGRAM, 0);
	struct sockaddr_in ua = loop_addr(7101);
	bind(us, (struct sockaddr *)&ua, sizeof ua);
	pid = fork();
	if (pid == 0) {
		char buf[64];
		struct sockaddr_in from;
		socklen_t fl = sizeof from;
		ssize_t n = recvfrom(us, buf, sizeof buf, 0, (struct sockaddr *)&from, &fl);
		if (n > 0) { buf[0] = 'P'; sendto(us, buf, (size_t)n, 0, (struct sockaddr *)&from, fl); }
		_exit(0);
	}
	int uc = socket(AF_INET, SOCK_DGRAM, 0);
	struct sockaddr_in dst = loop_addr(7101);
	sendto(uc, "ping", 4, 0, (struct sockaddr *)&dst, sizeof dst);
	char ub[16] = {0};
	struct sockaddr_in from;
	socklen_t fl = sizeof from;
	ssize_t un = recvfrom(uc, ub, sizeof ub, 0, (struct sockaddr *)&from, &fl);
	waitpid(pid, &st, 0);
	close(uc);
	close(us);
	check("udp sendto/recvfrom reply", un == 4 && memcmp(ub, "Ping", 4) == 0 && ntohs(from.sin_port) == 7101);

	/* getaddrinfo: numeric and localhost (no network needed) */
	struct addrinfo hints, *ai;
	memset(&hints, 0, sizeof hints);
	hints.ai_family = AF_INET;
	hints.ai_socktype = SOCK_STREAM;
	int g1 = getaddrinfo("10.0.2.2", "80", &hints, &ai) == 0
		&& ((struct sockaddr_in *)ai->ai_addr)->sin_port == htons(80);
	if (g1) freeaddrinfo(ai);
	int g2 = getaddrinfo("localhost", "http", &hints, &ai) == 0
		&& ((struct sockaddr_in *)ai->ai_addr)->sin_addr.s_addr == htonl(INADDR_LOOPBACK);
	if (g2) freeaddrinfo(ai);
	check("getaddrinfo numeric + localhost", g1 && g2);

	printf("socktest: %s\n", bad ? "FAILED" : "ok");
	return bad ? 1 : 0;
}
