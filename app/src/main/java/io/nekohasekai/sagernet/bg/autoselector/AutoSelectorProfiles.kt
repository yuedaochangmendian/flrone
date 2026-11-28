package io.nekohasekai.sagernet.bg.autoselector

import io.flrone.bridge.DartProfileWriter
import io.nekohasekai.sagernet.database.ProfileManager
import io.nekohasekai.sagernet.document.json.JsonArray
import io.nekohasekai.sagernet.document.json.JsonInput
import io.nekohasekai.sagernet.document.json.JsonObject
import io.nekohasekai.sagernet.document.json.JsonValues
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex

/** Auto-selector profiles in storage: load / save of the two pruned fields, and the ranking of
 *  mainwindow_autoselector.cpp.
 *
 *  S8 residual: nothing here constructs the Kotlin `AutoSelector` outbound model any more. The stored
 *  document is the data contract ([io.nekohasekai.sagernet.database.ProxyEntity.type] /
 *  `outboundJson`), so [SelectorPruneView] is parsed straight from it through [JsonInput] — the same
 *  column read [io.nekohasekai.sagernet.database.StoredProfile] does for its display facts — and
 *  [save] patches only `pool` / `last_built` back into the stored document instead of re-exporting a
 *  whole model. A parse/patch/write round trip keeps every other field, and the canonical
 *  sorted-key compact form, byte-identical.
 *
 *  The document write goes through [DartProfileWriter] (ADR 0006 stage C2c2b2: per-column patches to
 *  the Dart-owned document, the only store).
 */
object AutoSelectorProfiles {

    const val TYPE = "autoselector"

    /** Held by every :bg writer that loads a selector, changes it and saves it whole, so none undoes another's change. */
    val writes = Mutex()

    /**
     * The selector state the group-changed prune works on: the tracked groups [gids] and the two
     * ranked member lists. Parsed like the model's `AutoSelector.parseFromJson` + `normalize` — `gids`
     * wins over the older single `gid`, ids below 0 and repeats are dropped — so a prune makes exactly
     * the decisions the model did.
     */
    data class SelectorPruneView(
        val gids: List<Long>,
        val pool: List<Long>,
        val lastBuilt: List<Long>,
    ) {
        /**
         * [this] with the members that no longer exist dropped (`removeAll` on the model's lists), or
         * null when neither list changed — the caller then writes nothing.
         */
        fun pruned(keep: Set<Long>): SelectorPruneView? {
            val keptPool = pool.filter { it in keep }
            val keptLastBuilt = lastBuilt.filter { it in keep }
            if (keptPool == pool && keptLastBuilt == lastBuilt) return null
            return copy(pool = keptPool, lastBuilt = keptLastBuilt)
        }
    }

    /** A fresh parse of the stored selector [id]; null when it is gone, not a selector, or unreadable. */
    fun load(id: Long): SelectorPruneView? {
        val profile = ProfileManager.getProfile(id) ?: return null
        if (profile.type != TYPE) return null
        val document = documentOf(profile.outboundJson) ?: return null
        return SelectorPruneView(
            gids = gidsOf(document),
            pool = idsOf(document, "pool"),
            lastBuilt = idsOf(document, "last_built"),
        )
    }

    /** Writes the pruned [view]'s `pool` / `last_built` into the stored document, so traffic, test
     *  results and every other selector field written meanwhile stay.
     *
     *  Only `outbound_json` is patched: the `type` / `name` columns are unchanged by a prune, and the
     *  two `*_at` counters are deliberately left alone because the prune never changed them. A document
     *  this host cannot read is left untouched rather than replaced by a two-key object.
     */
    fun save(id: Long, view: SelectorPruneView) {
        val profile = ProfileManager.getProfile(id) ?: return
        if (profile.type != TYPE) return
        val document = documentOf(profile.outboundJson) ?: return
        document["pool"] = idArray(view.pool)
        document["last_built"] = idArray(view.lastBuilt)
        val patch = mapOf<String, Any?>("outbound_json" to document.toCompact())
        runBlocking(Dispatchers.IO) {
            DartProfileWriter.patchProfiles(mapOf(id to patch))
        }
    }

    /** ProfilesRepo::GetProfileIdsByType("autoselector"), from the Dart-owned document. */
    fun ids(): List<Long> =
        io.flrone.bridge.DartProfileStore.profiles()
            .filter { it.type == TYPE }
            .map { it.id }

    /** The ids among [ids] that still exist. */
    fun existing(ids: Collection<Long>): Set<Long> =
        if (ids.isEmpty()) emptySet() else ProfileManager.getProfiles(ids.distinct()).mapTo(HashSet()) { it.id }

    // --------------------------------------------------------------------------------- document readers

    /** The stored document: an empty object for a blank column (the type's defaults), null when unreadable. */
    private fun documentOf(json: String): JsonObject? =
        if (json.isBlank()) JsonObject() else JsonInput.parseObjectOrNull(json)

    /** `AutoSelector.parseFromJson` + `normalize`: `gids` wins over the older `gid`; negative and repeat ids dropped. */
    private fun gidsOf(document: JsonObject): List<Long> {
        val raw = when {
            document.contains("gids") -> document.array("gids").mapNotNull { longOr(it).takeIf { id -> id >= 0 } }
            document.contains("gid") -> longOr(document["gid"]).takeIf { it >= 0 }?.let(::listOf).orEmpty()
            else -> emptyList()
        }
        val seen = HashSet<Long>()
        return raw.filterTo(ArrayList()) { seen.add(it) }
    }

    /** `obj.array(key).mapTo(ArrayList()) { JsonValues.toInteger(it) }`, the model's list read. */
    private fun idsOf(document: JsonObject, key: String): List<Long> =
        document.array(key).mapTo(ArrayList()) { JsonValues.toInteger(it) }

    private fun idArray(ids: List<Long>): JsonArray = JsonArray().also { array -> ids.forEach { array.add(it) } }

    /** autoSelector's `QJsonValue::toInt(id, -1)`: a whole number, else the default. */
    private fun longOr(value: Any?): Long = when (value) {
        is Long -> value
        is Double -> if (value == Math.rint(value) && value >= Long.MIN_VALUE.toDouble() && value < Long.MAX_VALUE.toDouble()) {
            value.toLong()
        } else {
            -1L
        }

        else -> -1L
    }
}
