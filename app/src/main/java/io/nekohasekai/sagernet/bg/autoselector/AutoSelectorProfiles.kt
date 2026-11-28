package io.nekohasekai.sagernet.bg.autoselector

import io.nekohasekai.sagernet.database.ProfileManager
import io.nekohasekai.sagernet.outbound.types.AutoSelector
import kotlinx.coroutines.sync.Mutex

/** Auto-selector profiles in storage: load / save, and the ranking of mainwindow_autoselector.cpp. */
object AutoSelectorProfiles {

    const val TYPE = "autoselector"

    /** Held by every :bg writer that loads a selector, changes it and saves it whole, so none undoes another's change. */
    val writes = Mutex()

    /** A fresh parse of the stored selector [id]; null when it is gone or not a selector. */
    fun load(id: Long): AutoSelector? = ProfileManager.getProfile(id)?.outbound as? AutoSelector

    /** Writes the selector's JSON only, so traffic and test results written meanwhile stay.
     *  ADR 0006 stage C2c2b2: a per-column patch to the Dart document, the only store. */
    fun save(id: Long, selector: AutoSelector) {
        val patch = mapOf<String, Any?>(
            "type" to selector.type,
            "name" to selector.name,
            "outbound_json" to selector.exportToJson().toCompact(),
        )
        kotlinx.coroutines.runBlocking(kotlinx.coroutines.Dispatchers.IO) {
            io.flrone.bridge.DartProfileWriter.patchProfiles(mapOf(id to patch))
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

}
