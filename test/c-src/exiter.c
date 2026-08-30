/* roadmap §7 stage 6 helper: a program stage6test.c fork+exec's and
 * then reads back through its exit code.
 *   exiter            -> 42
 *   exiter <n>        -> n
 *   exiter argv0      -> 0 iff argv[0] == "exiter-was-here"
 *   exiter env <NAME> -> 0 iff getenv(<NAME>) == "yes"
 */
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
	if (argc >= 3 && strcmp(argv[1], "env") == 0) {
		char *v = getenv(argv[2]);
		return (v && strcmp(v, "yes") == 0) ? 0 : 1;
	}
	if (argc >= 2 && strcmp(argv[1], "argv0") == 0)
		return strcmp(argv[0], "exiter-was-here") == 0 ? 0 : 1;
	if (argc >= 2)
		return atoi(argv[1]);
	return 42;
}
