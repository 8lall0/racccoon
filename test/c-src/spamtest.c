#include <stdio.h>

/* Prints a lot of console output then exits -- isolates whether heavy
 * console/UART volume (not memory footprint) is what makes SYS_EXIT
 * hang after c3c's -vvv stdlib compile (see docs/devlog.md, c3c
 * self-host arc). */
int main(void)
{
	for (int i = 0; i < 80000; i++)
		printf("spam line %d of 80000, some padding text here too\n", i);
	printf("spamtest: done, exiting\n"); fflush(stdout);
	return 0;
}
