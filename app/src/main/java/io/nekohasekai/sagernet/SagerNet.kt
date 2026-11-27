package io.nekohasekai.sagernet

import android.annotation.SuppressLint
import android.app.*
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.StrictMode
import android.os.UserManager
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import androidx.core.content.getSystemService
import io.nekohasekai.sagernet.appwidget.Widgets
import io.nekohasekai.sagernet.bg.CoreRuntime
import io.nekohasekai.sagernet.bg.ServiceClasses
import io.nekohasekai.sagernet.bg.SingBoxDashboard
import io.nekohasekai.sagernet.bg.autoselector.AutoSelectorRuntime
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.SettingsJsonStore
import io.nekohasekai.sagernet.database.SettingsMapper
import io.nekohasekai.sagernet.group.SubscriptionScheduler
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.ktx.isOss
import io.nekohasekai.sagernet.ktx.runOnDefaultDispatcher
import io.nekohasekai.sagernet.ui.MainActivity
import io.nekohasekai.sagernet.update.UpdateManager
import io.nekohasekai.sagernet.utils.*
import io.flrone.bridge.DozeModule
import io.flrone.bridge.FlroneMemory
import io.flrone.bridge.FlroneRuntime
import io.flrone.flutter.ServiceEngineManager
import io.flutter.FlutterInjector
import kotlinx.coroutines.DEBUG_PROPERTY_NAME
import kotlinx.coroutines.DEBUG_PROPERTY_VALUE_ON
import java.io.File
import moe.matsuri.nb4a.utils.JavaUtil
import moe.matsuri.nb4a.utils.cleanWebview
import androidx.work.Configuration as WorkConfiguration

class SagerNet : Application(),
    WorkConfiguration.Provider {

    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)

        application = this
    }

    val process: String = JavaUtil.getProcessName()
    private val isMainProcess = process == BuildConfig.APPLICATION_ID
    // Legacy guard: no component is pinned to `:bg` any more (everything shares the main
    // process), but the checks that read this remain harmless and keep the door open for a
    // future dedicated process. Do not infer from it that a `:bg` process currently exists.
    val isBgProcess = process.endsWith(":bg")

    override fun onCreate() {
        super.onCreate()

        // ADR 0006 stage C2: the settings documents are the store in every process, from the
        // first read — not from the moment the UI's Dart engine calls `data.path`/`data.documents`.
        // A service started from a tile, at boot or by the VpnService consent (no Flutter engine,
        // no Dart attach) would otherwise read and write a different copy than the UI: what the
        // service saved never reached the UI, and what the UI saved never reached the service.
        // Mounting here, before this method's first DataStore read
        // (apiDashboardEnabled below) and before any service can start, removes the window.
        // Every process that runs this method mounts (today just the shared main process),
        // so SettingsJsonStore's file lock keeps their writes from overwriting each other.
        SettingsJsonStore.directory = File(filesDir, "documents")
        // ADR 0006 stages C2b/C2c2b2: the retired settings/markers tables and their reader
        // are gone; upgrades from pre-document installs are no longer supported. A first
        // install just seeds two empty documents. Idempotent: a healthy document pair costs
        // two file stats.
        SettingsJsonStore.ensure()

        Thread.setDefaultUncaughtExceptionHandler(CrashHandler)

        if (isMainProcess || isBgProcess) {
            SettingsMapper.installOutboundHooks()

            // P6 stage 1: start the Flutter loader before any engine is created (a standalone
            // engine, and any group, needs it). Process-global and on the main process, where the
            // UI and the services live — an always-on VPN / tile that starts before the UI exists
            // can still bring up the kernel engine.
            FlutterInjector.instance().flutterLoader().startInitialization(this)
            ServiceEngineManager.install(this)
            // Device doze detection lives for the app process lifetime, not the
            // engine's: screen-off/idle broadcasts must be observed even before
            // the Flutter engine attaches. Idempotent across processes/re-entry.
            DozeModule.install(this)
            // Pre-load the core library off the main thread (ensureStarted's own
            // System.loadLibrary on the tap path then no-ops), and pre-create the kernel
            // engine a few seconds in: the first start otherwise pays library load +
            // engine creation inside the tap's `service.start` on the main thread and
            // drops frames — the start button jank. The prewarm args keep serviceMain's
            // auto-start from bringing the tunnel up on their own.
            Thread { runCatching { System.loadLibrary("throne") } }.start()
            // TODO(P1-WP1.3 perf, deferred): this prewarm also creates the FlutterEngine on the
            // main thread (the delayed runnable posts to the main looper), and it is 3 s late
            // for a boot / always-on / tile start that arrives first — that path pays
            // `FlutterEngine` construction synchronously in `BaseService.startProxy` on main.
            // Engine construction CANNOT move off-main: DartExecutor's @UiThread assertion
            // and merged_platform_ui_thread (see ADR 0004 P6 / pre.88) pin it there, and the
            // kernel's FFI work already runs in the spawned kernelWorker isolate. Prewarming
            // earlier for boot/always-on would only shift the same main-thread cost into
            // startup. Measurement before any change: `serviceEngine: started (standalone
            // isolate group) in Xms with args=…` distinguishes a prewarm creation ([prewarm])
            // from a start-path creation ([quick, boot]) — compare X and the start-turn frame
            // probe on a device. No ordering change adopted without that evidence.
            Handler(Looper.getMainLooper()).postDelayed(
                { ServiceEngineManager.prewarm() },
                3_000,
            )

            // The B-box bridge lives in the UI process: one service connection and one state snapshot for every screen.
            if (isMainProcess) FlroneRuntime.install(this)
            // Zero cross-process: the core, the widgets and the tile all live beside the UI now
            // (the manifest no longer pins anything to :bg), so the old :bg-only setup runs here.
            if (isMainProcess || isBgProcess) {
                updateNotificationChannels()
                // Heal widgets left "Connected" by a killed service.
                Widgets.push(this)
                // The FFI path's platform duties (callbacks from the Go runtime). Register before
                // setup() installs the log sink: early core lines arrive through platform_request.
                runCatching {
                    io.flrone.core.Core.setPlatform(io.flrone.bridge.FlroneCorePlatform)
                }.onFailure { Logs.w("bridge: core shim unavailable: ${it.message}") }
                // The core (and its JNI library) shares the process with the Flutter engine.
                CoreRuntime.setup(this)
                // The single global rule table has no profile-default repair: the build always starts
                // from the built-in Default (`route.final = proxy`) and attaches the table. The old
                // route-document repair belonged to the retired multi-profile model.
                // The Clash API's switch and secret are one state (ControllerSecret): an install that
                // saved "on with no secret" gets one generated and persisted now, before any config
                // build can serve an open controller, and a secret kept for an API that is off is
                // dropped. Idempotent: a healthy pair costs one settings read. The build path
                // (SettingsMapper) repeats the repair, so a start from a tile/boot is covered too.
                runCatching { DataStore.ensureClashApiSecret() }
                    .onFailure { Logs.w("settings: clash api secret repair skipped: ${it.message}") }
                AutoSelectorRuntime.install()
            }

            // fix multi process issue in Android 9+
            JavaUtil.handleWebviewDir(this)

            runOnDefaultDispatcher {
                PackageCache.register()
                PackageCache.prewarm()
                cleanWebview()
            }
        }

        if (isMainProcess) {
            Theme.apply(this)
            Theme.applyNightTheme()
            AppLocale.apply()
            UpdateManager.onAppStart(this)
            runOnDefaultDispatcher {
                DefaultNetworkListener.start(this) {
                    underlyingNetwork = it
                }
            }
            // The icon pack of the removed custom icon feature; a no-op once it is gone.
            runOnDefaultDispatcher { File(filesDir, "custom_icon").deleteRecursively() }
            // The sing-box dashboard is unpacked out of the APK once per install (46 files, a few
            // megabytes). Doing it here instead of at the first connect keeps those copies off the
            // one path the user is waiting on: `config.build` runs it, and only the stamp check
            // remains by the time the tunnel is asked for.
            if (DataStore.apiDashboardEnabled) {
                runOnDefaultDispatcher { SingBoxDashboard.install() }
            }
            SubscriptionScheduler.schedule()
            Widgets.watchSelection(this)
        }

        if (BuildConfig.DEBUG) {
            System.setProperty(DEBUG_PROPERTY_NAME, DEBUG_PROPERTY_VALUE_ON)
            // Scope the thread policy to the UI process. A future dedicated :bg process (the
            // manifest currently declares none) legitimately does disk/network on its own thread;
            // flagging it would only produce noise that hides real UI regressions.
            if (isMainProcess) {
                StrictMode.setThreadPolicy(
                    StrictMode.ThreadPolicy.Builder()
                        .detectDiskReads()
                        .detectDiskWrites()
                        .detectNetwork()
                        .penaltyLog()
                        .build()
                )
            }
            StrictMode.setVmPolicy(
                StrictMode.VmPolicy.Builder()
                    .detectLeakedSqlLiteObjects()
                    .detectLeakedClosableObjects()
                    .detectLeakedRegistrationObjects()
                    .penaltyLog()
                    .build()
            )
        }
    }

    /**
     * Bettbox's background-GC strategy on Android: the system's own memory-pressure signal is the
     * trigger, and the response is proportional to how urgent the signal is. Runs in both the UI and
     * the :bg process; ART's trim only touches the Java heap, so the Go core's own allocator is left
     * alone.
     */
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        // The UI hears about it first (it can drop decoded images), then ART gets the hint; the
        // policy itself lives in FlroneMemory so the bridge and the application cannot drift apart.
        FlroneMemory.onTrim(level)
    }

    override fun onLowMemory() {
        super.onLowMemory()
        FlroneMemory.onLowMemory()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        updateNotificationChannels()
    }

    // Enqueueing (RemoteWorkManagerService) and SystemJobService live in the main process, so the reschedule after a
    // reboot, force-stop or update (ForceStopRunnable, default process only) must run there too; workers hop to :bg.
    override fun getWorkManagerConfiguration(): WorkConfiguration {
        return WorkConfiguration.Builder()
            .setDefaultProcessName(BuildConfig.APPLICATION_ID)
            .build()
    }

    @SuppressLint("InlinedApi")
    companion object {

        lateinit var application: SagerNet

        val isTv by lazy {
            uiMode.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
                application.packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
        }

        val configureIntent: (Context) -> PendingIntent by lazy {
            {
                PendingIntent.getActivity(
                    it,
                    0,
                    // The ported interface is the app's only screen (batch L0).
                    Intent(
                        application, io.flrone.flutter.FlroneActivity::class.java
                    ).setFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
                )
            }
        }
        val activity by lazy { application.getSystemService<ActivityManager>()!! }
        val clipboard by lazy { application.getSystemService<ClipboardManager>()!! }
        val connectivity by lazy { application.getSystemService<ConnectivityManager>()!! }
        val notification by lazy { application.getSystemService<NotificationManager>()!! }
        val user by lazy { application.getSystemService<UserManager>()!! }
        val uiMode by lazy { application.getSystemService<UiModeManager>()!! }
        val power by lazy { application.getSystemService<PowerManager>()!! }

        fun getClipboardText(): String {
            return clipboard.primaryClip?.takeIf { it.itemCount > 0 }
                ?.getItemAt(0)?.text?.toString() ?: ""
        }

        /** The clip travels as UTF-16 in one binder transaction, whose buffer (about 1 MB) the process shares. */
        const val MAX_CLIP_CHARS = 400_000

        /** False when the text is over [MAX_CLIP_CHARS] or the clipboard refused it. */
        fun trySetPrimaryClip(clip: String): Boolean {
            if (clip.length > MAX_CLIP_CHARS) return false
            return try {
                clipboard.setPrimaryClip(ClipData.newPlainText(null, clip))
                true
            } catch (e: RuntimeException) {
                Logs.w(e)
                false
            }
        }

        fun updateNotificationChannels() {
            if (Build.VERSION.SDK_INT >= 26) @RequiresApi(26) {
                notification.createNotificationChannels(
                    listOf(
                        NotificationChannel(
                            "service-vpn",
                            application.getText(R.string.service_vpn),
                            if (Build.VERSION.SDK_INT >= 28) NotificationManager.IMPORTANCE_MIN
                            else NotificationManager.IMPORTANCE_LOW
                        ),   // #1355
                        NotificationChannel(
                            "service-proxy",
                            application.getText(R.string.service_proxy),
                            NotificationManager.IMPORTANCE_LOW
                        ), NotificationChannel(
                            "service-subscription",
                            application.getText(R.string.service_subscription),
                            NotificationManager.IMPORTANCE_DEFAULT
                        ), NotificationChannel(
                            "connection-test",
                            application.getText(R.string.connection_test),
                            NotificationManager.IMPORTANCE_DEFAULT
                        ), NotificationChannel(
                            PlatformNotifications.CHANNEL_WARNINGS,
                            application.getText(R.string.channel_warnings),
                            NotificationManager.IMPORTANCE_DEFAULT
                        )
                    )
                )
            }
        }

        /**
         * The service-engine args for the next [startService] call. A tile / boot / always-on start
         * sets "quick" (and "boot" for boot) so the kernel engine launches silently; a UI start
         * passes nothing. Consumed by BaseService.startProxy via [takePendingEngineArgs].
         */
        @Volatile
        private var pendingEngineArgs: List<String> = emptyList()

        fun setPendingEngineArgs(args: List<String>) { pendingEngineArgs = args }

        fun takePendingEngineArgs(): List<String> {
            val args = pendingEngineArgs
            pendingEngineArgs = emptyList()
            return args
        }

        /**
         * Stops the foreground service class the current mode does not name. One tunnel at a
         * time: that is why a mode switch cannot leave the previous class up.
         *
         * [startChosenService] is the start-path owner; `VpnService.onStartCommand` calls this
         * too because an always-on VPN is started by the platform, not by a start call.
         */
        fun stopOtherService() {
            application.stopService(Intent(application, ServiceClasses.other(DataStore.serviceMode)))
        }

        /**
         * The single owner of "start a service": every path funnels here — the UI bridge, the
         * service engine, the tile/boot/widget quick start, the boot receiver and the VPN consent
         * activity's fallback. The class comes from the saved service mode, and the *other* class
         * is stopped first: FlClash's ServiceController does the same (ServiceController.kt:81-85,
         * 134-141) because a mode switch otherwise leaves the previous tunnel running while the
         * app, its notification and the kernel all report the new mode. Stopping a service that is
         * not running is a no-op.
         */
        private fun startChosenService(args: List<String>?) {
            stopOtherService()
            val intent = Intent(application, ServiceClasses.forMode(DataStore.serviceMode))
            if (args != null) {
                intent.putStringArrayListExtra(EXTRA_ENGINE_ARGS, ArrayList(args))
            }
            ContextCompat.startForegroundService(application, intent)
        }

        /** Silent background start (tile, quick tile, always-on VPN, widget). */
        fun startServiceQuick(boot: Boolean = false) {
            pendingEngineArgs = buildList {
                add(ServiceEngineManager.ARG_QUICK)
                if (boot) add(ServiceEngineManager.ARG_BOOT)
            }
            startService()
        }

        fun startService() = startChosenService(null)

        /** Starts the service carrying explicit engine args in the intent extras. */
        fun startService(args: List<String>) = startChosenService(args)

        const val EXTRA_ENGINE_ARGS = "io.flrone.service.engine_args"

        /** The silent-start flags of [intent], or null. ArrayList extras avoid the
         *  String[] / Serializable overload ambiguity of putExtra. */
        fun engineArgsFrom(intent: Intent?): Array<String>? =
            intent?.getStringArrayListExtra(EXTRA_ENGINE_ARGS)?.toTypedArray()

        fun reloadService() =
            application.sendBroadcast(Intent(Action.RELOAD).setPackage(application.packageName))

        fun stopService() =
            application.sendBroadcast(Intent(Action.CLOSE).setPackage(application.packageName))

        var underlyingNetwork: Network? = null

        var appVersionNameForDisplay = {
            var n = BuildConfig.VERSION_NAME
            if (!isOss) {
                n += " ${BuildConfig.FLAVOR}"
            }
            if (BuildConfig.DEBUG) {
                n += " DEBUG"
            }
            n
        }()
    }

}
