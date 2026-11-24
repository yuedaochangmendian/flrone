// The Dart-driven kernel's slim Kotlin surface (zero AIDL, zero cross-process).
//
// The kernel lives in the service Flutter engine and is owned exclusively by Dart
// over dart:ffi. Kotlin here only builds the core config from the Dart-owned
// profiles document (DartProfileStore/DartProfileWriter) and performs Android-side
// duties (VPN fd, Wi-Fi/SSID, reload/stop signals into the service engine). It holds
// no FFI handle and has no gobind fallback: every kernel call goes through the
// service engine.
package io.flrone.bridge

import io.nekohasekai.sagernet.bg.proto.BoxInstance
import io.nekohasekai.sagernet.bg.proto.DeferredRuleSets
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.ProxyEntity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

object BboxKernel {

    /** True once Dart announced the FFI path; the bg start path then skips the core. */
    @Volatile
    var ffiMode: Boolean = false

    /**
     * How a non-Dart reload (widget, tile, notification) reaches Dart in ffiMode:
     * the bridge plugs an emitter here so BaseService.reload can ask the FFI
     * driver to rebuild the core without bouncing the service.
     */
    @Volatile
    var onReloadWanted: (() -> Unit)? = null

    /**
     * How an SSID/BSSID change reaches Dart in ffiMode. The monitor has to live on the Android
     * side (it owns the ConnectivityManager callback), but the core that must re-read the state
     * is Dart's, so the change is announced rather than applied here.
     */
    @Volatile
    var onWifiChanged: (() -> Unit)? = null

    /**
     * How a non-Dart stop (widget/tile/notification) reaches the service engine's
     * Dart kernel: the service bridge registers this callback and it notifies the
     * kernel over `io.flrone/service` to close the core it exclusively owns. It
     * never falls back to a host-held handle — the host owns no FFI handle.
     */
    @Volatile
    var onStopWanted: ((Long) -> Unit)? = null

    /**
     * Builds the StartOptions payload for the selected profile exactly as the
     * service start path does (BoxInstance.init) — including the dashboard install
     * — but without creating a gobind Instance: the caller
     * starts the core itself through the FFI bindings. The native DB is the sole
     * source of truth; no profile id crosses the channel.
     */
    suspend fun buildStartOptions(): Map<String, Any?> = withContext(Dispatchers.IO) {
        // The connections screen needs the core's own Clash API. Enable it here, before the
        // config is generated, and only when the user never set the port explicitly — otherwise
        // opening that screen used to rewrite clashApiEnabled and reload the running tunnel.
        BboxApi.enableForConnectionsScreen()
        val profile = resolveProfile()
            ?: error("No profile selected: add or import a profile before starting the core")
        // The same consent the service path spends (BaseService): with it the
        // config leaves uncached remote rule-sets empty instead of failing the
        // whole start, and Dart downloads them after the box is up. Without
        // this the "Start without rule sets" setting did nothing in FFI mode.
        val deferRuleSets = DeferredRuleSets.consume()
        val capture = StartOptionsCapture(profile, deferRuleSets)
        capture.init()
        try {
            capture.options
        } finally {
            capture.close()
        }
    }

    /**
     * The running-config facts the service used to write right after `proxy.init()`
     * (`runningProfiles` and `runningRouteId`). They are not decoration: `ProfileManager.runningUses`
     * reads the first to refuse deleting a node a running chain still uses, and
     * `RouteManager.runningRouteId` reads the second to decide whether a group's routing change
     * needs a reload. Dart owns the core now, so it reports them here once the start actually
     * succeeded — writing them in [buildStartOptions] would leave stale values behind whenever the
     * core refuses to come up.
     */
    fun markRunning(involvedProfileIds: List<Long>, routeId: Long) {
        DataStore.runningProfiles = involvedProfileIds.map { it.toString() }
        DataStore.runningRouteId = routeId
    }

    /** The stop half of [markRunning]: nothing is running, so nothing may look like it is. */
    fun clearRunning() {
        DataStore.runningProfiles = emptyList()
        DataStore.runningRouteId = 0L
    }

    /** The mode switch's persist half; Dart reloads the core itself (FFI). */
    fun setMode(mode: String) {
        BboxMode.set(BboxMode.Mode.of(mode))
        // Writing the store is not enough: BboxBridge caches the mode in its UI state
        // and re-publishes that cache every second. Without this refresh the pump kept
        // pushing the *old* mode, so it stomped the value Dart had just pushed and the
        // mode chips kept highlighting the previous choice until some unrelated catalog
        // change happened to rebuild the state. BboxCommands.setMode does the same.
        BboxBridge.scheduleRefresh(immediate = true)
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

    /** BoxInstance.init minus loadConfig: the build half the FFI caller needs. */
    private class StartOptionsCapture(
        profile: ProxyEntity,
        deferRuleSets: Boolean,
    ) : BoxInstance(profile) {

        var options: Map<String, Any?> = emptyMap()
            private set

        init {
            this.deferRuleSets = deferRuleSets
        }

        override suspend fun loadConfig() {
            options = mapOf(
                "coreConfig" to core.coreConfig,
                // Dart owns the post-start rule-set fetch in FFI mode; the flag
                // says whether the start was the deferred kind.
                "deferRuleSets" to deferRuleSets,
                "involvedProfileIds" to config.involvedProfileIds.toList(),
                "routeId" to routeId,
            )
        }
    }
}
