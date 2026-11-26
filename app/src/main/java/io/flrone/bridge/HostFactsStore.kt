package io.flrone.bridge

import org.json.JSONObject
import java.io.File

/**
 * Reads/writes the one document Kotlin owns: `<basePath>/documents/host_facts.json`.
 *
 * Host facts are environment observations (currently `batteryExempt`) published for
 * Go's `settingsWire`. The host is the only writer; there is no legacy seed and no
 * SharedPreferences fallback. The wire shape is the same enveloped document the
 * other stores use: `{version: 1, name: "host_facts", rows: {...}}`.
 */
object HostFactsStore {

    /** Where the documents live; the host sets it once the kernel base path is known. */
    @Volatile
    var directory: File? = null

    /**
     * Diagnostics sink. Injected rather than calling android.util.Log directly: the JVM
     * unit tests exercise the corrupt-file path, and an unmocked Log.w would fail them.
     */
    @Volatile
    var logger: (String, Throwable?) -> Unit = { message, error ->
        if (error != null) {
            io.nekohasekai.sagernet.ktx.Logs.w(message, error)
        } else {
            io.nekohasekai.sagernet.ktx.Logs.w(message)
        }
    }

    /** Reads `host_facts.json`. Missing or corrupt → empty map. */
    fun readHostFacts(): Map<String, Any?> {
        val dir = directory ?: return emptyMap()
        val file = File(dir, "host_facts.json")
        if (!file.isFile) return emptyMap()
        return try {
            val root = JSONObject(file.readText())
            val rows = root.optJSONObject("rows") ?: return emptyMap()
            rows.keys().asSequence().associateWith { key ->
                when (val v = rows.get(key)) {
                    JSONObject.NULL -> null
                    else -> v
                }
            }
        } catch (e: Exception) {
            logger("unreadable host_facts.json; falling back to defaults", e)
            emptyMap()
        }
    }

    /** Writes `host_facts.json` atomically (called on attach and resume). */
    fun writeHostFacts(values: Map<String, Any?>) {
        val dir = directory ?: return
        if (!dir.isDirectory && !dir.mkdirs()) return
        val payload = JSONObject().apply {
            put("version", 1)
            put("name", "host_facts")
            put("rows", JSONObject().apply {
                values.forEach { (key, value) ->
                    if (value != null) put(key, value) else put(key, JSONObject.NULL)
                }
            })
        }.toString()
        DocumentAtomicWrite.write(File(dir, "host_facts.json"), payload)
    }
}
