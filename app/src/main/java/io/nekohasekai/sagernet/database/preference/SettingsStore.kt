package io.nekohasekai.sagernet.database.preference

import androidx.preference.PreferenceDataStore
import io.nekohasekai.sagernet.database.SagerDatabase
import io.nekohasekai.sagernet.database.SettingsJsonStore
import io.nekohasekai.sagernet.ktx.PreferenceProxy
import io.nekohasekai.sagernet.outbound.json.JsonArray
import io.nekohasekai.sagernet.outbound.json.JsonInput

/**
 * The configuration store: a [PreferenceDataStore] over the settings documents, in the desktop's
 * encodings (SettingsRepo.cpp): booleans "true"/"false" (read back "true" or "1"), integers as decimal text, string
 * lists and string sets as compact JSON arrays, strings raw. The store is shared by every process and read without a
 * cache; Room is resolved on first use.
 *
 * ADR 0006 stage C1/C2: once the host mounts [SettingsJsonStore] — every process does, in
 * [io.nekohasekai.sagernet.SagerNet.onCreate] — the documents are the store (`settings.json` under
 * `filesDir/documents`) and they are read without a cache. Room's `settings` table is the
 * pre-migration seed and the fallback for an install that has not mounted the directory yet;
 * [Room] is the only Room-facing seam, so this class is testable without Room or Android.
 *
 * The one-argument getters return what is stored (null when the row is missing or unparsable). The two-argument
 * [PreferenceDataStore] getters fall back to [defaults] (the encoded default of a registered key) before the
 * caller's default, so a preference screen shows the effective value of a key without persisting it.
 */
@Suppress("MemberVisibilityCanBePrivate", "unused")
class SettingsStore internal constructor(
    private val room: Room,
    private val defaults: (String) -> String?,
) : PreferenceDataStore() {

    constructor(
        databaseProvider: () -> SagerDatabase,
        defaults: (String) -> String? = { null },
    ) : this(RoomTable(databaseProvider), defaults)

    /**
     * The legacy Room side of the store: its `settings` table. Narrow on purpose — the JVM tests
     * implement it over a map, so no Room or Android type is loaded in the test process.
     */
    internal interface Room {
        fun get(key: String): String?
        fun all(): Map<String, String>
        fun put(key: String, value: String)
        fun putAll(values: Map<String, String>)
        fun remove(key: String)
        fun reset()
    }

    private class RoomTable(private val databaseProvider: () -> SagerDatabase) : Room {

        private val database get() = databaseProvider()
        private val dao get() = database.settingsDao()

        override fun get(key: String): String? = dao[key]

        override fun all(): Map<String, String> =
            dao.all().associateTo(LinkedHashMap()) { it.key to it.value }

        override fun put(key: String, value: String) {
            dao.put(SettingEntry(key, value))
        }

        override fun putAll(values: Map<String, String>) {
            database.runInTransaction {
                dao.putAll(values.map { (key, value) -> SettingEntry(key, value) })
            }
        }

        override fun remove(key: String) {
            dao.delete(key)
        }

        override fun reset() {
            dao.reset()
        }
    }

    // ------------------------------------------------------------------------------------------------ read snapshot

    /**
     * Rows an enclosing [withSnapshot] should be read from instead of the store.
     *
     * Every typed getter below is a separate lookup (`SELECT value FROM settings WHERE key = ?`,
     * or one document read), and `SettingsSchema.read()` walks 158 keys — so building the settings
     * wire cost 158 lookups and did it twice per write. `settingsWire` runs on an IO thread and
     * asks for one consistent view, which is exactly what one whole-store read gives it.
     *
     * Thread-scoped on purpose: a snapshot must never leak into another caller (a service
     * thread reading a preference mid-sweep would otherwise see a stale row), and it keeps
     * [withSnapshot] re-entrant without a lock.
     */
    private val snapshot = ThreadLocal<Map<String, String>?>()

    /** Reads [key] from the enclosing snapshot when there is one, else from the store. */
    private fun raw(key: String): String? {
        val rows = snapshot.get()
        if (rows != null) {
            // An empty snapshot means "the table has no rows", not "no snapshot":
            // falling through to a read here would issue the very query the
            // snapshot exists to avoid.
            return rows[key]
        }
        // ADR 0006 stage C1: the document is the store once the host mounts the
        // directory; Room's table is the pre-mount fallback (and the seed).
        if (SettingsJsonStore.mounted) return SettingsJsonStore.get(key)
        return room.get(key)
    }

    /**
     * Runs [block] with every read served from [rows], one whole-store read (`SELECT *` or the
     * document) taken by the caller.
     *
     * Writes are unaffected: they still go to the store and fire their listeners, so a caller
     * that writes inside the block (a getter that seeds a default) sees its own write on the next
     * snapshot, not through this one.
     */
    fun <T> withSnapshot(rows: Map<String, String>, block: () -> T): T {
        val previous = snapshot.get()
        snapshot.set(rows)
        try {
            return block()
        } finally {
            snapshot.set(previous)
        }
    }

    // ------------------------------------------------------------------------------------------------ raw access

    fun contains(key: String): Boolean = raw(key) != null

    fun getRaw(key: String): String? = raw(key)

    /** Every stored row, sorted by key. */
    fun all(): Map<String, String> =
        if (SettingsJsonStore.mounted) SettingsJsonStore.all()
        else room.all()

    /** Upserts [values]; listeners are not notified (bulk restores restart the app). */
    fun putAll(values: Map<String, String>) {
        if (values.isEmpty()) return
        if (SettingsJsonStore.mounted) {
            SettingsJsonStore.putAll(values)
            return
        }
        room.putAll(values)
    }

    fun reset() {
        if (SettingsJsonStore.mounted) {
            SettingsJsonStore.reset()
            return
        }
        room.reset()
    }

    fun remove(key: String) {
        if (SettingsJsonStore.mounted) {
            SettingsJsonStore.remove(key)
        } else {
            room.remove(key)
        }
        fireChangeListener(key)
    }

    private fun write(key: String, value: String) {
        if (SettingsJsonStore.mounted) {
            SettingsJsonStore.put(key, value)
        } else {
            room.put(key, value)
        }
        fireChangeListener(key)
    }

    // ------------------------------------------------------------------------------------------------ typed reads
    // All of these go through raw(), so an enclosing withSnapshot serves them from its rows.

    fun getBoolean(key: String): Boolean? = raw(key)?.let(::decodeBoolean)
    fun getFloat(key: String): Float? = raw(key)?.trim()?.toFloatOrNull()
    fun getInt(key: String): Int? = raw(key)?.let(::decodeInt)
    fun getLong(key: String): Long? = raw(key)?.let(::decodeLong)
    fun getString(key: String): String? = raw(key)
    fun getStringList(key: String): List<String>? = raw(key)?.let(::decodeList)
    fun getStringSet(key: String): MutableSet<String>? = getStringList(key)?.toMutableSet()

    override fun getBoolean(key: String, defValue: Boolean): Boolean =
        getBoolean(key) ?: defaults(key)?.let(::decodeBoolean) ?: defValue

    override fun getFloat(key: String, defValue: Float): Float =
        getFloat(key) ?: defaults(key)?.trim()?.toFloatOrNull() ?: defValue

    override fun getInt(key: String, defValue: Int): Int =
        getInt(key) ?: defaults(key)?.let(::decodeInt) ?: defValue

    override fun getLong(key: String, defValue: Long): Long =
        getLong(key) ?: defaults(key)?.let(::decodeLong) ?: defValue

    override fun getString(key: String, defValue: String?): String? =
        getString(key) ?: defaults(key) ?: defValue

    override fun getStringSet(key: String, defValues: MutableSet<String>?): MutableSet<String>? =
        getStringSet(key) ?: defaults(key)?.let(::decodeList)?.toMutableSet() ?: defValues

    fun getStringList(key: String, defValue: List<String>): List<String> =
        getStringList(key) ?: defaults(key)?.let(::decodeList) ?: defValue

    // ------------------------------------------------------------------------------------------------ typed writes

    override fun putBoolean(key: String, value: Boolean) = write(key, encodeBoolean(value))
    override fun putFloat(key: String, value: Float) = write(key, value.toString())
    override fun putInt(key: String, value: Int) = write(key, value.toString())
    override fun putLong(key: String, value: Long) = write(key, value.toString())

    override fun putString(key: String, value: String?) = if (value == null) remove(key) else write(key, value)

    override fun putStringSet(key: String, values: MutableSet<String>?) =
        if (values == null) remove(key) else write(key, encodeList(values))

    fun putStringList(key: String, values: List<String>?) =
        if (values == null) remove(key) else write(key, encodeList(values))

    fun putBoolean(key: String, value: Boolean?) = if (value == null) remove(key) else putBoolean(key, value)
    fun putFloat(key: String, value: Float?) = if (value == null) remove(key) else putFloat(key, value)
    fun putInt(key: String, value: Int?) = if (value == null) remove(key) else putInt(key, value)
    fun putLong(key: String, value: Long?) = if (value == null) remove(key) else putLong(key, value)

    /** The JSON-array delegate next to the PreferenceDataStore ones of ktx/Preferences.kt. */
    fun stringList(
        name: String,
        defaultValue: () -> List<String> = { emptyList() },
    ) = PreferenceProxy(name, defaultValue, ::getStringList, ::putStringList)

    // ------------------------------------------------------------------------------------------------ listeners

    private val listeners = HashSet<OnPreferenceDataStoreChangeListener>()

    private fun fireChangeListener(key: String) {
        val listeners = synchronized(listeners) {
            listeners.toList()
        }
        listeners.forEach { it.onPreferenceDataStoreChanged(this, key) }
    }

    fun registerChangeListener(listener: OnPreferenceDataStoreChangeListener) {
        synchronized(listeners) {
            listeners.add(listener)
        }
    }

    fun unregisterChangeListener(listener: OnPreferenceDataStoreChangeListener) {
        synchronized(listeners) {
            listeners.remove(listener)
        }
    }

    companion object {
        @JvmStatic
        fun encodeBoolean(value: Boolean): String = if (value) "true" else "false"

        /** SettingsRepo.cpp:312-313. */
        @JvmStatic
        fun decodeBoolean(raw: String): Boolean = raw == "true" || raw == "1"

        @JvmStatic
        fun decodeInt(raw: String): Int? = raw.trim().toIntOrNull()

        @JvmStatic
        fun decodeLong(raw: String): Long? = raw.trim().toLongOrNull()

        /** QJsonDocument(QJsonArray::fromStringList(list)).toJson(Compact): blanks are kept. */
        @JvmStatic
        fun encodeList(values: Collection<String>): String {
            val array = JsonArray()
            for (value in values) array.add(value)
            return array.toCompact()
        }

        /** Null when [raw] is not a JSON array, the case in which the desktop keeps the default. */
        @JvmStatic
        fun decodeList(raw: String): List<String>? = (JsonInput.parseValue(raw) as? JsonArray)?.strings()
    }
}
