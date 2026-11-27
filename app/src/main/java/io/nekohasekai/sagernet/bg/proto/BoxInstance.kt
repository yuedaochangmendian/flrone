package io.nekohasekai.sagernet.bg.proto

import io.nekohasekai.sagernet.bg.CoreRuntime
import io.nekohasekai.sagernet.bg.SingBoxDashboard
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.ProxyEntity
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.ktx.isLoopbackPortFree
import io.nekohasekai.sagernet.ktx.mkPort
import io.nekohasekai.sagernet.ktx.readableMessage
import io.nekohasekai.sagernet.outbound.config.GeneratedConfig
import io.nekohasekai.sagernet.outbound.types.Custom
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Config capture for the Dart-owned FFI kernel.
 *
 * The service engine owns the kernel handle; this class only builds the
 * StartOptions payload from the Dart-owned profile document and performs the
 * Android-side pre-start duties (dashboard install, empty rule-set placeholder).
 * It creates no instance handle and never launches a core: the caller starts the
 * core itself through the FFI bindings.
 */
class BoxInstance(val profile: ProxyEntity) {

    lateinit var config: GeneratedConfig
    lateinit var core: CoreConfig

    /** This start does not wait for remote rule-sets the core has no copy of. */
    var deferRuleSets = false

    var options: Map<String, Any?> = emptyMap()
        private set

    /** Capture the payload without creating an instance. */
    private suspend fun loadConfig() {
        options = mapOf(
            "coreConfig" to core.coreConfig,
            // Dart owns the post-start rule-set fetch in FFI mode; the flag
            // says whether the start was the deferred kind.
            "deferRuleSets" to deferRuleSets,
            "involvedProfileIds" to config.involvedProfileIds.toList(),
        )
    }

    private fun buildConfig() {
        // random_inbound_port: a fresh port per start, saved so the app's own requests reach it (mainwindow_setup.cpp:193-196).
        if (DataStore.randomInboundPort) DataStore.inboundSocksPort = mkPort()
        // The dashboard is on by default, so another app holding its port must not fail the start: it moves, and the
        // dashboard screen follows the saved port.
        if (DataStore.apiDashboardEnabled && !isLoopbackPortFree(DataStore.coreBoxApiPort)) {
            val port = mkPort()
            Logs.w("sing-box API port ${DataStore.coreBoxApiPort} is in use, the dashboard moves to $port")
            DataStore.coreBoxApiPort = port
        }
        // A custom full config keeps its own rule-sets as written.
        if (isCustomFullConfig()) deferRuleSets = false
        config = CoreConfigs.buildMain(profile, deferRuleSets)
    }

    suspend fun init() {
        buildConfig()
        core = CoreConfig.from(config, listOf(CoreConfig.TAG_PROXY))
        CoreRuntime.applyLogLevel(config.coreConfig)
        // Before the start: the core downloads the dashboard itself when it finds the dir empty.
        if (DataStore.apiDashboardEnabled) withContext(Dispatchers.IO) { SingBoxDashboard.install() }
        // Every remote rule-set carries this file as its initial_path, so the core needs it whether or not this
        // start defers the download: without it a blocked mirror fails the whole start.
        withContext(Dispatchers.IO) {
            runCatching { DeferredRuleSets.writeEmptySet() }.onFailure { Logs.w("rule-sets: ${it.readableMessage}") }
        }
        loadConfig()
    }

    private fun isCustomFullConfig(): Boolean = (profile.outbound as? Custom)?.isFullConfig() == true
}
