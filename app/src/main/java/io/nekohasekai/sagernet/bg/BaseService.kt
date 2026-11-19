package io.nekohasekai.sagernet.bg

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.*
import android.widget.Toast
import io.nekohasekai.sagernet.Action
import io.nekohasekai.sagernet.BootReceiver
import io.nekohasekai.sagernet.Key
import io.nekohasekai.sagernet.R
import io.nekohasekai.sagernet.SagerNet
import io.nekohasekai.sagernet.aidl.ISagerNetService
import io.nekohasekai.sagernet.aidl.ISagerNetServiceCallback
import io.nekohasekai.sagernet.aidl.LiveStatsBatch
import io.nekohasekai.sagernet.appwidget.Widgets
import io.nekohasekai.sagernet.bg.autoselector.AutoSelectorRuntime
import io.nekohasekai.sagernet.bg.proto.DeferredRuleSets
import io.nekohasekai.sagernet.bg.proto.LocalDnsFailedException
import io.nekohasekai.sagernet.bg.proto.ProxyInstance
import io.nekohasekai.sagernet.bg.proto.RuleSetDownloadFailedException
import io.nekohasekai.sagernet.bg.proto.exitsThroughVpn
import io.nekohasekai.sagernet.bg.proto.urlTestCurrent
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.ProfileOrder
import io.nekohasekai.sagernet.database.ProxyEntity
import io.nekohasekai.sagernet.database.SagerDatabase
import io.nekohasekai.sagernet.ktx.*
import io.nekohasekai.sagernet.outbound.json.jsonObjectOf
import io.nekohasekai.sagernet.utils.DefaultNetworkListener
import io.nekohasekai.sagernet.utils.PlatformNotifications
import io.nekohasekai.sagernet.utils.WifiStateAccess
import io.flrone.core.CoreInstance
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import moe.matsuri.nb4a.Protocols
import moe.matsuri.nb4a.utils.Util
import java.net.UnknownHostException
import java.util.concurrent.Executors

class BaseService {

    companion object {
        /**
         * The main core's build, start and close: blocking JNI and database work kept off the main looper, one at a
         * time, so a close never overlaps a start.
         */
        private val coreDispatcher = Executors.newSingleThreadExecutor { Thread(it, "CoreLifecycle") }.asCoroutineDispatcher()
    }

    enum class State(
        val canStop: Boolean = false,
        val started: Boolean = false,
        val connected: Boolean = false,
    ) {
        /**
         * Idle state is only used by UI and will never be returned by BaseService.
         */
        Idle, Connecting(true, true, false), Connected(true, true, true), Stopping, Stopped,
    }

    interface ExpectedException

    class Data internal constructor(private val service: Interface) {
        var state = State.Stopped
        var proxy: ProxyInstance? = null
        var notification: ServiceNotification? = null
        var wifiMonitor: WifiStateAccess.Monitor? = null

        /** The engine args of the last start intent ("quick"/"boot"), kept for in-place restarts. */
        var engineArgs: List<String> = emptyList()

        // Pause and wake are JNI calls into the core: run them in order and off the main thread.
        private val idleLock = Mutex()

        @Volatile
        private var pausedBox: CoreInstance? = null

        /** [box] is paused for device idle. */
        fun idlePaused(box: CoreInstance): Boolean = pausedBox === box

        val receiver = broadcastReceiver { ctx, intent ->
            when (intent.action) {
                Intent.ACTION_SHUTDOWN -> service.persistStats()
                Action.RELOAD -> service.reload()
                Action.CLOSE -> service.stopRunner()
                Action.SWITCH_NEXT -> service.switchRelative(1)
                Action.SWITCH_PREVIOUS -> service.switchRelative(-1)
                Action.SWITCH_PROFILE -> service.switchProfile(intent.getLongExtra(Action.EXTRA_PROFILE_ID, 0L))
                Action.REFRESH_WIFI_STATE -> afterStart { refreshWifiState(ctx) }
                Action.AUTO_SELECTOR_AUTOMATIC -> AutoSelectorRuntime.releasePin(intent.getLongExtra(Action.EXTRA_PROFILE_ID, 0L))
                PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED -> afterStart { applyIdleMode() }

                Action.RESET_UPSTREAM_CONNECTIONS -> afterStart {
                    runOnDefaultDispatcher {
                        proxy?.boxOrNull?.resetNetwork()
                        runOnMainDispatcher {
                            Util.collapseStatusBar(ctx)
                            Toast.makeText(ctx, "Reset upstream connections done", Toast.LENGTH_SHORT)
                                .show()
                        }
                    }
                }
            }
        }

        /** Runs [block] once a start in progress is over: the box is never touched while it starts on another thread. */
        private fun afterStart(block: () -> Unit) {
            val job = connectingJob?.takeIf { it.isActive } ?: return block()
            runOnMainDispatcher {
                job.join()
                block()
            }
        }

        var closeReceiverRegistered = false

        val binder = Binder(this)
        var connectingJob: Job? = null

        /** A plain stop asked for while a restart was stopping the old core: the restart ends stopped instead. */
        var stopRequested = false

        /**
         * A start asked for while the core was still stopping.
         *
         * `onStartCommand` used to answer `START_STICKY` and do nothing whenever the state was not
         * Stopped — including Stopping. A start inside that window therefore never built a proxy
         * and never re-registered the VpnService, so Dart's `startServiceAndAwaitTun` polled a null
         * `vpnService` for its full 8 s budget and failed with "VpnService did not start within 8s"
         * on a simple stop-then-start. Recording the request lets the stop's tail start the proxy.
         */
        var startRequested = false

        fun changeState(s: State, msg: String? = null) {
            if (state == s && msg == null) return
            state = s
            DataStore.serviceState = s
            binder.stateChanged(s, msg)
            Widgets.push(service as Context)
            // No more AIDL callback to the tile: service + tile are one process now, so a
            // listening-state request is enough for the tile to re-read DataStore directly.
            TileUpdater.refresh(service as Context)
        }

        /** Reads the idle mode when the job runs, so the last of several quick events always wins. */
        private fun applyIdleMode() = runOnDefaultDispatcher {
            idleLock.withLock {
                val box = proxy?.boxOrNull ?: return@withLock
                if (SagerNet.power.isDeviceIdleMode) {
                    if (pausedBox !== box) {
                        box.pause()
                        pausedBox = box
                    }
                } else if (pausedBox === box) {
                    pausedBox = null
                    box.wake()
                    if (DataStore.configurationStore.getBoolean(Key.WAKE_RESET_CONNECTIONS, true)) {
                        box.resetNetwork()
                    }
                }
            }
        }

        private fun refreshWifiState(ctx: Context) = runOnDefaultDispatcher {
            val box = proxy?.boxOrNull ?: return@runOnDefaultDispatcher
            if (!box.needWIFIState()) return@runOnDefaultDispatcher
            box.updateWIFIState()
            if (WifiStateAccess.status(ctx) == WifiStateAccess.Status.OK) {
                PlatformNotifications.cancelWifiRulesInactive(ctx)
            }
        }
    }

    class Binder(private var data: Data? = null) : ISagerNetService.Stub(), CoroutineScope,
        AutoCloseable {
        private val callbacks = object : RemoteCallbackList<ISagerNetServiceCallback>() {
            override fun onCallbackDied(callback: ISagerNetServiceCallback?, cookie: Any?) {
                super.onCallbackDied(callback, cookie)
            }
        }

        val callbackIdMap = java.util.concurrent.ConcurrentHashMap<ISagerNetServiceCallback, Int>()

        override val coroutineContext = Dispatchers.Main.immediate + Job()

        override fun getState(): Int = (data?.state ?: State.Idle).ordinal
        override fun getProfileName(): String = data?.proxy?.displayProfileName ?: "Idle"

        override fun registerCallback(cb: ISagerNetServiceCallback, id: Int) {
            if (id == SagerConnection.CONNECTION_ID_RESTART_BG) {
                Runtime.getRuntime().exit(0)
                return
            }
            if (!callbackIdMap.contains(cb)) {
                callbacks.register(cb)
            }
            callbackIdMap[cb] = id
        }

        private val broadcastMutex = Mutex()

        suspend fun broadcast(work: (ISagerNetServiceCallback) -> Unit) {
            broadcastMutex.withLock {
                val count = callbacks.beginBroadcast()
                try {
                    repeat(count) {
                        try {
                            work(callbacks.getBroadcastItem(it))
                        } catch (_: RemoteException) {
                        } catch (_: Exception) {
                        }
                    }
                } finally {
                    callbacks.finishBroadcast()
                }
            }
        }

        override fun unregisterCallback(cb: ISagerNetServiceCallback) {
            callbackIdMap.remove(cb)
            callbacks.unregister(cb)
        }

        override fun resetTraffic(profileIds: LongArray) {
            launch(Dispatchers.Default) {
                data?.proxy?.looper?.resetTraffic(profileIds)
            }
        }

        override fun urlTest(): Int {
            val proxy = data?.proxy?.takeIf { it.isInitialized() } ?: error("core not started")
            try {
                return runBlocking {
                    urlTestCurrent(
                        proxy.box, proxy.core, DataStore.testUrl, DataStore.urlTestTimeoutMs,
                        exitsThroughVpn(proxy.profile),
                    )
                }
            } catch (e: Exception) {
                error(Protocols.genFriendlyMsg(e.readableMessage))
            }
        }

        /**
         * Instance.updateRuleSets (core/internal/rulesets UpdateAll): every remote rule-set of the running instance,
         * at most 5 at a time within 60 s. Arrives on a binder thread, so blocking that long is fine.
         */
        override fun updateRuleSets(): String = try {
            val box = data?.takeIf { it.state.connected }?.proxy?.boxOrNull
            if (box == null) {
                ruleSetUpdateJson(0, "not running")
            } else {
                val update = box.updateRuleSets()
                ruleSetUpdateJson(update.updated, update.error)
            }
        } catch (e: Throwable) {
            ruleSetUpdateJson(0, e.readableMessage)
        }

        private fun ruleSetUpdateJson(updated: Int, error: String): String =
            jsonObjectOf("updated" to updated, "error" to error).toCompact()

        override fun autoSelectorStatus(withMembers: Boolean): String = AutoSelectorRuntime.statusJson(withMembers)

        override fun autoSelectorRecheck() = AutoSelectorRuntime.recheck()

        override fun autoSelectorSelect(memberProfileId: Long) = AutoSelectorRuntime.select(memberProfileId)

        override fun liveStats(session: Long, afterSerial: Long): LiveStatsBatch = LiveStatsRecorder.batch(session, afterSerial)

        fun stateChanged(s: State, msg: String?) = launch {
            val profileName = profileName
            broadcast { it.stateChanged(s.ordinal, profileName, msg) }
        }

        override fun close() {
            callbacks.kill()
            cancel()
            data = null
        }
    }

    interface Interface {
        val data: Data
        val tag: String
        fun createNotification(profileName: String): ServiceNotification

        fun onBind(intent: Intent): IBinder? =
            if (intent.action == Action.SERVICE) data.binder else null

        fun reload() {
            if (io.flrone.bridge.BboxKernel.ffiMode) {
                // The core is Dart's; a widget/tile/notification reload asks it to rebuild
                // instead of bouncing the foreground service.
                io.flrone.bridge.BboxKernel.onReloadWanted?.invoke()
                return
            }
            if (DataStore.selectedProxy == 0L) {
                stopRunner(false, (this as Context).getString(R.string.profile_empty))
                return
            }
            val s = data.state
            when {
                s == State.Stopped -> startRunner()
                s.canStop -> AutoSelectorRuntime.restart(this) { stopRunner(true) }
                else -> Logs.w("Illegal state $s when invoking use")
            }
        }

        /** Runs [id] instead of the current profile, staying in the foreground; the running profile is left alone. */
        fun switchProfile(id: Long) {
            if (id <= 0L) return
            DataStore.selectedProxy = id
            val s = data.state
            if (s.canStop && data.proxy?.profile?.id == id) return
            runOnDefaultDispatcher {
                data.binder.broadcast { it.cbSelectorUpdate(id) }
            }
            // Tile used to learn the new profile via cbSelectorUpdate; now it re-reads shared state.
            TileUpdater.refresh(this as Context)
            // FFI mode: Dart reloads the core on the selection change; a service restart here
            // would only bounce the notification.
            if (io.flrone.bridge.BboxKernel.ffiMode) {
                Widgets.push(this as Context)
                return
            }
            // While stopping, a restart in flight starts whatever is selected once the old core is gone.
            if (s.canStop) AutoSelectorRuntime.restart(this) { stopRunner(true) } else Widgets.push(this as Context)
        }

        /** The neighbour [step] away in the group of the selected profile, wrapping around. */
        fun switchRelative(step: Int) {
            val current = DataStore.selectedProxy.takeIf { it > 0L } ?: data.proxy?.profile?.id ?: return
            val target = ProfileOrder.neighbour(current, step) ?: return
            switchProfile(target.id)
        }

        suspend fun startProcesses() {
            data.proxy!!.launch()
        }

        fun startRunner() {
            this as Context
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(Intent(this, javaClass))
            else startService(Intent(this, javaClass))
        }

        suspend fun killProcesses(): Throwable? {
            val proxy = data.proxy
            val serviceId = Integer.toHexString(System.identityHashCode(data))
            val proxyId = proxy?.let { Integer.toHexString(System.identityHashCode(it)) } ?: "none"
            var cleanupError: Throwable? = null
            fun recordCleanupFailure(stage: String, error: Throwable) {
                if (cleanupError == null) {
                    cleanupError = error
                } else if (cleanupError !== error) {
                    cleanupError?.addSuppressed(error)
                }
                Logs.w(
                    "ServiceLifecycleTrace serviceId=$serviceId proxyId=$proxyId " +
                        "profileId=${proxy?.profile?.id ?: -1L} stage=$stage failed " +
                        "type=${error.javaClass.name} message=${error.message}"
                )
            }
            Logs.i(
                "ServiceLifecycleTrace serviceId=$serviceId proxyId=$proxyId " +
                    "profileId=${proxy?.profile?.id ?: -1L} stage=kill begin"
            )
            try {
                data.wifiMonitor?.stop()
            } catch (error: Throwable) {
                recordCleanupFailure("wifi-monitor-stop", error)
            } finally {
                data.wifiMonitor = null
            }

            try {
                if (proxy != null) withContext(coreDispatcher) { proxy.close() }
                Logs.i(
                    "ServiceLifecycleTrace serviceId=$serviceId proxyId=$proxyId " +
                        "profileId=${proxy?.profile?.id ?: -1L} stage=proxy-close success"
                )
            } catch (error: Throwable) {
                recordCleanupFailure("proxy-close", error)
            }

            try {
                DefaultNetworkListener.stop(this)
            } catch (error: Throwable) {
                recordCleanupFailure("network-listener-stop", error)
            }

            Logs.i(
                "ServiceLifecycleTrace serviceId=$serviceId proxyId=$proxyId " +
                    "profileId=${proxy?.profile?.id ?: -1L} stage=kill done " +
                    "hasCleanupError=${cleanupError != null}"
            )
            return cleanupError
        }

        /**
         * A restart keeps the service, its notification and the receiver: the new core starts in place, so a switch
         * from the notification or a widget never needs another foreground-service start from the background.
         */
        fun stopRunner(restart: Boolean = false, msg: String? = null) {
            DataStore.baseService = null
            DataStore.vpnService = null

            val serviceId = Integer.toHexString(System.identityHashCode(data))
            val proxy = data.proxy
            val proxyId = proxy?.let { Integer.toHexString(System.identityHashCode(it)) } ?: "none"
            val caller = Thread.currentThread().stackTrace.firstOrNull { frame ->
                frame.className != Thread::class.java.name && frame.methodName != "stopRunner"
            }?.let { frame -> "${frame.className}.${frame.methodName}:${frame.lineNumber}" }
                ?: "unknown"
            Logs.i(
                "ServiceStopTrace serviceId=$serviceId proxyId=$proxyId restart=$restart " +
                    "state=${data.state} profileId=${proxy?.profile?.id ?: -1L} " +
                    "hasMessage=${msg != null} caller=$caller"
            )
            if (data.state == State.Stopping) {
                // the old core now closes off the main thread, so a Stop can arrive in the middle of a restart
                if (!restart) data.stopRequested = true
                Logs.i(
                    "ServiceStopTrace serviceId=$serviceId proxyId=$proxyId " +
                        "stage=ignored-already-stopping"
                )
                return
            }
            this as Service

            data.stopRequested = false
            data.changeState(State.Stopping)
            val originalMessage = msg

            runOnMainDispatcher {
                // A non-Dart stop (widget/tile/notification) is forwarded by the
                // service bridge to the service engine's Dart kernel, which owns
                // the only FFI handle and closes the core itself. There is no
                // host-held handle to fall back to. A restart keeps its core —
                // it is an in-place rebuild, not a stop.
                if (!restart && io.flrone.bridge.BboxKernel.ffiMode) {
                    io.flrone.bridge.BboxKernel.onStopWanted?.invoke()
                }
                var cleanupError: Throwable? = null
                fun recordCleanupFailure(stage: String, error: Throwable) {
                    if (cleanupError == null) {
                        cleanupError = error
                    } else if (cleanupError !== error) {
                        cleanupError?.addSuppressed(error)
                    }
                    Logs.w(
                        "ServiceStopTrace serviceId=$serviceId proxyId=$proxyId " +
                            "stage=$stage failed type=${error.javaClass.name} " +
                            "message=${error.message}"
                    )
                }

                try {
                    data.connectingJob?.cancelAndJoin() // ensure stop connecting first
                } catch (error: Throwable) {
                    recordCleanupFailure("connecting-job-cancel", error)
                } finally {
                    data.connectingJob = null
                }

                var keepNotification = restart && data.notification != null
                if (keepNotification) {
                    try {
                        data.notification?.postNotificationTitle(getString(R.string.notification_switching))
                    } catch (error: Throwable) {
                        recordCleanupFailure("notification-title", error)
                    }
                } else {
                    try {
                        data.notification?.destroy()
                    } catch (error: Throwable) {
                        recordCleanupFailure("notification-destroy", error)
                    } finally {
                        data.notification = null
                    }
                }

                try {
                    killProcesses()?.let { recordCleanupFailure("process-cleanup", it) }
                } catch (error: Throwable) {
                    recordCleanupFailure("process-cleanup-boundary", error)
                }

                val stopInstead = restart && data.stopRequested
                data.stopRequested = false
                if (stopInstead && keepNotification) {
                    keepNotification = false
                    try {
                        data.notification?.destroy()
                    } catch (error: Throwable) {
                        recordCleanupFailure("notification-destroy", error)
                    } finally {
                        data.notification = null
                    }
                }
                val finishRestart = restart && !stopInstead

                if (!keepNotification) {
                    try {
                        if (data.closeReceiverRegistered) {
                            unregisterReceiver(data.receiver)
                        }
                    } catch (error: Throwable) {
                        recordCleanupFailure("receiver-unregister", error)
                    } finally {
                        data.closeReceiverRegistered = false
                    }
                    PlatformNotifications.cancelWifiRulesInactive(this@Interface)
                }
                data.proxy = null

                cleanupError?.let { error ->
                    Logs.w(
                        "ServiceStopTrace serviceId=$serviceId proxyId=$proxyId " +
                            "stage=cleanup failed type=${error.javaClass.name} " +
                            "message=${error.message} suppressed=${error.suppressed.size} " +
                            "originalMessagePreserved=${originalMessage != null}"
                    )
                }

                try {
                    data.changeState(State.Stopped, originalMessage)
                } catch (error: Throwable) {
                    recordCleanupFailure("state-stopped", error)
                }
                Logs.i(
                    "ServiceStopTrace serviceId=$serviceId proxyId=$proxyId " +
                        "stage=stopped restart=$restart hasCleanupError=${cleanupError != null}"
                )
                if (!finishRestart) {
                    DeferredRuleSets.serviceStopped()
                    AutoSelectorRuntime.serviceStopped()
                }

                try {
                    // A start that arrived while this stop was running was recorded by
                    // onStartCommand; honour it here instead of stopping the service the caller
                    // just asked to start (which used to surface as an 8 s "VpnService did not
                    // start" timeout). Cleared first so a failed start does not loop.
                    val resumeStart = data.startRequested
                    data.startRequested = false
                    when {
                        keepNotification -> startProxy()
                        finishRestart -> startRunner()
                        resumeStart -> startProxy()
                        else -> {
                            // The engine stays for the life of the process: it owns the
                            // kernel's Dart state (action completers, subscriptions) and
                            // destroying it here would race the `service.stop` reply the
                            // kernel is still awaiting. A stopped engine costs one idle
                            // isolate and makes the next connect instant.
                            stopSelf() // stop the service if nothing has bound to it
                        }
                    }
                } catch (error: Throwable) {
                    recordCleanupFailure("service-finish", error)
                    if (keepNotification) {
                        failRunner("${getString(R.string.service_failed)} ${error.readableMessage}")
                    }
                }
            }
        }

        /**
         * A start that failed: MainActivity keeps showing [message] until the next start, also on a later visit, and
         * offers the DNS settings with it when [dnsSettings], the Xray geo asset settings when [geoSettings], a start
         * without the rule-sets when [ruleSets].
         */
        fun failRunner(message: String, dnsSettings: Boolean = false, geoSettings: Boolean = false, ruleSets: Boolean = false) {
            if (data.state != State.Stopping) {
                DataStore.serviceError = message
                DataStore.serviceErrorDns = dnsSettings
                DataStore.serviceErrorGeo = geoSettings
                DataStore.serviceErrorRuleSets = ruleSets
            }
            stopRunner(false, message)
        }

        fun persistStats() {
            // TODO NEW save app stats?
        }

        // networks
        var upstreamInterfaceName: String?

        suspend fun preInit() {
            // Tracks the underlying network for VpnService.setUnderlyingNetworks only; the
            // "reset on network change" switch is applied by BboxCorePlatform's monitor callback.
            DefaultNetworkListener.start(this) { network ->
                if (network == null) {
                    SagerNet.underlyingNetwork = null
                    DataStore.vpnService?.updateUnderlyingNetwork()
                    return@start
                }
                SagerNet.connectivity.getLinkProperties(network)?.also { link ->
                    SagerNet.underlyingNetwork = network
                    DataStore.vpnService?.updateUnderlyingNetwork()
                    val oldName = upstreamInterfaceName
                    if (oldName != link.interfaceName) {
                        Logs.d("Network changed: $oldName -> ${link.interfaceName}")
                        upstreamInterfaceName = link.interfaceName
                    }
                }
            }
        }

        suspend fun lateInit() {
            data.notification?.postConnected()
        }

        /**
         * The FFI driver's status snapshot, published where [TrafficLooper] would have put it: the
         * notification's speed line and the widget. In ffiMode nothing on this side owns a
         * TrafficUpdater — that needs a ProxyInstance — so Dart pushes the numbers it already reads
         * from the core's aggregate status instead of the notification sitting at zero.
         */
        fun publishKernelStats(stats: io.nekohasekai.sagernet.aidl.SpeedDisplayData) {
            val context = this as Context
            // Both sinks are main-thread and suspending; the status feed arrives once a second
            // from the channel, so hop rather than assume.
            runOnMainDispatcher {
                data.notification?.apply {
                    if (listenPostSpeed) postNotificationSpeedUpdate(stats)
                }
                Widgets.pushSpeed(context, stats.txRateProxy, stats.rxRateProxy)
            }
        }

        /** Wi-Fi rules (route, DNS or rule-set ones) need location access and a fresh Wi-Fi state on roaming. */
        fun watchWifiRules(proxy: ProxyInstance) {
            this as Context
            val box = proxy.boxOrNull ?: return
            if (!box.needWIFIState()) {
                PlatformNotifications.cancelWifiRulesInactive(this)
                return
            }
            data.wifiMonitor = WifiStateAccess.Monitor(this) { box.updateWIFIState() }.also { it.start() }
            if (WifiStateAccess.status(this) == WifiStateAccess.Status.OK) {
                PlatformNotifications.cancelWifiRulesInactive(this)
            } else {
                PlatformNotifications.wifiRulesInactive(this)
            }
        }

        /**
         * The same monitor without a [ProxyInstance]: in FFI mode the box belongs to Dart, so the
         * caller asks the core whether the config needs Wi-Fi state and passes the answer here.
         * Only the monitor lives on this side — it owns the Android callback — and every change is
         * reported back to Dart, which asks the core to re-read the platform's SSID/BSSID
         * (`BboxCorePlatform.readWifiState` is still the reader).
         */
        fun watchWifiRules(enabled: Boolean) {
            this as Context
            if (!enabled) {
                data.wifiMonitor?.stop()
                data.wifiMonitor = null
                PlatformNotifications.cancelWifiRulesInactive(this)
                return
            }
            // A reload asks again for a monitor that is already watching: rebuilding it would
            // drop a change that lands between unregister and register.
            if (data.wifiMonitor != null) return
            data.wifiMonitor = WifiStateAccess.Monitor(this) {
                io.flrone.bridge.BboxKernel.onWifiChanged?.invoke()
                if (WifiStateAccess.status(this) == WifiStateAccess.Status.OK) {
                    PlatformNotifications.cancelWifiRulesInactive(this)
                }
            }.also { it.start() }
            if (WifiStateAccess.status(this) == WifiStateAccess.Status.OK) {
                PlatformNotifications.cancelWifiRulesInactive(this)
            } else {
                PlatformNotifications.wifiRulesInactive(this)
            }
        }

        /** Always-on VPN starts the service by itself; without a profile it can only explain why nothing connects. */
        fun onNoProfile() {}

        fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
            DataStore.baseService = this
            // The service engine needs the silent-start flags even when an in-place restart
            // calls startProxy() later without an intent; keep the last ones.
            data.engineArgs = SagerNet.engineArgsFrom(intent).orEmpty().toList()

            // START_STICKY: when the system reclaims the service under memory pressure it is
            // restarted with a null intent, so the proxy reconnects instead of silently dropping.
            // A user-initiated stop still ends it for good, because stopRunner() calls stopSelf().
            if (data.state != State.Stopped) {
                // Stopping is not "already running": remember the ask so the stop's tail starts
                // the proxy instead of leaving the caller to time out. Connected/Connecting are
                // genuine no-ops.
                if (data.state == State.Stopping) data.startRequested = true
                return Service.START_STICKY
            }
            startProxy()
            return Service.START_STICKY
        }

        /** Starts the selected profile; the notification and the receiver of a restart are reused. */
        fun startProxy() {
            DataStore.baseService = this
            // P6 stage 1: bring up the headless service engine that owns the kernel. Idempotent,
            // so an already-running engine (an in-place restart, a second start command) is kept.
            // Args come from the intent (tile/boot/widget silent start) or the pending slot set by
            // startServiceQuick; a normal UI start carries none.
            val engineArgs = data.engineArgs.ifEmpty { SagerNet.takePendingEngineArgs() }
            val engineWasRunning = io.flrone.flutter.ServiceEngineManager.isRunning()
            io.flrone.flutter.ServiceEngineManager.ensureStarted(engineArgs)
            // A reused engine already ran serviceMain's one-shot auto-start; ask it for this
            // start explicitly. A freshly created engine gets it from serviceMain itself.
            if (engineWasRunning) io.flrone.flutter.ServiceBridge.startKernel()
            // The FFI core opens the tun through CorePlatform.openTun while it starts.
            // The channel path registers the live VpnService in startProcesses(), but
            // the FFI path returns early and never calls it, so openTun used to see a
            // null service and the start failed with "bridge: platform callback failed".
            // Register here, before the core can ask for the interface.
            if (this is VpnService) DataStore.vpnService = this
            val data = data
            // Consumed: whichever path got here (a direct start, or the stop's tail honouring a
            // queued request) is starting now.
            data.startRequested = false
            val profile = SagerDatabase.proxyDao.getById(DataStore.selectedProxy)
            this as Context
            if (profile == null) { // gracefully shutdown: https://stackoverflow.com/q/47337857/2245107
                if (data.notification == null) data.notification = createNotification("")
                onNoProfile()
                stopRunner(false, getString(R.string.profile_empty))
                return
            }
            PlatformNotifications.cancelAlwaysOnNoProfile(this)

            val proxy = ProxyInstance(profile, this)
            proxy.deferRuleSets = DeferredRuleSets.consume()
            data.proxy = proxy
            BootReceiver.enabled = DataStore.rememberEnable
            if (!data.closeReceiverRegistered) {
                val filter = IntentFilter().apply {
                    addAction(Action.RELOAD)
                    addAction(Intent.ACTION_SHUTDOWN)
                    addAction(Action.CLOSE)
                    addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
                    addAction(Action.RESET_UPSTREAM_CONNECTIONS)
                    addAction(Action.SWITCH_NEXT)
                    addAction(Action.SWITCH_PREVIOUS)
                    addAction(Action.SWITCH_PROFILE)
                    addAction(Action.REFRESH_WIFI_STATE)
                    addAction(Action.AUTO_SELECTOR_AUTOMATIC)
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    registerReceiver(
                        data.receiver,
                        filter,
                        "$packageName.SERVICE",
                        null,
                        Context.RECEIVER_EXPORTED
                    )
                } else {
                    registerReceiver(
                        data.receiver,
                        filter,
                        "$packageName.SERVICE",
                        null
                    )
                }
                data.closeReceiverRegistered = true
            }

            if (DataStore.serviceError.isNotEmpty()) {
                DataStore.serviceError = ""
                DataStore.serviceErrorDns = false
                DataStore.serviceErrorGeo = false
                DataStore.serviceErrorRuleSets = false
            }
            data.changeState(State.Connecting)
            // startForeground before anything can stop the service (see the link above).
            val title = ServiceNotification.genTitle(profile)
            val notification = data.notification
            if (notification == null) {
                data.notification = createNotification(title)
            } else {
                runOnMainDispatcher { notification.refresh(title) }
            }
            data.connectingJob = CoroutineScope(Dispatchers.Main).launch {
                try {
                    // The FFI path drives the core from Dart (zero AIDL): this service only
                    // keeps the foreground notification and the Android duties alive.
                    if (io.flrone.bridge.BboxKernel.ffiMode) {
                        DataStore.currentProfile = profile.id
                        data.changeState(State.Connected)
                        lateInit()
                        return@launch
                    }
                    preInit()
                    withContext(coreDispatcher) { proxy.init() }
                    DataStore.currentProfile = profile.id
                    DataStore.runningProfiles = proxy.config.involvedProfileIds.map { it.toString() }
                    DataStore.runningRouteId = proxy.routeId

                    withContext(coreDispatcher) { startProcesses() }
                    data.changeState(State.Connected)
                    runCatching { watchWifiRules(proxy) }.onFailure { Logs.w(it) }

                    lateInit()
                } catch (_: CancellationException) { // if the job was cancelled, it is canceller's responsibility to call stopRunner
                } catch (_: UnknownHostException) {
                    failRunner(getString(R.string.invalid_server))
                } catch (exc: LocalDnsFailedException) {
                    failRunner(
                        if (exc.servers.isEmpty()) getString(R.string.local_dns_failed_system)
                        else getString(R.string.local_dns_failed, exc.servers),
                        dnsSettings = true,
                    )
                } catch (exc: RuleSetDownloadFailedException) {
                    failRunner(
                        getString(R.string.rule_set_deferred_failed, DeferredRuleSets.describe(exc.readableMessage)),
                        ruleSets = true,
                    )
                } catch (exc: XrayGeoAssets.DownloadException) {
                    failRunner(
                        if (exc.fetchable) getString(R.string.xray_geo_start_download_failed, exc.readableMessage)
                        else exc.readableMessage,
                        geoSettings = true,
                    )
                } catch (exc: Throwable) {
                    // gomobile surfaces Go errors as go.Universe$proxyerror: message only, no stack worth logging
                    if (exc.javaClass.name.endsWith("proxyerror")) {
                        Logs.w(exc.readableMessage)
                    } else {
                        Logs.w(exc)
                    }
                    val geoFailure = XrayGeoAssets.describeFailure(exc.readableMessage, profile.displayName())
                    if (geoFailure != null) {
                        failRunner(geoFailure, geoSettings = true)
                    } else {
                        failRunner("${getString(R.string.service_failed)} ${exc.readableMessage}")
                    }
                } finally {
                    data.connectingJob = null
                }
            }
        }
    }

}
