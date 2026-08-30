#ifndef _DIRENT_H
#define _DIRENT_H

#include <sys/types.h>

#define DT_UNKNOWN 0
#define DT_DIR     4
#define DT_REG     8

struct dirent {
	ino_t         d_ino;
	unsigned char d_type;
	char          d_name[64];
};

typedef struct __dir DIR;

DIR           *opendir(const char *path);
struct dirent *readdir(DIR *d);
int            closedir(DIR *d);
void           rewinddir(DIR *d);

#endif
