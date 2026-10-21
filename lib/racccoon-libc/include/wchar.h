#ifndef _RACCCOON_WCHAR_H
#define _RACCCOON_WCHAR_H
#ifdef __cplusplus
extern "C" {
#endif
#include <stddef.h>
#ifndef __cplusplus   /* a keyword in C++ */
typedef int wchar_t;
#endif
typedef int wint_t;
#define WEOF ((wint_t)-1)
typedef struct { unsigned __opaque[2]; } mbstate_t;
#ifdef __cplusplus
}
#endif
#endif
