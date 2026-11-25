// The Go half of the rule-matching spike (see ../src). Same LCG, same workload,
// same hash-set-of-suffixes algorithm, so the Rust number means something.
//
//	go run main.go
package main

import (
	"fmt"
	"strings"
	"time"
)

type lcg uint64

func (l *lcg) next() uint64 {
	*l = lcg(uint64(*l)*6364136223846793005 + 1442695040888963407)
	return uint64(*l)
}

const (
	rules   = 200_000
	queries = 1_000_000
)

var tlds = []string{"com", "net", "org"}

var index map[string]struct{}

func matches(name string) bool {
	for start := 0; ; {
		if _, ok := index[name[start:]]; ok {
			return true
		}
		offset := strings.IndexByte(name[start:], '.')
		if offset < 0 {
			return false
		}
		start += offset + 1
	}
}

func main() {
	var rng lcg = 0x5eed1234abcd9876
	names := make([]string, 0, rules)
	for i := 0; i < rules; i++ {
		names = append(names, fmt.Sprintf("site%d.%s", i, tlds[i%len(tlds)]))
	}
	qs := make([]string, 0, queries)
	for i := 0; i < queries; i++ {
		a := rng.next()
		b := rng.next()
		if i%2 == 0 {
			qs = append(qs, fmt.Sprintf("sub%d.site%d.%s", a%1000, b%rules, tlds[i%len(tlds)]))
		} else {
			qs = append(qs, fmt.Sprintf("miss%d.nomatch%d.%s", a, b%rules, tlds[i%len(tlds)]))
		}
	}

	started := time.Now()
	index = make(map[string]struct{}, len(names))
	for _, name := range names {
		index[name] = struct{}{}
	}
	build := time.Since(started)

	best := time.Duration(1<<63 - 1)
	matched := 0
	for round := 0; round < 3; round++ {
		started = time.Now()
		hits := 0
		for _, query := range qs {
			if matches(query) {
				hits++
			}
		}
		if elapsed := time.Since(started); elapsed < best {
			best = elapsed
		}
		matched = hits
	}

	perQuery := float64(best.Nanoseconds()) / queries
	fmt.Printf("go rules=%d queries=%d build_ms=%.1f query_ms=%.1f ns_per_query=%.2f matches=%d\n",
		len(index), queries, float64(build.Microseconds())/1000, float64(best.Microseconds())/1000, perQuery, matched)
}
