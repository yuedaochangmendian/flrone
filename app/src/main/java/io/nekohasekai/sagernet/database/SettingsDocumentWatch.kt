package io.nekohasekai.sagernet.database

/** mtime+length of one document; an equal pair means the document did not change. */
data class SettingsStamp(val modified: Long, val length: Long)

/**
 * A read-driven change detector for `settings.json` (ADR 0006).
 *
 * [SettingsJsonStore] fires an in-process listener on every individual write, but not on a
 * whole-document [SettingsJsonStore.replaceAll] — a backup restore — and, if a second process
 * is ever pinned (`:bg`), its writes fire nothing here at all. Those changes are only visible
 * on the next service reload without a watch.
 *
 * The watch is deliberately passive: [check] is called by the readers that would otherwise
 * serve stale values, so an idle process never stats anything, and there is no thread of its
 * own. Three rules keep it cheap and quiet:
 *
 *  - at most one pair of stats per [intervalNanos] (2 s by default), whatever the caller's
 *    read rate — a log line is one [check] but a burst of them is one stat;
 *  - the first successful stat only records a baseline: construction and first use cannot
 *    fire, because there is nothing to compare against yet;
 *  - a reader that has just re-read the settings pins that moment with [prime], so what it
 *    cached and the baseline describe the same state.
 *
 * A missing document (null stamp) is a no-op and keeps the last seen stamp: the directory is
 * briefly unmounted during a migration, and forgetting the baseline would turn the next read
 * after the remount into a spurious change. [onChanged] is called outside the monitor, so a
 * callback that re-reads the document cannot deadlock the watch.
 */
class SettingsDocumentWatch(
    private val stampSource: () -> SettingsStamp?,
    private val onChanged: () -> Unit,
    private val clock: () -> Long = System::nanoTime,
    private val intervalNanos: Long = DEFAULT_INTERVAL_NANOS,
) {

    private val lock = Any()
    private var lastCheckNanos: Long? = null
    private var lastStamp: SettingsStamp? = null

    /** Stats at most once per [intervalNanos]; fires [onChanged] when the stamp moved. */
    fun check() {
        val changed = synchronized(lock) {
            val now = clock()
            val lastCheck = lastCheckNanos
            if (lastCheck != null && now - lastCheck < intervalNanos) return@synchronized false
            lastCheckNanos = now
            val stamp = stampSource() ?: return@synchronized false
            val seen = lastStamp
            when {
                seen == null -> {
                    lastStamp = stamp
                    false
                }

                seen == stamp -> false

                else -> {
                    lastStamp = stamp
                    true
                }
            }
        }
        if (changed) onChanged()
    }

    /**
     * Records the current stamp as the baseline without firing.
     *
     * A reader that is about to re-read the settings calls this *before* the read: the fresh
     * values and the baseline then describe the same moment, so a write that lands during the
     * read differs on the next [check] (a redundant refresh at worst, never a missed one). The
     * first [check] alone cannot close that window, because it would take the post-restore stamp
     * for its baseline and never notice the settings changed under a cache filled earlier.
     * A null stamp leaves the previous baseline alone.
     */
    fun prime() {
        synchronized(lock) {
            val stamp = stampSource() ?: return
            lastStamp = stamp
        }
    }

    companion object {
        const val DEFAULT_INTERVAL_NANOS = 2_000_000_000L
    }
}
