#ifndef _CTYPE_H
#define _CTYPE_H

/* ASCII only — racccoon has no locale. Defined as functions in
 * src/ctype.c (not macros) so &isdigit etc. work and the addresses are
 * stable, the way portable C sometimes expects. */

int isalnum(int c);
int isalpha(int c);
int isblank(int c);
int iscntrl(int c);
int isdigit(int c);
int isgraph(int c);
int islower(int c);
int isprint(int c);
int ispunct(int c);
int isspace(int c);
int isupper(int c);
int isxdigit(int c);
int tolower(int c);
int toupper(int c);

#endif
