/* exit() / abort(). atexit handlers + stdio flushing arrive with the
 * later stages; for now exit() is just _exit(). abort() exits with the
 * conventional 128 + SIGABRT code (racccoon has no signals). */
#include <stdlib.h>

void exit(int code)
{
	_exit(code);
}

void abort(void)
{
	_exit(134);   /* 128 + SIGABRT */
}
