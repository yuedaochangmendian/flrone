package io.flrone.bridge

import org.json.JSONObject
import java.io.File

/**
 * The one-time seed of the UI documents from SharedPreferences (ADR 0002, phase 3e).
 *
 * Route rules are no part of this: the Go kernel is the only writer of the single
 * `global_route_rules.json` table, and there is no legacy route format to migrate.
 * A missing table is an empty rule table; a build starts from the in-memory Default
 * profile. Android keeps a read-only view (`RouteJsonStore`) because `ConfigGenerator`
 * needs a synchronous answer and cannot call into Go.
 */
object LegacyDocumentSeed {

    /**
     * Seeds the UI documents from SharedPreferences. Per-file skip: an upgrade
     * from an earlier build adds just the new docs. Returns true when at least
     * one document was written.
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
