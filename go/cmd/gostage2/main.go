package main

// Stage 2 for Go on racccoon (docs/go-port-plan.md): the runtime under
// load — the garbage collector, goroutines + channels, sync primitives,
// and the timer path (time.Sleep / time.Now). Single M (GOMAXPROCS=1),
// cooperative — the goroutines interleave at scheduling points, they do
// not run in parallel.
//
// Exits 0 only if every check passes; the shell's gostage2test reads
// that exit code.

import (
	"runtime"
	"sync"
	"time"
)

var failed bool

func check(name string, ok bool) {
	if ok {
		println("  ok  ", name)
	} else {
		println("  FAIL", name)
		failed = true
	}
}

// gc exercises the collector: churn through far more allocation than the
// live set, force a cycle, and confirm GC actually ran and the heap did
// not run away.
func gc() {
	var ms0, ms1 runtime.MemStats
	runtime.ReadMemStats(&ms0)

	live := make([][]byte, 64) // ~2 MiB kept live
	for i := range live {
		live[i] = make([]byte, 32*1024)
	}

	// ~48 MiB of pure garbage, in 24 KiB bites
	for i := 0; i < 2000; i++ {
		b := make([]byte, 24*1024)
		b[0] = byte(i)
		b[len(b)-1] = byte(i)
		if i%512 == 0 {
			runtime.GC()
		}
	}
	runtime.GC()

	runtime.ReadMemStats(&ms1)
	check("gc ran", ms1.NumGC > ms0.NumGC)
	check("heap bounded (<96 MiB)", ms1.HeapAlloc < 96*1024*1024)

	// live set still intact after all those cycles
	intact := true
	for i := range live {
		if len(live[i]) != 32*1024 {
			intact = false
		}
	}
	check("live set survived gc", intact)
	runtime.KeepAlive(live)
}

// goroutines: a fan-out/fan-in over a channel plus a WaitGroup, then a
// select with a timeout arm.
func goroutines() {
	const n = 200
	results := make(chan int, n)
	var wg sync.WaitGroup
	wg.Add(n)
	for i := 0; i < n; i++ {
		go func(k int) {
			defer wg.Done()
			s := 0
			for j := 0; j <= k; j++ {
				s += j
			}
			results <- s
		}(i)
	}
	wg.Wait()
	close(results)

	total := 0
	got := 0
	for r := range results {
		total += r
		got++
	}
	// sum over k of k*(k+1)/2, k=0..199
	want := 0
	for k := 0; k < n; k++ {
		want += k * (k + 1) / 2
	}
	check("all goroutines reported", got == n)
	check("channel results correct", total == want)

	done := make(chan struct{})
	go func() { close(done) }()
	select {
	case <-done:
		check("select recv", true)
	case <-time.After(time.Second):
		check("select recv", false)
	}

	var mu sync.Mutex
	counter := 0
	var wg2 sync.WaitGroup
	wg2.Add(100)
	for i := 0; i < 100; i++ {
		go func() {
			defer wg2.Done()
			mu.Lock()
			counter++
			mu.Unlock()
		}()
	}
	wg2.Wait()
	check("mutex-guarded counter", counter == 100)
}

// timers: time.Now must advance across a sleep, and by roughly the
// requested amount (loose bounds — this is a spin-idle scheduler).
func timers() {
	start := time.Now()
	time.Sleep(20 * time.Millisecond)
	elapsed := time.Since(start)
	check("time advanced across Sleep", elapsed > 0)
	check("Sleep ~20ms (5ms..500ms)", elapsed > 5*time.Millisecond && elapsed < 500*time.Millisecond)

	ticks := 0
	deadline := time.After(80 * time.Millisecond)
	t := time.NewTicker(10 * time.Millisecond)
	defer t.Stop()
loop:
	for {
		select {
		case <-t.C:
			ticks++
		case <-deadline:
			break loop
		}
	}
	check("ticker fired a few times", ticks >= 2 && ticks <= 20)
}

func main() {
	println("go stage 2: runtime under load")
	println("GOMAXPROCS =", runtime.GOMAXPROCS(0), " NumGoroutine =", runtime.NumGoroutine())

	println("[gc]")
	gc()
	println("[goroutines]")
	goroutines()
	println("[timers]")
	timers()

	if failed {
		println("go stage 2: FAILED")
		panic("stage 2 checks failed")
	}
	println("go stage 2: all checks passed")
}
