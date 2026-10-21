#include <ctype.h>

int isdigit(int c)  { return c >= '0' && c <= '9'; }
int isupper(int c)  { return c >= 'A' && c <= 'Z'; }
int islower(int c)  { return c >= 'a' && c <= 'z'; }
int isalpha(int c)  { return isupper(c) || islower(c); }
int isalnum(int c)  { return isalpha(c) || isdigit(c); }
int isspace(int c)  { return c == ' ' || (c >= '\t' && c <= '\r'); }
int isblank(int c)  { return c == ' ' || c == '\t'; }
int iscntrl(int c)  { return (c >= 0 && c < 32) || c == 127; }
int isprint(int c)  { return c >= 32 && c < 127; }
int isgraph(int c)  { return c > 32 && c < 127; }
int ispunct(int c)  { return isgraph(c) && !isalnum(c); }
int isxdigit(int c) { return isdigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'); }

int tolower(int c)  { return isupper(c) ? c + 32 : c; }
int toupper(int c)  { return islower(c) ? c - 32 : c; }

int isalnum_l(int c, locale_t l) { (void)l; return isalnum(c); }
int isalpha_l(int c, locale_t l) { (void)l; return isalpha(c); }
int isblank_l(int c, locale_t l) { (void)l; return isblank(c); }
int iscntrl_l(int c, locale_t l) { (void)l; return iscntrl(c); }
int isdigit_l(int c, locale_t l) { (void)l; return isdigit(c); }
int isgraph_l(int c, locale_t l) { (void)l; return isgraph(c); }
int islower_l(int c, locale_t l) { (void)l; return islower(c); }
int isprint_l(int c, locale_t l) { (void)l; return isprint(c); }
int ispunct_l(int c, locale_t l) { (void)l; return ispunct(c); }
int isspace_l(int c, locale_t l) { (void)l; return isspace(c); }
int isupper_l(int c, locale_t l) { (void)l; return isupper(c); }
int isxdigit_l(int c, locale_t l) { (void)l; return isxdigit(c); }
int tolower_l(int c, locale_t l) { (void)l; return tolower(c); }
int toupper_l(int c, locale_t l) { (void)l; return toupper(c); }
