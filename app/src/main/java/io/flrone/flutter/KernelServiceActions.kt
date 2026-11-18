package io.flrone.flutter

// The method bodies the FFI/kernel driver needs from the host. They live in one
// place so the UI engine's `io.flrone/box` bridge and the service engine's
// `io.flrone/service` bridge answer identically — no second copy of the config
// build, the WARP landing or the running-state writes. This object is deliberately
// free of any Activity/FlutterEngine reference: everything it needs is either a
// process-wide singleton (BboxKernel, DataStore) or passed in by the caller.

import io.flrone.bridge.BboxKernel
import io.flrone.bridge.BboxWarp
import io.flrone.bridge.Settings as ThroneSettings
import io.nekohasekai.sagernet.Key
import io.nekohasekai.sagernet.SagerNet
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.RouteActions
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.ui.warp.WarpClient
import kotlinx.coroutines.delay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import moe.matsuri.nb4a.utils.CoreLog

internal object KernelServiceActions {

    /** How long `service.start` waits for the live VpnService before failing loudly. */
    const val SERVICE_READY_TIMEOUT_MS = 8_000L

    /**
     * Starts the background service and, in VPN mode, waits until the VpnService exists before
     * returning. `SagerNet.startService()` only posts a startForegroundService intent, so a kernel
     * that asks for the tun immediately would see a null `DataStore.vpnService`. Answering only
     * once the service is registered makes that ordering deterministic.
     *
     * [flags] are the service-engine arguments for a silent start ("quick", "boot"); a UI start
     * passes an empty list.
     */
    suspend fun startServiceAndAwaitTun(flags: List<String> = emptyList()) {
        // A service that is already starting (the UI just posted service.start, or
        // this engine's automatic start raced it) still has no VpnService yet;
        // returning here would let the kernel call openTun too early.
        if (!DataStore.serviceState.canStop) SagerNet.startService(flags)
        if (DataStore.serviceMode != Key.MODE_VPN) return
        val deadline = System.currentTimeMillis() + SERVICE_READY_TIMEOUT_MS
        while (DataStore.vpnService == null) {
            if (System.currentTimeMillis() > deadline) {
                error("VpnService did not start within ${SERVICE_READY_TIMEOUT_MS / 1000}s")
            }
            // The service is created in a few hundred milliseconds; a 50 ms poll added up to
            // that again in quantization on a path the user is watching.
            delay(10)
        }
    }

    /** The stop half: only a running service is told to stop; the call is otherwise a no-op. */
    fun stopService() {
        if (DataStore.serviceState.canStop) SagerNet.stopService()
    }

    /** A widget/tile/notification reload asks the FFI driver to rebuild the core in place. */
    fun reloadService() {
        if (DataStore.serviceState.canStop) SagerNet.reloadService()
    }

    /** config.build: the native DB owns the profile selection; no id crosses the boundary. */
    suspend fun buildStartOptions(): Map<String, Any?> = BboxKernel.buildStartOptions()

    /** mode.set: the FFI path persists the mode itself; no service reload here. */
    fun setMode(mode: String) = BboxKernel.setMode(mode)

    /**
     * Picks the route profile a config builds with. The host owns the
     * `settings.current_route_id` row (Room is its only writer), so this writes it first; the Go
     * side never opens its own connection against that table (SQLite 522). Disk-bound, so IO.
     */
    suspend fun setCurrentRoute(id: Long): Map<String, Any?> = withContext(Dispatchers.IO) {
        RouteActions.setCurrent(id)
        mapOf("id" to id)
    }

    /** state.markRunning / state.clearRunning: the facts written right after a successful start. */
    fun markRunning(involvedProfileIds: List<Long>, routeId: Long) =
        BboxKernel.markRunning(involvedProfileIds, routeId)

    fun clearRunning() = BboxKernel.clearRunning()

    /**
     * The FFI driver's status snapshot. Nothing polls the core on the service side in FFI mode,
     * so without this the notification's speed line and the widget stay at zero all session.
     */
    fun publishKernelStats(txRate: Long, rxRate: Long, txTotal: Long, rxTotal: Long) {
        DataStore.baseService?.publishKernelStats(
            io.nekohasekai.sagernet.aidl.SpeedDisplayData(
                txRateProxy = txRate,
                rxRateProxy = rxRate,
                txTotal = txTotal,
                rxTotal = rxTotal,
            ),
        )
    }

    /** The WARP registration landing: persists the identity and the generated keys. */
    fun completeWarp(
        tunnelType: String,
        identity: WarpClient.Identity,
        packets: List<String>,
        packetsError: String?,
    ): Map<String, Any?> = BboxKernel.completeWarp(tunnelType, identity, packets, packetsError)

    /** config.warpParams: the parameters the kernel needs before registering. */
    fun warpParams(tunnelType: String): Map<String, Any?> = WarpClient.registerParams(tunnelType)

    /**
     * warp.register: a new identity made in the core process, saved like the native WARP screen
     * does. The answer's `reload` flag tells the caller whether a running service must rebuild.
     */
    suspend fun registerWarp(tunnelType: String): Map<String, Any?> = BboxWarp.register(tunnelType)

    /** settings.get: the kernel reads a handful of rows through this on start. */
    fun settings(): Map<String, Any?> = ThroneSettings.read()

    /**
     * Wi-Fi rules in FFI mode: the Android callback belongs to the host, the core that re-reads
     * the SSID/BSSID belongs to Dart. [onChanged] is announced on every change; there is no UI
     * event sink on the service engine, so the callback simply pokes the kernel-side driver.
     */
    fun watchWifi(enabled: Boolean, onChanged: (() -> Unit)?) {
        BboxKernel.onWifiChanged = if (enabled) onChanged else null
        DataStore.baseService?.watchWifiRules(enabled)
    }

    /** Lifecycle breadcrumbs, written into the same core.log the log screen shows. */
    fun note(text: String) {
        if (text.isNotEmpty()) {
            runCatching { CoreLog.write("[lifecycle] $text") }.onFailure { Logs.w(it) }
        }
    }
}
