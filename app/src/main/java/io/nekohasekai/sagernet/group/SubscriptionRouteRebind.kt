package io.nekohasekai.sagernet.group

import io.nekohasekai.sagernet.R
import io.nekohasekai.sagernet.database.ProfileManager
import io.nekohasekai.sagernet.database.ProxyEntity
import io.nekohasekai.sagernet.database.RouteActions
import io.nekohasekai.sagernet.database.RouteJsonStore
import io.nekohasekai.sagernet.database.RouteManager
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.ktx.app

/**
 * Android-only (#94): route rules and default outbounds name a server by profile id, so a refresh that replaces a node
 * (a new identity, "clear servers before updating", a filter) would leave them pointing at nothing. They follow the
 * group's member of the same name instead, when exactly one member has it.
 *
 * ADR 0006 stage C2c2b2: the route documents are the kernel's, so the rewrite reads them through
 * [RouteJsonStore] and saves each touched profile through the action bus ([RouteActions.save]); the
 * Room route DAO this used to pump is gone.
 */
internal object SubscriptionRouteRebind {

    /** The names of the [members] some route profile references, taken before the refresh deletes any of them. */
    fun referencedNames(members: List<ProxyEntity>): Map<Long, String> {
        val profiles = RouteJsonStore.allProfiles().orEmpty()
        val referenced = HashSet<Long>()
        for (profile in profiles) {
            if (profile.defaultOutboundId > 0) referenced.add(profile.defaultOutboundId)
        }
        for (rule in RouteJsonStore.allRules().orEmpty()) {
            if (rule.outboundId > 0) referenced.add(rule.outboundId)
        }
        if (referenced.isEmpty()) return emptyMap()
        val names = HashMap<Long, String>()
        for (profile in members) {
            if (profile.id in referenced) names[profile.id] = profile.displayName()
        }
        return names
    }

    /**
     * Re-points the references to the [removed] ids of group [gid]; [names] is [referencedNames]' result. The running
     * service keeps the old node until reloaded, so the UI is asked for its reload hint when the running config used one.
     */
    fun rebind(gid: Long, removed: Collection<Long>, names: Map<Long, String>) {
        val orphans = removed.filter { !names[it].isNullOrBlank() }
        if (orphans.isEmpty()) return
        val byName = HashMap<String, Long>()
        val ambiguous = HashSet<String>()
        for (profile in ProfileManager.members(gid)) {
            if (profile.type == SubscriptionRefresh.AUTOSELECTOR) continue
            val name = profile.displayName()
            if (byName.put(name, profile.id) != null) ambiguous.add(name)
        }
        val replacements = HashMap<Long, Long>()
        for (old in orphans) {
            val name = names.getValue(old)
            if (name in ambiguous) continue
            replacements[old] = byName[name] ?: continue
        }
        if (replacements.isEmpty()) return

        var rebound = 0
        // Every profile the kernel stores, as a model: the save handler merges the row it is
        // given into the stored one, so a default outbound or a rule's target moves without
        // disturbing the columns this model does not carry. A raw profile cannot be written and
        // is left alone (the old DAO would have edited it; it was never on Android's build path).
        for (route in RouteManager.all()) {
            if (route.is_raw) continue
            var changed = false
            replacements[route.default_outbound_id]?.let {
                route.default_outbound_id = it
                changed = true
                rebound++
            }
            for (rule in route.rules) {
                val replacement = replacements[rule.outbound_id] ?: continue
                rule.outbound_id = replacement
                changed = true
                rebound++
            }
            if (changed) RouteActions.save(route)
        }

        if (rebound > 0) Logs.i(app.getString(R.string.subs_routes_rebound, rebound))
        if (replacements.keys.any { ProfileManager.runningUses(it) }) SubscriptionQueue.reloadNeeded(gid)
    }
}
