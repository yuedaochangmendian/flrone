package io.nekohasekai.sagernet.database

/** Single-field writes of the profiles screen (scroll position, sort sub-criteria, shown test items). */
internal object GroupFields {

    /**
     * Applies [change] to a fresh copy of group [groupId] and writes it only
     * when something changed. The group is Dart's document (ADR 0006 stage
     * C2c2b2: no Room branch remains), so the write goes through
     * [io.flrone.bridge.DartProfileWriter]. Returns the stored group, null when
     * it is gone.
     */
    fun update(groupId: Long, change: (ProxyGroup) -> Unit): ProxyGroup? {
        val group = GroupRepo.get(groupId) ?: return null
        val before = group.copy()
        change(group)
        if (group == before) return group
        kotlinx.coroutines.runBlocking(kotlinx.coroutines.Dispatchers.IO) {
            io.flrone.bridge.DartProfileWriter.updateGroups(listOf(group))
        }
        return group
    }
}
