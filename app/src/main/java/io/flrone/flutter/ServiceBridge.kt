package io.flrone.flutter

// The host side of the service engine's kernel channel. Only the service FlutterEngine attaches
// to `io.flrone/service`; the UI keeps its own `io.flrone/box`. The ~10 kernel methods are the
// same ones ThroneBoxBridge answers on the UI bridge, so their bodies live in
// KernelServiceActions and both bridges delegate there — no duplicated logic.

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import io.flrone.bridge.AppliedConfigStore
import io.flrone.bridge.BboxKernel
import io.nekohasekai.sagernet.bg.BaseService
import io.nekohasekai.sagernet.bg.ServiceStateRules
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.ktx.Logs
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/** Process-scoped, so an unanswered call never dies with an Activity (the service engine has none). */
private val ServiceBridgeScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

/**
 * A plain MethodChannel handler for the headless service engine, paired with a small EventChannel
 * for host-pushed events (Wi-Fi changes, reconnectIpc). It has no Activity: everything it touches
 * is process-wide (DataStore, BboxKernel, the services) or stateless (the config build, WARP).
 * Disk-bound calls hop off the channel thread and always answer on it, the same contract
 * [ThroneBoxBridge] uses.
 */
internal object ServiceBridge : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private const val CHANNEL = "io.flrone/service"
    private const val EVENTS = "io.flrone/service/events"
    private var channel: MethodChannel? = null
    private var events: EventChannel? = null

    @Volatile
    private var sink: EventChannel.EventSink? = null

    /** Called once by [ServiceEngineManager.ensureStarted] for the fresh engine. */
    fun attach(messenger: BinaryMessenger) {
        channel?.setMethodCallHandler(null)
        // FlClash binds its core channel to a background task queue
        // (ServicePlugin.onAttachedToEngine -> makeBackgroundTaskQueue). This
        // channel is the same kind of surface — headless, process-wide state
        // only — so every method call and its reply may run off the platform
        // main thread.
        val taskQueue = messenger.makeBackgroundTaskQueue()
        channel = MethodChannel(messenger, CHANNEL, StandardMethodCodec.INSTANCE, taskQueue)
            .also { it.setMethodCallHandler(this) }
        events?.setStreamHandler(null)
        events = EventChannel(messenger, EVENTS).also { it.setStreamHandler(this) }
        // The service engine is the kernel's sole owner: register the host→kernel
        // stop/reload callbacks here, at attach, so a widget/tile/notification
        // stop always reaches the one engine that holds the FFI handle. The UI
        // bridge must never overwrite these.
        BboxKernel.onReloadWanted = { notify("reload") }
        BboxKernel.onStopWanted = { revision ->
            // The revision is the one in force when the STOP command arrived:
            // if a start lands after it, the Dart side ignores this stop.
            notify("serviceStop", mapOf("revision" to revision))
        }
    }

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink?) {
        sink = eventSink
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    /** Pushes a named event to the service engine's Dart kernel on the platform thread. */
    private fun emit(type: String, value: Any?) {
        onMain {
            runCatching { sink?.success(mapOf("type" to type, "value" to value)) }
                .onFailure { Logs.w("serviceEngine: emit $type failed: ${it.message}") }
        }
    }

    /**
     * A service start reused an engine that was already running (a tile/boot start after
     * a previous session): its `serviceMain` ran long ago, so it will not auto-start this
     * one. Ask it to bring the core up from the persisted selection. The revision lets the
     * Dart side discard a stop notification that predates this start.
     */
    fun startKernel(revision: Long) {
        notifyRetrying("startKernel", mapOf("revision" to revision))
    }

    /**
     * [notify] with a short retry window.
     *
     * A freshly created engine installs its Dart handler a moment after [attach];
     * a start command that landed in that window threw MissingPluginException and
     * was dropped, so the tunnel only came up on the next unrelated command. Two
     * seconds of retries covers the engine boot; the lost-core recovery owns the
     * failure from there.
     */
    private fun notifyRetrying(method: String, args: Any?, attempt: Int = 0) {
        val ch = channel ?: return
        onMain {
            // A retry queued before a re-attach belongs to the old channel: stop
            // it instead of invoking into a handler that was cleared.
            if (ch !== channel) return@onMain
            runCatching { ch.invokeMethod(method, args) }.onFailure { error ->
                if (attempt >= 20) {
                    Logs.w("serviceEngine: $method was never delivered: ${error.message}")
                    return@onMain
                }
                Handler(Looper.getMainLooper()).postDelayed(
                    { notifyRetrying(method, args, attempt + 1) },
                    100,
                )
            }
        }
    }

    /** Host→Dart signal on the service channel (reload/serviceStop). */
    private fun notify(method: String, args: Any? = null) {
        val ch = channel ?: return
        onMain {
            runCatching { ch.invokeMethod(method, args) }
                .onFailure { Logs.w("serviceEngine: $method invoke failed: ${it.message}") }
        }
    }

    /** Avoid a redundant main-looper hop when a host callback already runs there. */
    private inline fun onMain(crossinline block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block()
        else Handler(Looper.getMainLooper()).post { block() }
    }

    /**
     * `state.markRunning`: the kernel reported a core that started.
     *
     * The service state follows the kernel's facts, not the start request: `startProxyBody`
     * leaves the service at `Connecting` exactly so this call can end it. Runs on the main
     * thread — the same thread every other state transition uses, so the read-then-promote
     * cannot interleave with a stop.
     */
    private fun noteKernelRunning() {
        val data = DataStore.baseService?.data ?: return
        data.kernelRunning = true
        if (ServiceStateRules.canPromoteToConnected(data.state)) {
            data.changeState(BaseService.State.Connected)
        } else {
            // The report is still recorded for startProxyBody's tail (it may not have run yet);
            // an already-connected or already-stopped service just has nothing to promote.
            Logs.i("serviceEngine: kernel reported running in state ${data.state}")
        }
    }

    /**
     * `state.clearRunning`: the kernel side has no core any more.
     *
     * A start that never held leaves the service at `Connecting`; taking it down is what turns
     * that into `Stopped` (the notification and the VPN icon must not outlive the core). Any
     * other state is already heading somewhere — a stop in flight, or a live tunnel whose stop
     * path owns the teardown — so it is left alone.
     */
    private fun noteKernelStopped() {
        val service = DataStore.baseService ?: return
        val data = service.data
        data.kernelRunning = false
        if (ServiceStateRules.shouldStopAfterKernelStopped(data.state)) {
            Logs.i("serviceEngine: the core never came up; stopping the service")
            service.stopRunner()
        }
    }

    /**
     * Runs [block] off the channel thread and answers with its result. A thrown exception becomes
     * a platform error the kernel can log instead of hanging on an unanswered call. The [Throwable]
     * arm matters: an `Error` (NoSuchMethodError on an old API, an ICU ExceptionInInitializerError)
     * would otherwise escape and take the process down.
     */
    private fun MethodChannel.Result.respond(block: suspend () -> Any?) {
        // A single-thread dispatcher is not available here (no Activity scope), so use the
        // default IO-bound coroutine scope provided by the helper below.
        ServiceBridgeScope.launch {
            try {
                success(block())
            } catch (e: CancellationException) {
                error("cancelled", e.message ?: "Operation cancelled", null)
                throw e
            } catch (e: Exception) {
                Logs.w(e)
                error("failed", e.message ?: e.javaClass.simpleName, null)
            } catch (e: Throwable) {
                Logs.w(e)
                error("fatal", e.message ?: e.javaClass.simpleName, null)
            }
        }
    }

    /** Synchronous answer for the pure in-memory reads; no coroutine needed. */
    private fun reply(result: MethodChannel.Result, block: () -> Any?) {
        try {
            result.success(block())
        } catch (e: Exception) {
            Logs.w(e)
            result.error("failed", e.message ?: e.javaClass.simpleName, null)
        } catch (e: Throwable) {
            Logs.w(e)
            result.error("fatal", e.message ?: e.javaClass.simpleName, null)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // config / service lifecycle
            "config.build" -> result.respond { KernelServiceActions.buildStartOptions() }
            // A15: the last accepted config, so a relaunch or a silent start does not pay for a
            // build whose inputs are unchanged. The kernel owns the reuse rule (fingerprint
            // comparison, completeness, clear-before-push); this side only persists the record.
            "config.fingerprint" -> reply(result) { AppliedConfigStore.fingerprint() }
            "config.appliedGet" -> reply(result) {
                val fingerprint = AppliedConfigStore.appliedFingerprint()
                val options = AppliedConfigStore.appliedOptions()
                if (fingerprint == null || options == null) null
                else mapOf("fingerprint" to fingerprint, "options" to options)
            }
            "config.appliedSet" -> reply(result) {
                val fingerprint = call.argument<String>("fingerprint")
                val options = call.argument<Map<String, Any?>>("options")
                if (!fingerprint.isNullOrEmpty() && options != null) {
                    AppliedConfigStore.store(fingerprint, options)
                }
                null
            }
            "config.appliedClear" -> reply(result) { AppliedConfigStore.clear(); null }
            "service.start" -> result.respond {
                val flags = (call.argument<List<*>>("flags") ?: emptyList<Any?>())
                    .mapNotNull { it as? String }
                KernelServiceActions.startServiceAndAwaitTun(flags)
                null
            }
            "service.stop" -> reply(result) { KernelServiceActions.stopService(); null }
            "service.reload" -> reply(result) { KernelServiceActions.reloadService(); null }

            // running-state writes (documents on disk: answer off the channel thread)
            "state.markRunning" -> result.respond {
                val ids = (call.argument<List<*>>("involvedProfileIds") ?: emptyList<Any?>())
                    .mapNotNull { (it as? Number)?.toLong() }
                KernelServiceActions.markRunning(ids, (call.argument<Number>("routeId"))?.toLong() ?: 0L)
                // The kernel has a started core: this — not the host's own start request — is
                // what makes the service Connected.
                onMain { noteKernelRunning() }
                null
            }
            "state.clearRunning" -> result.respond {
                KernelServiceActions.clearRunning()
                // Nothing runs any more. A service still waiting for the start that produced
                // this call would otherwise sit at Connecting forever.
                onMain { noteKernelStopped() }
                null
            }
            "state.setMode" -> result.respond {
                val mode = call.argument<String>("mode")
                    ?: throw IllegalArgumentException("Missing mode")
                KernelServiceActions.setMode(mode)
                null
            }
            "state.setCurrentRoute" -> result.respond {
                val id = call.argument<Number>("id")?.toLong()
                    ?: throw IllegalArgumentException("Missing id")
                KernelServiceActions.setCurrentRoute(id)
            }
            "state.stats" -> reply(result) {
                KernelServiceActions.publishKernelStats(
                    txRate = (call.argument<Number>("txRate"))?.toLong() ?: 0L,
                    rxRate = (call.argument<Number>("rxRate"))?.toLong() ?: 0L,
                    txTotal = (call.argument<Number>("txTotal"))?.toLong() ?: 0L,
                    rxTotal = (call.argument<Number>("rxTotal"))?.toLong() ?: 0L,
                )
                null
            }

            // Wi-Fi (ADR 0005 phase 2: settings.get is gone; the UI owns the
            // UI-only overlay and reads authoritative rows from the `ready` snapshot).
            "wifi.watch" -> reply(result) {
                val enabled = call.argument<Boolean>("enabled") == true
                // The Android Wi-Fi callback belongs to the host; every change is announced to
                // the service engine's Dart kernel, which re-reads the SSID/BSSID from
                // BboxCorePlatform. No UI event sink is involved.
                KernelServiceActions.watchWifi(enabled) { emit("wifi.state", true) }
                null
            }
            "log.note" -> result.respond {
                KernelServiceActions.note(call.argument<String>("text").orEmpty())
                null
            }

            // The service engine pushes its real FFI-attach state after
            // KernelService.initialize(). Engine existence alone is not proof
            // the driver attached: initialize() returns silently when
            // libthrone.so is absent. Gate BboxKernel.ffiMode on this fact so a
            // phantom driver cannot disable rates / no-op every kernel op.
            "driver.ready" -> reply(result) {
                BboxKernel.ffiMode = call.argument<Boolean>("ready") == true
                null
            }

            else -> result.error("unsupported", "io.flrone/service: ${call.method}", null)
        }
    }
}
