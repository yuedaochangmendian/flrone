package io.flrone.bridge

/**
 * The "the user explicitly cleared the WebDAV account" marker (ADR 0005 phase 1).
 *
 * Dart owns the account as one `webdavAccount` value in the preferences document.
 * A `preferences.set` that writes it to null removes the key, which left the
 * legacy Room rows as the only trace of the old account: the next `ready` folded
 * them straight back in and the clear appeared to do nothing. There is no mirror
 * writer to lean on (the old comment pointed at one that was deleted with
 * `webdav.set`), so the marker is durable and the rows are cleared as part of
 * the same write.
 *
 * Pure JVM: preferences and the legacy store are injected, so the state machine
 * is testable without an Activity, Room or the Keystore. The host is the only
 * writer of the marker; Dart continues to own [ACCOUNT_KEY].
 */
object WebDavAccountTombstone {

    const val ACCOUNT_KEY = "webdavAccount"
    const val CLEARED_KEY = "webdavAccountCleared"

    /** The merged preferences document and whether the legacy rows need clearing. */
    data class Write(val rows: Map<String, Any?>, val clearLegacy: Boolean, val clearMarker: Boolean)

    /**
     * Applies one `preferences.set` batch to [current].
     *
     * A null account (or an explicit marker) is an unbinding: remove the account
     * value, keep the marker, and ask the caller to empty the four legacy rows.
     * A new account removes the marker so a later clear can be recorded anew.
     */
    fun apply(values: Map<String, Any?>, current: Map<String, Any?>): Write {
        val rows = current.toMutableMap()
        values.forEach { (key, value) ->
            if (value == null) rows.remove(key) else rows[key] = value
        }
        // Only an explicit unbinding starts a clear. An unrelated `theme` write
        // while the marker is already set must not keep wiping the legacy rows.
        val explicitClear = values.containsKey(ACCOUNT_KEY) && !rows.containsKey(ACCOUNT_KEY)
        val markerSet = values[CLEARED_KEY] == true
        if (explicitClear || markerSet) {
            rows.remove(ACCOUNT_KEY)
            rows[CLEARED_KEY] = true
            return Write(rows, clearLegacy = true, clearMarker = false)
        }
        if (rows.containsKey(ACCOUNT_KEY)) {
            rows.remove(CLEARED_KEY)
            return Write(rows, clearLegacy = false, clearMarker = true)
        }
        return Write(rows, clearLegacy = false, clearMarker = false)
    }

    /** True when `ready` may fold the legacy Room account into the document. */
    fun mayFoldLegacy(rows: Map<String, Any?>): Boolean =
        !rows.containsKey(ACCOUNT_KEY) && rows[CLEARED_KEY] != true

    /** Keys device-local to this install: neither may travel in a backup. */
    fun backupExcludedKeys(): Set<String> = setOf(ACCOUNT_KEY, CLEARED_KEY)
}
