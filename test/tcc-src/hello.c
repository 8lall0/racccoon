/* On-device TinyCC smoke test (roadmap §7.7).
 *   tcc -E /hello.c            preprocessor only
 *   tcc -c /hello.c -o /h.o    riscv64 codegen + ELF object
 *   tcc /hello.c -o /hello     full compile + link, then run /hello
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
