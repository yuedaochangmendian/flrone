package io.nekohasekai.sagernet.database

import io.nekohasekai.sagernet.database.ProxyGroup
import io.nekohasekai.sagernet.database.SagerDatabase
import java.util.concurrent.Callable

/** Single-field writes of the profiles screen (scroll position, sort sub-criteria, shown test items). */
internal object GroupFields {

    /**
     * Applies [change] to a fresh copy of group [groupId] and writes it only
     * when something changed. ADR 0005: the Dart document is the authority once
     * migrated, so the write goes there; the Room path remains for the
     * pre-migration source. Returns the stored group, null when it is gone.
     */
    fun update(groupId: Long, change: (ProxyGroup) -> Unit): ProxyGroup? {
        val group = (if (ProfileManager.documentAvailable()) GroupRepo.get(groupId)
        else SagerDatabase.instance.runInTransaction(Callable { SagerDatabase.groupDao.getById(groupId) }))
            ?: return null
        val before = group.copy()
        change(group)
        if (group == before) return group
        if (ProfileManager.documentAvailable()) {
            kotlinx.coroutines.runBlocking(kotlinx.coroutines.Dispatchers.IO) {
                io.flrone.bridge.DartProfileWriter.updateGroups(listOf(group))
            }
        } else {
            SagerDatabase.instance.runInTransaction { SagerDatabase.groupDao.update(group) }
        }
        return group
    }
}
