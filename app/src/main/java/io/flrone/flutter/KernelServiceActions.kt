package io.flrone.flutter

// The method bodies the FFI/kernel driver needs from the host. They live in one
// place so the UI engine's `io.flrone/box` bridge and the service engine's
// `io.flrone/service` bridge answer identically — no second copy of the config
// build or the running-state writes. This object is deliberately
// free of any Activity/FlutterEngine reference: everything it needs is either a
// process-wide singleton (FlroneKernel, DataStore) or passed in by the caller.

import io.flrone.bridge.FlroneKernel
import io.nekohasekai.sagernet.Key
import io.nekohasekai.sagernet.SagerNet
import io.nekohasekai.sagernet.bg.ServiceClasses
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.RouteActions
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.utils.VpnPermission
import kotlinx.coroutines.delay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import moe.matsuri.nb4a.utils.CoreLog

internal object KernelServiceActions {

    /** How long `service.start` waits for the live VpnService once the VPN consent exists. */
    const val SERVICE_READY_TIMEOUT_MS = 8_000L

    /**
     * Starts the background service and, in VPN mode, waits until the VpnService exists before
     * returning. `SagerNet.startService()` only posts a startForegroundService intent, so a kernel
     * that asks for the tun immediately would see a null `DataStore.vpnService`. Answering only
     * once the service is registered makes that ordering deterministic.
     *
     * The VPN consent is a **pre-transition gate**, not part of the poll. A service started
     * without it answers by opening the consent dialog and stopping itself, so a user who reads
     * the dialog for more than the readiness budget used to be told "VpnService did not start
     * within 8s". [VpnPermission] awaits the dialog's answer first (single-flight: a second
     * start joins the open dialog); the budget below only covers the service coming up after
     * the permission exists.
     *
     * [flags] are the service-engine arguments for a silent start ("quick", "boot"); a UI start
     * passes an empty list.
     */
    suspend fun startServiceAndAwaitTun(flags: List<String> = emptyList()) {
        if (DataStore.serviceMode == Key.MODE_VPN) awaitVpnPermission()
        // A service that is already starting (the UI just posted service.start, or
        // this engine's automatic start raced it) still has no VpnService yet;
        // returning here would let the kernel call openTun too early. A service of the
        // *other* class does not count: the mode was switched under it, and the start
        // below stops it before bringing this mode's class up (SagerNet owns that hop).
        if (!DataStore.serviceState.canStop || runningServiceIsForAnotherMode()) {
            SagerNet.startService(flags)
        }
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

    /**
     * Waits for the consent dialog, if one is needed. A refusal is reported as the channel
     * error it is (the message names the permission, never a timeout).
     */
    private suspend fun awaitVpnPermission() {
        try {
            VpnPermission.ensureGranted(SagerNet.application)
        } catch (refused: VpnPermission.Denied) {
            // The consent screen's own "use proxy instead" action flips the mode and starts the
            // proxy service. That is an answer, not a refusal: continue in the chosen mode.
            if (DataStore.serviceMode == Key.MODE_VPN) throw refused
        }
    }

    /** True when a service is up but it is not the class the current mode names. */
    private fun runningServiceIsForAnotherMode(): Boolean {
        val running = DataStore.baseService ?: return false
        val mode = DataStore.serviceMode
        if (mode != Key.MODE_VPN && mode != Key.MODE_PROXY) return false
        return running.javaClass != ServiceClasses.forMode(mode)
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
    suspend fun buildStartOptions(): Map<String, Any?> = FlroneKernel.buildStartOptions()

    /** mode.set: the FFI path persists the mode itself; no service reload here. */
    fun setMode(mode: String) = FlroneKernel.setMode(mode)

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
        FlroneKernel.markRunning(involvedProfileIds, routeId)

    fun clearRunning() = FlroneKernel.clearRunning()

    /**
     * The FFI driver's status snapshot. Nothing polls the core on the service side in FFI mode,
     * so without this the notification's speed line and the widget stay at zero all session.
     * FlClash's NotificationModule loops with `distinctUntilChanged`: an idle tunnel's 0/0 tick
     * must not rebuild the notification and the widget every second.
     */
    @Volatile
    private var lastStats: io.nekohasekai.sagernet.aidl.SpeedDisplayData? = null

    fun publishKernelStats(txRate: Long, rxRate: Long, txTotal: Long, rxTotal: Long) {
        val stats = io.nekohasekai.sagernet.aidl.SpeedDisplayData(
            txRateProxy = txRate,
            rxRateProxy = rxRate,
            txTotal = txTotal,
            rxTotal = rxTotal,
        )
        val previous = lastStats
        if (previous != null &&
            previous.txRateProxy == stats.txRateProxy &&
            previous.rxRateProxy == stats.rxRateProxy &&
            previous.txTotal == stats.txTotal &&
            previous.rxTotal == stats.rxTotal
        ) {
            return
        }
        lastStats = stats
        DataStore.baseService?.publishKernelStats(stats)
    }

    /**
     * Wi-Fi rules in FFI mode: the Android callback belongs to the host, the core that re-reads
     * the SSID/BSSID belongs to Dart. [onChanged] is announced on every change; there is no UI
     * event sink on the service engine, so the callback simply pokes the kernel-side driver.
     */
    fun watchWifi(enabled: Boolean, onChanged: (() -> Unit)?) {
        FlroneKernel.onWifiChanged = if (enabled) onChanged else null
        DataStore.baseService?.watchWifiRules(enabled)
    }

    /** Lifecycle breadcrumbs, written into the same core.log the log screen shows. */
    fun note(text: String) {
        if (text.isNotEmpty()) {
            runCatching { CoreLog.write("[lifecycle] $text") }.onFailure { Logs.w(it) }
        }
    }

    /**
     * A notification setting (buttons, show-group) changed while the service runs: the
     * General page promises no restart, so push the change to the live notification.
     */
    suspend fun applyNotificationSettings() {
        DataStore.baseService?.applyNotificationSettings()
    }
}
