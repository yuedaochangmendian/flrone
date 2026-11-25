# Rule-matching spike: Rust vs Go

**Question.** The proposal was to replace performance-critical parts of the
core (TUN / rules / DNS / crypto) with Rust. The only part of that list that can
cross the C ABI per *connection* instead of per *packet* is rule matching;
per-packet FFI is a non-starter (see the main answer). This spike measures the
one thing language choice can actually win here: the suffix match itself.

**Answer, in one line:** for the same algorithm (hash set of rule suffixes, walk
the query's label boundaries), **Rust is not faster than Go**. A language swap
alone buys nothing; only a better data structure or a different interface
(batching, memory layout) can.

## Workload

Identical, deterministic on both sides (same 64-bit LCG, same formatting):

| | |
| --- | --- |
| rules | 200,000 apex domains (`site<i>.com/net/org`) |
| queries | 1,000,000 (50% `sub<s>.site<i>.tld`, 50% `miss<s>.nomatch<i>.tld`) |
| match semantics | a name matches when any of its suffix labels equals a rule |
| confirmed matches | 166,549 on both sides (same data, same answers) |
| timing | best of 3 passes, release build, host x86_64 |

## Results (host, Windows x86_64)

| implementation | hasher | build ms | ns / query |
| --- | --- | ---: | ---: |
| Go 1.27 `map[string]struct{}` | runtime memhash | 10.6–13.3 | **93–100** |
| Rust 1.99 `HashSet<Vec<u8>>` | std SipHash-1-3 (default) | 26.6 | 112.6 |
| Rust, FNV-1a | FNV-1a | 30.8 | 129.2 |
| Rust, FxHash-style | rotate/xor 8-byte folds | 84.7 | 316.3 (poor distribution) |
| Rust, ahash (`compile-time` off, fixed seeds) | ahash | 27.3–32.8 | **96–103** |

"Best Rust" (ahash) lands inside Go's run-to-run range: **parity, not a win**.
The default SipHash is ~10–20% slower; a naive FxHash is much slower because of
collisions, which is a useful reminder that a hasher is not a free upgrade.

## What this means

1. **Do not rewrite this module in Rust for raw speed.** The Go runtime's map
   and hasher are already at parity with the best practical Rust setup tested.
2. **A cgo call per connection makes Rust worse.** A cross-language call plus
   argument marshalling costs tens to hundreds of nanoseconds — about the same
   order as the match itself. Any real integration needs a **batched** API
   (`match_many(names) -> bitset`), not one call per name.
3. **The remaining Rust openings are not language-level:**
   - memory ceiling / pause behavior on huge rule sets (Go GC vs Rust ownership);
   - algorithmic: a compact trie / double-array automaton, SIMD IP-prefix
     matching, or an index shared read-only across processes;
   - threading: one shared index queried from many workers without a GC barrier.
   Each needs its own measurement against **sing-box's real matcher**, not this
   toy hash set.
4. **Host results are not arm64 results.** Both languages should be re-measured
   on a device (cross-compile both, `adb push`, run on `arm64-v8a`) before any
   decision; Go's map and Rust's hashbrown behave differently across ABIs.

## Integration cost if it is ever pursued

- Rust targets `aarch64-linux-android`, `armv7-linux-androideabi`,
  `x86_64-linux-android` + NDK clang; `cargo build --release` per ABI.
- Link the `staticlib` into the core via cgo, add the hook behind a build tag
  (the overlay already patches upstream route internals), and keep a Go fallback.
- Add a cross-build to the local inputs and CI cache; pin a Rust toolchain next
  to the pinned Go/Flutter ones.
- Prove the end-to-end delta on a real rule-set workload, not a microbenchmark;
  if it is under ~10–15%, the build and CI complexity is not justified.

## Running it

```bash
# Rust (host); the toolchain and target used here were GNU, no VS needed
cargo run --release

# Go baseline (same output line, same match count)
cd go-baseline && go run main.go
```

The C ABI in `src/lib.rs` (`rm_build` / `rm_match` / `rm_free`) and
`rule_match.h` are the shape a cgo bridge would consume; they are not wired into
the app. The spike is intentionally outside the Gradle/CI graph.
