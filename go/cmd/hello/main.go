package main

// Stage 1 smoke test for Go on racccoon (docs/go-port-plan.md).
// Deliberately exercises a spread of runtime features without touching
// the filesystem or the network (neither is wired yet):
// println, integer + float arithmetic, defer, panic/recover, a slice
// with append, and a map.

func classify(n int) string {
	switch {
	case n < 0:
		return "neg"
	case n == 0:
		return "zero"
	default:
		return "pos"
	}
}

func mustPositive(n int) (ok bool) {
	defer func() {
		if recover() != nil {
			ok = false
		}
	}()
	if n <= 0 {
		panic("not positive")
	}
	return true
}

func main() {
	println("hello from go on racccoon")

	sum := 0
	for i := 1; i <= 100; i++ {
		sum += i
	}
	println("sum 1..100 =", sum)

	// float path (hardware FPU, roadmap §3)
	var f float64 = 1
	for i := 0; i < 10; i++ {
		f *= 1.5
	}
	println("1.5^10 ~", int(f))

	xs := []int{}
	for i := -2; i <= 5; i++ {
		xs = append(xs, i*i*i)
	}
	total := 0
	for _, v := range xs {
		total += v
	}
	println("sum of cubes -2..5 =", total)

	counts := map[string]int{}
	for _, n := range []int{-3, 0, 7, -1, 4, 0} {
		counts[classify(n)]++
	}
	println("neg/zero/pos =", counts["neg"], counts["zero"], counts["pos"])

	println("mustPositive(5) =", mustPositive(5))
	println("mustPositive(-1) =", mustPositive(-1))

	defer println("deferred: bye")
	println("done")
}
