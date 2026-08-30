/* roadmap §7 stage 5 — stdio: the printf family + buffered FILE* I/O.
 * "stage5test: ok" (0) or the first failing case (1). */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>

static int fails = 0;

static void chk(const char *got, const char *want, const char *what)
{
	if (strcmp(got, want) != 0) {
		fails++;
		fprintf(stderr, "  %s: got \"%s\" want \"%s\"\n", what, got, want);
	}
}

int main(void)
{
	char b[128];

	snprintf(b, sizeof b, "%d %i %u", -7, 42, 4000000000u);
	chk(b, "-7 42 4000000000", "int");

	snprintf(b, sizeof b, "%5d|%-5d|%05d|%+d| %d", 3, 3, 3, 3, 3);
	chk(b, "    3|3    |00003|+3| 3", "int width/flags");

	snprintf(b, sizeof b, "%x %X %#x %o %#o", 255, 255, 255, 8, 8);
	chk(b, "ff FF 0xff 10 010", "hex/oct");

	snprintf(b, sizeof b, "%ld %lld %zu", 10000000000L, -10000000000LL, sizeof(int));
	chk(b, "10000000000 -10000000000 4", "long");

	snprintf(b, sizeof b, "[%s][%10s][%-10s][%.3s]", "hi", "hi", "hi", "truncate");
	chk(b, "[hi][        hi][hi        ][tru]", "string");

	snprintf(b, sizeof b, "%c%c%c", 'a', 'b', 'c');
	chk(b, "abc", "char");

	snprintf(b, sizeof b, "%.2f %.0f %.3f %+.1f", 3.14159, 7.0, 0.125, 2.5);
	chk(b, "3.14 7 0.125 +2.5", "float");

	snprintf(b, sizeof b, "%d%% done, ptr=%p", 50, (void *)0x1234);
	chk(b, "50% done, ptr=0x1234", "misc");

	int wrote = snprintf(b, 6, "%s", "abcdefghij");
	if (wrote != 10 || strcmp(b, "abcde") != 0) { fails++; fprintf(stderr, "  snprintf trunc: \"%s\" (%d)\n", b, wrote); }

	/* FILE* round trip */
	const char *path = "/CT5.TXT";
	FILE *f = fopen(path, "w");
	if (!f) { printf("stage5test: FAILED (fopen w)\n"); return 1; }
	fprintf(f, "line one\n");
	fprintf(f, "value = %d\n", 123);
	fputs("last line\n", f);
	fclose(f);

	f = fopen(path, "r");
	if (!f) { printf("stage5test: FAILED (fopen r)\n"); return 1; }
	char line[64];
	fgets(line, sizeof line, f); chk(line, "line one\n", "fgets 1");
	fgets(line, sizeof line, f); chk(line, "value = 123\n", "fgets 2");

	/* getline for the rest */
	char *lp = NULL; size_t ln = 0;
	if (getline(&lp, &ln, f) < 0 || strcmp(lp, "last line\n") != 0) { fails++; fprintf(stderr, "  getline: \"%s\"\n", lp ? lp : "(null)"); }
	free(lp);

	/* ftell / fseek */
	rewind(f);
	if (fgetc(f) != 'l') fails++;
	if (ftell(f) != 1) { fails++; fprintf(stderr, "  ftell after 1 getc: %ld\n", ftell(f)); }
	fseek(f, 0, SEEK_END);
	long size = ftell(f);
	if (size != 31) { fails++; fprintf(stderr, "  file size: %ld want 31\n", size); }
	fclose(f);

	unlink(path);

	if (fails) { printf("stage5test: FAILED (%d)\n", fails); return 1; }
	printf("stage5test: ok\n");
	return 0;
}
