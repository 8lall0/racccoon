#ifndef _SYS_TYPES_H
#define _SYS_TYPES_H
#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>

typedef long          ssize_t;
typedef long          off_t;
typedef unsigned int  mode_t;
typedef int           pid_t;
typedef unsigned int  uid_t;
typedef unsigned int  gid_t;
typedef unsigned long ino_t;
typedef unsigned int  nlink_t;
typedef long          time_t;
typedef long          blkcnt_t;
typedef long          blksize_t;
typedef unsigned int  dev_t;

#ifdef __cplusplus
}
#endif
#endif
