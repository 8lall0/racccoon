#ifndef _INTTYPES_H
#define _INTTYPES_H

#include <stdint.h>

/* LP64: 64-bit values are `long`. */
#define PRId8   "d"
#define PRId16  "d"
#define PRId32  "d"
#define PRId64  "ld"
#define PRIi32  "i"
#define PRIi64  "li"
#define PRIu8   "u"
#define PRIu16  "u"
#define PRIu32  "u"
#define PRIu64  "lu"
#define PRIx32  "x"
#define PRIx64  "lx"
#define PRIX32  "X"
#define PRIX64  "lX"
#define PRIo64  "lo"

#define PRIdPTR "ld"
#define PRIuPTR "lu"
#define PRIxPTR "lx"

typedef struct { intmax_t quot; intmax_t rem; } imaxdiv_t;

intmax_t  imaxabs(intmax_t j);
intmax_t  strtoimax(const char *nptr, char **endptr, int base);
uintmax_t strtoumax(const char *nptr, char **endptr, int base);

#endif
