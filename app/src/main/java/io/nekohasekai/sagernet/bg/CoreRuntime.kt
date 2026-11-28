package io.nekohasekai.sagernet.bg

import android.app.Application
import io.flrone.core.CoreHost
import io.flrone.core.CoreInstance
import io.nekohasekai.sagernet.BuildConfig
import io.nekohasekai.sagernet.bg.test.TestEngine
import moe.matsuri.nb4a.utils.CoreLog
import java.io.File

// Shares the app process with the Flutter engine (zero cross-process): everything here pulls the
// ThroneCore AAR (libthrone.so) in — the same Go runtime the Dart FFI path drives.
object CoreRuntime {

    /** The core's working dir under filesDir, which relative paths of its config resolve against. */
    const val WORKING_DIR = "core"

    private const val LOG_QUEUE_LINES = 1024

    // sing-box log.Level: panic..trace. Kept local so the host no longer imports
    // the gomobile constants.
    private const val LOG_PANIC = 0
    private const val LOG_FATAL = 1
    private const val LOG_ERROR = 2
    private const val LOG_WARN = 3
    private const val LOG_INFO = 4
    private const val LOG_DEBUG = 5
    private const val LOG_TRACE = 6

    /** The started main instance and the profile it runs, from box start to close (test-current). */
    class RunningCore(val instance: CoreInstance, val profileId: Long)

    @Volatile
    var running: RunningCore? = null
        private set

    @Synchronized
    fun attachRunning(instance: CoreInstance, profileId: Long) {
        running = RunningCore(instance, profileId)
    }

    fun detachRunning(instance: CoreInstance) {
        val detached = synchronized(this) {
            (running?.instance === instance).also { if (it) running = null }
        }
        if (detached) TestEngine.onRunningClosed()
    }

    /**
     * The sing-box level lines must reach to be written. The main box already drops its own lines above the config's
     * `log.level`, but probe boxes filter by their own config and Go std-log lines arrive at a fixed level, so
     * the sink still applies the running config's `log.level` (unset = trace, like sing-box).
     */
    @Volatile
    private var logLevel = LOG_TRACE

    fun setup(app: Application) {
        CoreLog.newSession()
        logLevel = CoreLog.logLevel?.let(::levelOf) ?: LOG_WARN
        CoreHost.setup(
            basePath = app.filesDir.absolutePath,
            workingPath = File(app.filesDir, WORKING_DIR).absolutePath,
            tempPath = app.cacheDir.absolutePath,
            logMaxLines = LOG_QUEUE_LINES,
            debug = BuildConfig.DEBUG,
        )
        CoreLog.write("[Info] core: sing-box ${CoreHost.version()}, ${CoreHost.goVersion()}")
        CoreHost.setLogSink()
    }

    private fun levelOf(level: String): Int = when (level.trim().lowercase()) {
        "panic" -> LOG_PANIC
        "fatal" -> LOG_FATAL
        "error" -> LOG_ERROR
        "warn", "warning" -> LOG_WARN
        "info" -> LOG_INFO
        "debug" -> LOG_DEBUG
        else -> LOG_TRACE
    }

    /** Called from FlroneCorePlatform's `log` platform_request. */
    fun appendCoreLog(level: Int, message: String) {
        if (level > logLevel) return
        CoreLog.write("[${levelName(level)}] $message")
    }

    private fun levelName(level: Int): String = when (level) {
        LOG_PANIC -> "Panic"
        LOG_FATAL -> "Fatal"
        LOG_ERROR -> "Error"
        LOG_WARN -> "Warning"
        LOG_INFO -> "Info"
        LOG_DEBUG -> "Debug"
        LOG_TRACE -> "Trace"
        else -> "Info"
    }
}
