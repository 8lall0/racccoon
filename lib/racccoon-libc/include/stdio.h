#ifndef _STDIO_H
#define _STDIO_H

#include <stddef.h>
#include <stdarg.h>
#include <sys/types.h>

#define EOF        (-1)
#define BUFSIZ     4096
#define FOPEN_MAX  64
#define FILENAME_MAX 256
#define L_tmpnam   32

#define _IOFBF 0
#define _IOLBF 1
#define _IONBF 2

/* SEEK_* also in <unistd.h>; guard so both can be included. */
#ifndef SEEK_SET
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
#endif

typedef struct __FILE FILE;
typedef off_t fpos_t;

extern FILE *stdin;
extern FILE *stdout;
extern FILE *stderr;

FILE  *fopen(const char *path, const char *mode);
FILE  *fdopen(int fd, const char *mode);
FILE  *open_memstream(char **bufp, size_t *sizep);
FILE  *popen(const char *cmd, const char *mode);
int    pclose(FILE *f);
FILE  *freopen(const char *path, const char *mode, FILE *f);
int    fclose(FILE *f);
int    fflush(FILE *f);

size_t fread(void *ptr, size_t size, size_t nmemb, FILE *f);
size_t fwrite(const void *ptr, size_t size, size_t nmemb, FILE *f);

int    fgetc(FILE *f);
int    getc(FILE *f);
int    getchar(void);
int    ungetc(int c, FILE *f);
char  *fgets(char *s, int n, FILE *f);

int    fputc(int c, FILE *f);
int    putc(int c, FILE *f);
int    putchar(int c);
int    fputs(const char *s, FILE *f);
int    puts(const char *s);

int    fseek(FILE *f, long off, int whence);
long   ftell(FILE *f);
void   rewind(FILE *f);
int    fgetpos(FILE *f, fpos_t *pos);
int    fsetpos(FILE *f, const fpos_t *pos);

int    feof(FILE *f);
int    ferror(FILE *f);
void   clearerr(FILE *f);
int    fileno(FILE *f);

int    setvbuf(FILE *f, char *buf, int mode, size_t size);
void   setbuf(FILE *f, char *buf);

int    printf(const char *fmt, ...)                 __attribute__((format(printf, 1, 2)));
int    fprintf(FILE *f, const char *fmt, ...)       __attribute__((format(printf, 2, 3)));
int    sprintf(char *s, const char *fmt, ...)       __attribute__((format(printf, 2, 3)));
int    snprintf(char *s, size_t n, const char *fmt, ...) __attribute__((format(printf, 3, 4)));
int    vprintf(const char *fmt, va_list ap);
int    vfprintf(FILE *f, const char *fmt, va_list ap);
int    vsprintf(char *s, const char *fmt, va_list ap);
int    vsnprintf(char *s, size_t n, const char *fmt, va_list ap);

void   perror(const char *s);
int    remove(const char *path);
int    rename(const char *oldp, const char *newp);

FILE  *tmpfile(void);
char  *tmpnam(char *s);

ssize_t getline(char **lineptr, size_t *n, FILE *f);
ssize_t getdelim(char **lineptr, size_t *n, int delim, FILE *f);

#endif
