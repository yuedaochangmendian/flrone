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
 * The selection is resolved through the same rule FlroneKernel always used
 * (DataStore.selectedProxy, else the first profile, persisted), so the Go
 * builder's `profileId` lookup and the Kotlin host agree on the first start of
 * a fresh install.
 */
object ConfigPrepare {

    suspend fun prepare(): Map<String, Any?> = withContext(Dispatchers.IO) {
        val profile = resolveProfile()
            ?: error("No profile selected: add or import a profile before starting the core")

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
            "deferRuleSets" to deferRuleSets,
        )
    }

    /**
     * Resolves the ProxyEntity to start. B-box's profile cards carry *group* ids
     * and the Flutter preference store carries UI settings only, so a 0, a stale
     * id or a group id is never a valid proxy id: the native selection
     * (DataStore.selectedProxy) is the single source of truth. A fresh install
     * whose nodes were imported but never selected falls back to the first one.
     */
    private fun resolveProfile(): ProxyEntity? {
        // ADR 0005 final stage: Dart owns the profile document; the reader falls
        // back to Room only before the one-time migration has produced it.
        val selected = DataStore.selectedProxy
        if (selected > 0L) DartProfileStore.profile(selected)?.let { return it }
        val first = DartProfileStore.profiles().firstOrNull() ?: return null
        DataStore.selectedProxy = first.id
        return first
    }
}
