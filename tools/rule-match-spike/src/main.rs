// Host benchmark for the suffix matcher against the same workload in
// go-baseline/main.go. The numbers are a ceiling for the module, not an
// end-to-end gain: a real integration also pays the cgo call per connection.

use std::hint::black_box;
use std::time::Instant;

use rule_match_spike::RuleIndex;

/// The same 64-bit LCG on both sides, so the generated rules and queries match.
struct Lcg(u64);

impl Lcg {
    fn next(&mut self) -> u64 {
        self.0 = self
            .0
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        self.0
    }
}

const RULES: usize = 200_000;
const QUERIES: usize = 1_000_000;
const TLDS: [&str; 3] = ["com", "net", "org"];

fn main() {
    let mut rng = Lcg(0x5eed_1234_abcd_9876);
    let rules: Vec<String> = (0..RULES)
        .map(|index| format!("site{index}.{}", TLDS[index % TLDS.len()]))
        .collect();
    let queries: Vec<String> = (0..QUERIES)
        .map(|index| {
            let a = rng.next() as usize;
            let b = rng.next() as usize;
            let tld = TLDS[index % TLDS.len()];
            if index % 2 == 0 {
                format!("sub{}.site{}.{}", a % 1000, b % RULES, tld)
            } else {
                format!("miss{}.nomatch{}.{}", a, b % RULES, tld)
            }
        })
        .collect();

    let started = Instant::now();
    let index = RuleIndex::build(rules.iter().map(String::as_bytes));
    let build = started.elapsed();

    let mut best = std::time::Duration::MAX;
    let mut matched = 0usize;
    for _ in 0..3 {
        let started = Instant::now();
        let mut hits = 0usize;
        for query in &queries {
            if index.matches(black_box(query.as_bytes())) {
                hits += 1;
            }
        }
        best = best.min(started.elapsed());
        matched = hits;
    }

    let per_query = best.as_nanos() as f64 / QUERIES as f64;
    println!(
        "rust rules={} queries={} build_ms={:.1} query_ms={:.1} ns_per_query={:.2} matches={}",
        index.rules(),
        QUERIES,
        build.as_secs_f64() * 1000.0,
        best.as_secs_f64() * 1000.0,
        per_query,
        black_box(matched),
    );
}
