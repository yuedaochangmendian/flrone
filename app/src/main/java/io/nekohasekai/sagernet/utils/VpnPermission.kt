package io.nekohasekai.sagernet.utils

// The Android half of the VPN consent gate.
//
// `KernelServiceActions.startServiceAndAwaitTun` used to post the service start and then poll
// `DataStore.vpnService` for 8 s. On a first start the platform has no consent yet, so
// `VpnService.onStartCommand` launched [io.nekohasekai.sagernet.ui.VpnRequestActivity] and
// stopped itself: a user who read the dialog for longer than the budget was told "VpnService
// did not start within 8s". The permission is therefore a pre-transition gate now — this
// object awaits the dialog's answer *before* the service is asked to start, and the 8 s
// budget only covers the service coming up afterwards.
//
// Single-flight: one dialog answers every overlapping start ([VpnConsentGate]), and the
// caller that launched it starts the service; the activity's own start hop is suppressed for
// that case (the activity is also reachable from the platform-started service, which still
// needs it).

import android.content.Context
import android.content.Intent
import android.net.VpnService
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.ui.VpnRequestActivity
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withTimeoutOrNull

object VpnPermission {

    /**
     * How long one request may stay unanswered before it is released. This is a leak guard
     * for a dialog that never came up (a background activity start the platform swallowed, a
     * process-side activity that was killed) — not a readiness budget: the user may read the
     * dialog for as long as they like within it.
     */
    const val WAIT_TIMEOUT_MS = 5 * 60_000L

    /** The refusal a denied/cancelled consent turns into; the message names the permission. */
    class Denied(message: String) : IllegalStateException(message)

    private val gate = VpnConsentGate()

    /** True while a consent request this process started has not answered yet. */
    val requestInFlight: Boolean
        get() = gate.inFlight

    /**
     * Returns when the VPN consent exists, otherwise throws [Denied]. Safe to call from any
     * thread and any number of times: an already-granted permission costs one `prepare()`,
     * and an open dialog is joined rather than reopened.
     */
    suspend fun ensureGranted(context: Context) {
        if (VpnService.prepare(context) == null) return
        val ticket = gate.begin()
        if (ticket.mustAsk) {
            Logs.i("vpn: waiting for the consent dialog before starting the service")
            launch(context, ticket)
        } else {
            Logs.i("vpn: joining the consent dialog another start already opened")
        }
        val outcome = try {
            withTimeoutOrNull(WAIT_TIMEOUT_MS) { ticket.result.await() }
        } catch (cancelled: CancellationException) {
            gate.abandon(ticket)
            throw cancelled
        }
        if (outcome == null) {
            // Nobody answered within the guard window: release every waiter with a refusal
            // instead of leaving the request (and the next caller) stuck behind it.
            gate.complete(VpnConsentOutcome.CANCELLED)
        }
        if (outcome != VpnConsentOutcome.GRANTED) {
            throw Denied(
                if (outcome == VpnConsentOutcome.DENIED) "VPN permission denied"
                else "VPN permission denied: the consent dialog was not answered"
            )
        }
        // The dialog's OK is the system's answer; a prepare() that still wants consent means
        // the grant did not stick (revoked while the dialog was open).
        if (VpnService.prepare(context) != null) throw Denied("VPN permission denied")
    }

    /**
     * The consent activity's answer. Returns true when a waiting start was resolved — false
     * for an activity the platform's own service start opened, where nobody is waiting and
     * the activity starts the service itself.
     */
    fun deliver(granted: Boolean): Boolean = gate.complete(
        if (granted) VpnConsentOutcome.GRANTED else VpnConsentOutcome.DENIED
    )

    private fun launch(context: Context, ticket: VpnConsentGate.Ticket) {
        val intent = Intent(context, VpnRequestActivity::class.java)
            // The start path has no Activity of its own (the service engine has none at all).
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra(VpnRequestActivity.EXTRA_DEFERRED_START, true)
        try {
            context.startActivity(intent)
            gate.markLaunched(ticket)
        } catch (error: Exception) {
            // No VpnDialogs (some TV/AOSP builds), a security refusal, or a background
            // activity start with no visible task. Answer the waiters instead of hanging.
            Logs.w("vpn: consent dialog could not open: ${error.message}")
            gate.complete(VpnConsentOutcome.CANCELLED)
        }
    }
}
