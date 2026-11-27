package io.nekohasekai.sagernet.group

/**
 * The per-group intent counter behind "newest intent wins": a subscription download that outlasts
 * an edit of its own group must not apply its stale answer over that edit (FlClash's rule for a
 * slow profile download, `providers/actions/profiles.dart:168-179`).
 *
 * Two writers move a group's revision:
 *
 *  - a user save / edit of the group ([edit]) — the profile form ([io.flrone.bridge.FlroneProfiles.save])
 *    and the configuration editor (Dart's `ProfileDocumentService.write`, whose `revision.edit` duty
 *    performs this bump before the document write);
 *  - a refresh starting ([begin]) — the newest refresh owns the right to apply.
 *
 * [SubscriptionRefresh.refresh] captures its ticket with [begin] before the fetch and compares it with
 * [holds] before applying. A mismatch means an edit (or a newer refresh) happened while the answer was
 * downloading: the answer is discarded instead of replacing the newer intent, and the queue entry
 * completes as superseded. The edit itself always lands — it was written by the UI path, not here.
 *
 * The counter lives in memory on purpose. What it orders — the queue's refresh job and the bridge's
 * save calls — lives in one process (`:bg` and the UI share it since P6), and after a restart no
 * download is in flight that could still apply. Group ids are never reused, so an entry nobody reads
 * again is inert; [forget] drops it when a refresh notices the group is gone.
 */
internal object GroupRevisions {

    private val revisions = HashMap<Long, Long>()
    private val lock = Any()

    /** A refresh is starting: returns its ticket. Only the newest ticket may apply its answer. */
    fun begin(gid: Long): Long = synchronized(lock) {
        val next = (revisions[gid] ?: 0L) + 1L
        revisions[gid] = next
        next
    }

    /** A user save / edit of [gid]: any answer already downloading for it is stale from here on. */
    fun edit(gid: Long) {
        synchronized(lock) {
            revisions[gid] = (revisions[gid] ?: 0L) + 1L
        }
    }

    /** Whether [ticket] (a [begin] result) is still [gid]'s newest intent. */
    fun holds(gid: Long, ticket: Long): Boolean = synchronized(lock) { revisions[gid] == ticket }

    /** The group is gone from the document: its counter has nothing left to order. */
    fun forget(gid: Long) {
        synchronized(lock) { revisions.remove(gid) }
    }

    /** The current value (0 before anything touched the group this process), for diagnostics. */
    fun current(gid: Long): Long = synchronized(lock) { revisions[gid] ?: 0L }
}
