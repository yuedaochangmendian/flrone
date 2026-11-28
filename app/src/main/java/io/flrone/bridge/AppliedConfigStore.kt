package io.flrone.bridge

import android.content.Context
import io.nekohasekai.sagernet.SagerNet
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * The last config the kernel accepted, keyed by a fingerprint of the inputs it was built from.
 *
 * A start (a relaunch, a silent boot/tile start) usually rebuilds the exact same config it
 * applied the previous time: the profiles document, the settings and the routing selection
 * have not moved. Building it costs a full Go `configBuild` pass — every profile parsed,
 * ports leased, rule-sets resolved — before the core can even be created. Recording the
 * accepted build lets the kernel skip that pass and hand the same options to `createInstance`.
 *
 * Lifecycle (the caller's contract, mirrored in `kernel_service.dart`):
 *  1. before a new config is pushed, the record is cleared — a start that dies half way must
 *     not leave a record claiming a config it never applied;
 *  2. it is written only after `worker.start()` succeeded;
 *  3. it is trusted only when [fingerprint] still matches — the inputs can change between two
 *     starts, and a stale record must never win over a fresh build. The comparison is the
 *     caller's, so it is testable with a fake host; this object only stores and hands back.
 *
 * The record lives in the UI preferences (`bbox_ui`), which both Flutter engines in this
 * process share. [fingerprint], the encoding helpers and the prefs plumbing are unit tested
 * (`AppliedConfigStoreTest`).
 */
object AppliedConfigStore {

    /** The preferences file the UI bridge already owns; one store per process either way. */
    private const val PREFS = "bbox_ui"
    private const val KEY_FINGERPRINT = "kernel_applied_fingerprint"
    private const val KEY_OPTIONS = "kernel_applied_options"

    /** The documents whose contents the build reads. Missing files are stamped `-`. */
    private val DOCUMENTS = listOf(
        "profiles.json",
        "profile_selection.json",
        "settings.json",
        "global_route_rules.json",
    )

    /**
     * A cheap stamp of everything `config.build` reads.
     *
     * `config.prepare` resolves the selected profile out of the
 * Dart-owned `profiles.json`, the generator settings out of `settings.json`, and the
 * single global rule table out of `global_route_rules.json`; the selection itself is
 * `selectedProxy` in the settings. Sizes and mtimes cover the documents
     * without hashing 100+ KB on every start, and the writers replace those files atomically,
     * so any rewrite changes at least one of them.
     */
    fun fingerprint(): String {
        val documents = File(SagerNet.application.filesDir, "documents")
        val parts = DOCUMENTS.joinToString("|") { name -> stamp(File(documents, name)) } +
            "|profile=${io.nekohasekai.sagernet.database.DataStore.selectedProxy}"
        return parts
    }

    /** `len:mtime` of one document, `-` when it is absent (the build then reads its fallback). */
    private fun stamp(file: File): String =
        if (file.isFile) "${file.length()}:${file.lastModified()}" else "-"

    /** The fingerprint of the stored record, null when there is none. */
    fun appliedFingerprint(): String? = prefs().getString(KEY_FINGERPRINT, null)

    /** The built options of the stored record, null when absent or unreadable. */
    fun appliedOptions(): Map<String, Any?>? = decode(prefs().getString(KEY_OPTIONS, null))

    /**
     * Replaces the record. [fingerprint] is the one the caller sampled *before* building: inputs
     * that move during the start then miss on the next launch instead of pairing a stale config
     * with a newer stamp.
     */
    fun store(fingerprint: String, options: Map<String, Any?>) {
        val encoded = encode(options) ?: return
        prefs().edit()
            .putString(KEY_FINGERPRINT, fingerprint)
            .putString(KEY_OPTIONS, encoded)
            .apply()
    }

    fun clear() {
        prefs().edit()
            .remove(KEY_FINGERPRINT)
            .remove(KEY_OPTIONS)
            .apply()
    }

    private fun prefs() = SagerNet.application.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    // --- JSON ---------------------------------------------------------------
    //
    // The build options are a flat map of strings, booleans, integers, string lists and the
    // optional integer list `involvedProfileIds` (see the Go `configBuild` reply).
    // Encoding them one by one keeps the round trip type-exact: the Dart side reads
    // `autoSelectorIntervalSec` and the profile ids as ints.

    internal fun encode(options: Map<String, Any?>): String? = runCatching {
        val json = JSONObject()
        for ((key, value) in options) {
            when (value) {
                null -> json.put(key, JSONObject.NULL)
                is String -> json.put(key, value)
                is Boolean -> json.put(key, value)
                is Int -> json.put(key, value)
                is Long -> json.put(key, value)
                is List<*> -> json.put(key, JSONArray(value.map { it ?: JSONObject.NULL }))
                else -> json.put(key, value.toString())
            }
        }
        json.toString()
    }.getOrNull()

    internal fun decode(encoded: String?): Map<String, Any?>? {
        if (encoded.isNullOrBlank()) return null
        return runCatching {
            val json = JSONObject(encoded)
            val options = LinkedHashMap<String, Any?>()
            for (key in json.keys()) {
                val value = json.get(key)
                // JSON null is a sentinel object, not a Kotlin null; a nested object never comes
                // from the build. Both are dropped rather than handed to the kernel.
                if (value === JSONObject.NULL || value is JSONObject) continue
                options[key] = when {
                    value is JSONArray -> (0 until value.length()).map { value.get(it) }
                    // JSON has one number type; the build only produces integers here. A double
                    // would arrive in Dart as a double and break the int casts downstream.
                    value is Int || value is Long -> value
                    value is Number -> value.toLong()
                    else -> value
                }
            }
            if (options.isEmpty()) null else options
        }.getOrNull()
    }
}
