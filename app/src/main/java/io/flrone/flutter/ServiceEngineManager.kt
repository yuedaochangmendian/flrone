package io.flrone.flutter

import android.content.Context
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineGroup
import io.flutter.embedding.engine.dart.DartExecutor
import io.flrone.bridge.BboxKernel
import io.nekohasekai.sagernet.SagerNet
import io.nekohasekai.sagernet.ktx.Logs

/**
 * Owns the second, headless Flutter engine that runs the kernel.
 *
 * Today the UI engine's worker isolate drives the core over dart:ffi. This manager adds a
 * dedicated **service engine** in the same process (the services are not pinned to `:bg`): the
 * kernel moves into its `serviceMain` entrypoint and the UI engine becomes UI-only. The group is
 * created once by [SagerNet] right after `FlutterInjector.startInitialization`, because a
 * `FlutterEngineGroup` must be built after the loader has started or cold engine creation fails.
 *
 * Everything here is guarded by the object's monitor: a tile tap, always-on VPN, a widget and the
 * UI can all ask to start at once, and only one engine may ever exist. The engine is cached for
 * the life of the process — destroying and recreating it on a quick stop/start would relaunch the
 * Dart isolate and drop the kernel's in-memory state. [destroy] is reserved for the real teardown
 * (the service self-stops); [reconnectIpc] is the hook the UI uses when its engine was recreated.
 */
object ServiceEngineManager {

    /** The Dart entrypoint the service engine runs (added by the Dart side in P6). */
    private const val SERVICE_ENTRYPOINT = "serviceMain"

    /** Silent-start flags, mirroring Bettbox's arg semantics. */
    const val ARG_QUICK = "quick"
    const val ARG_BOOT = "boot"

    /** Pre-warm marker: the engine comes up idle and must not auto-start the tunnel. */
    const val ARG_PREWARM = "prewarm"

    @Volatile
    private var engineGroup: FlutterEngineGroup? = null

    @Volatile
    private var serviceEngine: FlutterEngine? = null

    /**
     * Commands (start/stop) get a monotonic revision. FlClash's notifyStopped
     * carries the commandRevision it answers so a delayed stop report cannot
     * kill a run started after it — the same contract here, one counter.
     */
    @Volatile
    private var commandRevision = 0L

    @Synchronized
    fun nextCommandRevision(): Long = ++commandRevision

    fun currentCommandRevision(): Long = commandRevision

    /** The args the running engine was created with, for diagnostics. */
    @Volatile
    private var startedArgs: List<String> = emptyList()

    /**
     * Called by [SagerNet.onCreate] after `FlutterInjector.instance().flutterLoader()
     * .startInitialization(this)`. Safe to call twice; the first group wins.
     */
    @Synchronized
    fun install(context: Context) {
        if (engineGroup != null) return
        engineGroup = try {
            FlutterEngineGroup(context.applicationContext)
        } catch (error: Throwable) {
            // A null group is recoverable: ensureStarted logs and no-ops instead of crashing the
            // app. The UI engine still works, so a service-engine failure is not fatal at startup.
            Logs.w("serviceEngine: FlutterEngineGroup creation failed: ${error.message}")
            null
        }
    }

    /**
     * Brings the kernel engine up idle before any start is tapped. The first start otherwise
     * pays `System.loadLibrary` + `createAndRunEngine` on the main thread inside the tap's
     * `service.start` — the frame drop seen as button jank. The [ARG_PREWARM] args keep
     * serviceMain's one-shot auto-start from bringing the tunnel up; a real start later takes
     * the reused-engine path (`ServiceBridge.startKernel()`).
     */
    fun prewarm() {
        ensureStarted(listOf(ARG_PREWARM))
    }

    /** Idempotent: multiple callers from different threads share one engine. */
    @Synchronized
    fun ensureStarted(args: List<String>) {
        if (serviceEngine != null) {
            // Already up. A later caller cannot change the entrypoint args; remember only that a
            // start was requested so a future destroy/restart can honour the last flags.
            BboxKernel.ffiMode = true
            return
        }
        // The service engine is the sole owner of the kernel while it exists. The flag is set
        // only after the engine is created: a failure here leaves the service's own path intact
        // instead of marking the tunnel "Dart-owned" with nothing behind it.
        // A missing/unloadable libthrone.so makes the service engine useless: without this gate
        // ffiMode would be true while KernelService.initialize() silently returns, leaving a
        // connected notification with no tunnel. Fall back to the service-side box instead.
        if (runCatching { System.loadLibrary("throne") }.isFailure) {
            Logs.w("serviceEngine: libthrone.so is unavailable; keeping the service-side box")
            return
        }
        val group = engineGroup ?: run {
            Logs.w("serviceEngine: cannot start before FlutterEngineGroup is installed")
            return
        }
        val entrypoint = DartExecutor.DartEntrypoint(
            FlutterInjector.instance().flutterLoader().findAppBundlePath(),
            SERVICE_ENTRYPOINT,
        )
        val options = FlutterEngineGroup.Options(SagerNet.application).apply {
            dartEntrypoint = entrypoint
            dartEntrypointArgs = args
        }
        val engine = try {
            group.createAndRunEngine(options)
        } catch (error: Throwable) {
            Logs.w("serviceEngine: createAndRunEngine failed: ${error.message}")
            return
        }
        // GeneratedPluginRegistrant wires the plugins the Flutter module declares (file picker,
        // connectivity, path provider, ...). This host links the module as an AAR instead of
        // applying the Flutter Gradle plugin, so the class is not guaranteed to exist in this
        // module's compile classpath; reflect over it so the service engine still builds and
        // simply skips plugin registration when the host does not ship one.
        runCatching {
            Class.forName("io.flutter.plugins.GeneratedPluginRegistrant")
                .getMethod("registerWith", FlutterEngine::class.java)
                .invoke(null, engine)
        }.onFailure { Logs.w("serviceEngine: plugin registration failed: ${it.message}") }
        // Throne has no native FlutterPlugin classes (unlike Bettbox's VpnPlugin/AppPlugin/
        // TilePlugin/ServicePlugin): its host work is done by plain MethodChannels installed on
        // whichever engine asked for them. The kernel channel is installed below on this engine.
        ServiceBridge.attach(engine.dartExecutor.binaryMessenger)
        serviceEngine = engine
        // The engine now owns the kernel; every service path must stop building a host box.
        BboxKernel.ffiMode = true
        startedArgs = args
        Logs.i("serviceEngine: started with args=${args.joinToString()}")
    }

    /** True while a service engine exists. */
    fun isRunning(): Boolean = serviceEngine != null

    /** The args the running engine was created with (empty when not running). */
    fun currentArgs(): List<String> = startedArgs

    /**
     * Tears down the engine only on a real stop. [force] is false for the normal case, where a
     * config change / in-place restart must keep the engine (and its kernel state) alive; passing
     * true from the service's own stop path is what actually releases it. Because the engine is
     * process-scoped, a UI that is still up keeps working — only the kernel engine goes away.
     */
    @Synchronized
    fun destroy(force: Boolean = true) {
        val engine = serviceEngine ?: return
        if (!force) return
        serviceEngine = null
        startedArgs = emptyList()
        ServiceBridge.detach()
        BboxKernel.ffiMode = false
        runCatching { engine.destroy() }.onFailure { Logs.w("serviceEngine: destroy failed: ${it.message}") }
        Logs.i("serviceEngine: destroyed")
    }

    /**
     * Called when the UI engine was recreated and must rebind to the kernel. Pushes a real
     * `reconnectIpc` call to the service engine's Dart side; in-process stage 1 the channel is
     * always live, but the Dart kernel still uses this to refresh anything tied to the UI engine.
     */
    @Synchronized
    fun reconnectIpc() {
        if (serviceEngine == null) return
        ServiceBridge.reconnectIpc()
    }
}
