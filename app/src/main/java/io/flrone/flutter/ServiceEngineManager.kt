package io.flrone.flutter

import android.content.Context
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.nekohasekai.sagernet.ktx.Logs

/**
 * Owns the second, headless Flutter engine that runs the kernel.
 *
 * Today the UI engine's worker isolate drives the core over dart:ffi. This manager adds a
 * dedicated **service engine** in the same process (the services are not pinned to `:bg`): the
 * kernel moves into its `serviceMain` entrypoint and the UI engine becomes UI-only.
 *
 * **The engine is created standalone, not spawned from a FlutterEngineGroup.** A group spawn
 * runs `Dart_CreateIsolateInGroup` (engine `RuntimeController::Spawn`), which puts the service
 * isolate in the *same isolate group* as the UI isolate — and the Dart VM keeps one heap per
 * isolate group (`isolate.cc`: `group()->heap()`), with a group-wide stop-the-world collector.
 * Under that sharing, every allocation the service engine makes while it starts — decoding the
 * `config.build` reply (the whole core config), creating the core instance, the event and log
 * traffic that follows — grows the UI isolate's heap and its GC pauses stop the UI isolate's
 * frame pipeline. That is precisely the start-only frame drop the card has always shown, and
 * FlClash never pays it: its core runs in Kotlin/Go on Dispatchers.Default and allocates nothing
 * in the UI isolate's heap. A standalone `FlutterEngine` gets its own isolate group, heap and
 * collector; the engines then share only the process. The cost is paid once at pre-warm
 * (creation is somewhat slower than a group spawn) and messages between them are copied instead
 * of passed by reference — both are irrelevant for handshake-sized maps.
 *
 * Everything here is guarded by the object's monitor: a tile tap, always-on VPN, a widget and the
 * UI can all ask to start at once, and only one engine may ever exist. The engine is cached for
 * the life of the process — destroying and recreating it on a quick stop/start would relaunch the
 * Dart isolate and drop the kernel's in-memory state, so there is deliberately **no teardown
 * path**: a user stop leaves the engine warm for the next start, and only process death releases
 * it. [EngineState] reports where an engine creation stands for diagnostics.
 */
object ServiceEngineManager {

    /** The Dart entrypoint the service engine runs (added by the Dart side in P6). */
    private const val SERVICE_ENTRYPOINT = "serviceMain"

    /** Silent-start flags, mirroring Bettbox's arg semantics. */
    const val ARG_QUICK = "quick"
    const val ARG_BOOT = "boot"

    /** Pre-warm marker: the engine comes up idle and must not auto-start the tunnel. */
    const val ARG_PREWARM = "prewarm"

    /** The application context [install] was handed; a standalone engine needs one. */
    @Volatile
    private var appContext: Context? = null

    /** Where the engine is in its one-time creation, for diagnostics and joins. */
    enum class EngineState { idle, creating, ready, failed }

    @Volatile
    var state: EngineState = EngineState.idle
        private set

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



    /**
     * Called by [io.nekohasekai.sagernet.SagerNet.onCreate] after `FlutterInjector.instance()
     * .flutterLoader().startInitialization(this)`. Only records the context a later standalone
     * engine is built from; engine creation itself is lazy ([prewarm]/[ensureStarted]).
     */
    @Synchronized
    fun install(context: Context) {
        if (appContext != null) return
        appContext = context.applicationContext
    }

    /**
     * Brings the kernel engine up idle before any start is tapped. The first start otherwise
     * pays `System.loadLibrary` + `createAndRunEngine` on the main thread inside the tap's
     * `service.start` — the frame drop seen as button jank. The [ARG_PREWARM] args keep
     * serviceMain's one-shot auto-start from bringing the tunnel up; a real start later takes
     * the reused-engine path (`ServiceBridge.startKernel()`).
     */    fun prewarm() {
        ensureStarted(listOf(ARG_PREWARM))
    }

    /**
     * Idempotent: multiple callers from different threads share one engine.
     *
     * Answers whether **this call created it**. A reuse (a prewarm that finished
     * first, or a previous session's engine) needs the explicit `startKernel`
     * command; a fresh engine's `serviceMain` runs the start itself from the args.
     * Sampling [isRunning] before the call was the race: a prewarm in flight read
     * as "not running", the command was skipped, and the PREWARM args never bring
     * the tunnel up.
     */
    @Synchronized
    fun ensureStarted(args: List<String>): Boolean {
        if (serviceEngine != null) {
            // Already up. A later caller cannot change the entrypoint args; remember only that a
            // start was requested so a future destroy/restart can honour the last flags.
            // Do NOT force ffiMode=true here: engine existence is not proof the FFI driver
            // attached. Keep the last value Dart pushed via `driver.ready` after its
            // initialize(); a phantom driver would disable rates and no-op every core op.
            state = EngineState.ready
            return false
        }
        // The service engine is the sole owner of the kernel while it exists, but the
        // ffiMode flag is now set only by Dart's `driver.ready` push after a real attach:
        // a failure here leaves the service's own path intact and never marks the tunnel
        // "Dart-owned" with nothing behind it.
        // A missing/unloadable libthrone.so makes the service engine useless: gate engine
        // creation on the library so the service-side box stays in charge when Dart cannot
        // attach (and would push driverReady=false anyway).
        if (runCatching { System.loadLibrary("throne") }.isFailure) {
            Logs.w("serviceEngine: libthrone.so is unavailable; keeping the service-side box")
            state = EngineState.failed
            return false
        }
        val app = appContext ?: run {
            Logs.w("serviceEngine: install() was never called; cannot create the engine")
            state = EngineState.failed
            return false
        }
        val entrypoint = DartExecutor.DartEntrypoint(
            FlutterInjector.instance().flutterLoader().findAppBundlePath(),
            SERVICE_ENTRYPOINT,
        )
        // Standalone construction (see the class doc): its own isolate group, heap and GC. A
        // group spawn would share the UI isolate's heap, and the kernel's start-time allocations
        // would pause the frame pipeline.
        val beganAt = System.currentTimeMillis()
        state = EngineState.creating
        val engine = try {
            FlutterEngine(app).also { created ->
                created.dartExecutor.executeDartEntrypoint(entrypoint, args)
            }
        } catch (error: Throwable) {
            Logs.w("serviceEngine: engine creation failed: ${error.message}")
            state = EngineState.failed
            return false
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
        // The engine will own the kernel *if* Dart attaches the FFI driver. That
        // happens asynchronously in serviceMain.initialize(); it pushes the real
        // result over `driver.ready`, which is the only place BboxKernel.ffiMode
        // is now set true. Keeping the service-side box until then avoids a
        // phantom-driver window where rates are closed and every op no-ops.
        state = EngineState.ready
        Logs.i(
            "serviceEngine: started (standalone isolate group) in " +
                "${System.currentTimeMillis() - beganAt}ms with args=${args.joinToString()}",
        )
        return true
    }
}
