package io.flrone.flutter

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flrone.bridge.DartProfileWriter
import io.nekohasekai.sagernet.ktx.Logs

/**
 * The fail-closed liveness decision, separated from [FlutterEngine] so it is
 * testable on the JVM (a real engine needs the native VM and the main looper).
 *
 * A *normal stop* never marks the engine failed: it stays warm. Only an
 * undeliverable start — a bounded retry window that never reached the worker —
 * flips the flag, which forces the next [ServiceEngineManager.ensureStarted] to
 * destroy the dead object and build a fresh one. Existence of the object is not
 * evidence its isolate is alive.
 */
internal class EngineLiveness {
    @Volatile
    var failed: Boolean = false
        private set

    /** Marks the cached engine dead. Idempotent. */
    @Synchronized
    fun markFailed() { failed = true }

    /**
     * Whether a cached engine may be reused right now.
     * A failed one must be destroyed and recreated instead.
     */
    fun canReuse(): Boolean = !failed

    /** Called once a fresh engine is cached (or created) successfully. */
    @Synchronized
    fun markHealthy() { failed = false }
}

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
 * `configBuild` reply (the whole core config), creating the core instance, the event and log
 * traffic that follows — grows the UI isolate's heap and its GC pauses stop the UI isolate's
 * frame pipeline. That is precisely the start-only frame drop the card has always shown, and
 * FlClash never pays it: its core runs in Kotlin/Go on Dispatchers.Default and allocates nothing
 * in the UI isolate's heap. A standalone `FlutterEngine` gets its own isolate group, heap and
 * collector; the engines then share only the process. The cost is paid once at pre-warm
 * (creation is somewhat slower than a group spawn) and messages between them are copied instead
 * of passed by reference — both are irrelevant for handshake-sized maps.
 *
 * Everything here is guarded by the object's monitor: a tile tap, always-on VPN, a widget and the
 * UI can all ask to start at once, and only one engine may ever exist. A normal user stop leaves the
 * engine warm for the next start (destroying it would drop the isolate, and `FlutterEngine.destroy`
 * is only safe when no Dart attach/UI holds it). The one exception is **fail-closed recovery**: a
 * start command that cannot be delivered to its worker within a bounded window means the cached
 * isolate is dead even though the object is still cached. [ServiceBridge] reports that with
 * [noteEngineUndeliverable], which marks the engine failed and clears the cache; the next
 * [ensureStarted] destroys the stale object (guarded) and creates a fresh engine. [EngineState]
 * reports where an engine creation stands for diagnostics.
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
     * A failed engine is *replaced*, not reused: a cached FlutterEngine whose
     * isolate died still answers channel calls with MissingPluginException, so
     * existence alone is not liveness. Set only by [noteEngineUndeliverable]
     * (a bounded, failed start delivery), never by a normal stop.
     */
    internal val liveness = EngineLiveness()

    /**
     * Test seam for the engine factory. Production builds a standalone engine
     * (own isolate group/heap); a JVM test injects a fake engine so `destroy()`
     * can be asserted without a Dart VM. The factory must not register plugins
     * — the caller does that once it has the engine.
     */
    internal var engineFactory: (() -> FlutterEngine)? = null

    /**
     * Test seam for the native-library gate. Production loads libthrone.so;
     * a JVM test reports true so the engine factory above can be exercised.
     */
    internal var libraryReady: () -> Boolean = { runCatching { System.loadLibrary("throne") }.isSuccess }

    /**
     * S6: the bounded attach wait for the service engine to become the document
     * owner. A UI fallback may be in place when a document write races engine
     * creation; we prefer the service owner, so wait briefly for its attach.
     * Mutable so a JVM test need not sleep.
     */
    @Volatile
    internal var ownerAttachTimeoutMs: Long = 2_000L

    /**
     * S6: the optional `ensureForDocument` seam. A write that must land on the
     * service owner brings the engine up when no owner is attached yet (a boot
     * or tile path that never prewarmed). Kept injectable for tests — production
     * points at [ensureStarted]. Null means "no engine available" (UI fallback
     * remains the owner).
     */
    @Volatile
    internal var ensureForDocument: (() -> Boolean)? = null

    /** Installs the production seam: a document write may create the service engine. */
    @Synchronized
    fun installDocumentSeam() {
        if (ensureForDocument == null) {
            ensureForDocument = { ensureStarted(listOf(ARG_PREWARM)) }
        }
    }

    /**
     * Executes [block] on the main thread, posting when needed and running it
     * in place when there is no looper (JVM tests). The document writer's
     * MethodChannel attach must happen on main, like every Flutter engine op.
     */
    private inline fun onMain(crossinline block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block()
        else if (!runCatching { Handler(Looper.getMainLooper()).post { block() } }.getOrDefault(false)) block()
    }

    /**
     * Makes the freshly created service engine the single owner of
     * `documents/profiles.json`. Called once at attach; the UI engine is only
     * ever a fallback and must not steal ownership back on close.
     */
    private fun attachDocumentOwner(engine: FlutterEngine) {
        onMain { DartProfileWriter.attachService(engine.dartExecutor.binaryMessenger) }
    }

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
     * S6: ensures the service document owner is attached before a write,
     * bounded by [ownerAttachTimeoutMs]. The UI engine is not a document owner
     * (it has no profiles_doc handler), so a boot/prewarm write that arrives
     * before the service engine exists brings it up through [ensureForDocument]
     * instead of electing a broken fallback.
     */
    fun ensureDocumentOwner(): Boolean {
        if (DartProfileWriter.currentRole() == DartProfileWriter.OwnerRole.SERVICE &&
            DartProfileWriter.attached()
        ) {
            return true
        }
        ensureForDocument?.invoke()
        val deadline = System.currentTimeMillis() + ownerAttachTimeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (DartProfileWriter.currentRole() == DartProfileWriter.OwnerRole.SERVICE &&
                DartProfileWriter.attached()
            ) {
                return true
            }
            runCatching { Thread.sleep(10) }
        }
        return false
    }



    /**
     * Called by [io.nekohasekai.sagernet.SagerNet.onCreate] after `FlutterInjector.instance()
     * .flutterLoader().startInitialization(this)`. Only records the context a later standalone
     * engine is built from; engine creation itself is lazy ([prewarm]/[ensureStarted]).
     */
    @Synchronized
    fun install(context: Context) {
        if (appContext != null) return
        appContext = context.applicationContext
        installDocumentSeam()
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
            if (!liveness.canReuse()) {
                // Fail closed: the cached isolate is dead. Destroy is safe here —
                // this engine is headless (no UI attach) and its worker just
                // failed to answer a start, so no Dart code is still running on
                // it. A normal stop never reaches this branch.
                destroyCachedEngine("failed engine")
            } else {
                // Already up. A later caller cannot change the entrypoint args; remember only that a
                // start was requested so a future destroy/restart can honour the last flags.
                // Do NOT force ffiMode=true here: engine existence is not proof the FFI driver
                // attached. Keep the last value Dart pushed via `driver.ready` after its
                // initialize(); a phantom driver would disable rates and no-op every core op.
                state = EngineState.ready
                return false
            }
        }
        // The service engine is the sole owner of the kernel while it exists, but the
        // ffiMode flag is now set only by Dart's `driver.ready` push after a real attach:
        // a failure here leaves the service's own path intact and never marks the tunnel
        // "Dart-owned" with nothing behind it.
        // A missing/unloadable libthrone.so makes the service engine useless: gate engine
        // creation on the library so the service-side box stays in charge when Dart cannot
        // attach (and would push driverReady=false anyway).
        if (!libraryReady()) {
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
            val created = engineFactory?.invoke() ?: FlutterEngine(app)
            created.dartExecutor.executeDartEntrypoint(entrypoint, args)
            created
        } catch (error: Throwable) {
            Logs.w("serviceEngine: engine creation failed: ${error.message}")
            state = EngineState.failed
            return false
        }
        liveness.markHealthy()
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
        // S6: this engine owns the profiles document from the moment it exists.
        // The UI fallback is replaced (and its in-flight calls failed) here.
        attachDocumentOwner(engine)
        serviceEngine = engine
        // The engine will own the kernel *if* Dart attaches the FFI driver. That
        // happens asynchronously in serviceMain.initialize(); it pushes the real
        // result over `driver.ready`, which is the only place FlroneKernel.ffiMode
        // is now set true. Keeping the service-side box until then avoids a
        // phantom-driver window where rates are closed and every op no-ops.
        state = EngineState.ready
        Logs.i(
            "serviceEngine: started (standalone isolate group) in " +
                "${System.currentTimeMillis() - beganAt}ms with args=${args.joinToString()}",
        )
        return true
    }

    /**
     * Fail-closed report from [ServiceBridge] when a `startKernel` command
     * could not be delivered to the worker within its bounded retry window.
     * The cached engine's isolate is dead (or its channel handler never came
     * up), so it must not be reused: mark it failed, and let the next
     * [ensureStarted] destroy this object and build a replacement.
     *
     * A normal stop never calls this — the warm engine stays reusable.
     */
    @Synchronized
    fun noteEngineUndeliverable(reason: String) {
        Logs.w("serviceEngine: start was never delivered ($reason); marking the engine failed")
        liveness.markFailed()
        state = EngineState.failed
        // Fail closed: the cached isolate is dead, so it cannot own the document.
        // Detaching fails every in-flight write; the next document call goes
        // through ensureDocumentOwner() and either creates a replacement or
        // reports the owner unavailable instead of losing the write.
        onMain { DartProfileWriter.detach(DartProfileWriter.OwnerRole.SERVICE) }
    }

    /** Destroys the cached engine under the monitor; safe only for a headless, failed engine. */
    @Synchronized
    private fun destroyCachedEngine(reason: String) {
        val engine = serviceEngine ?: return
        serviceEngine = null
        // A normal stop never reaches here: only a failed engine is destroyed.
        // Give up document ownership explicitly before the isolate is gone, so
        // a write racing the destroy fails instead of hanging on a dead channel.
        onMain { DartProfileWriter.detach(DartProfileWriter.OwnerRole.SERVICE) }
        liveness.markHealthy()
        // The engine is headless (never attached to a UI/Activity) and its
        // worker just failed to answer, so no Dart attach or surface owns it.
        // A throw during destroy must not strand the monitor or block a new
        // engine: log it and continue with the replacement.
        runCatching { engine.destroy() }
            .onFailure { Logs.w("serviceEngine: destroy after $reason failed: ${it.message}") }
    }
}
