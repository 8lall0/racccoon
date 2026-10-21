#ifndef _RACCCOON_SYS_SOCKET_H
#define _RACCCOON_SYS_SOCKET_H
#ifdef __cplusplus
extern "C" {
#endif
/* BSD sockets on racccoon's /net (ipd, user/net/ipd.c3) — IPv4 TCP/UDP.
 * lib/racccoon-libc/src/rc_socket.c. A socket is a /net conversation;
 * setsockopt is accepted and ignored; poll() reports sockets as always
 * ready (a read just waits for data). */
#include <sys/types.h>
typedef unsigned int socklen_t;
typedef unsigned short sa_family_t;
struct sockaddr { sa_family_t sa_family; char sa_data[14]; };
struct sockaddr_storage { sa_family_t ss_family; char __pad[126]; };
#define AF_UNSPEC 0
#define AF_INET   2
#define PF_INET   AF_INET
#define AF_INET6  10
#define SOCK_STREAM 1
#define SOCK_DGRAM  2
#define SOL_SOCKET   1
#define SO_REUSEADDR 2
#define SO_KEEPALIVE 9
#define SO_RCVTIMEO  20
#define SO_SNDTIMEO  21
#define SO_ERROR     4
#define SHUT_RD   0
#define SHUT_WR   1
#define SHUT_RDWR 2
#define MSG_NOSIGNAL 0x4000
int socket(int domain, int type, int protocol);
int bind(int fd, const struct sockaddr *addr, socklen_t len);
int listen(int fd, int backlog);
int accept(int fd, struct sockaddr *addr, socklen_t *len);
int connect(int fd, const struct sockaddr *addr, socklen_t len);
ssize_t send(int fd, const void *buf, size_t n, int flags);
ssize_t recv(int fd, void *buf, size_t n, int flags);
ssize_t sendto(int fd, const void *buf, size_t n, int flags, const struct sockaddr *to, socklen_t tolen);
ssize_t recvfrom(int fd, void *buf, size_t n, int flags, struct sockaddr *from, socklen_t *fromlen);
int shutdown(int fd, int how);
int setsockopt(int fd, int level, int name, const void *val, socklen_t len);
int getsockopt(int fd, int level, int name, void *val, socklen_t *len);
int getsockname(int fd, struct sockaddr *addr, socklen_t *len);
int getpeername(int fd, struct sockaddr *addr, socklen_t *len);
#ifdef __cplusplus
}
#endif
#endif
