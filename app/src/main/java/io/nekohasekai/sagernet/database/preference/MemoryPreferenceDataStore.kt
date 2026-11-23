package io.nekohasekai.sagernet.database.preference

import androidx.preference.PreferenceDataStore
import java.nio.ByteBuffer

/**
 * The profile editor's transient cache (dirty flag, the row being edited, the add-group form).
 *
 * ADR 0006 stage C2c2b2: this used to be a Room database held in memory. Nothing
 * here survives the process and no other process reads it, so a plain map is
 * the honest store — the retired database machinery (an annotation processor,
 * a second database class, an in-memory SQLite connection) bought nothing for
 * eight editor fields.
 *
 * The value codec is the one the retired row used ([Value]): booleans as one
 * byte, longs as eight, strings as UTF-8, string sets as a length-prefixed list.
 * The delegate helpers (`boolean()`, `long()`, `string()`, `stringToInt()`) come
 * from `ktx/Preferences.kt` and only need [PreferenceDataStore].
 */
class MemoryPreferenceDataStore : PreferenceDataStore() {

    private val values = HashMap<String, Value>()

    fun getBoolean(key: String): Boolean? = values[key]?.boolean
    fun getLong(key: String): Long? = values[key]?.long
    fun getString(key: String): String? = values[key]?.string
    fun getStringSet(key: String): Set<String>? = values[key]?.stringSet

    override fun getBoolean(key: String, defValue: Boolean): Boolean = getBoolean(key) ?: defValue
    override fun getLong(key: String, defValue: Long): Long = getLong(key) ?: defValue
    override fun getString(key: String, defValue: String?): String? = getString(key) ?: defValue
    override fun getStringSet(key: String, defValues: MutableSet<String>?): MutableSet<String>? =
        getStringSet(key)?.toMutableSet() ?: defValues
    override fun getFloat(key: String, defValue: Float): Float = defValue
    override fun getInt(key: String, defValue: Int): Int = getLong(key)?.toInt() ?: defValue

    fun putBoolean(key: String, value: Boolean?) = put(key, value?.let { Value.boolean(it) })
    fun putLong(key: String, value: Long?) = put(key, value?.let { Value.long(it) })

    override fun putBoolean(key: String, value: Boolean) = put(key, Value.boolean(value))
    override fun putLong(key: String, value: Long) = put(key, Value.long(value))
    override fun putString(key: String, value: String?) = put(key, value?.let { Value.string(it) })
    override fun putInt(key: String, value: Int) = put(key, Value.long(value.toLong()))
    override fun putFloat(key: String, value: Float) = Unit
    override fun putStringSet(key: String, values: MutableSet<String>?) =
        put(key, values?.let { Value.stringSet(it) })

    fun remove(key: String) {
        synchronized(values) { values.remove(key) }
        fireChangeListener(key)
    }

    fun reset() {
        synchronized(values) { values.clear() }
    }

    private fun put(key: String, value: Value?) {
        synchronized(values) {
            if (value == null) values.remove(key) else values[key] = value
        }
        fireChangeListener(key)
    }

    private val listeners = HashSet<OnPreferenceDataStoreChangeListener>()

    private fun fireChangeListener(key: String) {
        val listeners = synchronized(listeners) { listeners.toList() }
        listeners.forEach { it.onPreferenceDataStoreChanged(this, key) }
    }

    fun registerChangeListener(listener: OnPreferenceDataStoreChangeListener) {
        synchronized(listeners) { listeners.add(listener) }
    }

    fun unregisterChangeListener(listener: OnPreferenceDataStoreChangeListener) {
        synchronized(listeners) { listeners.remove(listener) }
    }

    /** One cached value, in the encoding the retired Room row used. */
    private class Value(private val type: Int, private val bytes: ByteArray) {

        val boolean: Boolean?
            get() = if (type == TYPE_BOOLEAN) ByteBuffer.wrap(bytes).get() != 0.toByte() else null

        val long: Long?
            get() = if (type == TYPE_LONG) ByteBuffer.wrap(bytes).long else null

        val string: String?
            get() = if (type == TYPE_STRING) String(bytes) else null

        val stringSet: Set<String>?
            get() {
                if (type != TYPE_STRING_SET) return null
                val buffer = ByteBuffer.wrap(bytes)
                val result = HashSet<String>()
                while (buffer.hasRemaining()) {
                    val chunk = ByteArray(buffer.int)
                    buffer.get(chunk)
                    result.add(String(chunk))
                }
                return result
            }

        companion object {
            private const val TYPE_BOOLEAN = 1
            private const val TYPE_LONG = 4
            private const val TYPE_STRING = 5
            private const val TYPE_STRING_SET = 6

            fun boolean(value: Boolean) =
                Value(TYPE_BOOLEAN, ByteBuffer.allocate(1).put((if (value) 1 else 0).toByte()).array())

            fun long(value: Long) = Value(TYPE_LONG, ByteBuffer.allocate(8).putLong(value).array())

            fun string(value: String) = Value(TYPE_STRING, value.toByteArray())

            fun stringSet(values: Set<String>): Value {
                val buffer = java.io.ByteArrayOutputStream()
                for (value in values) {
                    buffer.write(ByteBuffer.allocate(4).putInt(value.length).array())
                    buffer.write(value.toByteArray())
                }
                return Value(TYPE_STRING_SET, buffer.toByteArray())
            }
        }
    }
}
