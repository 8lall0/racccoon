// WASI fixture: sleep()/usleep()/nanosleep() (wasi-libc -> poll_oneoff with
// a clock subscription) must really wait, measured on CLOCK_MONOTONIC.
// Self-checking: exits 0, or the number of the first failed check.
#include <stdio.h>
#include <time.h>
#include <unistd.h>

static long long now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

int main(void)
{
    long long t0 = now_ms();
    if (usleep(200000) != 0) return 1;                       // 200 ms
    long long t1 = now_ms();
    if (t1 - t0 < 190 || t1 - t0 > 2000) { printf("usleep took %lld ms\n", t1 - t0); return 2; }

    struct timespec req = { 0, 300000000 };                  // 300 ms
    if (nanosleep(&req, NULL) != 0) return 3;
    long long t2 = now_ms();
    if (t2 - t1 < 290 || t2 - t1 > 2000) { printf("nanosleep took %lld ms\n", t2 - t1); return 4; }

    if (sleep(1) != 0) return 5;                             // 1 s
    long long t3 = now_ms();
    if (t3 - t2 < 990 || t3 - t2 > 3000) { printf("sleep took %lld ms\n", t3 - t2); return 6; }

    printf("wasi_sleep: ok (%lld / %lld / %lld ms)\n", t1 - t0, t2 - t1, t3 - t2);
    return 0;
}
