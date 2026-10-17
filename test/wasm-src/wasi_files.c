// WASI fixture: file + directory I/O through wasi-libc (path_open, fd_read/
// write/seek, filestat, readdir, rename, unlink, mkdir/rmdir). Self-checking:
// exits 0 on success, else the number of the first failed check. Works from
// any cwd that has a writable `tmp/` below it (racccoon images: the root).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <errno.h>
#include <sys/stat.h>
#include <unistd.h>

#define CHECK(n, cond) do { if (!(cond)) { printf("wasi_files: check %d failed (errno %d)\n", n, errno); return n; } } while (0)

int main(void)
{
    const char *d = "tmp/wasid";
    const char *f = "tmp/wasid/a.txt";
    const char *g = "tmp/wasid/b.txt";
    char buf[128];

    remove(g); remove(f); rmdir(d);                       // leftovers from a failed run

    CHECK(1, mkdir(d, 0755) == 0);
    struct stat st;
    CHECK(2, stat(d, &st) == 0 && S_ISDIR(st.st_mode));

    FILE *fp = fopen(f, "w");
    CHECK(3, fp != NULL);
    CHECK(4, fprintf(fp, "line one\nline %d\n", 2) > 0);
    CHECK(5, fclose(fp) == 0);

    CHECK(6, stat(f, &st) == 0 && S_ISREG(st.st_mode) && st.st_size == 16);

    fp = fopen(f, "r");
    CHECK(7, fp != NULL);
    CHECK(8, fgets(buf, sizeof buf, fp) != NULL && strcmp(buf, "line one\n") == 0);
    CHECK(9, fgets(buf, sizeof buf, fp) != NULL && strcmp(buf, "line 2\n") == 0);
    CHECK(10, fgets(buf, sizeof buf, fp) == NULL);        // EOF
    CHECK(11, fseek(fp, 5, SEEK_SET) == 0 && fgetc(fp) == 'o');
    CHECK(12, fseek(fp, 0, SEEK_END) == 0 && ftell(fp) == 16);
    fclose(fp);

    fp = fopen(f, "a");                                    // append
    CHECK(13, fp != NULL && fputs("tail\n", fp) >= 0);
    fclose(fp);
    CHECK(14, stat(f, &st) == 0 && st.st_size == 21);

    fp = fopen(f, "r+");                                   // overwrite in place
    CHECK(15, fp != NULL && fseek(fp, 0, SEEK_SET) == 0 && fputs("LINE", fp) >= 0);
    fclose(fp);
    fp = fopen(f, "r");
    CHECK(16, fp != NULL && fgets(buf, sizeof buf, fp) != NULL && strcmp(buf, "LINE one\n") == 0);
    fclose(fp);

    DIR *dir = opendir(d);
    CHECK(17, dir != NULL);
    int seen = 0;
    struct dirent *de;
    while ((de = readdir(dir)) != NULL)
        if (strcmp(de->d_name, "a.txt") == 0) seen = 1;
    closedir(dir);
    CHECK(18, seen);

    CHECK(19, rename(f, g) == 0);
    CHECK(20, stat(f, &st) != 0 && errno == ENOENT);
    CHECK(21, stat(g, &st) == 0 && st.st_size == 21);

    CHECK(22, fopen("tmp/wasid/missing.txt", "r") == NULL && errno == ENOENT);
    CHECK(23, rmdir(d) != 0);                              // not empty

    CHECK(24, remove(g) == 0);
    CHECK(25, rmdir(d) == 0);
    CHECK(26, stat(d, &st) != 0);

    printf("wasi_files: ok\n");
    return 0;
}
