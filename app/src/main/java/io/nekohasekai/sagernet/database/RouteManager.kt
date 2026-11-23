package io.nekohasekai.sagernet.database

import io.flrone.bridge.DartProfileStore
import io.flrone.bridge.DartProfileWriter
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.route.RouteDns
import io.nekohasekai.sagernet.route.RouteProfile
import io.nekohasekai.sagernet.route.RouteRule
import io.nekohasekai.sagernet.route.RuleSetCatalog
import java.io.File

/**
 * The route profile repository (the desktop's RoutesRepo) as a READ-ONLY view of
 * the kernel's `documents/route_*.json` (ADR 0002 phase 3c; ADR 0006 stage
 * C2c2b2 removed the last Room fallback).
 *
 * Go is the only writer. Android keeps this synchronous view because
 * `ConfigGenerator`, `CoreConfigs` and the group route picker cannot call into
 * Go: they read the same files through [RouteJsonStore]. A missing document set
 * means the kernel has not seeded yet (a fresh install before the routing
 * screen is opened); [all] then answers the built-in Default profile in memory,
 * which is exactly what the kernel's own seed writes — nothing is persisted
 * here, and no database is created.
 *
 * Writes go through the action bus ([RouteActions]); there is deliberately no
 * write method in this object.
 */
object RouteManager {

    /** Every profile in id order; the built-in Default alone while the kernel has not seeded. */
    fun all(): List<RouteProfile> {
        val profiles = RouteJsonStore.allProfiles() ?: return listOf(RouteProfile.defaultProfile())
        val rules = RouteJsonStore.allRules().orEmpty().groupBy { it.routeProfileId }
        return profiles.map { it.toModel(rules[it.id].orEmpty()) }
    }

    fun get(id: Long): RouteProfile? {
        val profile = RouteJsonStore.getProfile(id) ?: return null
        return profile.toModel(RouteJsonStore.rulesOf(id))
    }

    /**
     * GetCustomDns (RoutesRepo.cpp): the profile's ActiveDns without loading its rules; null when it follows the
     * global DNS settings or does not exist.
     */
    fun customDns(id: Long): RouteDns? =
        RouteProfileEntity.dnsFromJson(RouteJsonStore.getProfile(id)?.dnsJson)

    /**
     * The profile named by current_route_id; a missing or raw one falls back to the first profile Android can use
     * (a new Default one when only raw profiles exist) and fixes the setting.
     */
    fun current(): RouteProfile {
        get(DataStore.currentRouteId)?.takeIf { !it.is_raw }?.let { return it }
        val first = usable().firstOrNull() ?: RouteProfile.defaultProfile()
        // A synthetic Default (documents absent) has no stored id: pinning 0 would name nothing.
        if (first.id > 0L) DataStore.currentRouteId = first.id
        return first
    }

    /** Every profile but the desktop's raw ones, which Android keeps read-only and never uses. */
    fun usable(): List<RouteProfile> = all().filterNot { it.is_raw }

    fun isUsable(id: Long): Boolean = id > 0L && RouteJsonStore.isUsable(id)

    /**
     * ResolveRouteId (RunningProfiles.cpp): a group override naming a profile Android can use, else the global one.
     * Raw profiles count as gone, like for [current].
     */
    fun resolveRouteId(groupRouteId: Long): Long =
        if (isUsable(groupRouteId)) groupRouteId else globalRouteId()

    /** RouteIdFor: the routing profile a profile of group [gid] is built with. */
    fun routeIdFor(gid: Long): Long = resolveRouteId(groupRouteId(gid))

    /** The profile [routeIdFor] names. */
    fun routeFor(gid: Long): RouteProfile =
        groupRouteId(gid).takeIf { it > 0L }?.let { get(it) }?.takeIf { !it.is_raw } ?: current()

    /** RunningRouteId: the routing profile the running config was built with; 0 when stopped or for a custom full config. */
    fun runningRouteId(): Long = if (DataStore.serviceState.started) DataStore.runningRouteId else 0L

    /**
     * ActiveRouteId: the routing profile in effect, the running config's else the global one. For "which route
     * applies"; the user's global choice stays current_route_id.
     */
    fun activeRouteId(): Long = runningRouteId().takeIf { it > 0L } ?: DataStore.currentRouteId

    /**
     * ConnectionModes.cpp:220-226: the group of the running profile when its own routing profile is the one running,
     * so switching the global profile leaves the running config as it is; null otherwise.
     */
    fun groupKeepingRunningRoute(): ProxyGroup? {
        val running = runningRouteId().takeIf { it > 0L } ?: return null
        val profileId = ProfileManager.runningProfileId().takeIf { it > 0L } ?: return null
        val gid = ProfileManager.getProfile(profileId)?.groupId ?: return null
        val group = GroupRepo.get(gid) ?: return null
        return group.takeIf { it.routeId == running && isUsable(running) }
    }

    /** RoutesRepo::OwnedBy: the profiles the subscription of group [gid] keeps updated, in id order. */
    fun ownedBy(gid: Long): List<Long> =
        if (gid > 0L) {
            RouteJsonStore.allProfiles().orEmpty()
                .filter { it.sourceGid == gid }
                .map { it.id }
                .sorted()
        } else {
            emptyList()
        }

    /**
     * GroupService.cpp:160-164: deletes the profiles group [gid] owns, current_route_id moving off them; the number
     * deleted. Unlike a user delete it may take the last profile, [current] then answers the built-in Default.
     *
     * The delete crosses the action bus (the kernel is the document's writer); groups routed by a deleted profile
     * follow the global one again, and the groups that owned one stop importing it.
     */
    fun deleteOwnedBy(gid: Long): Int {
        val ids = ownedBy(gid)
        if (ids.isEmpty()) return 0
        for (id in ids) RouteActions.delete(id)
        forgetDeleted(ids.toSet(), emptySet())
        if (DataStore.currentRouteId in ids) current()
        return ids.size
    }

    private fun groupRouteId(gid: Long): Long =
        (if (gid > 0L) GroupRepo.get(gid)?.routeId else null) ?: -1L

    private fun globalRouteId(): Long = DataStore.currentRouteId.takeIf { isUsable(it) } ?: current().id

    /**
     * RoutesRepo::forgetDeleted: groups routed by a deleted profile follow the global one again, and the groups that
     * owned one stop importing it. Groups are Dart's document, so the patch goes through [DartProfileWriter].
     */
    private fun forgetDeleted(deleted: Set<Long>, owners: Collection<Long>) {
        val groups = DartProfileStore.groups()
        val patches = HashMap<Long, Map<String, Any?>>()
        for (group in groups) {
            if (group.routeId in deleted) {
                patches[group.id] = mapOf("route_id" to -1L)
                Logs.i("[Groups] ${group.displayName()}: routing profile reset to Default (its profile was deleted)")
            }
            if (group.id in owners && group.importSubRoute) {
                patches[group.id] = (patches[group.id] ?: emptyMap()) + ("import_sub_route" to false)
                Logs.i("[Groups] ${group.displayName()}: stopped importing the subscription's routing profile (it was deleted)")
            }
        }
        if (patches.isEmpty()) return
        kotlinx.coroutines.runBlocking(kotlinx.coroutines.Dispatchers.IO) {
            DartProfileWriter.patchGroups(patches)
        }
    }

    /** The name of a server profile as shares carry it (the desktop's DisplayName). */
    fun profileName(id: Long): String? = ProfileManager.getProfile(id)?.displayName()

    /**
     * A share-import resolver for rule outbound names: the first profile whose name matches exactly
     * (ProfilesRepo::GetProfileByName), then one whose display name does, each by lowest id. The stored name is the
     * outbound's, so only the profiles without one are parsed, plus the rare rows a stored name cannot speak for; each
     * name is looked up once. The rows are Dart's `profiles.json` (ADR 0006 stage C2c2b1).
     */
    fun profileIdResolver(): (String) -> Long? {
        val allProfiles by lazy { DartProfileStore.profiles() }
        val unnamed by lazy { allProfiles.filter { it.name.isNullOrEmpty() } }
        // A row whose type or data does not parse has no outbound name and shows its type, whatever name it stores.
        val rows by lazy { allProfiles }
        fun byId(id: Long): ProxyEntity? = allProfiles.firstOrNull { it.id == id }
        fun firstOf(ids: List<Long>, match: (ProxyEntity) -> Boolean): Long? =
            ids.mapNotNull(::byId).filter(match).minOfOrNull { it.id }

        fun resolve(name: String): Long? {
            val named = allProfiles.firstOrNull { it.name == name && it.outbound.name == name }?.id
            listOfNotNull(named, unnamed.firstOrNull { it.outbound.name == name }?.id).minOrNull()?.let { return it }
            val shownType = rows.filter { !it.name.isNullOrEmpty() && it.type == name }.map { it.id }
            return listOfNotNull(
                unnamed.firstOrNull { it.displayName() == name }?.id,
                firstOf(shownType) { it.displayName() == name },
            ).minOrNull()
        }

        val resolved = HashMap<String, Long?>()
        return { name ->
            when {
                name.isBlank() -> null
                name in resolved -> resolved[name]
                else -> resolve(name).also { resolved[name] = it }
            }
        }
    }

    @Volatile
    private var catalogCache: Pair<Long, RuleSetCatalog>? = null

    /** The rule-set list: the runtime copy of srslist.h, else the bundled asset, else empty; cached per source. */
    fun catalog(): RuleSetCatalog {
        val file = RouteRepo.srsListFile()
        val stamp = if (file.isFile) file.lastModified() else ASSET_STAMP
        catalogCache?.let { if (it.first == stamp) return it.second }
        var catalog = if (stamp != ASSET_STAMP) readCatalog(file) else null
        if (catalog == null || catalog.size == 0) {
            catalog = RouteRepo.readAsset(RouteRepo.SRS_LIST)?.let { RuleSetCatalog.parseSrsList(it) }
                ?: RuleSetCatalog(emptyList())
        }
        catalogCache = stamp to catalog
        return catalog
    }

    fun invalidateCatalog() {
        catalogCache = null
    }

    private const val ASSET_STAMP = -1L

    private fun readCatalog(file: File): RuleSetCatalog? = try {
        RuleSetCatalog.parseSrsList(file.readText())
    } catch (e: Exception) {
        Logs.w("read ${file.name}", e)
        null
    }

    /**
     * The build's global rules: every pool rule the kernel stores (`global_route_rules` in the document) except the
     * ones [profileId] disables, in pool order. An empty pool — no document yet — answers no rules.
     *
     * The kernel owns the pool, so the document is the only source; reading a database snapshot here was a live bug
     * once (nothing wrote it after the seed, so every edit made in the UI was invisible to the build).
     */
    fun globalRulesForBuild(profileId: Long): List<RouteRule> {
        val document = RouteJsonStore.allGlobalRules() ?: return emptyList()
        // A pool rule is identified by its `rule_id`, and the profile's disable list names
        // those ids. Both come from the kernel, so they agree with each other.
        val disabled = RouteProfileEntity.parseIdJson(
            RouteJsonStore.getProfile(profileId)?.disabledGlobalRuleJson.orEmpty()
        ).toSet()
        val kept = document.sortedBy { it.ruleOrder }
            .filterNot { it.ruleId in disabled }
            .map { it.toModel() }
        return dropStaleOutbounds(kept)
    }

    /**
     * A rule naming an outbound that no longer exists cannot be part of a build.
     *
     * Internal so the JVM tests can drive the pool rules without Android: this filter is what the build observes.
     */
    internal fun dropStaleOutbounds(rules: List<RouteRule>): List<RouteRule> =
        rules.filter { it.outbound_id <= 0L || ProfileManager.getProfile(it.outbound_id) != null }
}
