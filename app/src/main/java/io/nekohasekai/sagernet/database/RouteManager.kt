package io.nekohasekai.sagernet.database

import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.route.RuleSetCatalog
import java.io.File

/**
 * The rule-set catalog the profile/rule editors validate against: the runtime copy of
 * `srslist.h`, else the bundled asset, else empty. The global rule table itself is read by
 * the Go config builder; Kotlin only keeps this catalog for editor validation.
 */
object RouteManager {

    /** The parsed catalog and the source stamp it came from (runtime file's mtime, or the bundled asset). */
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
}
