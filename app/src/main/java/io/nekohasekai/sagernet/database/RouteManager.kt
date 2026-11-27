package io.nekohasekai.sagernet.database

import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.route.RouteProfile
import io.nekohasekai.sagernet.route.RouteRule
import io.nekohasekai.sagernet.route.RuleSetCatalog
import java.io.File

/**
 * A read-only view of the single global route-rule table (`global_route_rules.json`), the
 * one table Go writes and every config build reads (the "unique global rule table" model).
 *
 * There are no route profiles any more. The build always starts from the built-in in-memory
 * [RouteProfile.defaultProfile] and attaches the global rule table to its `rules`, so
 * the Go config builder keeps producing a sing-box `route.rules` / `route.rule_set` / `route.final`
 * without a document, a database or a profile selection. A missing document simply means no
 * global rules (the default profile's own hijack-dns rule still applies).
 *
 * The kernel is the only writer; this object only reads the JSON document (through
 * [RouteJsonStore]) and owns the synchronous in-memory view the config generator needs.
 */
object RouteManager {

    /** The parsed catalog and the source stamp it came from (runtime file's mtime, or the bundled asset). */
    private var catalogCache: Pair<Long, RuleSetCatalog>? = null

    /**
     * The one profile a build uses: the built-in Default in memory, with the global rule table
     * attached. Always available — no document, id or preference is consulted.
     */
    fun current(): RouteProfile = RouteProfile.defaultProfile().also { profile ->
        profile.rules.addAll(globalRulesForBuild())
    }

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

    /** The whole global rule table, in stored order. No per-profile opt-out exists any more. */
    fun globalRulesForBuild(): List<RouteRule> {
        val document = RouteJsonStore.allGlobalRules() ?: return emptyList()
        return document.sortedBy { it.ruleOrder }.map { it.toModel() }.let(::dropStaleOutbounds)
    }

    /**
     * A rule naming an outbound that no longer exists cannot be part of a build.
     *
     * Internal so JVM tests can drive the table rules without Android: this filter is what the build observes.
     */
    internal fun dropStaleOutbounds(rules: List<RouteRule>): List<RouteRule> = rules.filter { rule ->
        if (rule.outbound_id <= 0L) return@filter true
        // A profiles document that is not available cannot vouch for any outbound; a rule that
        // names one would build a config with a missing tag. Drop it rather than throwing into
        // the build path (the UI reports the document problem through its own diagnostics).
        runCatching { ProfileManager.getProfile(rule.outbound_id) != null }.getOrDefault(false)
    }
}
