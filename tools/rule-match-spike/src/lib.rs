// A domain-suffix matcher with the same shape as sing-box's geosite lookup:
// rules are apex domains, and a name matches when any of its suffix labels is a
// rule (`a.b.example.com` matches `example.com`).
//
// The index is a hash set of the rule names themselves. A query walks its label
// boundaries from the left and probes `&name[start..]`; every probe is a slice,
// so a lookup allocates nothing. This is the cheapest useful baseline; a trie
// or a compressed FST would trade memory for cache behavior.
//
// The C ABI below is what a cgo caller would use if the spike becomes real:
// build once from the rule-set snapshot, then one query per connection.

use std::collections::HashSet;

/// A fixed-seed ahash set: the hasher production Rust would pick for short
/// keys, and the fair comparison against Go's runtime map hasher. The spike
/// keeps fixed seeds so the GNU host toolchain needs no getrandom/dlltool.
type FastSet = HashSet<Vec<u8>, ahash::RandomState>;

pub struct RuleIndex {
    set: FastSet,
    rules: usize,
}

impl RuleIndex {
    pub fn build<I, S>(rules: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: AsRef<[u8]>,
    {
        let mut set = FastSet::with_hasher(ahash::RandomState::with_seeds(1, 2, 3, 4));
        let mut count = 0usize;
        for rule in rules {
            let bytes = rule.as_ref();
            if bytes.is_empty() {
                continue;
            }
            set.insert(bytes.to_vec());
            count += 1;
        }
        Self { set, rules: count }
    }

    pub fn rules(&self) -> usize {
        self.rules
    }

    #[inline]
    pub fn matches(&self, name: &[u8]) -> bool {
        if name.is_empty() || self.set.is_empty() {
            return false;
        }
        let mut start = 0usize;
        loop {
            if self.set.contains(&name[start..]) {
                return true;
            }
            match name[start..].iter().position(|byte| *byte == b'.') {
                Some(offset) => start += offset + 1,
                None => return false,
            }
        }
    }
}

// --- C ABI (what a cgo bridge would call) ----------------------------------

/// Builds an index from `count` UTF-8 rule names. Returns null when the input is
/// empty or inconsistent; the caller owns the pointer and releases it with
/// [`rm_free`].
///
/// # Safety
/// `names` must point to `count` readable pointers, each valid for `lengths[i]`
/// bytes for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn rm_build(
    names: *const *const u8,
    lengths: *const usize,
    count: usize,
) -> *mut RuleIndex {
    if names.is_null() || lengths.is_null() || count == 0 {
        return std::ptr::null_mut();
    }
    let rules = (0..count).map(|index| {
        let pointer = *names.add(index);
        let length = *lengths.add(index);
        if pointer.is_null() {
            &[][..]
        } else {
            std::slice::from_raw_parts(pointer, length)
        }
    });
    Box::into_raw(Box::new(RuleIndex::build(rules)))
}

/// 1 when `name` matches a rule, 0 otherwise.
///
/// # Safety
/// `index` must come from [`rm_build`] and `name` must be readable for `length`
/// bytes.
#[no_mangle]
pub unsafe extern "C" fn rm_match(index: *const RuleIndex, name: *const u8, length: usize) -> i32 {
    if index.is_null() || name.is_null() {
        return 0;
    }
    let name = std::slice::from_raw_parts(name, length);
    i32::from((*index).matches(name))
}

/// Releases an index built by [`rm_build`].
///
/// # Safety
/// `index` must be null or a pointer returned by [`rm_build`] that was not
/// freed yet.
#[no_mangle]
pub unsafe extern "C" fn rm_free(index: *mut RuleIndex) {
    if !index.is_null() {
        drop(Box::from_raw(index));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_suffix_matches_but_a_prefix_does_not() {
        let index = RuleIndex::build(["example.com", "site.test"]);
        assert!(index.matches(b"a.b.example.com"));
        assert!(index.matches(b"example.com"));
        assert!(!index.matches(b"notexample.com"));
        assert!(!index.matches(b"example.com.evil"));
        assert!(!index.matches(b""));
    }

    #[test]
    fn an_empty_index_never_matches() {
        let index = RuleIndex::build(Vec::<String>::new());
        assert!(!index.matches(b"example.com"));
    }
}
