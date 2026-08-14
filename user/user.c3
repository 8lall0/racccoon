module user;

// Linker script symbol - declared as extern so C3 knows about it,
// @cname ensures no mangling
extern char[] __stack_top @cname("__stack_top");

const int SYS_PUTCHAR   = 1;
const int SYS_GETCHAR   = 2;
const int SYS_READFILE  = 4;
const int SYS_WRITEFILE = 5;

// @export gives these functions C-compatible names so asm can call them
fn void exit() @noreturn @export("exit") {
    for (;;);
}

fn int syscall(int sysno, int arg0, int arg1, int arg2) {
    int result;
    asm {
        mv $a0, arg0;
        mv $a1, arg1;
        mv $a2, arg2;
        mv $a3, sysno;
        ecall;
        mv result, $a0;
    }
    return result;
}

fn void putchar(char ch) @export("putchar") {
    syscall(SYS_PUTCHAR, (int)ch, 0, 0);
}

fn int getchar() @export("getchar") {
    return syscall(SYS_GETCHAR, 0, 0, 0);
}

fn void print(char* s) {
    while (*s != 0) {
        putchar(*s);
        s++;
    }
}

fn int readfile(char* filename, char* buf, int len) @export("readfile") {
    return syscall(SYS_READFILE, (int)filename, (int)buf, len);
}

fn int writefile(char* filename, char* buf, int len) @export("writefile") {
    return syscall(SYS_WRITEFILE, (int)filename, (int)buf, len);
}

fn int strcmp(char* a, char* b) {
    while (*a != 0 && *a == *b) {
        a++;
        b++;
    }
    return (int)(char)*a - (int)(char)*b;
}

fn void start() @section(".text.start") @naked @nostrip @used @export("start") {
    asm(`
        la sp, __stack_top
        call main
        call exit
    `);
}
