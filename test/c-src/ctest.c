/* First C program to run on racccoon (roadmap §7 stage 1).
 * Proves crt0 + the argv ABI + console write() + exit codes.
 *   ctest            -> "hello from C on racccoon", exit 0
 *   ctest a b c      -> also "argv[1..]: a b c", exit 3
 */
#include <unistd.h>

static void puts_(const char *s)
{
	unsigned long n = 0;
	while (s[n]) n++;
	write(STDOUT_FILENO, s, n);
}

int main(int argc, char **argv, char **envp)
{
	(void)envp;
	puts_("hello from C on racccoon\n");

	if (argc > 1) {
		puts_("argv[1..]:");
		for (int i = 1; i < argc; i++) {
			puts_(" ");
			puts_(argv[i]);
		}
		puts_("\n");
		return 3;
	}
	return 0;
}
