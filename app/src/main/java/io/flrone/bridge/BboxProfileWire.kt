package io.flrone.bridge

import io.flrone.model.ProfileInfo

/** Wire shape of a profile card, shared by `ready` and the catalog's `profiles` events. */
object BboxProfileWire {
    fun profiles(profiles: List<ProfileInfo>): List<Map<String, Any?>> = profiles.map { profile ->
        mapOf(
            "id" to profile.id.toInt(),
            "name" to profile.name,
            "type" to profile.type,
            "remote" to (profile.type == "subscription"),
            "url" to profile.url,
            "traffic" to profile.traffic,
            "expiry" to profile.expiry,
            "selected" to profile.selected,
            "updatedAt" to profile.updatedAt,
            "autoUpdate" to profile.autoUpdate,
            "interval" to profile.interval,
            // The single-node container is not a profile card: the grid filters it
            // out and the node page (the other mode) lists its members.
            "single" to profile.single,
        )
    }
}
