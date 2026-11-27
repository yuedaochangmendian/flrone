package io.nekohasekai.sagernet.database

import io.nekohasekai.sagernet.SagerNet
import io.nekohasekai.sagernet.aidl.TrafficData
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.outbound.Outbound
import io.flrone.bridge.DartProfileStore
import io.flrone.bridge.DartProfileWriter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The profile repository (the desktop's ProfilesRepo plus the list edits of Group.cpp) over the
 * Dart-owned `profiles.json` document. A group's members are its rows ordered by `user_order`,
 * kept dense (0..n-1 = the desktop's `profiles_json` index). Writes that change what a kept group
 * sort reads queue a [GroupSort] re-sort, as ProfilesRepo.cpp does.
 *
 * ADR 0005 final stage / ADR 0006 stage C2c2b1: the document is the ONLY store. Reads go through
 * [DartProfileStore]; a missing/corrupt document throws [io.flrone.bridge.ProfilesDocumentUnavailable] rather than
 * silently answering stale Room rows. Every write crosses [DartProfileWriter] (Dart owns the file,
 * the ids and the atomic edit); Room's `profiles` table is a migration source only and is never
 * read or written here.
 *
 * `runBlocking` remains only in [saveTestResult] and [clearTestResults]: the test runners and the
 * speed-test service call them from a synchronous path and already run on IO threads, so the short
 * channel round-trip is bridged there and never blocks the main thread.
 */
object ProfileManager {

    interface Listener {
        suspend fun onAdd(profile: ProxyEntity)
        suspend fun onUpdated(data: List<TrafficData>)
        suspend fun onUpdated(profile: ProxyEntity, noTraffic: Boolean)
        suspend fun onRemoved(groupId: Long, profileId: Long)
    }

    /** Told about the bytes [addTraffic] credits, in the process that credits them. */
    fun interface CreditListener {
        suspend fun onCredited(profileId: Long, rx: Long, tx: Long)
    }

    /**
     * The result of [batchDeleteProfiles]: [kept] holds the requested ids that were not deleted, [stopped] the running
     * profile this delete stopped (allow_stopping_active_profile).
     */
    class DeleteOutcome(
        @JvmField val ok: Boolean,
        @JvmField val deleted: List<Long>,
        @JvmField val kept: List<Long>,
        @JvmField val stopped: ProxyEntity? = null,
    )

    private val listeners = ArrayList<Listener>()
    private val creditListeners = CopyOnWriteArrayList<CreditListener>()

    suspend fun iterator(what: suspend Listener.() -> Unit) {
        synchronized(listeners) {
            listeners.toList()
        }.forEach { listener ->
            what(listener)
        }
    }

    fun addListener(listener: Listener) {
        synchronized(listeners) {
            listeners.add(listener)
        }
    }

    fun removeListener(listener: Listener) {
        synchronized(listeners) {
            listeners.remove(listener)
        }
    }

    fun addCreditListener(listener: CreditListener) {
        creditListeners.add(listener)
    }

    fun removeCreditListener(listener: CreditListener) {
        creditListeners.remove(listener)
    }

    // ------------------------------------------------------------------------------------------------ reads

    /**
     * Whether the one-time seed has produced the document. Kept for callers outside this object
     * that gate on the handover; it is **not** a fallback signal here — every read below uses
     * [DartProfileStore] and a missing document throws. A present-but-corrupt document is also
     * "exists" and throws from the read, which is the loud failure a bad handover needs.
     */
    fun documentAvailable(): Boolean = DartProfileStore.documentExists()

    fun getProfile(profileId: Long): ProxyEntity? {
        if (profileId <= 0L) return null
        return DartProfileStore.profile(profileId)
    }

    fun getProfiles(profileIds: List<Long>): List<ProxyEntity> {
        if (profileIds.isEmpty()) return listOf()
        return DartProfileStore.profiles(profileIds)
    }

    /** The group's profile ids in list order (Group::Profiles). */
    fun memberIds(groupId: Long): List<Long> = DartProfileStore.memberIds(groupId)

    /** The group's profiles in list order. */
    fun members(groupId: Long): List<ProxyEntity> = DartProfileStore.members(groupId)

    /** The profile the service runs (the desktop's started_id), 0 when stopped. */
    fun runningProfileId(): Long = if (DataStore.serviceState.started) DataStore.currentProfile else 0L

    /**
     * The running config was built from [profileId]: the started profile, or one of the profiles it pulled in (chain
     * hops, the group's landing / front proxy, auto-selector members, route outbounds), RunningUsesProfile.
     */
    fun runningUses(profileId: Long): Boolean {
        val running = runningProfileId()
        if (running <= 0L || profileId <= 0L) return false
        return profileId == running || profileId.toString() in DataStore.runningProfiles
    }

    // ------------------------------------------------------------------------------------------------ add

    /** ProfilesRepo::AddProfile: appended to group [groupId], the current group when it is not a group id (<= 0).
     *  Dart assigns the id and owns the row; the document is the only store. */
    suspend fun addProfile(outbound: Outbound, groupId: Long = -1L): ProxyEntity {
        val gid = if (groupId <= 0) GroupRepo.currentId() else groupId
        val profile = ProxyEntity(groupId = gid).putOutbound(outbound)
        DartProfileWriter.addProfiles(listOf(profile), gid)
        iterator { onAdd(profile) }
        GroupSort.repositionLater(mapOf(gid to listOf(profile.id)), SortInput.MEMBERSHIP)
        return profile
    }

    suspend fun createProfile(groupId: Long, outbound: Outbound): ProxyEntity = addProfile(outbound, groupId)

    /**
     * ProfilesRepo::AddProfileBatch: appended to group [groupId] (the current group when <= 0) in input order.
     * One applyDocument call owns the whole batch (Dart assigns all ids atomically).
     */
    suspend fun addProfileBatch(outbounds: List<Outbound>, groupId: Long = -1L): List<ProxyEntity> {
        if (outbounds.isEmpty()) return emptyList()
        val gid = if (groupId <= 0) GroupRepo.currentId() else groupId
        val entities = outbounds.map { ProxyEntity(groupId = gid).putOutbound(it) }
        val added = DartProfileWriter.addProfiles(entities, gid)
        GroupRepo.postReload(gid)
        GroupSort.repositionLater(mapOf(gid to added.map { it.id }), SortInput.MEMBERSHIP)
        return added
    }

    // ------------------------------------------------------------------------------------------------ update

    suspend fun updateProfile(profile: ProxyEntity) {
        DartProfileWriter.updateProfiles(listOf(profile))
        iterator { onUpdated(profile, false) }
    }

    suspend fun updateProfile(profiles: List<ProxyEntity>) {
        DartProfileWriter.updateProfiles(profiles)
        profiles.forEach {
            iterator { onUpdated(it, false) }
        }
    }

    /**
     * Stores only the profile data (type, name, outbound JSON): test results and traffic written meanwhile stay.
     * Returns whether that data changed. A per-column patch, so other columns are never clobbered.
     */
    suspend fun updateOutbound(profile: ProxyEntity): Boolean {
        val before = getProfile(profile.id)
        val patch = mapOf<String, Any?>(
            "type" to profile.type,
            "name" to profile.name,
            "outbound_json" to profile.outboundJson,
        )
        // The caller already mutated `profile` via putOutbound before this
        // call; only the type/name/json columns need persisting.
        DartProfileWriter.patchProfiles(mapOf(profile.id to patch))
        val changed = before == null || before.type != profile.type || before.name != profile.name ||
            before.outboundJson != profile.outboundJson
        if (changed) {
            GroupSort.repositionLater(mapOf(profile.groupId to listOf(profile.id)), SortInput.CONFIG)
        }
        iterator { onUpdated(profile, false) }
        return changed
    }

    suspend fun updateTraffic(profileId: Long, rx: Long, tx: Long) {
        val patch = mapOf<String, Any?>("traffic_dl" to rx, "traffic_up" to tx)
        DartProfileWriter.patchProfiles(mapOf(profileId to patch))
    }

    /**
     * Bytes moved around the running box's tracker (speed tests, TestRunner::creditTraffic): stored, and handed to the
     * [CreditListener]s so the traffic looper's live totals, which the rows show, include them.
     */
    suspend fun addTraffic(profileId: Long, rx: Long, tx: Long) {
        // Dart applies the delta inside its serialized edit so concurrent
        // credits cannot lose updates.
        DartProfileWriter.addTraffic(mapOf(profileId to Pair(rx, tx)))
        for (listener in creditListeners) listener.onCredited(profileId, rx, tx)
    }

    suspend fun resetTraffic(profileIds: LongArray) {
        if (profileIds.isEmpty()) return
        // A single patch per id; Dart applies them in one atomic edit.
        DartProfileWriter.patchProfiles(profileIds.associate { id ->
            id to mapOf<String, Any?>("traffic_dl" to 0L, "traffic_up" to 0L)
        })
        GroupSort.repositionLater(profileIds.toList(), SortInput.TRAFFIC)
    }

    // ------------------------------------------------------------------------------------------------ delete

    /** Deletes one profile (the list's own delete, no running-profile rule) and closes the gap in its group.
     *  Dart deletes the row and compacts userOrder itself. */
    suspend fun deleteProfile(groupId: Long, profileId: Long) {
        val exists = DartProfileStore.profile(profileId) != null
        if (!exists) return
        DartProfileWriter.deleteProfiles(listOf(profileId))
        if (DataStore.selectedProxy == profileId) {
            DataStore.selectedProxy = 0L
        }
        iterator { onRemoved(groupId, profileId) }
    }

    /**
     * ProfilesRepo::BatchDeleteProfiles through GroupUpdater's deleteProfiles: when the running profile is among
     * [profileIds] the service is stopped if [stopRunning] (allow_stopping_active_profile), otherwise that profile is
     * kept. Each affected group is reloaded once; Dart compacts the remaining positions in the same edit.
     */
    suspend fun batchDeleteProfiles(
        profileIds: List<Long>,
        stopRunning: Boolean = DataStore.allowStoppingActiveProfile,
    ): DeleteOutcome {
        val requested = profileIds.distinct()
        if (requested.isEmpty()) return DeleteOutcome(true, emptyList(), emptyList())
        val toDelete = ArrayList(requested)
        val running = runningProfileId()
        var stopping: ProxyEntity? = null
        if (running > 0 && running in toDelete) {
            if (stopRunning) {
                stopping = getProfile(running)
                SagerNet.stopService()
            } else {
                toDelete.remove(running)
            }
        }
        val groups = HashSet<Long>()
        val deleted = ArrayList<Long>()
        val ok = try {
            // Read the exact existing ids from the document before deleting so
            // the returned outcome (and the route/link cleanup callers) is as
            // precise as the old Room transaction's existingIds().
            val existing = DartProfileStore.profiles(toDelete)
            deleted.addAll(existing.map { it.id })
            groups.addAll(existing.map { it.groupId })
            DartProfileWriter.deleteProfiles(toDelete)
            true
        } catch (e: Exception) {
            Logs.w(e)
            deleted.clear()
            false
        }
        if (DataStore.selectedProxy in deleted) DataStore.selectedProxy = 0L
        for (gid in groups) GroupRepo.postReload(gid)
        val deletedSet = deleted.toHashSet()
        return DeleteOutcome(ok, deleted, requested.filter { it !in deletedSet }, stopping?.takeIf { ok && it.id in deletedSet })
    }

    // ------------------------------------------------------------------------------------------------ order

    /**
     * The group's list becomes [ids] (Group::profiles = ids): positions 0..n-1 in that order; members missing from
     * [ids] follow in their current order, ids of other groups are ignored.
     */
    suspend fun setOrder(groupId: Long, ids: List<Long>) {
        DartProfileWriter.reorderGroup(groupId, ids)
        GroupRepo.postReload(groupId)
    }

    /**
     * Group::EmplaceProfile (the desktop's drag and drop): the row at [from] is inserted after the row at [to], so
     * it lands at [to] when moving down and at [to] + 1 when moving up. False when an index is out of range.
     * A hand-placed row is a manual order, which a kept sort would undo: the group stops sorting.
     */
    suspend fun emplace(groupId: Long, from: Int, to: Int): Boolean {
        GroupSort.setSort(groupId, GroupSortAction())
        val ids = memberIds(groupId).toMutableList()
        if (from !in ids.indices || to !in ids.indices) return false
        ids.add(to + 1, ids[from])
        if (from < to) ids.removeAt(from) else ids.removeAt(from + 1)
        DartProfileWriter.reorderGroup(groupId, ids)
        GroupRepo.postReload(groupId)
        return true
    }

    /** Android extra: moves [profileIds] to the end of group [groupId] in the given order. */
    suspend fun moveToGroup(profileIds: List<Long>, groupId: Long) {
        if (GroupRepo.get(groupId) == null) return
        val sources = HashSet<Long>()
        val moved = ArrayList<Long>()
        var order = memberIds(groupId).size.toLong()
        val patches = HashMap<Long, Map<String, Any?>>()
        for (id in profileIds.distinct()) {
            val profile = DartProfileStore.profile(id) ?: continue
            if (profile.groupId == groupId) continue
            sources.add(profile.groupId)
            patches[id] = mapOf("gid" to groupId, "user_order" to order++)
            moved.add(id)
        }
        DartProfileWriter.patchProfiles(patches)
        for (gid in sources) GroupRepo.postReload(gid)
        GroupRepo.postReload(groupId)
        GroupSort.repositionLater(mapOf(groupId to moved), SortInput.MEMBERSHIP)
    }

    // ------------------------------------------------------------------------------------------------ test results

    /**
     * Persists the test-result columns of [profile] (not its traffic or data), as one per-column patch.
     *
     * [runBlocking] here is deliberate: callers run on IO threads (TestRunner's
     * persist dispatcher / the speed test service) and are synchronous, so the
     * short channel round-trip is bridged; it never blocks the main thread.
     */
    fun saveTestResult(profile: ProxyEntity) {
        val patch = mapOf<String, Any?>(
            "latency" to profile.latency,
            "latency_at" to profile.latencyAt,
            "dl_speed" to profile.dlSpeed,
            "ul_speed" to profile.ulSpeed,
            "test_country" to profile.testCountry,
            "ip_out" to profile.ipOut,
            "test_error" to profile.testError,
        )
        runBlocking(Dispatchers.IO) { DartProfileWriter.patchProfiles(mapOf(profile.id to patch)) }
    }

    /** TestRunner::applyUrlResult; returns the updated profile, null when it no longer exists. */
    fun saveUrlTestResult(profileId: Long, latencyMs: Int, error: String, connectOnly: Boolean = false): ProxyEntity? {
        val profile = getProfile(profileId) ?: return null
        profile.applyUrlResult(latencyMs, error, connectOnly)
        saveTestResult(profile)
        return profile
    }

    /** TestRunner::applyIpResult. */
    fun saveIpTestResult(profileId: Long, ip: String, country: String, error: String): ProxyEntity? {
        val profile = getProfile(profileId) ?: return null
        profile.applyIpResult(ip, country, error)
        saveTestResult(profile)
        return profile
    }

    /** The speed-test result loop of TestRunner.cpp:614-648; [country] is an ISO code. */
    fun saveSpeedTestResult(
        profileId: Long,
        dl: String,
        ul: String,
        latencyMs: Int,
        country: String,
        error: String,
    ): ProxyEntity? {
        val profile = getProfile(profileId) ?: return null
        profile.applySpeedResult(dl, ul, latencyMs, country, error)
        saveTestResult(profile)
        return profile
    }

    // ------------------------------------------------------------------------------------------------ listeners

    // postUpdate: post to listeners, don't change the DB

    suspend fun postUpdate(profileId: Long, noTraffic: Boolean = false) {
        postUpdate(getProfile(profileId) ?: return, noTraffic)
    }

    suspend fun postUpdate(profile: ProxyEntity, noTraffic: Boolean = false) {
        iterator { onUpdated(profile, noTraffic) }
    }

    suspend fun postUpdate(data: List<TrafficData>) {
        if (data.isEmpty()) return
        iterator { onUpdated(data) }
    }

}
