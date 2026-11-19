package io.nekohasekai.sagernet.database

import android.database.sqlite.SQLiteCantOpenDatabaseException
import io.nekohasekai.sagernet.SagerNet
import io.nekohasekai.sagernet.aidl.TrafficData
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.outbound.Outbound
import io.flrone.bridge.DartProfileStore
import io.flrone.bridge.DartProfileWriter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import java.io.IOException
import java.sql.SQLException
import java.util.concurrent.Callable
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The profile repository (the desktop's ProfilesRepo plus the list edits of Group.cpp) over `profiles`. A group's
 * members are its rows ordered by `user_order`, kept dense (0..n-1 = the desktop's `profiles_json` index).
 * Writes that change what a kept group sort reads queue a [GroupSort] re-sort, as ProfilesRepo.cpp does.
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

    /** SQLite's bound-parameter limit is 999; id lists are split below it. */
    internal const val CHUNK = 500

    private val listeners = ArrayList<Listener>()
    private val creditListeners = CopyOnWriteArrayList<CreditListener>()

    private val dao get() = SagerDatabase.proxyDao

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

    // ADR 0005 final stage: the Dart document is the sole authority. The ONLY
    // time Room is read is before the one-time migration produced the file at
    // all (documentExists == false). A file that exists but is corrupt must NOT
    // fall back to Room: DartProfileStore then throws
    // ProfilesDocumentUnavailable, so a failed/corrupt handover is loud and the
    // user can trigger the explicit re-migrate recovery path.
    fun documentAvailable(): Boolean = DartProfileStore.documentExists()

    private fun documentReady(): Boolean = documentAvailable()

    fun getProfile(profileId: Long): ProxyEntity? {
        if (profileId <= 0L) return null
        if (documentReady()) return DartProfileStore.profile(profileId)
        return try {
            dao.getById(profileId)
        } catch (ex: SQLiteCantOpenDatabaseException) {
            throw IOException(ex)
        } catch (ex: SQLException) {
            Logs.w(ex)
            null
        }
    }

    fun getProfiles(profileIds: List<Long>): List<ProxyEntity> {
        if (profileIds.isEmpty()) return listOf()
        if (documentReady()) return DartProfileStore.profiles(profileIds)
        return try {
            profileIds.chunked(CHUNK).flatMap { dao.getEntities(it) }
        } catch (ex: SQLiteCantOpenDatabaseException) {
            throw IOException(ex)
        } catch (ex: SQLException) {
            Logs.w(ex)
            listOf()
        }
    }

    /** The group's profile ids in list order (Group::Profiles). */
    fun memberIds(groupId: Long): List<Long> =
        if (documentReady()) DartProfileStore.memberIds(groupId) else dao.getIdsByGroup(groupId)

    /** The group's profiles in list order. */
    fun members(groupId: Long): List<ProxyEntity> =
        if (documentReady()) DartProfileStore.members(groupId) else dao.getByGroup(groupId)

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
     *  ADR 0005: Dart assigns the id and owns the row; Room is no longer written. */
    suspend fun addProfile(outbound: Outbound, groupId: Long = -1L): ProxyEntity {
        val gid = if (groupId <= 0) GroupRepo.currentId() else groupId
        val profile = ProxyEntity(groupId = gid).putOutbound(outbound)
        if (documentReady()) {
            DartProfileWriter.addProfiles(listOf(profile), gid)
        } else {
            // Pre-migration (JVM tests / a document not yet produced): keep the
            // old Room path so the host can still seed the migration source.
            SagerDatabase.instance.runInTransaction {
                profile.userOrder = dao.nextOrder(gid)
                profile.id = dao.addProxy(profile)
            }
        }
        iterator { onAdd(profile) }
        GroupSort.repositionLater(mapOf(gid to listOf(profile.id)), SortInput.MEMBERSHIP)
        return profile
    }

    suspend fun createProfile(groupId: Long, outbound: Outbound): ProxyEntity = addProfile(outbound, groupId)

    /**
     * ProfilesRepo::AddProfileBatch: appended to group [groupId] (the current group when <= 0) in input order.
     * ADR 0005: one applyDocument call owns the whole batch (Dart assigns all ids
     * atomically); the pre-migration Room path stays for the migration source.
     */
    suspend fun addProfileBatch(outbounds: List<Outbound>, groupId: Long = -1L): List<ProxyEntity> {
        if (outbounds.isEmpty()) return emptyList()
        val gid = if (groupId <= 0) GroupRepo.currentId() else groupId
        val added: List<ProxyEntity>
        if (documentReady()) {
            val entities = outbounds.map { ProxyEntity(groupId = gid).putOutbound(it) }
            added = DartProfileWriter.addProfiles(entities, gid)
        } else {
            added = ArrayList(outbounds.size)
            for (chunk in outbounds.chunked(CHUNK)) {
                val rows = SagerDatabase.instance.runInTransaction(Callable {
                    var order = dao.nextOrder(gid)
                    val rows = chunk.map { ProxyEntity(groupId = gid, userOrder = order++).putOutbound(it) }
                    dao.insert(rows).forEachIndexed { index, id -> rows[index].id = id }
                    rows
                })
                added.addAll(rows)
            }
        }
        GroupRepo.postReload(gid)
        GroupSort.repositionLater(mapOf(gid to added.map { it.id }), SortInput.MEMBERSHIP)
        return added
    }

    // ------------------------------------------------------------------------------------------------ update

    suspend fun updateProfile(profile: ProxyEntity) {
        if (documentReady()) DartProfileWriter.updateProfiles(listOf(profile)) else dao.updateProxy(profile)
        iterator { onUpdated(profile, false) }
    }

    suspend fun updateProfile(profiles: List<ProxyEntity>) {
        if (documentReady()) DartProfileWriter.updateProfiles(profiles) else dao.updateProxy(profiles)
        profiles.forEach {
            iterator { onUpdated(it, false) }
        }
    }

    /**
     * Stores only the profile data (type, name, outbound JSON): test results and traffic written meanwhile stay.
     * Returns whether that data changed. ADR 0005: with the document live this
     * is a per-column patch so other columns are never clobbered.
     */
    suspend fun updateOutbound(profile: ProxyEntity): Boolean {
        val before = if (documentReady()) getProfile(profile.id) else dao.getById(profile.id)
        val patch = mapOf<String, Any?>(
            "type" to profile.type,
            "name" to profile.name,
            "outbound_json" to profile.outboundJson,
        )
        if (documentReady()) {
            // The caller already mutated `profile` via putOutbound before this
            // call; only the type/name/json columns need persisting.
            DartProfileWriter.patchProfiles(mapOf(profile.id to patch))
        } else {
            dao.updateOutbound(profile.id, profile.type, profile.name, profile.outboundJson)
        }
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
        if (documentReady()) DartProfileWriter.patchProfiles(mapOf(profileId to patch))
        else dao.updateTraffic(profileId, rx, tx)
    }

    /**
     * Bytes moved around the running box's tracker (speed tests, TestRunner::creditTraffic): stored, and handed to the
     * [CreditListener]s so the traffic looper's live totals, which the rows show, include them.
     */
    suspend fun addTraffic(profileId: Long, rx: Long, tx: Long) {
        // The document is the authority; a Room addTraffic would increment the
        // stale table and be invisible to the catalog. Dart applies the delta
        // inside its serialized edit so concurrent credits cannot lose updates.
        if (documentReady()) {
            DartProfileWriter.addTraffic(mapOf(profileId to Pair(rx, tx)))
        } else {
            dao.addTraffic(profileId, rx, tx)
        }
        for (listener in creditListeners) listener.onCredited(profileId, rx, tx)
    }

    suspend fun resetTraffic(profileIds: LongArray) {
        if (profileIds.isEmpty()) return
        if (documentReady()) {
            // A single patch per id; Dart applies them in one atomic edit.
            DartProfileWriter.patchProfiles(profileIds.associate { id ->
                id to mapOf<String, Any?>("traffic_dl" to 0L, "traffic_up" to 0L)
            })
        } else {
            SagerDatabase.instance.runInTransaction {
                profileIds.toList().chunked(CHUNK).forEach { dao.resetTraffic(it.toLongArray()) }
            }
        }
        GroupSort.repositionLater(profileIds.toList(), SortInput.TRAFFIC)
    }

    // ------------------------------------------------------------------------------------------------ delete

    /** Deletes one profile (the list's own delete, no running-profile rule) and closes the gap in its group.
     *  ADR 0005: Dart deletes the row and compacts userOrder itself. */
    suspend fun deleteProfile(groupId: Long, profileId: Long) {
        val deleted = if (documentReady()) {
            val exists = DartProfileStore.profile(profileId) != null
            if (exists) DartProfileWriter.deleteProfiles(listOf(profileId))
            exists
        } else {
            SagerDatabase.instance.runInTransaction(Callable {
                // In a group numbered 0..n-1, shifting the rows behind the gap is the same as renumbering them all.
                val order = dao.orderInGroup(profileId, groupId)?.takeIf { dao.isDense(groupId) }
                if (dao.deleteById(profileId) == 0) return@Callable false
                if (order != null) dao.closeGap(groupId, order) else compactLocked(groupId)
                true
            })
        }
        if (!deleted) return
        if (DataStore.selectedProxy == profileId) {
            DataStore.selectedProxy = 0L
        }
        iterator { onRemoved(groupId, profileId) }
    }

    /**
     * ProfilesRepo::BatchDeleteProfiles through GroupUpdater's deleteProfiles: when the running profile is among
     * [profileIds] the service is stopped if [stopRunning] (allow_stopping_active_profile), otherwise that profile is
     * kept. Each affected group is compacted and reloaded once.
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
            if (documentReady()) {
                // Read the exact existing ids from the document before deleting so
                // the returned outcome (and the route/link cleanup callers) is
                // as precise as the old Room transaction's existingIds().
                val existing = DartProfileStore.profiles(toDelete)
                deleted.addAll(existing.map { it.id })
                groups.addAll(existing.map { it.groupId })
                DartProfileWriter.deleteProfiles(toDelete)
            } else {
                SagerDatabase.instance.runInTransaction {
                    for (chunk in toDelete.chunked(CHUNK)) {
                        groups.addAll(dao.groupsOf(chunk))
                        val existing = dao.existingIds(chunk)
                        dao.deleteByIds(chunk)
                        deleted.addAll(existing)
                    }
                    groups.forEach(::compactLocked)
                }
            }
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
        if (documentReady()) {
            DartProfileWriter.reorderGroup(groupId, ids)
        } else {
            SagerDatabase.instance.runInTransaction {
                val current = dao.getPositionsByGroup(groupId)
                val members = current.mapTo(HashSet(current.size * 2)) { it.id }
                val wanted = ids.distinct().filter { it in members }
                val wantedSet = wanted.toHashSet()
                writeOrder(current, wanted + current.mapNotNull { row -> row.id.takeIf { it !in wantedSet } })
            }
        }
        GroupRepo.postReload(groupId)
    }

    /**
     * Group::EmplaceProfile (the desktop's drag and drop): the row at [from] is inserted after the row at [to], so
     * it lands at [to] when moving down and at [to] + 1 when moving up. False when an index is out of range.
     * A hand-placed row is a manual order, which a kept sort would undo: the group stops sorting.
     */
    suspend fun emplace(groupId: Long, from: Int, to: Int): Boolean {
        GroupSort.setSort(groupId, GroupSortAction())
        if (documentReady()) {
            val ids = memberIds(groupId).toMutableList()
            if (from !in ids.indices || to !in ids.indices) return false
            ids.add(to + 1, ids[from])
            if (from < to) ids.removeAt(from) else ids.removeAt(from + 1)
            DartProfileWriter.reorderGroup(groupId, ids)
        } else {
            val moved = SagerDatabase.instance.runInTransaction(Callable {
                val current = dao.getPositionsByGroup(groupId)
                val ids = current.mapTo(ArrayList(current.size)) { it.id }
                if (from !in ids.indices || to !in ids.indices) return@Callable false
                ids.add(to + 1, ids[from])
                if (from < to) ids.removeAt(from) else ids.removeAt(from + 1)
                writeOrder(current, ids)
                true
            })
            if (!moved) return false
        }
        GroupRepo.postReload(groupId)
        return true
    }

    /** Android extra: moves [profileIds] to the end of group [groupId] in the given order. */
    suspend fun moveToGroup(profileIds: List<Long>, groupId: Long) {
        if (GroupRepo.get(groupId) == null) return
        val sources = HashSet<Long>()
        val moved = ArrayList<Long>()
        if (documentReady()) {
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
        } else {
            SagerDatabase.instance.runInTransaction {
                var order = dao.nextOrder(groupId)
                for (chunk in profileIds.distinct().chunked(CHUNK)) {
                    val movable = dao.idsOutsideGroup(chunk, groupId).toHashSet()
                    if (movable.isEmpty()) continue
                    sources.addAll(dao.groupsOf(movable.toList()))
                    for (id in chunk) {
                        if (id !in movable) continue
                        dao.setGroup(id, groupId, order++)
                        moved.add(id)
                    }
                }
                sources.forEach(::compactLocked)
            }
        }
        for (gid in sources) GroupRepo.postReload(gid)
        GroupRepo.postReload(groupId)
        GroupSort.repositionLater(mapOf(groupId to moved), SortInput.MEMBERSHIP)
    }

    /** Renumbers the group's members 0..n-1 in their current order. */
    private fun compactLocked(groupId: Long) {
        dao.getPositionsByGroup(groupId).forEachIndexed { index, row ->
            if (row.userOrder != index.toLong()) dao.setUserOrder(row.id, index.toLong())
        }
    }

    /**
     * Inside the transaction that read [current] (the group's getPositionsByGroup): [ids], members of that group, get
     * positions 0..n-1 in that order. Only the rows whose stored position differs are written.
     */
    internal fun writeOrder(current: List<ProfilePosition>, ids: List<Long>) {
        val stored = HashMap<Long, Long>(current.size * 2)
        for (row in current) stored[row.id] = row.userOrder
        ids.forEachIndexed { index, id ->
            if (stored[id] != index.toLong()) dao.setUserOrder(id, index.toLong())
        }
    }

    // ------------------------------------------------------------------------------------------------ test results

    /**
     * Persists the test-result columns of [profile] (not its traffic or data).
     * ADR 0005: with the document live, a per-column patch is sent to Dart.
     * Callers run on IO threads (TestRunner's persist dispatcher / the speed
     * test service), so the short channel round-trip is wrapped in runBlocking
     * on Dispatchers.IO and never blocks the main thread.
     */
    fun saveTestResult(profile: ProxyEntity) {
        if (documentReady()) {
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
        } else {
            dao.updateTestResult(
                profile.id, profile.latency, profile.latencyAt, profile.dlSpeed, profile.ulSpeed,
                profile.testCountry, profile.ipOut, profile.testError,
            )
        }
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

    fun clearTestResults(profileIds: List<Long>) {
        if (profileIds.isEmpty()) return
        if (documentReady()) {
            val clears = profileIds.associateWith { _ ->
                mapOf<String, Any?>(
                    "latency" to 0, "latency_at" to 0L,
                    "dl_speed" to null, "ul_speed" to null,
                    "test_country" to null, "ip_out" to null, "test_error" to null,
                )
            }
            runBlocking(Dispatchers.IO) { DartProfileWriter.patchProfiles(clears) }
        } else {
            SagerDatabase.instance.runInTransaction { profileIds.chunked(CHUNK).forEach { dao.clearTestResults(it) } }
        }
        GroupSort.repositionLater(profileIds, SortInput.TEST_RESULT)
    }

    fun clearGroupTestResults(groupId: Long) {
        if (documentReady()) {
            val ids = memberIds(groupId)
            clearTestResults(ids)
        } else {
            dao.clearGroupTestResults(groupId)
        }
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
