package io.nekohasekai.sagernet.group

/**
 * The per-group intent counter behind "newest intent wins": a subscription download that outlasts
 * an edit of its own group must not apply its stale answer over that edit (FlClash's rule for a
 * slow profile download, `providers/actions/profiles.dart:168-179`).
 *
 * The user-edit side of that rule survives: a profile form save
 * ([io.flrone.bridge.FlroneProfiles.save]) and the configuration editor (Dart's
 * `ProfileDocumentService.write`, whose `revision.edit` duty performs this bump
 * before the document write) move the counter. The Kotlin refresh that used to
 * capture a ticket here (`begin`/`holds`) was removed in S8 — refreshes run in
 * the service engine's Dart queue, which carries its own newest-intent seam
 * (`isCurrentIntent` in `subscription_refresh.dart`).
 *
 * The counter lives in memory on purpose. What it orders lives in one process
 * (`:bg` and the UI share it since P6), and after a restart no download is in
 * flight that could still apply.
 */
internal object GroupRevisions {

    private val revisions = HashMap<Long, Long>()
    private val lock = Any()

    /** A user save / edit of [gid]: any answer already downloading for it is stale from here on. */
    fun edit(gid: Long) {
        synchronized(lock) {
            revisions[gid] = (revisions[gid] ?: 0L) + 1L
        }
    }

    /** The current value (0 before anything touched the group this process), for diagnostics. */
    fun current(gid: Long): Long = synchronized(lock) { revisions[gid] ?: 0L }
}
