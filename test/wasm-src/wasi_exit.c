// WASI fixture: exit(7) must reach the shell as exit code 7 (proc_exit), with
// stdio flushed first.
#include <stdio.h>
#include <stdlib.h>

int main(void)
{
    printf("exiting with 7\n");
    exit(7);
}
