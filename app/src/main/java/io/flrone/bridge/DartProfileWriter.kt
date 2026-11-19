package io.flrone.bridge

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.nekohasekai.sagernet.database.SagerDatabase
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Kotlin -> Dart bridge for the profiles/groups document (ADR 0005 final
 * stage). This stage flips the **read** authority to the Dart document; the
 * profile/group writes still go through Room, and the only production caller
 * here is [publishFromRoom], which mirrors those rows into the document until
 * the CRUD handlers themselves move to Dart. The parse-only handlers
 * (importFile, scan, nodeLink, nodeConfig, decodeIntent) still write Room too.
 *
 * A suspend `invoke` wraps the standard async MethodChannel reply so callers can
 * treat the write as an ordinary `await`. Restarting the writer on a new
 * messenger is safe; the bridge installs one per UI engine attach.
 */
object DartProfileWriter {

    private const val APPLY = "applyDocument"

    @Volatile
    private var channel: MethodChannel? = null

    fun attach(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, "io.flrone/profiles_doc")
    }

    fun detach() {
        channel = null
    }

    /**
     * Merges [profiles]/[groups] rows (Room column names) into the document, or
     * replaces it entirely when [replaceAll]. Returns the document Dart wrote
     * back, or null when no Dart engine is attached (bridge fallback mode).
     */
    suspend fun applyDocument(
        profiles: List<Map<String, Any?>> = emptyList(),
        groups: List<Map<String, Any?>> = emptyList(),
        replaceAll: Boolean = false,
        nextProfileId: Long? = null,
        nextGroupId: Long? = null,
        deleteProfileIds: Collection<Long> = emptyList(),
        deleteGroupIds: Collection<Long> = emptyList(),
    ): JSONObject? {
        val ch = channel ?: return null
        val args = JSONObject().apply {
            put("replaceAll", replaceAll)
            put("profiles", JSONArray(profiles.map { JSONObject(it) }))
            put("groups", JSONArray(groups.map { JSONObject(it) }))
            put("deleteProfileIds", JSONArray(deleteProfileIds))
            put("deleteGroupIds", JSONArray(deleteGroupIds))
            if (nextProfileId != null) put("nextProfileId", nextProfileId)
            if (nextGroupId != null) put("nextGroupId", nextGroupId)
        }
        val raw = call<Any?>(APPLY, args) ?: return null
        return runCatching { JSONObject(raw.toString()) }.getOrNull()
    }

    /**
     * Publishes the current Room profile/group tables to the document as a full
     * replace. Used by the staged migration: while a write handler still goes
     * through Room, it calls this afterwards so the Dart read authority sees the
     * same rows. Reads have already moved to DartProfileStore; this is the
     * reverse sync that keeps them correct until each Room write is retired.
     *
     * A no-op when no Dart engine is attached (bridge mode / tests).
     */
    suspend fun publishFromRoom() {
        // Only publish once Dart has produced the document (the one-time
        // migration). Before that, Room is the sole source and Dart will seed
        // from it; publishing an empty pre-migration document would clobber it.
        if (channel == null || !DartProfileStore.available()) return
        val (profiles, groups, nextProfileId, nextGroupId) = withContext(Dispatchers.IO) {
            val profiles = SagerDatabase.proxyDao.getAll().map { p ->
                mapOf(
                    "id" to p.id,
                    "type" to p.type,
                    "name" to p.name,
                    "gid" to p.groupId,
                    "user_order" to p.userOrder,
                    "latency" to p.latency,
                    "latency_at" to p.latencyAt,
                    "dl_speed" to p.dlSpeed,
                    "ul_speed" to p.ulSpeed,
                    "test_country" to p.testCountry,
                    "ip_out" to p.ipOut,
                    "outbound_json" to p.outboundJson,
                    "traffic_dl" to p.rx,
                    "traffic_up" to p.tx,
                    "test_error" to p.testError,
                )
            }
            val groups = SagerDatabase.groupDao.allGroups().map { g ->
                mapOf(
                    "id" to g.id,
                    "archive" to g.archive,
                    "skip_auto_update" to g.skipAutoUpdate,
                    "name" to g.name,
                    "url" to g.url,
                    "info" to g.info,
                    "sub_last_update" to g.subLastUpdate,
                    "front_proxy_id" to g.frontProxyId,
                    "landing_proxy_id" to g.landingProxyId,
                    "column_width_json" to g.columnWidthJson,
                    "scroll_last_profile" to g.scrollLastProfile,
                    "auto_clear_unavailable" to g.autoClearUnavailable,
                    "test_sort_by" to g.testSortBy,
                    "traffic_sort_by" to g.trafficSortBy,
                    "test_items_to_show" to g.testItemsToShow,
                    "type_sort_by" to g.typeSortBy,
                    "sub_options_json" to g.subOptions.toJsonString(),
                    "sub_metadata_json" to g.subMetadata.toJsonString(),
                    "sort_method" to g.sortMethod,
                    "sort_descending" to g.sortDescending,
                    "display_order" to g.displayOrder,
                    "route_id" to g.routeId,
                    "import_sub_route" to g.importSubRoute,
                )
            }
            val nextProfileId = (profiles.maxOfOrNull { it["id"] as? Long ?: 0L } ?: 0L) + 1
            val nextGroupId = (groups.maxOfOrNull { it["id"] as? Long ?: 0L } ?: 0L) + 1
            Quad(profiles, groups, nextProfileId, nextGroupId)
        }
        applyDocument(
            profiles = profiles,
            groups = groups,
            replaceAll = true,
            nextProfileId = nextProfileId,
            nextGroupId = nextGroupId,
        )
    }

    private data class Quad(
        val profiles: List<Map<String, Any?>>,
        val groups: List<Map<String, Any?>>,
        val nextProfileId: Long,
        val nextGroupId: Long,
    )

    private suspend fun <T> call(method: String, args: Any?): T? =
        suspendCancellableCoroutine { cont ->
            val ch = channel
            if (ch == null) {
                cont.resume(null)
                return@suspendCancellableCoroutine
            }
            ch.invokeMethod(method, args, object : MethodChannel.Result {
                override fun success(result: Any?) {
                    @Suppress("UNCHECKED_CAST")
                    cont.resume(result as T?)
                }

                override fun error(code: String, message: String?, details: Any?) {
                    cont.resumeWithException(
                        IllegalStateException("profiles_doc.$method: $code ${message.orEmpty()}")
                    )
                }

                override fun notImplemented() {
                    cont.resume(null)
                }
            })
        }
}
