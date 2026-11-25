package io.nekohasekai.sagernet.group

import io.flrone.core.Core
import io.nekohasekai.sagernet.database.GlobalRouteRuleEntity
import io.nekohasekai.sagernet.database.ProfileManager
import io.nekohasekai.sagernet.database.ProxyEntity
import io.nekohasekai.sagernet.database.RouteJsonStore
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.ktx.app
import io.nekohasekai.sagernet.outbound.json.JsonArray
import io.nekohasekai.sagernet.outbound.json.JsonInput
import io.nekohasekai.sagernet.outbound.json.JsonObject
import io.nekohasekai.sagernet.route.RouteRule

/**
 * Android-only (#94): a global rule naming a server by profile id would point at nothing after a
 * subscription refresh replaces a node. It follows the group's member of the same name instead,
 * when exactly one member has it.
 *
 * The single global rule table is the kernel's (`global_route_rules.json`). This rebind reads it
 * through [RouteJsonStore] and writes the rewritten table back through the kernel's
 * `saveGlobalRules` action; Kotlin is never the document's writer. Every column round-trips
 * through [RouteRule] so a rebind cannot drop a rule's conditions.
 */
internal object SubscriptionRouteRebind {

    /** The ids of global rules some node of [members] names, taken before the refresh deletes any of them. */
    fun referencedNames(members: List<ProxyEntity>): Map<Long, String> {
        val referenced = HashSet<Long>()
        for (rule in RouteJsonStore.allGlobalRules().orEmpty()) {
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
     * Re-points the global rules' references to the [removed] ids of group [gid]; [names] is
     * [referencedNames]' result. The running service keeps the old node until reloaded, so the UI
     * is asked for its reload hint when the running config used one.
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

        val rules = RouteJsonStore.allGlobalRules().orEmpty()
        var rebound = 0
        for (rule in rules) {
            val replacement = replacements[rule.outboundId] ?: continue
            rule.outboundId = replacement
            rebound++
        }
        if (rebound == 0) return
        saveGlobalRules(rules)
        Logs.i(app.getString(R.string.subs_routes_rebound, rebound))
        if (replacements.keys.any { ProfileManager.runningUses(it) }) SubscriptionQueue.reloadNeeded(gid)
    }

    /** Persists the rewritten table through the kernel action bus (Go remains the sole writer). */
    private fun saveGlobalRules(entities: List<GlobalRouteRuleEntity>) {
        val rules = JsonArray()
        for (entity in entities) {
            val rule = entity.toModel()
            val row = JsonObject()
            row["id"] = entity.ruleId
            for (field in RouteRule.STRING_FIELDS) row[field.name] = field.get(rule)
            for (field in RouteRule.LIST_FIELDS) {
                row["${field.name}_json"] = JsonArray().also { list -> for (value in field.get(rule)) list.add(value) }
            }
            for (field in RouteRule.BOOL_FIELDS) row[field.name] = field.get(rule)
            row["disabled"] = rule.disabled
            row["invert"] = rule.invert
            row["action"] = rule.action
            row["outbound_id"] = rule.outbound_id
            rules.add(row)
        }
        val request = JsonObject().apply {
            this["id"] = "kotlin:rebindGlobalRules"
            this["method"] = "saveGlobalRules"
            this["data"] = JsonObject().apply { this["rules"] = rules }
        }
        val answer = JsonInput.parseObjectOrNull(Core.runAction(request.toCompact()))
            ?: error("saveGlobalRules answered no result")
        val code = answer.integer("code")
        if (code != 0L) error(answer.string("data").ifEmpty { "saveGlobalRules failed with code $code" })
    }
}
