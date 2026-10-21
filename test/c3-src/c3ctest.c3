// c3ctest's fixture: compiled on racccoon by /bin/c3c (compile-only,
// -g0) and compared byte-for-byte with the host's object for it
// (scripts/selfbuild_ref.sh). Freestanding: no stdlib needed.
module c3ctest;

struct Point { int x, y; }

fn int manhattan(Point a, Point b) @export("manhattan")
{
	int dx = a.x - b.x;
	int dy = a.y - b.y;
	return (dx < 0 ? -dx : dx) + (dy < 0 ? -dy : dy);
}

fn long sum_squares(int n) @export("sum_squares")
{
	long s = 0;
	for (int i = 1; i <= n; i++) s += (long)i * i;
	return s;
}

fn double mean(double* v, int n) @export("mean")
{
	double s = 0;
	for (int i = 0; i < n; i++) s += v[i];
	return n ? s / n : 0;
}
