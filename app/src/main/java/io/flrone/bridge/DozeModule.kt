package io.flrone.bridge

// App-level doze detection. The kernel action bus used to tie device doze to
// Flutter's paused/hidden lifecycle, which only means the app was backgrounded:
// that paused the instance and starved auto-selector/URLTest/WireGuard periodic
// recovery. Here the host watches the real PowerManager facts instead — the
// screen must be off AND the device must be in idle maintenance — and forwards
// the result to ServiceBridge.setDoze.

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import io.flrone.flutter.ServiceBridge
import io.nekohasekai.sagernet.ktx.Logs

/** Process-lifetime doze watcher; registered once from [SagerNet.onCreate]. */
@RequiresApi(Build.VERSION_CODES.N)
object DozeModule {
    private const val ENTER_DELAY_MS = 3_000L

    private val handler = Handler(Looper.getMainLooper())
    private var installed = false
    private var receiver: BroadcastReceiver? = null

    /** Idempotent: safe to call from any process that runs Application.onCreate. */
    @Synchronized
    fun install(app: Context) {
        if (installed) return
        installed = true
        val power = app.getSystemService(PowerManager::class.java)
        if (power == null) {
            Logs.w("doze: no PowerManager; doze detection disabled")
            return
        }
        appPowerManager = power
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_USER_PRESENT)
            addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
        }
        val r = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    Intent.ACTION_SCREEN_ON, Intent.ACTION_USER_PRESENT -> {
                        // Resume immediately: cancel any pending "enter doze" and
                        // wake the instance without waiting for the debounce.
                        handler.removeCallbacks(enterDoze)
                        ServiceBridge.setDoze(false)
                    }
                    else -> evaluate()
                }
            }
        }
        try {
            ContextCompat.registerReceiver(
                app.applicationContext,
                r,
                filter,
                ContextCompat.RECEIVER_NOT_EXPORTED,
            )
            receiver = r
            // Establish the initial state at startup (e.g. app restarted while
            // the device was already dozing). Entering doze still debounces.
            evaluate()
        } catch (e: Exception) {
            Logs.w(e)
        }
    }

    private val enterDoze = Runnable {
        // Re-read at fire time: the state may have changed during the debounce.
        if (currentDoze()) ServiceBridge.setDoze(true) else ServiceBridge.setDoze(false)
    }

    /** Re-read the PowerManager facts and apply the doze policy. */
    private fun evaluate() {
        handler.removeCallbacks(enterDoze)
        if (currentDoze()) {
            // Debounce entering doze so a transient screen-off/idle blip does not
            // pause the core's periodic work.
            handler.postDelayed(enterDoze, ENTER_DELAY_MS)
        } else {
            ServiceBridge.setDoze(false)
        }
    }

    private fun currentDoze(): Boolean {
        val power = appPowerManager ?: return false
        @Suppress("DEPRECATION")
        val interactive = power.isInteractive
        return DozePolicy.shouldDoze(interactive, power.isDeviceIdleMode)
    }

    @Volatile
    private var appPowerManager: PowerManager? = null
}
