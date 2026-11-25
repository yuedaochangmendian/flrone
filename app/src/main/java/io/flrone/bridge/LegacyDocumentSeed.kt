package io.flrone.bridge

import org.json.JSONObject
import java.io.File

/**
 * The one-time seed / migration of the single global route rule table.
 *
 * The Go kernel is the only ongoing writer of `global_route_rules.json`; Android keeps a
 * read-only view (`RouteJsonStore`) because `ConfigGenerator` needs a synchronous answer and
 * cannot call into Go. There are no per-profile route documents in the running model.
 *
 * This hand-over runs once, only when the global document does not exist: an upgrade carries
 * the retired per-profile rules (or a stored global pool) into the one table so no user rule is
 * silently dropped. The Go kernel performs the same migration; both are gated on the global
 * document's absence, so they are idempotent together. A fresh install (no old rules) leaves
 * the table absent and the build starts from the built-in Default profile.
 */
object LegacyDocumentSeed {

    /**
     * Migrates old rules into `global_route_rules.json` when needed. First handles an upgrade
     * whose retired per-profile documents are already on disk, then the Room hand-over for an
     * install that has no documents yet. Returns true when anything was written.
     */
    fun seed(dir: File): Boolean =
        LegacyRoomReader.migrateDocumentsToGlobal(dir) || LegacyRoomReader.seedGlobalFromRoom(dir)

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
