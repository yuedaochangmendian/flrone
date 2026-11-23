package io.nekohasekai.sagernet.ui

import android.app.Activity
import android.app.KeyguardManager
import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.VpnService
import android.os.Build.VERSION.SDK_INT
import android.os.Bundle
import android.view.ContextThemeWrapper
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContract
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.getSystemService
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import io.nekohasekai.sagernet.Key
import io.nekohasekai.sagernet.R
import io.nekohasekai.sagernet.SagerNet
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.ktx.broadcastReceiver
import io.nekohasekai.sagernet.utils.Theme
import io.nekohasekai.sagernet.utils.VpnPermission

/**
 * The VPN consent hop. Two kinds of caller reach it:
 *
 *  * a start that is **waiting** for the permission ([VpnPermission.ensureGranted], i.e.
 *    `KernelServiceActions.startServiceAndAwaitTun`) — it passes [EXTRA_DEFERRED_START], the
 *    answer goes back through [VpnPermission.deliver], and the caller starts the service;
 *  * the platform, which started `VpnService` before any consent existed — nobody waits, so
 *    the activity keeps its old job of starting the service after a grant.
 */
class VpnRequestActivity : AppCompatActivity() {
    private var receiver: BroadcastReceiver? = null

    /** The answer was delivered; [onDestroy] must not deliver a second one. */
    private var answered = false

    /**
     * Read from the intent at use time, not at construction: the intent is attached after the
     * activity object exists, and a recreated activity is handed the same extras again.
     */
    private val deferredStart: Boolean
        get() = intent?.getBooleanExtra(EXTRA_DEFERRED_START, false) == true

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (getSystemService<KeyguardManager>()!!.isKeyguardLocked) {
            receiver = broadcastReceiver { _, _ -> launchConnect() }
            if (SDK_INT >= 33) {
                // USER_PRESENT is a system broadcast: NOT_EXPORTED still delivers
                // it, while another app can no longer spoof it to surface the
                // VPN consent dialog.
                registerReceiver(
                    receiver,
                    IntentFilter(Intent.ACTION_USER_PRESENT),
                    Context.RECEIVER_NOT_EXPORTED
                )
            } else {
                registerReceiver(receiver, IntentFilter(Intent.ACTION_USER_PRESENT))
            }
        } else launchConnect()
    }

    private val connect = registerForActivityResult(StartService { deferredStart }) { denied ->
        // Deliver before the toast and the finish: a start on another thread resumes on this
        // answer, and an activity torn down right here must not turn it into a cancel.
        answered = true
        VpnPermission.deliver(!denied)
        if (denied) Toast.makeText(this, R.string.vpn_permission_denied, Toast.LENGTH_LONG).show()
        finish()
    }

    private fun launchConnect() {
        try {
            connect.launch(null)
        } catch (_: ActivityNotFoundException) {
            showConsentUnavailable(ContextThemeWrapper(this, Theme.getTheme())) { finish() }
        } catch (_: SecurityException) {
            showConsentUnavailable(ContextThemeWrapper(this, Theme.getTheme())) { finish() }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        if (receiver != null) unregisterReceiver(receiver)
        // A hop that goes away without an answer (back pressed before the system dialog
        // appeared, the keyguard wait given up, the task removed) must release the waiting
        // start instead of leaving it on a budget. A configuration change is not a finish:
        // the recreated instance receives the pending result through the registry.
        if (!answered && isFinishing) VpnPermission.deliver(false)
    }

    class StartService(
        /** True when a caller awaits the answer and starts the service itself. */
        private val deferred: () -> Boolean,
    ) : ActivityResultContract<Void?, Boolean>() {
        private var cachedIntent: Intent? = null

        override fun getSynchronousResult(
            context: Context,
            input: Void?,
        ): SynchronousResult<Boolean>? {
            if (DataStore.serviceMode == Key.MODE_VPN) VpnService.prepare(context)?.let { intent ->
                cachedIntent = intent
                return null
            }
            SagerNet.startService()
            return SynchronousResult(false)
        }

        override fun createIntent(context: Context, input: Void?) =
            cachedIntent!!.also { cachedIntent = null }

        override fun parseResult(resultCode: Int, intent: Intent?) =
            if (resultCode == Activity.RESULT_OK) {
                // A deferred start is already waiting and starts the service once the answer
                // reaches it; the platform's own start has no waiter and needs this hop.
                if (!deferred()) SagerNet.startService()
                false
            } else {
                Logs.e("Failed to start VpnService: $intent")
                true
            }
    }

    companion object {

        /**
         * Set when [VpnPermission] launched this activity: the caller awaits the consent
         * answer and starts the service itself, so the activity must not start a second one.
         */
        const val EXTRA_DEFERRED_START = "io.flrone.vpn.deferred_start"

        /**
         * Some TV, AOSP and vendor builds ship without VpnDialogs, so the consent screen cannot open. The app op can
         * still be granted over adb (VpnService.prepare then returns null), or the proxy mode used instead.
         */
        fun showConsentUnavailable(context: Context, onDismiss: () -> Unit = {}) {
            val command = "adb shell appops set ${context.packageName} ACTIVATE_VPN allow"
            MaterialAlertDialogBuilder(context)
                .setTitle(R.string.vpn_dialog_missing_title)
                .setMessage(context.getString(R.string.vpn_dialog_missing_message, context.packageName))
                .setPositiveButton(R.string.vpn_dialog_use_proxy) { _, _ ->
                    DataStore.serviceMode = Key.MODE_PROXY
                    SagerNet.startService()
                }
                .setNeutralButton(R.string.vpn_dialog_copy_command) { _, _ -> SagerNet.trySetPrimaryClip(command) }
                .setNegativeButton(android.R.string.cancel, null)
                .setOnDismissListener { onDismiss() }
                .show()
        }
    }
}
