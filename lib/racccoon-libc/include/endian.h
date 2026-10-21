#ifndef _ENDIAN_H
#define _ENDIAN_H

/* RISC-V is little-endian. */
#define LITTLE_ENDIAN 1234
#define BIG_ENDIAN    4321
#define PDP_ENDIAN    3412
#define BYTE_ORDER    LITTLE_ENDIAN
#define __LITTLE_ENDIAN LITTLE_ENDIAN
#define __BIG_ENDIAN    BIG_ENDIAN
#define __BYTE_ORDER    BYTE_ORDER

#endif
