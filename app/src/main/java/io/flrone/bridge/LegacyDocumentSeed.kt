package io.flrone.bridge

import org.json.JSONObject
import java.io.File

/**
 * The one-time seed of the kernel's route documents from the retired database
 * (ADR 0002 phase 3c; ADR 0006 stage C2c2b2 retired the last Room code in it).
 *
 * The Go kernel is the only ongoing writer of `route_profiles.json` and
 * `route_rules.json`; Android keeps a read-only view (`RouteJsonStore`) because
 * `ConfigGenerator` needs a synchronous answer and cannot call into Go.
 *
 * This is the hand-over, not a sync: it runs once, only when the documents do
 * not exist, and it copies each table by column name so ids, rule order, JSON
 * blobs and nulls survive verbatim. The rows come from [LegacyRoomReader], the
 * only reader of the old file, and are handed to
 * [LegacyRoomReader.seedRouteDocuments]. Old-version compatibility is
 * deliberately dropped: there is no round-trip back into the database, and no
 * merge on later launches. A fresh install (no database file) seeds nothing and
 * starts on the kernel's own Default profile.
 */
object LegacyDocumentSeed {

    /** The route tables the kernel owns. Profiles and groups are Dart's document
     * (`profiles.json`), seeded by Dart from `data.legacyRows`. */
    private val tables = listOf("route_profiles", "route_rules", "global_route_rules")

    /**
     * Writes [tables] into [dir] when it is empty. Returns false when the seed had already
     * run, so a caller cannot accidentally overwrite the kernel's live documents.
     */
    fun seed(dir: File): Boolean = LegacyRoomReader.seedRouteDocuments(dir, tables)

    /**
     * Seeds the UI documents from SharedPreferences (ADR 0002, phase 3e). Per-file skip:
     * an upgrade from a routes-seeded build adds just the new docs. Returns true when
     * at least one document was written.
     */
    fun seedUiDocuments(dir: File, settingsJson: String?, preferencesJson: String?): Boolean {
        if (!dir.isDirectory && !dir.mkdirs()) return false
        var seeded = false
        // ui_settings.json: the shell overlay layer.
        val uiFile = File(dir, "ui_settings.json")
        if (!uiFile.isFile && settingsJson != null) {
            val payload = JSONObject().apply {
                put("version", 1)
                put("name", "ui_settings")
                put("rows", JSONObject(settingsJson))
            }.toString()
            val temp = File(dir, "ui_settings.json.${System.nanoTime()}.tmp")
            temp.writeText(payload)
            if (!temp.renameTo(uiFile)) {
                uiFile.writeText(payload)
                temp.delete()
            }
            seeded = true
        }
        // preferences.json: UI preferences.
        val prefFile = File(dir, "preferences.json")
        if (!prefFile.isFile && preferencesJson != null) {
            val payload = JSONObject().apply {
                put("version", 1)
                put("name", "preferences")
                put("rows", JSONObject(preferencesJson))
            }.toString()
            val temp = File(dir, "preferences.json.${System.nanoTime()}.tmp")
            temp.writeText(payload)
            if (!temp.renameTo(prefFile)) {
                prefFile.writeText(payload)
                temp.delete()
            }
            seeded = true
        }
        return seeded
    }
}
