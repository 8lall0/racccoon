/* On-device TinyCC smoke test (roadmap §7.7). Seeded to /hello.c by
 * scripts/seed_tcc.sh.
 *   tcc -E /hello.c              preprocessor only
 *   tcc -c /hello.c -o /x.o      riscv64 codegen + ELF object
 *   tcc /hello.c -o /bin/hello   full compile + link (static, at
 *                                USER_BASE — lib/tcc/config.h + the
 *                                racccoon.patch set the defaults), then
 *   hello world                  run it
 *
 * Self-host (roadmap §7.8):
 *   tcc -DONE_SOURCE=1 -DCONFIG_TCC_STATIC=1 -DCONFIG_TCC_SEMLOCK=0 \
 *       -I/src/tcc /src/tcc/tcc.c -o /bin/tcc2
 *   tcc2 /hello.c -o /bin/hw2 && hw2 world
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int add(int a, int b) { return a + b; }

int main(int argc, char **argv)
{
	printf("hello from tcc-compiled C on racccoon\n");
	printf("2 + 3 = %d\n", add(2, 3));

	char buf[32];
	strcpy(buf, "abc");
	strcat(buf, "def");
	printf("strcat: %s (len %d)\n", buf, (int)strlen(buf));

	if (argc > 1)
		printf("argv[1] = %s, atoi = %d\n", argv[1], atoi(argv[1]));

	return 0;
}
