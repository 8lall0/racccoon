#ifndef _RACCCOON_POLL_H
#define _RACCCOON_POLL_H
/* poll(2) on SYS_AWAIT (lib/racccoon-libc/src/rc_posix.c). Regular files
 * are always ready; stdin waits for the console or its pipe; stdout and
 * stderr are always writable. A note (^C) makes it return -1/EINTR. */
typedef unsigned long nfds_t;
struct pollfd { int fd; short events; short revents; };
#define POLLIN   0x001
#define POLLPRI  0x002
#define POLLOUT  0x004
#define POLLERR  0x008
#define POLLHUP  0x010
#define POLLNVAL 0x020
int poll(struct pollfd *fds, nfds_t nfds, int timeout_ms);
#endif
