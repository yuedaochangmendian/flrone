package io.flrone.bridge

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.nekohasekai.sagernet.database.ProxyEntity
import io.nekohasekai.sagernet.database.ProxyGroup
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Kotlin -> Dart write bridge for the profiles/groups document (ADR 0005 final
 * stage, S6 owner cutover). Dart is the **only** writer of that document; every
 * catalog mutation — from the UI relay, the subscription importer, the test
 * runners or a backup restore — funnels through the single `document` channel
 * method. There is deliberately no second write protocol and no Room mirror.
 *
 * Owner election (S6 Option A): the **service engine** is the preferred owner.
 * It is attached by [io.flrone.flutter.ServiceEngineManager] when that engine
 * comes up. A UI engine may only be a *fallback* owner: it registers its
 * messenger here but is never attached while a service owner exists, and
 * closing the UI does not detach anything (the service keeps ownership). One
 * writable channel at a time — a second role cannot steal the owner. When the
 * service engine is destroyed/failed, its detach fails every in-flight call and
 * the next write re-elects the UI fallback.
 *
 * The transport is a small envelope: `invokeMethod("document", {id, method,
 * args})`, where `method` is the Dart document op (`applyDocument`,
 * `configurationWrite`, `nodeList`, …) and `args` is its unchanged payload.
 * The root isolate of the owning engine forwards it to its worker and echoes
 * the id back with the reply. Kotlin keeps the pending continuations keyed by
 * that id; a `ReplyGate` makes detach and a late reply settle exactly once.
 *
 * Every method here is a thin row-mapper/forwarder: no profile logic lives in
 * Kotlin. Callers on a synchronous thread wrap the suspend call in `runBlocking`
 * on an IO thread (ProfileManager/GroupRepo), so the caller's thread is never
 * blocked. The channel invoke itself is `@UiThread` (FlutterJNI), so [call]
 * marshals onto the main thread with a post — never a wait — and the caller
 * resumes on its own dispatcher when Dart replies.
 */
object DartProfileWriter {

    private const val DOCUMENT = "document"
    private const val APPLY = "applyDocument"

    /** Which Dart engine currently owns the profiles document. */
    enum class OwnerRole { NONE, SERVICE, UI }

    /** The small ack Dart replies to an apply, never the whole document. */
    data class WriteResult(
        val nextProfileId: Long,
        val nextGroupId: Long,
        /** Client id (negative) -> id Dart assigned, per table. */
        val profileIds: Map<Long, Long>,
        val groupIds: Map<Long, Long>,
    )

    @Volatile
    private var channel: MethodChannel? = null

    @Volatile
    private var role: OwnerRole = OwnerRole.NONE

    /** The UI engine's messenger, remembered but NOT attached as owner. */
    @Volatile
    private var uiMessenger: BinaryMessenger? = null

    /**
     * Calls waiting for a Dart reply, as `fail(exception)` closures. [detach]
     * fails them explicitly: a write in flight when the owner engine went away
     * otherwise never resumed and its `runBlocking(Dispatchers.IO)` caller
     * parked a thread forever. A closure keeps the cancellation type out of the
     * set's signature.
     */
    private val pending: MutableSet<(Throwable) -> Unit> =
        Collections.newSetFromMap(ConcurrentHashMap<(Throwable) -> Unit, Boolean>())

    @Volatile
    private var nextId = 0

    /** The UI engine hands its messenger over for fallback election. No attach. */
    fun registerUiMessenger(messenger: BinaryMessenger) {
        uiMessenger = messenger
    }

    /**
     * Elects the service engine as owner. A service engine always wins: an
     * existing UI fallback is drained and replaced, never kept alongside it.
     */
    @Synchronized
    fun attachService(messenger: BinaryMessenger) {
        if (role == OwnerRole.SERVICE && channel != null) return
        drainPending("profiles document owner changed to service")
        channel = MethodChannel(messenger, "io.flrone/profiles_doc")
        role = OwnerRole.SERVICE
        DartProfileStore.invalidate()
    }

    /**
     * Elects the UI engine as *fallback* owner. Refused while a service owner
     * is attached — the UI must not steal ownership, and especially must not
     * re-attach on close.
     */
    @Synchronized
    fun attachUiFallback(): Boolean {
        if (role == OwnerRole.SERVICE && channel != null) return false
        if (role == OwnerRole.UI && channel != null) return true
        val messenger = uiMessenger ?: return false
        channel = MethodChannel(messenger, "io.flrone/profiles_doc")
        role = OwnerRole.UI
        DartProfileStore.invalidate()
        return true
    }

    /** Detaches only the named role; the other owner is left untouched. */
    @Synchronized
    fun detach(owner: OwnerRole) {
        if (role != owner) return
        channel = null
        role = OwnerRole.NONE
        drainPending("profiles_doc engine detached ($owner)")
    }

    /** Detaches whichever role currently owns (tests/legacy callers). */
    @Synchronized
    fun detach() {
        val current = role
        if (current == OwnerRole.NONE) return
        channel = null
        role = OwnerRole.NONE
        drainPending("profiles_doc engine detached ($current)")
    }

    /** True while a Dart engine is attached to receive writes. */
    fun attached(): Boolean = channel != null || testTransport != null

    fun currentRole(): OwnerRole = role

    /**
     * Resolves the writable channel, electing the UI fallback only when no
     * service owner exists. [testTransport] takes precedence in JVM tests.
     */
    private fun ensureOwner(): MethodChannel? {
        channel?.let { return it }
        if (testTransport != null) return null
        if (attachUiFallback()) return channel
        return null
    }

    /**
     * Bounded wait for an owner. The service engine's Dart handler is installed
     * a moment after the Kotlin attach, and a prewarm/boot write can race it;
     * the window is short so a genuinely absent engine is reported, not parked.
     */
    suspend fun ensureOwner(timeoutMs: Long = 2_000): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (true) {
            if (ensureOwner() != null || testTransport != null) return true
            if (System.currentTimeMillis() >= deadline) return false
            delay(25)
        }
    }

    private fun drainPending(reason: String) {
        val stuck = synchronized(pending) { pending.toList().also { pending.clear() } }
        for (fail in stuck) {
            fail(IllegalStateException(reason))
        }
    }

    /**
     * In-process transport for JVM tests: it stands in for the owning engine's
     * `profiles_doc` handler — `(method, args) -> reply` — so the row mapping,
     * the id allocation and the error paths run without a Flutter engine (and
     * without Room). Production leaves this null and uses the channel.
     */
    @Volatile
    internal var testTransport: (suspend (String, Any?) -> Any?)? = null

    /** Whether a write can land anywhere: the live channel or a test transport. */
    private fun writable(): Boolean = channel != null || testTransport != null

    // ---------------------------------------------------------------------------- row mapping

    /** A ProxyEntity as the Room-column-keyed map the Dart document stores. */
    fun profileRow(p: ProxyEntity): Map<String, Any?> = mapOf(
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

    /** A ProxyGroup as the Room-column-keyed map the Dart document stores. */
    fun groupRow(g: ProxyGroup): Map<String, Any?> = buildMap {
        put("id", g.id)
        put("archive", g.archive)
        put("skip_auto_update", g.skipAutoUpdate)
        put("name", g.name)
        put("url", g.url)
        put("info", g.info)
        put("sub_last_update", g.subLastUpdate)
        put("front_proxy_id", g.frontProxyId)
        put("landing_proxy_id", g.landingProxyId)
        put("column_width_json", g.columnWidthJson)
        put("scroll_last_profile", g.scrollLastProfile)
        put("auto_clear_unavailable", g.autoClearUnavailable)
        put("test_sort_by", g.testSortBy)
        put("traffic_sort_by", g.trafficSortBy)
        put("test_items_to_show", g.testItemsToShow)
        put("type_sort_by", g.typeSortBy)
        put("sub_options_json", g.subOptions.toJsonString())
        put("sub_metadata_json", g.subMetadata.toJsonString())
        put("sort_method", g.sortMethod)
        put("sort_descending", g.sortDescending)
        put("display_order", g.displayOrder)
        put("route_id", g.routeId)
        put("import_sub_route", g.importSubRoute)
        // Document-only extension key (the single-node container). Omitted when
        // unset, so a normal group's row stays exactly the Room columns.
        if (g.single) put("single", true)
    }

    // ---------------------------------------------------------------------------- low level

    /**
     * One document op on the owner. [structural] marks writes whose loss is
     * data loss (a UI relay op, a backup replace-all): with no owner they throw
     * instead of answering null, so the caller cannot mistake success for a
     * no-op. Kotlin's legacy row writes stay inert when no engine is attached
     * (bridge mode), preserving their in-memory-entity behaviour.
     */
    suspend fun callOwner(method: String, args: Map<String, Any?>, structural: Boolean = false): Any? {
        val transport = testTransport
        if (transport != null) {
            @Suppress("UNCHECKED_CAST")
            return transport(method, args)
        }
        val ch = ensureOwner()
        if (ch == null) {
            if (structural) {
                throw IllegalStateException("profiles document owner is unavailable: $method")
            }
            return null
        }
        val result = call<Map<*, *>>(ch, method, args)
        DartProfileStore.invalidate()
        return result
    }

    /**
     * The UI engine's relay: one opaque document op, forwarded byte-for-byte to
     * the owner. No Kotlin parsing: the owner's [io.flrone.flutter.service_entry]
     * handler dispatches `method` to the Dart `ProfileDocumentService`.
     */
    suspend fun relay(method: String, args: Map<String, Any?>) {
        callOwner(method, args, structural = true)
    }

    /**
     * The one and only Kotlin row-write request. A single document edit may
     * combine a replace, deletes, row upserts, per-column patches and a reorder;
     * Dart runs them in order against its one in-memory copy and persists
     * atomically. Returns the ack Dart wrote back, or null when no engine is
     * attached (legacy bridge-mode behaviour).
     */
    suspend fun applyDocument(
        profiles: List<Map<String, Any?>> = emptyList(),
        groups: List<Map<String, Any?>> = emptyList(),
        replaceAll: Boolean = false,
        nextProfileId: Long? = null,
        nextGroupId: Long? = null,
        deleteProfileIds: Collection<Long> = emptyList(),
        deleteGroupIds: Collection<Long> = emptyList(),
        profilePatches: Map<Long, Map<String, Any?>> = emptyMap(),
        groupPatches: Map<Long, Map<String, Any?>> = emptyMap(),
        allocateIds: Boolean = false,
        reorderGroupId: Long? = null,
        reorderProfileIds: Collection<Long>? = null,
        reorderGroups: Boolean = false,
        trafficDeltas: Map<Long, Pair<Long, Long>> = emptyMap(),
    ): WriteResult? {
        if (!writable()) return null
        // Plain Map/List, not JSONObject: MethodChannel uses StandardMethodCodec,
        // which only accepts the codec's own primitives/maps/lists. Nulls are
        // legal map values here and mean "clear this Room column" on the Dart
        // side (Dart's normalizePlatformValue keeps them).
        val args = HashMap<String, Any?>().apply {
            put("replaceAll", replaceAll)
            put("profiles", profiles)
            put("groups", groups)
            put("deleteProfileIds", deleteProfileIds.toList())
            put("deleteGroupIds", deleteGroupIds.toList())
            put("allocateIds", allocateIds)
            if (profilePatches.isNotEmpty()) {
                put("profilePatches", profilePatches.mapKeys { (id, _) -> id.toString() })
            }
            if (groupPatches.isNotEmpty()) {
                put("groupPatches", groupPatches.mapKeys { (id, _) -> id.toString() })
            }
            if (reorderGroupId != null && reorderProfileIds != null) {
                put("reorderGroupId", reorderGroupId)
                put("reorderProfileIds", reorderProfileIds.toList())
            }
            if (reorderGroups) put("reorderGroups", true)
            if (trafficDeltas.isNotEmpty()) {
                put("trafficDeltas", trafficDeltas.mapValues { (_, delta) ->
                    listOf(delta.first, delta.second)
                })
            }
            if (nextProfileId != null) put("nextProfileId", nextProfileId)
            if (nextGroupId != null) put("nextGroupId", nextGroupId)
        }
        val raw = callOwner(APPLY, args) as? Map<*, *> ?: return null
        return WriteResult(
            nextProfileId = (raw["nextProfileId"] as? Number)?.toLong() ?: 0L,
            nextGroupId = (raw["nextGroupId"] as? Number)?.toLong() ?: 0L,
            profileIds = idMap(raw["profileIds"]),
            groupIds = idMap(raw["groupIds"]),
        )
    }

    // ---------------------------------------------------------------------------- typed writes

    /** Inserts [profiles] as new rows in [gid], assigning dense user_order
     * positions after the current members. Because Dart owns the id counter the
     * rows are sent with a temporary negative id and the real id is written back
     * into the entities from the ack. No-op (entities untouched) when no engine
     * is attached. */
    suspend fun addProfiles(profiles: List<ProxyEntity>, gid: Long): List<ProxyEntity> {
        if (profiles.isEmpty() || !writable()) return profiles
        val existing = DartProfileStore.memberIds(gid)
        // Captured BEFORE the ids are rewritten to temporary negatives — the
        // old order captured after the rewrite, so the failure path "restored"
        // -1/-2 and leaked them into the caller's entities.
        val originalIds = profiles.map { it.id }
        var temp = -1L
        val rows = ArrayList<Map<String, Any?>>(profiles.size)
        profiles.forEachIndexed { index, p ->
            p.id = temp--
            p.groupId = gid
            p.userOrder = (existing.size + index).toLong()
            rows.add(profileRow(p))
        }
        val ack = try {
            applyDocument(profiles = rows, allocateIds = true)
        } catch (cancelled: CancellationException) {
            profiles.forEachIndexed { i, p -> p.id = originalIds[i] }
            return profiles
        } catch (failure: Throwable) {
            profiles.forEachIndexed { i, p -> p.id = originalIds[i] }
            throw failure
        }
        if (ack == null) {
            profiles.forEachIndexed { i, p -> p.id = originalIds[i] }
            return profiles
        }
        val ids = ack.profileIds
        for (p in profiles) {
            ids[p.id]?.let { p.id = it }
        }
        return profiles
    }

    /** Inserts groups with a temporary negative id (Dart assigns the real one). */
    suspend fun addGroups(groups: List<ProxyGroup>): List<ProxyGroup> {
        if (groups.isEmpty() || !writable()) return groups
        val originalIds = groups.map { it.id }
        var temp = -1L
        val rows = ArrayList<Map<String, Any?>>(groups.size)
        for (g in groups) {
            g.id = temp--
            rows.add(groupRow(g))
        }
        val ack = try {
            applyDocument(groups = rows, allocateIds = true)
        } catch (cancelled: CancellationException) {
            groups.forEachIndexed { i, g -> g.id = originalIds[i] }
            return groups
        } catch (failure: Throwable) {
            groups.forEachIndexed { i, g -> g.id = originalIds[i] }
            throw failure
        }
        if (ack == null) {
            groups.forEachIndexed { i, g -> g.id = originalIds[i] }
            return groups
        }
        val ids = ack.groupIds
        for (g in groups) {
            ids[g.id]?.let { g.id = it }
        }
        return groups
    }

    suspend fun updateProfiles(profiles: Collection<ProxyEntity>) {
        if (profiles.isEmpty()) return
        applyDocument(profiles = profiles.map(::profileRow))
    }

    suspend fun updateGroups(groups: Collection<ProxyGroup>) {
        if (groups.isEmpty()) return
        applyDocument(groups = groups.map(::groupRow))
    }

    suspend fun patchProfiles(patches: Map<Long, Map<String, Any?>>) {
        if (patches.isEmpty()) return
        applyDocument(profilePatches = patches)
    }

    suspend fun patchGroups(patches: Map<Long, Map<String, Any?>>) {
        if (patches.isEmpty()) return
        applyDocument(groupPatches = patches)
    }

    suspend fun addTraffic(deltas: Map<Long, Pair<Long, Long>>) {
        if (deltas.isEmpty()) return
        applyDocument(trafficDeltas = deltas)
    }

    suspend fun deleteProfiles(ids: Collection<Long>) {
        if (ids.isEmpty()) return
        applyDocument(deleteProfileIds = ids)
    }

    suspend fun deleteGroups(ids: Collection<Long>) {
        if (ids.isEmpty()) return
        applyDocument(deleteGroupIds = ids)
    }

    suspend fun reorderGroup(gid: Long, ids: List<Long>) {
        applyDocument(reorderGroupId = gid, reorderProfileIds = ids)
    }

    /** Full replacement (used by a Kotlin-side restore that rewrites both tables). */
    suspend fun replaceAll(
        profiles: List<ProxyEntity>,
        groups: List<ProxyGroup>,
        nextProfileId: Long,
        nextGroupId: Long,
    ) {
        applyDocument(
            profiles = profiles.map(::profileRow),
            groups = groups.map(::groupRow),
            replaceAll = true,
            nextProfileId = nextProfileId,
            nextGroupId = nextGroupId,
        )
    }

    // ---------------------------------------------------------------------------- channel plumbing

    /**
     * `MethodChannel.invokeMethod` is `@UiThread`: FlutterJNI.dispatchPlatformMessage
     * asserts the main looper. The profile writers run on IO workers, so [call]
     * marshals onto the main thread (a post, never a blocking wait) while the
     * caller keeps suspending on its own dispatcher. Injectable for JVM tests.
     */
    @Volatile
    internal var isMainThread: () -> Boolean = {
        runCatching { Looper.myLooper() == Looper.getMainLooper() }.getOrDefault(true)
    }

    /** Posts [runnable] to the main looper; false when there is no main looper (JVM tests). */
    @Volatile
    internal var postToMain: (Runnable) -> Boolean = { runnable ->
        runCatching { Handler(Looper.getMainLooper()).post(runnable) }.getOrDefault(false)
    }

    /** Dart serialises the id maps with string keys; decode either representation. */
    private fun idMap(value: Any?): Map<Long, Long> {
        if (value !is Map<*, *>) return emptyMap()
        val out = HashMap<Long, Long>()
        value.forEach { (key, v) ->
            val client = (key as? Number)?.toLong() ?: key.toString().toLongOrNull() ?: return@forEach
            val real = (v as? Number)?.toLong() ?: return@forEach
            out[client] = real
        }
        return out
    }

    private suspend fun <T> call(ch: MethodChannel, method: String, args: Any?): T? =
        suspendCancellableCoroutine { cont ->
            val id = ++nextId
            // The envelope is what the owning engine's root isolate forwards to
            // its worker; it echoes `id` back with the reply. A single gate
            // settles the continuation: detach, late reply, cancel and invoke
            // failure all claim it first.
            val envelope = mapOf<String, Any?>("id" to id, "method" to method, "args" to args)
            val gate = ReplyGate()
            val failHolder = arrayOfNulls<(Throwable) -> Unit>(1)
            val fail: (Throwable) -> Unit = { error ->
                if (gate.claim()) {
                    pending.remove(failHolder[0])
                    cont.resumeWithException(error)
                }
            }
            failHolder[0] = fail
            pending.add(fail)
            fun settle() {
                if (gate.claim()) pending.remove(fail)
            }
            cont.invokeOnCancellation { settle() }
            dispatchToMain(isMainThread(), postToMain) {
                if (!cont.isActive) {
                    settle()
                    return@dispatchToMain
                }
                // The owner may have been replaced between the channel read and
                // the main-thread post. Calling an old messenger would throw on
                // a destroyed engine and the caller would wait forever.
                if (channel !== ch) {
                    fail(IllegalStateException("profiles_doc owner changed"))
                    return@dispatchToMain
                }
                runCatching {
                    ch.invokeMethod(DOCUMENT, envelope, object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            if (!gate.claim()) return
                            pending.remove(fail)
                            @Suppress("UNCHECKED_CAST")
                            cont.resume(result as T?)
                        }

                        override fun error(code: String, message: String?, details: Any?) {
                            if (!gate.claim()) return
                            pending.remove(fail)
                            cont.resumeWithException(
                                IllegalStateException("profiles_doc.$method: $code ${message.orEmpty()}")
                            )
                        }

                        override fun notImplemented() {
                            if (!gate.claim()) return
                            pending.remove(fail)
                            cont.resume(null)
                        }
                    })
                }.onFailure { failure ->
                    if (gate.claim()) {
                        pending.remove(fail)
                        cont.resumeWithException(failure)
                    }
                }
            }
        }
}

/** A one-shot settlement flag for a channel reply. [claim] is true exactly once. */
internal class ReplyGate {
    private val settled = java.util.concurrent.atomic.AtomicBoolean(false)

    fun claim(): Boolean = settled.compareAndSet(false, true)
}

/**
 * Runs [block] on the main thread: inline when already there, otherwise through
 * [post]; a [post] that cannot reach a main looper runs the block in place.
 * Top-level so a plain JVM test can drive every branch without loading
 * [DartProfileWriter] (whose default hooks mention `Looper`/`Handler`).
 */
internal inline fun dispatchToMain(
    isMain: Boolean,
    post: (Runnable) -> Boolean,
    crossinline block: () -> Unit,
) {
    if (isMain) {
        block()
    } else if (!post(Runnable { block() })) {
        block()
    }
}
