package io.nekohasekai.sagernet.database

import io.nekohasekai.sagernet.SagerNet
import io.nekohasekai.sagernet.ktx.Logs
import io.flrone.bridge.DartProfileStore
import io.flrone.bridge.DartProfileWriter
import java.util.concurrent.Callable
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The group repository (the desktop's GroupsRepo, GroupsRepo.cpp): the `groups` table in tab order
 * (`display_order`), the current group (`current_group`) and the Default group of an empty table.
 * Listeners are in-process; writes of the other process arrive through Room's multi-instance invalidation.
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

    private val dao get() = SagerDatabase.groupDao

    /** ADR 0005: the Dart document is the sole authority once the file exists;
     *  a present-but-corrupt document must throw, not fall back to Room. */
    private fun documentReady(): Boolean = DartProfileStore.documentExists()

    fun addListener(listener: Listener) {
        listeners.addIfAbsent(listener)
    }

    fun removeListener(listener: Listener) {
        listeners.remove(listener)
    }

    private suspend fun notify(what: suspend Listener.() -> Unit) {
        for (listener in listeners) listener.what()
    }

    // ------------------------------------------------------------------------------------------------ reads

    /** Every group in tab order; an empty table first gets the Default group. */
    /** The groups as stored, without creating the Default group of an empty table. */
    fun rawGroups(): List<ProxyGroup> =
        if (documentReady()) DartProfileStore.groups() else dao.allGroups()

    fun all(): List<ProxyGroup> {
        val groups = rawGroups()
        if (groups.isNotEmpty()) return groups
        ensureDefault()
        return rawGroups()
    }

    /** The group ids in tab order (GetGroupsTabOrder). */
    fun ids(): List<Long> = all().map { it.id }

    fun get(id: Long): ProxyGroup? =
        if (id > 0) (if (documentReady()) DartProfileStore.group(id) else dao.getById(id)) else null

    /** current_group when it names a group, else the first group, which then becomes current. */
    fun currentId(): Long {
        val stored = SettingsRegistry.CURRENT_GROUP.read(DataStore.configurationStore)
        if (stored > 0 && get(stored) != null) return stored
        val first = ids().first()
        setCurrent(first)
        return first
    }

    fun current(): ProxyGroup {
        val stored = SettingsRegistry.CURRENT_GROUP.read(DataStore.configurationStore)
        if (stored > 0) get(stored)?.let { return it }
        val first = all().first()
        setCurrent(first.id)
        return first
    }

    fun setCurrent(id: Long) {
        val store = DataStore.configurationStore
        if (SettingsRegistry.CURRENT_GROUP.read(store) != id) SettingsRegistry.CURRENT_GROUP.write(store, id)
    }

    /** Configs.cpp:35-39: the "Default" group of an empty catalog. ADR 0005:
     *  with the document live this writes Dart, not Room. */
    fun ensureDefault() {
        if (documentReady()) {
            if (DartProfileStore.groups().isNotEmpty()) return
            kotlinx.coroutines.runBlocking(kotlinx.coroutines.Dispatchers.IO) {
                DartProfileWriter.addGroups(listOf(ProxyGroup(
                    name = SagerDatabase.defaultGroupName(),
                    displayOrder = 1L,
                )))
            }
        } else {
            dao.insertDefaultIfEmpty(SagerDatabase.defaultGroupName())
        }
    }

    // ------------------------------------------------------------------------------------------------ writes

    /** GroupsRepo::AddGroup: a new id and the last tab (display_order = MAX + 1).
     *  ADR 0005: Dart allocates the id; Room is untouched once the doc is live. */
    suspend fun add(group: ProxyGroup): ProxyGroup {
        if (documentReady()) {
            group.id = -1L // negative -> Dart allocates and writes back via allocatedIds
            group.displayOrder = (rawGroups().maxOfOrNull { it.displayOrder } ?: 0L) + 1
            DartProfileWriter.addGroups(listOf(group))
        } else {
            SagerDatabase.instance.runInTransaction {
                group.id = 0L
                group.displayOrder = dao.nextDisplayOrder()
                group.id = dao.insert(group)
            }
        }
        notify { groupAdd(group) }
        return group
    }

    suspend fun save(group: ProxyGroup) {
        if (documentReady()) DartProfileWriter.updateGroups(listOf(group)) else dao.update(group)
        notify { groupUpdated(group) }
    }

    /**
     * GroupsRepo::DeleteGroup with the callers' rules: the last group is never deleted (returns false), a running
     * profile of the group is stopped first. The members go by the foreign key cascade.
     */
    suspend fun delete(id: Long): Boolean {
        val ids = if (documentReady()) DartProfileStore.groups().map { it.id } else dao.allIds()
        if (id !in ids || ids.size <= 1) return false
        val remaining = ids - id
        val running = ProfileManager.runningProfileId()
        if (running > 0 && ProfileManager.getProfile(running)?.groupId == id) SagerNet.stopService()
        val name = get(id)?.displayName()
        if (documentReady()) {
            // Dart cascades the group's member profiles in the same edit.
            DartProfileWriter.deleteGroups(listOf(id))
        } else {
            dao.deleteById(id)
        }
        // GroupService.cpp:160-164: the routing profiles its subscription provided go with it.
        if (RouteManager.deleteOwnedBy(id) > 0) {
            Logs.i("[Groups] $name: deleted the routing profile(s) its subscription provided")
        }
        if (SettingsRegistry.CURRENT_GROUP.read(DataStore.configurationStore) == id) setCurrent(remaining.first())
        if (DataStore.selectedProxy > 0 && ProfileManager.getProfile(DataStore.selectedProxy) == null) {
            DataStore.selectedProxy = 0L
        }
        notify { groupRemoved(id) }
        return true
    }

    /** SetGroupsTabOrder: [ids] become the tabs 0..n-1; groups missing from [ids] follow in their current order. */
    suspend fun setDisplayOrder(ids: List<Long>) {
        if (documentReady()) {
            val existing = DartProfileStore.groups().map { it.id }
            val ordered = ids.distinct().filter { it in existing } + existing.filter { it !in ids }
            DartProfileWriter.reorderGroups(ordered)
        } else {
            SagerDatabase.instance.runInTransaction {
                val existing = dao.allIds()
                val ordered = ids.distinct().filter { it in existing } + existing.filter { it !in ids }
                ordered.forEachIndexed { index, groupId -> dao.setDisplayOrder(groupId, index.toLong()) }
            }
        }
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
