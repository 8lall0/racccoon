#ifndef _RACCCOON_NETDB_H
#define _RACCCOON_NETDB_H
#ifdef __cplusplus
extern "C" {
#endif
#include <netinet/in.h>
struct addrinfo {
	int ai_flags, ai_family, ai_socktype, ai_protocol;
	socklen_t ai_addrlen;
	struct sockaddr *ai_addr;
	char *ai_canonname;
	struct addrinfo *ai_next;
};
struct hostent { char *h_name; char **h_aliases; int h_addrtype; int h_length; char **h_addr_list; };
#define h_addr h_addr_list[0]
#define AI_PASSIVE     0x01
#define AI_CANONNAME   0x02
#define AI_NUMERICHOST 0x04
#define AI_NUMERICSERV 0x400
#define EAI_NONAME  -2
#define EAI_FAMILY  -6
#define EAI_SERVICE -8
#define EAI_MEMORY  -10
#define EAI_FAIL    -4
int getaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res);
void freeaddrinfo(struct addrinfo *res);
const char *gai_strerror(int err);
struct hostent *gethostbyname(const char *name);
#ifdef __cplusplus
}
#endif
#endif
