#ifndef _RACCCOON_ARPA_INET_H
#define _RACCCOON_ARPA_INET_H
#ifdef __cplusplus
extern "C" {
#endif
#include <netinet/in.h>
int inet_pton(int af, const char *src, void *dst);
const char *inet_ntop(int af, const void *src, char *dst, socklen_t size);
in_addr_t inet_addr(const char *cp);
int inet_aton(const char *cp, struct in_addr *inp);
char *inet_ntoa(struct in_addr in);
#ifdef __cplusplus
}
#endif
#endif
