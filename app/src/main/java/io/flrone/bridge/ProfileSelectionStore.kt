package io.flrone.bridge

import org.json.JSONObject
import java.io.File

/**
 * ADR 0008 P1-5: the read-only Kotlin view of Dart's `profile_selection.json`.
 *
 * Dart is the ONLY writer of this document; Kotlin and Go only read it. During
 * migration it may be absent or malformed (an older install, an interrupted
 * upgrade), so every failure is a silent `null` and the caller falls back to
 * the settings-based selection (`DataStore.selectedProxy`) exactly as before.
 * This object never writes the file.
 */
object ProfileSelectionStore {

    private const val FILE_NAME = "profile_selection.json"
    private const val VERSION = 1

    /**
     * The selected member id, or null when the document is absent, unreadable
     * or invalid. `config.prepare` prefers this over `DataStore.selectedProxy`
     * and falls back to the settings value when it is null.
     */
    fun selectedProfileId(directory: File?): Long? {
        val dir = directory ?: return null
        val file = File(dir, FILE_NAME)
        if (!file.isFile) return null
        return try {
            val json = JSONObject(file.readText())
            // A wrong version or a non-positive id is a fallback, not an error.
            if (json.optInt("version", -1) != VERSION) return null
            val id = json.optLong("selectedProfileId", 0L)
            if (id <= 0L) null else id
        } catch (t: Throwable) {
            // Malformed JSON, an unreadable file, a directory in its place —
            // none of these may fail config.prepare during migration.
            null
        }
    }
}
