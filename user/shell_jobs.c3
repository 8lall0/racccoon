module user;

// Background job control for the shell (`cmd &`, `jobs`, `wait`) —
// split out of shell_common.c3. shell_run_pipeline registers a
// backgrounded pipeline here; shell_prompt calls shell_jobs_reap() once
// per prompt.
//
// The shell is one long-lived process, so a plain global table is all
// this needs. A job is a whole backgrounded pipeline — up to JOB_STAGES
// pids, each with its rfork generation so a recycled pid can't be
// mistaken for a still-running stage (same guard join() and the
// namespace already use). Reaped lazily: shell_jobs_reap() polls each
// job with proc_info and join()s the finished ones — join returns at
// once for an already-dead pid, so this never blocks.
const int JOBS_MAX     = 8;
const int JOB_STAGES    = 6;   // must match shell_run_pipeline's MAX_STAGES
const int JOB_CMD_MAX   = 72;

struct Job
{
    bool used;
    int  jobno;
    int  npid;
    int[JOB_STAGES]  pid;
    uint[JOB_STAGES] gen;
    char[JOB_CMD_MAX] cmd;
}
Job[JOBS_MAX] g_jobs;
int g_next_jobno = 1;

// Register a just-spawned background pipeline and print `[N] <lead pid>`.
fn void shell_job_add(int* pids, uint* gens, int n, char* cmd, int cmdlen)
{
    int slot = -1;
    for (int i = 0; i < JOBS_MAX; i++) { if (!g_jobs[i].used) { slot = i; break; } }
    if (slot < 0) { print("shell: too many background jobs\n"); return; }
    Job* j = &g_jobs[slot];
    j.used  = true;
    j.jobno = g_next_jobno; g_next_jobno++;
    j.npid  = n > JOB_STAGES ? JOB_STAGES : n;
    for (int i = 0; i < j.npid; i++) { j.pid[i] = pids[i]; j.gen[i] = gens[i]; }
    int s = 0;
    while (s < cmdlen && cmd[s] == ' ') { s++; }   // trim leading space
    int c = 0;
    while (s < cmdlen && c < JOB_CMD_MAX - 1) { j.cmd[c] = cmd[s]; c++; s++; }
    j.cmd[c] = 0;
    print("[");
    print_uint((uint)j.jobno);
    print("] ");
    print_uint((uint)pids[n - 1]);
    putchar('\n');
}

fn bool job_stage_alive(int pid, uint gen)
{
    uint g = 0;
    return proc_info(pid, null, &g, null) == 0 && g == gen;
}

// Print one finished job's line: `[N] done|exit S|killed   <cmd>`.
fn void job_report(Job* j, int st)
{
    print("[");
    print_uint((uint)j.jobno);
    print("] ");
    if (st == 0)      { print("done   "); }
    else if (st < 0)  { print("killed "); }
    else              { print("exit "); print_uint((uint)st); print("  "); }
    print(&j.cmd[0]);
    putchar('\n');
}

// Once per prompt: reap every job whose stages are all gone.
fn void shell_jobs_reap()
{
    for (int i = 0; i < JOBS_MAX; i++) {
        if (!g_jobs[i].used) { continue; }
        Job* j = &g_jobs[i];
        bool alive = false;
        for (int k = 0; k < j.npid; k++) {
            if (job_stage_alive(j.pid[k], j.gen[k])) { alive = true; break; }
        }
        if (alive) { continue; }
        int st = 0;
        for (int k = 0; k < j.npid; k++) { st = join(j.pid[k], j.gen[k]); }
        job_report(j, st);
        j.used = false;
    }
}

// `jobs` builtin.
fn void shell_jobs_list()
{
    shell_jobs_reap();   // report + drop anything that has already finished
    bool listed = false;
    for (int i = 0; i < JOBS_MAX; i++) {
        if (!g_jobs[i].used) { continue; }
        listed = true;
        Job* j = &g_jobs[i];
        print("[");
        print_uint((uint)j.jobno);
        print("] running  ");
        print(&j.cmd[0]);
        putchar('\n');
    }
    if (!listed) { print("no background jobs\n"); }
}

// `wait` builtin — block (cooperatively, via join) until every current
// background job has finished, reporting each as it's collected.
fn void shell_jobs_wait()
{
    for (int i = 0; i < JOBS_MAX; i++) {
        if (!g_jobs[i].used) { continue; }
        Job* j = &g_jobs[i];
        int st = 0;
        for (int k = 0; k < j.npid; k++) { st = join(j.pid[k], j.gen[k]); }
        job_report(j, st);
        j.used = false;
    }
}
