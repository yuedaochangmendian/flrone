package io.flrone.bridge

import io.nekohasekai.sagernet.database.ProxyEntity
import io.nekohasekai.sagernet.database.ProxyGroup
import io.nekohasekai.sagernet.database.SagerDatabase
import io.nekohasekai.sagernet.database.SubUserInfo
import io.nekohasekai.sagernet.database.SubscriptionOptions
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Read-only Kotlin view of the Dart-owned `profiles.json` document (ADR 0005
 * final stage).
 *
 * Dart is the storage authority for profiles and groups. This object is the
 * Kotlin *reader* that `ConfigGenerator` / `CoreConfigs` / `BboxKernel` use to
 * build `ProxyEntity` / `ProxyGroup` synchronously — those paths cannot call
 * back into Dart, so they read the same file Dart writes. It never writes the
 * document: every mutation crosses the `io.flrone/profiles_doc` channel to
 * Dart (see BboxProfiles / the parse-only handlers).
 *
 * The document is the Room profile/group tables re-typed as JSON with the exact
 * column names, so mapping here is a straight field copy (no second naming
 * layer to drift). The envelope also carries `nextProfileId` / `nextGroupId`
 * so an id Kotlin allocates (a new node before its link is known) cannot
 * collide with one Dart will hand out.
 *
 * Before the one-time migration the file does not exist; in that window the
 * getters fall back to Room so the host keeps working. Once Dart has written
 * the document it wins — Room's profile/group tables are no longer read for
 * catalog or config (they still own settings/routes and remain the migration
 * source). A corrupt document is treated like an absent one (Room fallback)
 * and logged; Dart owns repairing it, this reader never overwrites it.
 *
 * Parsed rows are cached by file mtime+length (like RouteJsonStore), because
 * buildStartOptions and the catalog can read the same snapshot many times in a
 * second. A Dart write changes both, so the next read re-parses.
 */
object DartProfileStore {

    private const val FILE_NAME = "profiles.json"
    private const val VERSION = 1

    /** The documents directory; the host sets it at attach from `data.path`. */
    @Volatile
    var directory: File? = null
        set(value) {
            field = value
            synchronized(cacheLock) { cached = null }
        }

    /** Diagnostics sink, injectable so JVM tests can exercise the corrupt path. */
    @Volatile
    var logger: (String, Throwable?) -> Unit = { message, error ->
        if (error != null) {
            io.nekohasekai.sagernet.ktx.Logs.w(message, error)
        } else {
            io.nekohasekai.sagernet.ktx.Logs.w(message)
        }
    }

    private class Snapshot(
        val stamp: Long,
        val profiles: List<ProxyEntity>,
        val groups: List<ProxyGroup>,
        val nextProfileId: Long,
        val nextGroupId: Long,
    )

    private val cacheLock = Any()
    private var cached: Snapshot? = null

    private fun file(): File? = directory?.let { File(it, FILE_NAME) }

    /**
     * True only when the document exists **and parses**. A corrupt file must
     * behave like an absent one everywhere: `config.build` falls back to Room,
     * and `publishFromRoom` must not treat the broken file as authoritative and
     * overwrite it.
     */
    fun available(): Boolean = snapshot() != null

    /** The parsed snapshot, or null when the document is absent/corrupt. */
    private fun snapshot(): Snapshot? {
        val file = file()
        if (file == null || !file.isFile) return null
        val stamp = file.lastModified() * 31 + file.length()
        synchronized(cacheLock) {
            val hit = cached
            if (hit != null && hit.stamp == stamp) return hit
            val parsed = try {
                parse(file.readText(), stamp)
            } catch (e: Exception) {
                logger("unreadable profiles.json; using Room fallback", e)
                return null
            }
            cached = parsed
            return parsed
        }
    }

    private fun parse(text: String, stamp: Long): Snapshot? {
        val root = JSONObject(text)
        if (root.optInt("version", -1) != VERSION) {
            logger("unsupported profiles.json version ${root.optInt("version")}", null)
            return null
        }
        val profiles = root.optJSONArray("profiles")?.mapProfiles().orEmpty()
        val groups = root.optJSONArray("groups")?.mapGroups().orEmpty()
        val maxProfile = profiles.maxOfOrNull { it.id } ?: 0L
        val maxGroup = groups.maxOfOrNull { it.id } ?: 0L
        return Snapshot(
            stamp = stamp,
            profiles = profiles,
            groups = groups,
            nextProfileId = maxOf(root.optLong("nextProfileId", maxProfile + 1), maxProfile + 1),
            nextGroupId = maxOf(root.optLong("nextGroupId", maxGroup + 1), maxGroup + 1),
        )
    }

    // --- row mapping: JSON column name -> entity field ---------------------

    internal fun profileOf(obj: JSONObject): ProxyEntity? {
        val id = obj.optLong("id", 0L).takeIf { it > 0L } ?: return null
        return ProxyEntity(
            id = id,
            type = obj.optString("type"),
            name = obj.optStringOrNull("name"),
            groupId = obj.optLong("gid", 0L),
            userOrder = obj.optLong("user_order", 0L),
            latency = obj.optInt("latency", 0),
            latencyAt = obj.optLong("latency_at", 0L),
            dlSpeed = obj.optStringOrNull("dl_speed"),
            ulSpeed = obj.optStringOrNull("ul_speed"),
            testCountry = obj.optStringOrNull("test_country"),
            ipOut = obj.optStringOrNull("ip_out"),
            outboundJson = obj.optString("outbound_json"),
            rx = obj.optLong("traffic_dl", 0L),
            tx = obj.optLong("traffic_up", 0L),
            testError = obj.optStringOrNull("test_error"),
        )
    }

    internal fun groupOf(obj: JSONObject): ProxyGroup? {
        val id = obj.optLong("id", 0L).takeIf { it > 0L } ?: return null
        val group = ProxyGroup(
            id = id,
            archive = obj.optBoolean("archive", false),
            skipAutoUpdate = obj.optBoolean("skip_auto_update", false),
            name = obj.optString("name"),
            url = obj.optString("url"),
            info = obj.optString("info"),
            subLastUpdate = obj.optLong("sub_last_update", 0L),
            frontProxyId = obj.optLong("front_proxy_id", -1L),
            landingProxyId = obj.optLong("landing_proxy_id", -1L),
            columnWidthJson = obj.optString("column_width_json"),
            scrollLastProfile = obj.optInt("scroll_last_profile", -1),
            autoClearUnavailable = obj.optBoolean("auto_clear_unavailable", false),
            testSortBy = obj.optInt("test_sort_by", 0),
            trafficSortBy = obj.optInt("traffic_sort_by", 0),
            testItemsToShow = obj.optInt("test_items_to_show", 0),
            typeSortBy = obj.optInt("type_sort_by", 0),
            sortMethod = obj.optInt("sort_method", 0),
            sortDescending = obj.optBoolean("sort_descending", false),
            displayOrder = obj.optLong("display_order", 0L),
            routeId = obj.optLong("route_id", -1L),
            importSubRoute = obj.optBoolean("import_sub_route", false),
        )
        // The two opaque codecs stay in Kotlin, which owns their model. A column
        // written before the typed JSON existed is skipped, giving the codec's
        // own defaults (both parse() handle blank/null as "empty").
        val subOptions = obj.optString("sub_options_json", "")
        if (subOptions.isNotEmpty()) group.subOptions = SubscriptionOptions.parse(subOptions)
        val subMetadata = obj.optString("sub_metadata_json", "")
        if (subMetadata.isNotEmpty()) group.subMetadata = SubUserInfo.parse(subMetadata)
        return group
    }

    // --- public read API ---------------------------------------------------

    /** Every profile, or Room's copy before the migration. */
    fun profiles(): List<ProxyEntity> =
        snapshot()?.profiles ?: runCatching { SagerDatabase.proxyDao.getAll() }
            .getOrDefault(emptyList())

    /** Every group in tab order, or Room's copy before the migration. */
    fun groups(): List<ProxyGroup> =
        snapshot()?.groups?.sortedBy { it.displayOrder }
            ?: runCatching { SagerDatabase.groupDao.allGroups() }.getOrDefault(emptyList())

    /** One profile by id, or Room's copy before the migration. */
    fun profile(id: Long): ProxyEntity? {
        if (id <= 0L) return null
        val snap = snapshot()
        if (snap != null) return snap.profiles.firstOrNull { it.id == id }
        return runCatching { SagerDatabase.proxyDao.getById(id) }.getOrNull()
    }

    /** One group by id, or Room's copy before the migration. */
    fun group(id: Long): ProxyGroup? {
        if (id <= 0L) return null
        val snap = snapshot()
        if (snap != null) return snap.groups.firstOrNull { it.id == id }
        return runCatching { SagerDatabase.groupDao.getById(id) }.getOrNull()
    }

    /** Profiles of a group in list order (user_order, id). */
    fun members(groupId: Long): List<ProxyEntity> =
        profiles().filter { it.groupId == groupId }
            .sortedWith(compareBy<ProxyEntity>({ it.userOrder }, { it.id }))

    /** Member ids of a group in list order. */
    fun memberIds(groupId: Long): List<Long> = members(groupId).map { it.id }

    /** Profiles by id, in the order requested (skipping missing ones). */
    fun profiles(ids: Collection<Long>): List<ProxyEntity> {
        if (ids.isEmpty()) return emptyList()
        val wanted = ids.toSet()
        return profiles().filter { it.id in wanted }
    }

    /** The id Dart will hand out for the next profile, from the document counters. */
    fun nextProfileId(): Long =
        snapshot()?.nextProfileId
            ?: runCatching { SagerDatabase.proxyDao.getAll().maxOfOrNull { it.id + 1 } ?: 1L }
                .getOrDefault(1L)

    // --- test / diagnostics ------------------------------------------------

    /** Forgets the cached snapshot. Tests call this; a production write changes
     * the file stamp so the cache self-invalidates. */
    fun invalidate() {
        synchronized(cacheLock) { cached = null }
    }
}

private fun JSONArray.mapProfiles(): List<ProxyEntity> {
    val out = ArrayList<ProxyEntity>(length())
    for (i in 0 until length()) {
        val obj = optJSONObject(i) ?: continue
        DartProfileStore.profileOf(obj)?.let(out::add)
    }
    return out
}

private fun JSONArray.mapGroups(): List<ProxyGroup> {
    val out = ArrayList<ProxyGroup>(length())
    for (i in 0 until length()) {
        val obj = optJSONObject(i) ?: continue
        DartProfileStore.groupOf(obj)?.let(out::add)
    }
    return out
}

/** JSONObject.NULL and an absent key both mean "no value" for a nullable column. */
private fun JSONObject.optStringOrNull(key: String): String? {
    if (isNull(key)) return null
    val value = opt(key) ?: return null
    val text = value.toString()
    return text.ifEmpty { null }
}
