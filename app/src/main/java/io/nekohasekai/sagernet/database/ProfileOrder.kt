package io.nekohasekai.sagernet.database

/** The one profile order shared by the list, the notification, the widgets and the TV controls: user_order. */
object ProfileOrder {

    /** ADR 0005: reads go through ProfileManager so they see the Dart-owned
     * document once it is authoritative; the Room path is the pre-migration
     * fallback. */
    private fun profile(id: Long): ProxyEntity? = ProfileManager.getProfile(id)

    /** The profile [step] places away from [profileId] inside its group, wrapping around; null below two profiles. */
    fun neighbour(profileId: Long, step: Int): ProxyEntity? {
        val gid = profile(profileId)?.groupId ?: return null
        val ids = ProfileManager.memberIds(gid)
        if (ids.size < 2) return null
        val index = ids.indexOf(profileId)
        if (index < 0) return null
        return profile(ids[(index + step).mod(ids.size)])
    }

    /** Whether [profileId] has a neighbour to switch to. */
    fun canCycle(profileId: Long): Boolean {
        val gid = profile(profileId)?.groupId ?: return false
        return ProfileManager.memberIds(gid).size > 1
    }
}
