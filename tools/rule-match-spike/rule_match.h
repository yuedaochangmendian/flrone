// C ABI of the rule-matching spike (tools/rule-match-spike). This is the shape
// a cgo bridge would call: build one index from the rule-set snapshot, query it
// per connection, free it on reload. Not linked into the app.
#ifndef RULE_MATCH_H
#define RULE_MATCH_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RuleIndex RuleIndex;

/* Builds an index from `count` UTF-8 rule names (apex/suffix domains).
 * Returns NULL for empty or invalid input. */
RuleIndex *rm_build(const uint8_t *const *names, const size_t *lengths, size_t count);

/* 1 when the name matches a rule suffix, 0 otherwise (also 0 for NULL). */
int32_t rm_match(const RuleIndex *index, const uint8_t *name, size_t length);

/* Releases an index; NULL is a no-op. */
void rm_free(RuleIndex *index);

#ifdef __cplusplus
}
#endif

#endif /* RULE_MATCH_H */
