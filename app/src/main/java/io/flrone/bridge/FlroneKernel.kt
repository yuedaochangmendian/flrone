// The Dart-driven kernel's slim Kotlin surface (zero AIDL, zero cross-process).
//
// The kernel lives in the service Flutter engine and is owned exclusively by Dart
// over dart:ffi. Kotlin here only performs Android-side duties (VPN fd, Wi-Fi/SSID,
// config.prepare's side effects, reload/stop signals into the service engine). It
// holds no FFI handle and has no gobind fallback: every kernel call goes through
// the service engine, and config generation itself is Go's `configBuild` action.
package io.flrone.bridge

import io.nekohasekai.sagernet.database.DataStore

object FlroneKernel {

    /** True once Dart's service engine announced a real FFI attach (`driver.ready`). */
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
     * Runs the Android-side pre-start duties (config.prepare): random port,
     * dashboard port fallback, secret repair, dashboard install, empty rule-set
     * placeholder and the deferred-start consent. The Go `configBuild` action
     * then reads the documents this prepared; no config is generated here.
     */
    suspend fun prepareStart(): Map<String, Any?> = ConfigPrepare.prepare()

    /**
     * The running-config fact the service used to write right after `proxy.init()`
     * (`runningProfiles`). It is not decoration: `ProfileManager.runningUses` reads it to refuse
     * deleting a node a running chain still uses. Dart owns the core now, so it reports the fact
     * here once the start actually succeeded — writing it in [prepareStart] would leave
     * stale values behind whenever the core refuses to come up. The retired `routeId` argument is
     * ignored: there is one global rule table, so no routing identity is tracked at runtime.
     */
    fun markRunning(involvedProfileIds: List<Long>, routeId: Long = 0L) {
        DataStore.runningProfiles = involvedProfileIds.map { it.toString() }
    }

    /** The stop half of [markRunning]: nothing is running, so nothing may look like it is. */
    fun clearRunning() {
        DataStore.runningProfiles = emptyList()
    }

    /** The mode switch's persist half; Dart reloads the core itself (FFI). */
    fun setMode(mode: String) {
        FlroneMode.set(FlroneMode.Mode.of(mode))
        // Writing the store is not enough: FlroneBridge caches the mode in its UI state
        // and re-publishes that cache every second. Without this refresh the pump kept
        // pushing the *old* mode, so it stomped the value Dart had just pushed and the
        // mode chips kept highlighting the previous choice until some unrelated catalog
        // change happened to rebuild the state. FlroneCommands.setMode does the same.
        FlroneBridge.scheduleRefresh(immediate = true)
    }
}
