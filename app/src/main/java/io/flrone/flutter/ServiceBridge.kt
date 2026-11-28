package io.flrone.flutter

// The host side of the service engine's kernel channel. Only the service FlutterEngine attaches
// to `io.flrone/service`; the UI keeps its own `io.flrone/box`. The ~10 kernel methods are the
// same ones FlronePlatformBridge answers on the UI bridge, so their bodies live in
// KernelServiceActions and both bridges delegate there — no duplicated logic.

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import io.flrone.bridge.AppliedConfigStore
import io.flrone.bridge.DartProfileStore
import io.flrone.bridge.FlroneBridge
import io.flrone.bridge.FlroneKernel
import io.flrone.bridge.FlroneProfileDuty
import io.nekohasekai.sagernet.bg.BaseService
import io.nekohasekai.sagernet.bg.CoreForeground
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
 * for host-pushed events (Wi-Fi changes). It has no Activity: everything it touches
 * is process-wide (DataStore, FlroneKernel, the services) or stateless (the config build, WARP).
 * Disk-bound calls hop off the channel thread and always answer on it, the same contract
 * [FlronePlatformBridge] uses.
 */
internal object ServiceBridge : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private const val CHANNEL = "io.flrone/service"
    private const val EVENTS = "io.flrone/service/events"
    private var channel: MethodChannel? = null
    private var events: EventChannel? = null

    @Volatile
    private var sink: EventChannel.EventSink? = null

    // Latest desired doze value. Doze broadcasts can arrive before the service
    // engine (and its Dart handler) exist; cache the value and flush it as soon
    // as the channel attaches, so an early enter-doze is never lost.
    @Volatile
    private var dozeWanted: Boolean? = null

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
        FlroneKernel.onReloadWanted = { notify("reload") }
        FlroneKernel.onStopWanted = { revision ->
            // The revision is the one in force when the STOP command arrived:
            // if a start lands after it, the Dart side ignores this stop.
            notify("serviceStop", mapOf("revision" to revision))
        }
        // An engine can be created after a doze transition (e.g. a boot while
        // the device is already idle, or the engine being rebuilt). Replay the
        // last desired value with a generous retry window so it lands once the
        // Dart handler is installed.
        flushPendingDoze()
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
     *
     * Fail closed: if the worker never accepts the command ([notifyRetrying] exhausts
     * its window), the cached engine is reported as failed so the next start recreates
     * it. The start itself is failed here — the service must not sit at `Connecting`
     * ("Starting") forever waiting for a kernel report that cannot arrive.
     */
    fun startKernel(revision: Long) {
        notifyRetrying(
            "startKernel",
            mapOf("revision" to revision),
            onGiveUp = { reason ->
                ServiceEngineManager.noteEngineUndeliverable(reason)
                // No kernel ever received the start: clear any running claim and
                // take a service still at Connecting down (same terminal report
                // the kernel's `state.clearRunning` would have sent).
                onMain { noteKernelStopped() }
            },
        )
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
    private fun notifyRetrying(
        method: String,
        args: Any?,
        attempt: Int = 0,
        maxAttempts: Int = 20,
        onGiveUp: ((String) -> Unit)? = null,
    ) {
        val ch = channel
        if (ch == null) {
            // No engine channel at all: a start cannot be delivered, so it is a
            // failed engine (not a silent no-op that leaves the service at
            // Connecting). Report the same terminal path as an exhausted retry.
            if (onGiveUp != null) {
                val reason = "$method was never delivered: no service channel"
                Logs.w("serviceEngine: $reason")
                onGiveUp(reason)
            }
            return
        }
        onMain {
            // A retry queued before a re-attach belongs to the old channel: stop
            // it instead of invoking into a handler that was cleared.
            if (ch !== channel) return@onMain
            runCatching { ch.invokeMethod(method, args) }.onFailure { error ->
                if (attempt >= maxAttempts) {
                    val reason = "$method was never delivered: ${error.message}"
                    Logs.w("serviceEngine: $reason")
                    onGiveUp?.invoke(reason)
                    return@onMain
                }
                Handler(Looper.getMainLooper()).postDelayed(
                    { notifyRetrying(method, args, attempt + 1, maxAttempts, onGiveUp) },
                    100,
                )
            }
        }
    }

    /**
     * Host→Dart device-doze hint. The value is cached so a command that arrives
     * before the engine exists (screen/idle broadcast during boot) is flushed
     * on attach. A generous retry window (100 × 100 ms = 10 s) covers a slow
     * engine boot, which can take seconds on a cold start.
     */
    fun setDoze(enabled: Boolean) {
        dozeWanted = enabled
        notifyRetrying("setDoze", mapOf("enabled" to enabled), maxAttempts = 100)
    }

    /** Replays the last cached doze value to a freshly attached engine. */
    fun flushPendingDoze() {
        dozeWanted?.let { notifyRetrying("setDoze", mapOf("enabled" to it), maxAttempts = 100) }
    }

    /**
     * S6: asks the service engine's Dart subscription queue to run one command.
     * The queue lives in the engine that owns the profiles document; Kotlin is
     * only the trigger. [action] is `subscription.refresh`,
     * `subscription.refreshAll` or `subscription.awaitIdle`.
     */
    fun requestSubscription(action: String, args: Map<String, Any?> = emptyMap()) {
        notify(action, args)
    }

    /**
     * Host→Dart request for a Go collection (best effort, no reply needed).
     * [full] selects `debug.FreeOSMemory()`; false is the light `runtime.GC()`
     * used for ordinary trim levels. The level is mandatory all the way down:
     * the Go handler refuses a missing flag rather than defaulting to full.
     */
    fun forceGc(full: Boolean) = notify("forceGc", mapOf("full" to full))

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

    /**
     * S6: a narrow Kotlin duty that rides inside the owner's document write
     * path (GroupSort reposition, the newest-intent bump before a configuration
     * save, the poller re-plan after a URL edit). The UI relays these to the
     * owner, which invokes them here; they never cross the UI's box bridge.
     */
    private suspend fun forwardDuty(call: MethodCall): Any? {
        @Suppress("UNCHECKED_CAST")
        val payload = call.argument<Map<String, Any?>>("payload").orEmpty()
        return FlroneProfileDuty.invoke(call.method, payload)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // config / service lifecycle
            "config.prepare" -> result.respond { KernelServiceActions.prepareStart() }
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
            // No reload arm here: the UI's reload action goes to the box bridge, and a
            // host-driven reload reaches the engine as a notify event (see attach).

            // running-state writes (documents on disk: answer off the channel thread)
            "state.markRunning" -> result.respond {
                val ids = (call.argument<List<*>>("involvedProfileIds") ?: emptyList<Any?>())
                    .mapNotNull { (it as? Number)?.toLong() }
                KernelServiceActions.markRunning(ids)
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
                // FlroneCorePlatform. No UI event sink is involved.
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
            // libthrone.so is absent. Gate FlroneKernel.ffiMode on this fact so a
            // phantom driver cannot disable rates / no-op every kernel op.
            "driver.ready" -> reply(result) {
                FlroneKernel.ffiMode = call.argument<Boolean>("ready") == true
                null
            }

            // S6 document owner: the service engine's kernelWorker resolves the
            // profiles document path from this fact (it has no Activity to ask),
            // plus the localized default group name the manifest renderer needs.
            "document.path" -> reply(result) {
                val dir = DartProfileStore.directory
                if (dir == null) {
                    throw IllegalStateException("documents directory is not mounted")
                }
                mapOf(
                    "directory" to dir.absolutePath,
                    "defaultGroupName" to
                        io.nekohasekai.sagernet.database.GroupRepo.defaultGroupName(),
                )
            }
            // S6: an owner write landed on disk; drop the Kotlin read cache and
            // schedule the catalog push. The UI engine no longer calls the box
            // bridge's data.refresh for document writes — the owner's own host
            // bridge (this one) is the single place that invalidates.
            "data.refresh" -> reply(result) {
                DartProfileStore.invalidate()
                FlroneBridge.scheduleRefresh(immediate = true)
                null
            }
            // S6: the narrow Kotlin duties that ride inside the owner's document
            // write path (revision bump before a configuration save, the poller
            // re-plan after a URL edit, GroupSort's test-result reposition). The
            // UI never calls these directly any more: box_api routes them
            // through the owner so they run in the same serialized write path.
            "sort.reposition" -> result.respond { forwardDuty(call) }
            "revision.edit" -> result.respond { forwardDuty(call) }
            "subscription.schedule" -> result.respond { forwardDuty(call) }
            // S6: the Dart subscription queue's foreground hold. The queue
            // lives in the service engine, but CoreForeground is an Android
            // fact; the engine asks here for each foreground job.
            "subscription.foreground" -> reply(result) {
                val active = call.argument<Boolean>("active") == true
                if (active) {
                    CoreForeground.acquire("subscriptions")
                } else {
                    CoreForeground.release("subscriptions")
                }
                null
            }

            else -> result.error("unsupported", "io.flrone/service: ${call.method}", null)
        }
    }
}
