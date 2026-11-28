package io.flrone.bridge

import io.nekohasekai.sagernet.bg.SingBoxDashboard
import io.nekohasekai.sagernet.bg.proto.DeferredRuleSets
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.ProxyEntity
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.ktx.isLoopbackPortFree
import io.nekohasekai.sagernet.ktx.mkPort
import io.nekohasekai.sagernet.ktx.readableMessage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * `config.prepare`: the Android-side duties that must run once before the Go
 * config builder reads the documents (ADR 0008).
 *
 * The build itself is pure: Go reads profiles.json / settings.json /
 * global_route_rules.json and writes nothing. Everything that writes — the
 * random mixed port, the dashboard's port fallback, secret generation, the
 * dashboard unpack, the empty rule-set placeholder and the deferred-start
 * consent — happens here, synchronously enough that the documents Go reads
 * already contain the result.
 *
 * The selection is resolved from Dart's `profile_selection.json` first (ADR
 * 0008 P1-5), falling back to DataStore.selectedProxy and then the first
 * profile, so the Go builder's `profileId` lookup and the Kotlin host agree on
 * the first start of
 * a fresh install.
 */
object ConfigPrepare {

    suspend fun prepare(): Map<String, Any?> = withContext(Dispatchers.IO) {
        val profile = resolveProfile()
            ?: error("No profile selected: add or import a profile before starting the core")

        // The per-user mixed port: Android adds UserHandle.hashCode() to the
        // registry default. The Go builder only sees the document, so persist the
        // resolved value once instead of letting it fall back to 2080 for every user.
        DataStore.initGlobal()
        // A fresh mixed port every start, saved so the app's own requests reach it.
        if (DataStore.randomInboundPort) DataStore.inboundSocksPort = mkPort()
        // The dashboard is on by default; another app holding its port must not
        // fail the start, so it moves and the dashboard screen follows the saved port.
        if (DataStore.apiDashboardEnabled && !isLoopbackPortFree(DataStore.coreBoxApiPort)) {
            val port = mkPort()
            Logs.w("sing-box API port ${DataStore.coreBoxApiPort} is in use, the dashboard moves to $port")
            DataStore.coreBoxApiPort = port
        }
        // Both secret getters generate-and-persist when the row is missing: the
        // Go builder must never see an enabled controller without a secret (it
        // would omit the section) and must not generate one itself.
        DataStore.coreBoxApiSecret
        DataStore.ensureClashApiSecret()

        // The service path's consent: a deferred start leaves uncached rule-sets
        // empty and downloads them after the box is up. It is spent here, so the
        // Go build receives the answer explicitly instead of re-reading the
        // timestamp (a consumed timestamp reads as "not deferred").
        val deferRuleSets = DeferredRuleSets.consume()

        if (DataStore.apiDashboardEnabled) SingBoxDashboard.install()
        // Every remote rule-set carries this file as its initial_path; without
        // it a blocked mirror fails the whole start, deferred or not.
        runCatching { DeferredRuleSets.writeEmptySet() }
            .onFailure { Logs.w("rule-sets: ${it.readableMessage}") }

        mapOf(
            "selectedProfileId" to profile.id,
            // The group holding the selected member: the selection document Dart
            // writes next uses the same id, so a build never rewrites it just
            // because settings.current_group names a browsed tab instead.
            "currentGroupId" to profile.groupId,
            // The service engine resolves `profile_selection.json` beside
            // profiles.json and persists the prepared selection there before Go
            // reads it (ADR 0008 S4). One path fact, no duplicate rule. Attach
            // sets the directory before any start; a missing fact is a host bug,
            // not a reason to guess a path.
            "documentsDir" to (DartProfileStore.directory?.path
                ?: error("The profiles document directory is not set")),
            "deferRuleSets" to deferRuleSets,
        )
    }

    /**
     * Resolves the ProxyEntity to start. B-box's profile cards carry *group* ids
     * and the Flutter preference store carries UI settings only, so a 0, a stale
     * id or a group id is never a valid proxy id: the selected *member* id is the
     * source of truth.
     *
     * Settings stay the settled selection (Dart mirrors every UI choice there
     * through `selection.mirror`; the platform paths — widget, quick toggle,
     * BaseService, subscription successor — write them directly). When settings
     * carry no usable selection (a fresh upgrade/reset) the Dart document is the
     * fallback, then the first profile. This is resolution, not a gate: the
     * start build itself reads only the document Dart writes from this answer.
     */
    private fun resolveProfile(): ProxyEntity? {
        val selected = DataStore.selectedProxy
        if (selected > 0L) DartProfileStore.profile(selected)?.let { return it }
        ProfileSelectionStore.selectedProfileId(DartProfileStore.directory)?.let { fromDocument ->
            DartProfileStore.profile(fromDocument)?.let {
                DataStore.selectedProxy = it.id
                return it
            }
        }
        val first = DartProfileStore.profiles().firstOrNull() ?: return null
        DataStore.selectedProxy = first.id
        return first
    }
}
