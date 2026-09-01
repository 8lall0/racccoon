package main

// Stage 1 smoke test for Go on racccoon. See docs/go-port-plan.md.

func main() {
	println("hello from go on racccoon")

	sum := 0
	for i := 1; i <= 100; i++ {
		sum += i
	}
	println("sum 1..100 =", sum)

	defer println("deferred: bye")

	xs := []int{}
	for i := 0; i < 8; i++ {
		xs = append(xs, i*i)
	}
	total := 0
	for _, v := range xs {
		total += v
	}
	println("sum of squares 0..7 =", total)
}
