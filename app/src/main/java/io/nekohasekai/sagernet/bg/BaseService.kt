package io.nekohasekai.sagernet.bg

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.*
import android.widget.Toast
import io.flrone.bridge.BboxBridge
import io.nekohasekai.sagernet.Action
import io.nekohasekai.sagernet.BootReceiver
import io.nekohasekai.sagernet.R
import io.nekohasekai.sagernet.SagerNet
import io.nekohasekai.sagernet.appwidget.Widgets
import io.nekohasekai.sagernet.bg.autoselector.AutoSelectorRuntime
import io.nekohasekai.sagernet.bg.proto.DeferredRuleSets
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.ProfileOrder
import io.nekohasekai.sagernet.ktx.*
import io.nekohasekai.sagernet.utils.DefaultNetworkListener
import io.nekohasekai.sagernet.utils.PlatformNotifications
import io.nekohasekai.sagernet.utils.WifiStateAccess
import kotlinx.coroutines.*
import moe.matsuri.nb4a.utils.Util

class BaseService {

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

        /**
         * Whether the Dart kernel has reported this run's core as started (`state.markRunning`).
         *
         * The kernel's own start runs in parallel with [startProxyBody]'s notification work, so the
         * report can land *before* the tail announces `Connecting`. This latch carries it across that
         * window instead of dropping it and leaving the service stuck at `Connecting`. Cleared when a
         * start begins, and when the kernel reports nothing running any more. Written on the main
         * thread (from the service bridge); `@Volatile` for the body's read off it.
         */
        @Volatile
        var kernelRunning = false

        /**
         * The running profile's id and display name. Since P6 the service engine's Dart kernel owns the core, so
         * there is no host-side ProxyInstance any more: notifications, widgets and the bridge read these instead.
         */
        var runningProfileId: Long = 0L
        var runningProfileName: String = ""

        var notification: ServiceNotification? = null
        var wifiMonitor: WifiStateAccess.Monitor? = null

        /** The engine args of the last start intent ("quick"/"boot"), kept for in-place restarts. */
        var engineArgs: List<String> = emptyList()

        /**
         * Whether the last start command was the platform's always-on VPN start rather than one the
         * app issued (`BootGate.isPlatformAlwaysOnStart`: the platform passes the
         * `android.net.VpnService` action, every app start passes none). Such a start carries no
         * engine args, so the boot gate needs this bit to tell it apart from a user start. Kept
         * beside [engineArgs] for the same reason: an in-place restart calls `startProxy()` later
         * without an intent.
         */
        var alwaysOnStart = false

        val receiver = broadcastReceiver { ctx, intent ->
            when (intent.action) {
                Intent.ACTION_SHUTDOWN -> service.persistStats()
                Action.RELOAD -> service.reload()
                Action.CLOSE -> service.stopRunner()
                Action.SWITCH_NEXT -> service.switchRelative(1)
                Action.SWITCH_PREVIOUS -> service.switchRelative(-1)
                Action.SWITCH_PROFILE -> service.switchProfile(intent.getLongExtra(Action.EXTRA_PROFILE_ID, 0L))
                Action.REFRESH_WIFI_STATE -> afterStart { io.flrone.bridge.BboxKernel.onWifiChanged?.invoke() }
                Action.AUTO_SELECTOR_AUTOMATIC -> AutoSelectorRuntime.releasePin(intent.getLongExtra(Action.EXTRA_PROFILE_ID, 0L))

                // The running core belongs to Dart now; there is no host box whose connections can be reset.
                Action.RESET_UPSTREAM_CONNECTIONS -> runOnMainDispatcher {
                    Util.collapseStatusBar(ctx)
                    Toast.makeText(ctx, "Reset upstream connections done", Toast.LENGTH_SHORT).show()
                }
            }
        }

        /** Runs [block] once a start in progress is over. */
        private fun afterStart(block: () -> Unit) {
            val job = connectingJob?.takeIf { it.isActive } ?: return block()
            runOnMainDispatcher {
                job.join()
                block()
            }
        }

        var closeReceiverRegistered = false
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
            // Service + UI share one process: publish straight into the bridge instead of
            // dispatching a stateChanged callback over the (now removed) ISagerNetService binder.
            BboxBridge.onServiceState(s, msg)
            Widgets.push(service as Context)
            // No AIDL callback to the tile: a listening-state request is enough for the tile to
            // re-read DataStore directly.
            TileUpdater.refresh(service as Context)
        }
    }

    interface Interface {
        val data: Data
        val tag: String
        fun createNotification(profileName: String): ServiceNotification

        /** No bound service any more: the UI, widget and tile all read DataStore in this process. */
        fun onBind(intent: Intent): IBinder? = null

        fun reload() {
            // The service engine is the kernel's sole owner: a widget/tile/notification reload
            // asks its Dart driver to rebuild the core instead of bouncing the foreground service.
            io.flrone.bridge.BboxKernel.onReloadWanted?.invoke()
        }

        /** Runs [id] instead of the current profile, staying in the foreground; the running profile is left alone. */
        fun switchProfile(id: Long) {
            if (id <= 0L) return
            DataStore.selectedProxy = id
            val s = data.state
            if (s.canStop && data.runningProfileId == id) return
            // Same-process replacement for cbSelectorUpdate: update the shared store and let the
            // bridge republish, so the tile/notification and the UI all see the new selection.
            BboxBridge.onSelectedProfile(id)
            TileUpdater.refresh(this as Context)
            // The Dart kernel reloads on selection change through the bridge; a service restart
            // here would only bounce the notification.
            Widgets.push(this as Context)
        }

        /** The neighbour [step] away in the group of the selected profile, wrapping around. */
        fun switchRelative(step: Int) {
            val current = DataStore.selectedProxy.takeIf { it > 0L }
                ?: data.runningProfileId.takeIf { it > 0L } ?: return
            val target = ProfileOrder.neighbour(current, step) ?: return
            switchProfile(target.id)
        }

        fun startRunner() {
            this as Context
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(Intent(this, javaClass))
            else startService(Intent(this, javaClass))
        }

        suspend fun killProcesses(): Throwable? {
            var cleanupError: Throwable? = null
            fun recordCleanupFailure(stage: String, error: Throwable) {
                if (cleanupError == null) {
                    cleanupError = error
                } else if (cleanupError !== error) {
                    cleanupError?.addSuppressed(error)
                }
                Logs.w("ServiceLifecycleTrace stage=$stage failed type=${error.javaClass.name} message=${error.message}")
            }
            try {
                data.wifiMonitor?.stop()
            } catch (error: Throwable) {
                recordCleanupFailure("wifi-monitor-stop", error)
            } finally {
                data.wifiMonitor = null
            }
            try {
                DefaultNetworkListener.stop(this)
            } catch (error: Throwable) {
                recordCleanupFailure("network-listener-stop", error)
            }
            // There is no host-owned box to close: the service engine's Dart kernel owns and
            // closes the core itself (onStopWanted in stopRunner).
            return cleanupError
        }

        /**
         * A restart keeps the service, its notification and the receiver: the new core starts in place, so a switch
         * from the notification or a widget never needs another foreground-service start from the background.
         */
        fun stopRunner(restart: Boolean = false, msg: String? = null) {
            // The revision in force when this stop command arrived. A start that
            // lands later claims a higher one, so this stop's delayed
            // notification is ignored instead of killing the new run.
            val stopRevision = io.flrone.flutter.ServiceEngineManager.currentCommandRevision()
            DataStore.baseService = null
            DataStore.vpnService = null

            if (data.state == State.Stopping) {
                // the old core now closes off the main thread, so a Stop can arrive in the middle of a restart
                if (!restart) data.stopRequested = true
                return
            }
            this as Service

            data.stopRequested = false
            data.changeState(State.Stopping)
            val originalMessage = msg

            runOnMainDispatcher {
                // A non-Dart stop (widget/tile/notification) is forwarded by the service bridge to
                // the service engine's Dart kernel, which owns the only FFI handle and closes the
                // core itself. A restart keeps its core — it is an in-place rebuild, not a stop.
                if (!restart) io.flrone.bridge.BboxKernel.onStopWanted?.invoke(stopRevision)
                var cleanupError: Throwable? = null
                fun recordCleanupFailure(stage: String, error: Throwable) {
                    if (cleanupError == null) {
                        cleanupError = error
                    } else if (cleanupError !== error) {
                        cleanupError?.addSuppressed(error)
                    }
                    Logs.w(
                        "ServiceStopTrace stage=$stage failed type=${error.javaClass.name} " +
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
                data.runningProfileId = 0L
                data.runningProfileName = ""

                if (cleanupError != null) {
                    Logs.w("ServiceStopTrace stage=cleanup failed suppressed=${cleanupError?.suppressed?.size} " +
                        "originalMessagePreserved=${originalMessage != null}")
                }

                try {
                    data.changeState(State.Stopped, originalMessage)
                } catch (error: Throwable) {
                    recordCleanupFailure("state-stopped", error)
                }
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
                            // The engine stays for the life of the process: it owns the kernel's
                            // Dart state (action completers, subscriptions) and destroying it here
                            // would race the `service.stop` reply the kernel is still awaiting.
                            stopSelf()
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
         * offers the DNS settings with it when [dnsSettings], a start without the rule-sets when [ruleSets].
         */
        fun failRunner(message: String, dnsSettings: Boolean = false, ruleSets: Boolean = false) {
            if (data.state != State.Stopping) {
                DataStore.serviceError = message
                DataStore.serviceErrorDns = dnsSettings
                DataStore.serviceErrorGeo = false
                DataStore.serviceErrorRuleSets = ruleSets
            }
            stopRunner(false, message)
        }

        fun persistStats() {
            // TODO NEW save app stats?
        }

        suspend fun lateInit() {
            data.notification?.postConnected()
        }

        /**
         * Dart pushes the kernel's status snapshot over `state.stats` once a second. This is the only
         * source of the notification's speed line and the widget now: the service owns no
         * TrafficUpdater (that needed a ProxyInstance) since the kernel moved into the engine.
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

        /**
         * A notification setting (buttons, show-group) changed while the service runs: the
         * General page promises these apply on the next notification update with no restart,
         * and the buttons plus the group name in the title are exactly the two things that
         * used to wait for a reconnect.
         */
        suspend fun applyNotificationSettings() {
            val notification = data.notification ?: return
            // The title bakes the group name in at connect time (genTitle); re-derive it so a
            // showGroupInNotification flip reaches the notification now.
            val profile = io.nekohasekai.sagernet.database.ProfileManager.getProfile(
                data.runningProfileId.takeIf { it > 0L } ?: DataStore.selectedProxy,
            )
            if (profile != null) {
                data.runningProfileName = ServiceNotification.genTitle(profile)
            }
            notification.updateActions()
            notification.postNotificationTitle(data.runningProfileName)
        }

        /**
         * Wi-Fi rules (route, DNS or rule-set ones) need location access and a fresh Wi-Fi state on roaming.
         * The core that re-reads the state is Dart's; only the Android callback lives here.
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
            // A platform always-on start carries no engine args — only its action says it was not
            // the user. Recorded per start command so a later user start clears it.
            data.alwaysOnStart = io.flrone.bridge.BootGate.isPlatformAlwaysOnStart(intent?.action)

            // START_STICKY: when the system reclaims the service under memory pressure it is
            // restarted with a null intent, so the proxy reconnects instead of silently dropping.
            // A user-initiated stop still ends it for good, because stopRunner() calls stopSelf().
            if (data.state != State.Stopped) {
                if (data.state == State.Stopping) data.startRequested = true
                return Service.START_STICKY
            }
            startProxy()
            return Service.START_STICKY
        }

        /** Starts the selected profile; the notification and the receiver of a restart are reused. */
        fun startProxy() {
            // A start command claims the next revision: a stop notification
            // carrying an older one is stale and must not kill this run.
            val startRevision = io.flrone.flutter.ServiceEngineManager.nextCommandRevision()
            DataStore.baseService = this
            // Bring up (or reuse) the headless service engine that owns the kernel. Idempotent,
            // so an in-place restart or a second start command keeps the same engine. Args come
            // from the intent (tile/boot/widget silent start) or the pending slot.
            val engineArgs = data.engineArgs.ifEmpty { SagerNet.takePendingEngineArgs() }
            // Boot guard (wave 4): the engine's own 300 ms auto-start is the app's only launch-time
            // automatic start, so it must not repeat a launch that died before the UI came up. The
            // marker is a mirror of Dart's BootGuard record: this process may hold no Flutter engine
            // at all, and the record lives in the UI's preferences document (`BootGate`).
            val bootBlocked = io.flrone.bridge.BootGate.shouldSkipAutoStart(
                io.flrone.bridge.BootGate.mirrorFile((this as Context).filesDir),
                System.currentTimeMillis(),
            )
            // `data.alwaysOnStart` is the start that carries no flag at all: the platform's
            // always-on VPN start. Treating it as silent is the whole point — it is exactly the
            // repeat-a-died-launch case, and the app never issues it for the user.
            val gatedArgs = io.flrone.bridge.BootGate.gateEngineArgs(
                engineArgs,
                bootBlocked,
                data.alwaysOnStart,
            )
            // `true` when this start created the engine: a fresh engine's serviceMain runs the
            // start itself from the args, while a reused one (or a prewarm that finished first)
            // needs the explicit command. Sampling isRunning() before the call was the race: a
            // prewarm in flight read as "not running", the command was skipped, and the PREWARM
            // args never bring the tunnel up.
            val createdNow = io.flrone.flutter.ServiceEngineManager.ensureStarted(gatedArgs)
            // A gated silent start leaves the fresh engine idle (PREWARM), so nothing will bring
            // the core up — and startProxyBody leaves the service at Connecting waiting for the
            // kernel's `state.markRunning`, which a gated engine never sends, i.e. a start that is
            // not there. Stop the service instead; that is also how a startForegroundService()
            // caller is answered without startForeground().
            // The reused-engine path below stays as it is for quick/boot: the 300 ms auto-start
            // exists only on a fresh engine, and a reused engine's explicit start is a later
            // user/tile intent. An always-on start is the exception: nobody tapped it, and its
            // tunnel comes up through startKernel() below rather than through the 300 ms
            // auto-start, so `createdNow` alone would let it through whenever a prewarm won the race.
            if ((bootBlocked && data.alwaysOnStart) || (createdNow && gatedArgs != engineArgs)) {
                val trigger = if (data.alwaysOnStart) "always-on" else "quick/boot"
                Logs.i(
                    "serviceEngine: boot gate held the automatic start ($trigger; " +
                        "documents/boot_guard.json says the previous launch was still starting)"
                )
                data.startRequested = false
                data.changeState(State.Stopped)
                DataStore.baseService = null
                this as Service
                stopSelf()
                return
            }
            // A new start invalidates the previous run's kernel report: nothing is promoted to
            // Connected until the kernel says this run's core started.
            data.kernelRunning = false
            if (!createdNow) io.flrone.flutter.ServiceBridge.startKernel(startRevision)
            // The FFI core opens the tun through CorePlatform.openTun while it starts. Register
            // the live VpnService here, before the core can ask for the interface.
            if (this is VpnService) DataStore.vpnService = this
            val data = data
            data.startRequested = false
            // FlClash hands the whole start to a Dispatchers.Default scope
            // (ServiceState.requestStart -> host.scope.launch { start }); only bindService is
            // main-bound there. Everything below reads documents, rewrites settings rows and
            // builds the notification — none of it may run on the thread that serves Flutter
            // frames: at tap time that cluster was the remaining start-button jank.
            val ctx = this as Context
            data.connectingJob?.cancel()
            data.connectingJob = CoroutineScope(Dispatchers.Default).launch {
                try {
                    startProxyBody()
                } catch (_: CancellationException) { // canceller's responsibility to call stopRunner
                } catch (exc: Throwable) {
                    Logs.w(exc)
                    failRunner("${ctx.getString(R.string.service_failed)} ${exc.readableMessage}")
                } finally {
                    data.connectingJob = null
                }
            }
        }

        /** [startProxy]'s document, settings and notification half. Never on the main thread. */
        private suspend fun startProxyBody() {
            val data = data
            // ADR 0005: read the selected profile through the Dart-owned document.
            val profile = io.nekohasekai.sagernet.database.ProfileManager.getProfile(DataStore.selectedProxy)
            this as Context
            if (profile == null) { // gracefully shutdown: https://stackoverflow.com/q/47337857/2245107
                if (data.notification == null) data.notification = createNotification("")
                onNoProfile()
                stopRunner(false, getString(R.string.profile_empty))
                return
            }
            PlatformNotifications.cancelAlwaysOnNoProfile(this)

            data.runningProfileId = profile.id
            data.runningProfileName = ServiceNotification.genTitle(profile)
            BootReceiver.enabled = DataStore.rememberEnable
            if (!data.closeReceiverRegistered) {
                val filter = IntentFilter().apply {
                    addAction(Action.RELOAD)
                    addAction(Intent.ACTION_SHUTDOWN)
                    addAction(Action.CLOSE)
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
            // The kernel's own start runs in parallel with the notification work below, so its
            // `state.markRunning` may already have landed: announce the state this run is really
            // in instead of stepping back to Connecting over a connected core.
            data.changeState(if (data.kernelRunning) State.Connected else State.Connecting)
            // startForeground before anything can stop the service (see the link above).
            val title = data.runningProfileName
            val notification = data.notification
            if (notification == null) {
                data.notification = createNotification(title)
            } else {
                runOnMainDispatcher { notification.refresh(title) }
            }
            // The kernel is driven from Dart (zero AIDL): this service only keeps the
            // foreground notification and the Android duties alive. The engine reports
            // runningProfiles/runningRouteId once the core is actually up.
            DataStore.currentProfile = profile.id
            // `Connected` is the kernel's report, not this body's guess: `state.markRunning`
            // announces it once worker.start() succeeded (ServiceBridge). The service stays
            // Connecting until then — an announcement here used to precede any core and left the
            // notification, tile and VPN icon claiming a tunnel that did not exist. That report
            // can also land while the notification above is being built, so honour it here too.
            if (data.kernelRunning) data.changeState(State.Connected)
            lateInit()
        }
    }
}
