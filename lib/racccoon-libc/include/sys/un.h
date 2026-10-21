#ifndef _SYS_UN_H
#define _SYS_UN_H
#ifdef __cplusplus
extern "C" {
#endif

/* Unix-domain addresses, for code that names them. racccoon's sockets
 * are TCP/UDP only (ipd), so socket(AF_UNIX, …) fails. */

#include <sys/socket.h>

#define AF_UNIX  1
#define AF_LOCAL AF_UNIX
#define PF_UNIX  AF_UNIX

struct sockaddr_un {
	sa_family_t sun_family;
	char        sun_path[108];
};

#ifdef __cplusplus
}
#endif
#endif
