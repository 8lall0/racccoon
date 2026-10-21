/* Source of hello.ll, the llctest fixture: a loop, a call, a switch,
 * some double math and a global string. Regenerate with
 *   clang --target=riscv64-unknown-elf -march=rv64imafdc -mabi=lp64d \
 *         -O1 -S -emit-llvm hello.c -o hello.ll
 * (any racccoon-era clang; llctest compares racccoon's llc against the
 * host llc on the same .ll, so the .ll itself needn't be reproducible). */
extern int puts(const char *s);

static const char *names[] = { "zero", "one", "two", "many" };

const char *name(int n)
{
	switch (n) {
	case 0: return names[0];
	case 1: return names[1];
	case 2: return names[2];
	default: return names[3];
	}
}

double mean(const double *v, int n)
{
	double s = 0;
	for (int i = 0; i < n; i++) s += v[i] * 0.5 + v[i] / 3.0;
	return n ? s / n : 0;
}

int main(void)
{
	static double v[8] = { 1, 2, 3, 4, 5, 6, 7, 8 };
	puts("hello from llc");
	puts(name((int)mean(v, 8)));
	return 0;
}
