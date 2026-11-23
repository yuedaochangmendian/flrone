package io.nekohasekai.sagernet.database

import io.nekohasekai.sagernet.R
import io.nekohasekai.sagernet.SagerNet
import io.nekohasekai.sagernet.database.preference.SettingsStore
import io.nekohasekai.sagernet.ktx.Logs
import io.flrone.bridge.DartProfileStore
import io.flrone.bridge.DartProfileWriter
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The group repository (the desktop's GroupsRepo, GroupsRepo.cpp) over the Dart-owned
 * `profiles.json` document: the `groups` rows in tab order (`display_order`), the current group
 * (`current_group`) and the single-node container.
 *
 * ADR 0005 final stage / ADR 0006 stage C2c2b1: the document is the ONLY store. Reads go through
 * [DartProfileStore] and a missing/corrupt document throws [io.flrone.bridge.ProfilesDocumentUnavailable]
 * instead of silently answering stale Room rows; every write crosses [DartProfileWriter] (Dart owns
 * the file, the ids and the atomic edit). Room's `groups` table is a migration source only and is
 * never touched here.
 *
 * Listeners are in-process; Dart notifies this process through the catalog refresh the writers
 * trigger (and through the listeners below after a local write).
 */
object GroupRepo {

    interface Listener {
        suspend fun groupAdd(group: ProxyGroup)
        suspend fun groupUpdated(group: ProxyGroup)
        suspend fun groupRemoved(groupId: Long)

        /** The group's members changed (added, removed, reordered, sorted, cleared): reload them. */
        suspend fun groupUpdated(groupId: Long)

        /** The tab order changed. */
        suspend fun groupsReordered() {}
    }

    private val listeners = CopyOnWriteArrayList<Listener>()

    /**
     * The settings store [SettingsRegistry.CURRENT_GROUP] lives in. Production leaves this null
     * and reads [DataStore.configurationStore]; a JVM test injects its own [SettingsStore] so
     * this object never triggers `DataStore`'s initialisation (it builds a Room-backed cache
     * store and needs Android).
     */
    @Volatile
    internal var settingsStore: SettingsStore? = null

    private fun store(): SettingsStore = settingsStore ?: DataStore.configurationStore

    fun addListener(listener: Listener) {
        listeners.addIfAbsent(listener)
    }

    fun removeListener(listener: Listener) {
        listeners.remove(listener)
    }

    private suspend fun notify(what: suspend Listener.() -> Unit) {
        for (listener in listeners) listener.what()
    }

    /** The localized Default group name; a JVM test overrides it (there is no Application there). */
    @Volatile
    internal var defaultGroupNameOverride: String? = null

    /** The localized Default group name (the desktop's `group_default_name`). */
    fun defaultGroupName(): String =
        defaultGroupNameOverride ?: SagerNet.application.getString(R.string.group_default_name)

    // ------------------------------------------------------------------------------------------------ reads

    /**
     * The groups as stored, in tab order. A pure read: it never seeds the Default group, because
     * a listing must not create a configuration the user did not ask for (the "hidden empty
     * Default" report). A missing/corrupt document throws, never Room.
     */
    fun rawGroups(): List<ProxyGroup> = DartProfileStore.groups()

    /** Every group in tab order, without creating the Default group of an empty document. */
    fun all(): List<ProxyGroup> = rawGroups()

    /** The group ids in tab order (GetGroupsTabOrder). */
    fun ids(): List<Long> = rawGroups().map { it.id }

    fun get(id: Long): ProxyGroup? = if (id > 0) DartProfileStore.group(id) else null

    /** current_group when it names a group, else the first group, which then becomes current.
     *  An empty document gets the Default group here, on the explicit path that needs a group
     *  to be the current one (never from a pure listing). */
    fun currentId(): Long {
        val stored = SettingsRegistry.CURRENT_GROUP.read(store())
        if (stored > 0 && get(stored) != null) return stored
        val first = rawGroups().firstOrNull() ?: ensureDefault()
        setCurrent(first.id)
        return first.id
    }

    fun current(): ProxyGroup {
        val stored = SettingsRegistry.CURRENT_GROUP.read(store())
        if (stored > 0) get(stored)?.let { return it }
        val first = rawGroups().firstOrNull() ?: ensureDefault()
        setCurrent(first.id)
        return first
    }

    fun setCurrent(id: Long) {
        val store = store()
        if (SettingsRegistry.CURRENT_GROUP.read(store) != id) SettingsRegistry.CURRENT_GROUP.write(store, id)
    }

    /**
     * Configs.cpp:35-39: the "Default" group of an empty catalog.
     *
     * Explicit on purpose: [all]/[ids]/[get] are pure reads and never call this. The current-group
     * resolution calls it because a current group must exist; an import that needs a container
     * calls it; a listing does not. A missing document throws (Dart seeds it once, see
     * `ProfileStore.migrate`), so this can never create a hidden group in a store that does not
     * exist.
     */
    fun ensureDefault(): ProxyGroup {
        val groups = DartProfileStore.groups()
        if (groups.isNotEmpty()) return groups.first()
        val group = ProxyGroup(
            name = defaultGroupName(),
            displayOrder = 1L,
        ).apply { single = true }
        kotlinx.coroutines.runBlocking(kotlinx.coroutines.Dispatchers.IO) {
            DartProfileWriter.addGroups(listOf(group))
        }
        // A write with no Dart engine attached is inert (DartProfileWriter keeps
        // the temporary negative id). Returning it would hand out a "current
        // group" that no document contains — exactly the hidden empty group this
        // method must not create — so surface the missing writer instead.
        check(group.id > 0L) {
            "the profiles.json document is not writable (Dart engine detached): cannot create the Default group"
        }
        return group
    }

    // ------------------------------------------------------------------------------------------------ writes

    /** GroupsRepo::AddGroup: a new id and the last tab (display_order = MAX + 1).
     *  The document is the store; Dart allocates the id and writes it back into [group]. */
    suspend fun add(group: ProxyGroup): ProxyGroup {
        group.id = -1L // negative -> Dart allocates and writes back via the ack
        group.displayOrder = (rawGroups().maxOfOrNull { it.displayOrder } ?: 0L) + 1
        DartProfileWriter.addGroups(listOf(group))
        notify { groupAdd(group) }
        return group
    }

    suspend fun save(group: ProxyGroup) {
        DartProfileWriter.updateGroups(listOf(group))
        notify { groupUpdated(group) }
    }

    /**
     * GroupsRepo::DeleteGroup with the callers' rules: the last group is never deleted (returns false), a running
     * profile of the group is stopped first. Dart cascades the group's member profiles in the same edit.
     */
    suspend fun delete(id: Long): Boolean {
        val ids = rawGroups().map { it.id }
        if (id !in ids || ids.size <= 1) return false
        val remaining = ids - id
        val running = ProfileManager.runningProfileId()
        if (running > 0 && ProfileManager.getProfile(running)?.groupId == id) SagerNet.stopService()
        val name = get(id)?.displayName()
        DartProfileWriter.deleteGroups(listOf(id))
        // GroupService.cpp:160-164: the routing profiles its subscription provided go with it.
        if (RouteManager.deleteOwnedBy(id) > 0) {
            Logs.i("[Groups] $name: deleted the routing profile(s) its subscription provided")
        }
        if (SettingsRegistry.CURRENT_GROUP.read(store()) == id) setCurrent(remaining.first())
        if (DataStore.selectedProxy > 0 && ProfileManager.getProfile(DataStore.selectedProxy) == null) {
            DataStore.selectedProxy = 0L
        }
        notify { groupRemoved(id) }
        return true
    }

    /** SetGroupsTabOrder: [ids] become the tabs 0..n-1; groups missing from [ids] follow in their current order. */
    suspend fun setDisplayOrder(ids: List<Long>) {
        val existing = rawGroups().map { it.id }
        val ordered = ids.distinct().filter { it in existing } + existing.filter { it !in ids }
        DartProfileWriter.reorderGroups(ordered)
        notify { groupsReordered() }
    }

    /** Tells the listeners to reload the members of [groupId]. */
    suspend fun postReload(groupId: Long) {
        notify { groupUpdated(groupId) }
    }

    /** Tells the listeners that [group] changed (name, options...) without writing it. */
    suspend fun postUpdate(group: ProxyGroup) {
        notify { groupUpdated(group) }
    }

    suspend fun postUpdate(groupId: Long) {
        postUpdate(get(groupId) ?: return)
    }
}

/**
 * The group that holds manually imported single nodes — Throne's Default group.
 *
 * The document flag [ProxyGroup.single] is the marker; the default name stays as
 * the fallback for a document written before the flag existed (and for the Room
 * migration source, which has no way to carry it). Callers that find a legacy
 * container should backfill the flag, so the name match is only ever a
 * transition.
 */
fun ProxyGroup.isSingleNodeGroup(): Boolean =
    !isSubscription && (single || name == GroupRepo.defaultGroupName())
