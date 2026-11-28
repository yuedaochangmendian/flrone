package io.flrone.bridge

import org.json.JSONObject
import java.io.File

/**
 * ADR 0008 S4: the read-only Kotlin view of Dart's `profile_selection.json`.
 *
 * Dart is the ONLY writer of this document; Kotlin and Go only read it. Kotlin
 * is the fallback reader for `config.prepare` when settings carry no usable
 * selection (an upgrade/reset): settings stay the settled selection because
 * every UI choice is mirrored there and the platform paths write them directly.
 * The start build itself reads only the document. This object never writes it.
 */
object ProfileSelectionStore {

    private const val FILE_NAME = "profile_selection.json"
    private const val VERSION = 1

    /**
     * The selected member id, or null when the document is absent, unreadable
     * or invalid. `config.prepare` uses it only after `DataStore.selectedProxy`
     * fails to name a live profile, then falls back to the first profile.
     */
    fun selectedProfileId(directory: File?): Long? {
        val dir = directory ?: return null
        val file = File(dir, FILE_NAME)
        if (!file.isFile) return null
        return try {
            val json = JSONObject(file.readText())
            // The same four-key contract Go's parseProfileSelection validates:
            // wrong version, non-positive member id, negative current group or
            // missing/zero updatedAt is a silent fallback, not an error.
            if (json.optInt("version", -1) != VERSION) return null
            val id = json.optLong("selectedProfileId", 0L)
            if (id <= 0L) return null
            if (json.optLong("currentGroupId", -1L) < 0L) return null
            if (json.optLong("updatedAt", 0L) <= 0L) return null
            id
        } catch (t: Throwable) {
            // Malformed JSON, an unreadable file, a directory in its place —
            // none of these may fail config.prepare during migration.
            null
        }
    }
}
