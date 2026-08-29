module kernel;

// Anonymous byte pipes for the shell's `|` and `>`/`<` redirection.
// A pipe is a kernel ring buffer with writer and reader refcounts. A
// process's stdout_pipe / stdin_pipe (Process, -1 = the console) point
// at one; SYS_PUTCHAR / SYS_GETCHAR route through it. The shell sets a
// child's ends with SYS_PIPE_SETOUT/SETIN right after rfork (before the
// child runs), and pumps a file end itself with SYS_PIPE_READ/WRITE.
//
// Bounded (PIPE_BUF): a `< bigfile` larger than this, or a producer
// that races far ahead of its consumer, just blocks until space frees
// — never grows. Fine at shell scale.

const int PIPES_MAX = 6;
const int PIPE_BUF  = 4096;

struct Pipe
{
	char[PIPE_BUF] data;
	int  head;   // read cursor
	int  count;  // bytes currently buffered
	int  writers;
	int  readers;
	bool used;
}

Pipe[PIPES_MAX] pipes;

fn int pipe_alloc()
{
	for (int i = 0; i < PIPES_MAX; i++)
	{
		if (!pipes[i].used)
		{
			pipes[i].used    = true;
			pipes[i].head    = 0;
			pipes[i].count   = 0;
			pipes[i].writers = 0;
			pipes[i].readers = 0;
			return i;
		}
	}
	return -1;
}

fn bool pipe_valid(int id)
{
	return id >= 0 && id < PIPES_MAX && pipes[id].used;
}

fn void pipe_free_if_idle(int id)
{
	if (pipe_valid(id) && pipes[id].writers == 0 && pipes[id].readers == 0)
	{
		pipes[id].used = false;
	}
}

// A process detaching one end (SYS_PIPE_SET* to a new target, or exit).
fn void pipe_detach(int id, bool as_writer)
{
	if (!pipe_valid(id)) { return; }
	if (as_writer) { if (pipes[id].writers > 0) { pipes[id].writers--; } }
	else           { if (pipes[id].readers > 0) { pipes[id].readers--; } }
	pipe_free_if_idle(id);
}

// Non-blocking single-byte put. true = stored (or harmlessly dropped —
// a closed/reader-less pipe swallows writes, SIGPIPE-style); false =
// buffer full, caller should yield and retry.
fn bool pipe_try_put(int id, char c)
{
	if (!pipe_valid(id) || pipes[id].readers == 0) { return true; }
	if (pipes[id].count >= PIPE_BUF) { return false; }
	int w = (pipes[id].head + pipes[id].count) % PIPE_BUF;
	pipes[id].data[w] = c;
	pipes[id].count++;
	return true;
}

// Non-blocking single-byte get. 0 = got a byte into *out; 1 = empty but
// writers remain (caller should yield and retry); 2 = EOF (empty, no
// writers left).
fn int pipe_try_get(int id, char* out)
{
	if (!pipe_valid(id)) { return 2; }
	if (pipes[id].count > 0)
	{
		*out = pipes[id].data[pipes[id].head];
		pipes[id].head = (pipes[id].head + 1) % PIPE_BUF;
		pipes[id].count--;
		return 0;
	}
	return pipes[id].writers == 0 ? 2 : 1;
}
