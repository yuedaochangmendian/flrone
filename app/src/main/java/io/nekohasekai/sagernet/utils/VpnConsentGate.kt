package io.nekohasekai.sagernet.utils

// The single-flight state of one VPN consent request.
//
// The consent dialog is paced by the user, so the start path cannot use a stopwatch for it:
// `KernelServiceActions` waits for the *answer* and only then counts a readiness budget for
// the service. Two starts that overlap (a tap racing a tile, a mode switch re-issuing the
// start) must share one dialog instead of stacking two. That bookkeeping is this class —
// pure Kotlin, no Android, no scheduling — so the state machine is unit-tested on the JVM;
// the Android half (prepare/startActivity/activity results) lives in [VpnPermission].

import kotlinx.coroutines.CompletableDeferred

/** The answer the single consent request resolved with. */
enum class VpnConsentOutcome { GRANTED, DENIED, CANCELLED }

class VpnConsentGate {

    /**
     * One caller's view of the request: the shared answer plus whether *this* caller is the
     * one that must put the dialog on screen. Joiners get `mustAsk = false` and the same
     * [result] the launcher awaits.
     */
    class Ticket internal constructor(
        internal val result: CompletableDeferred<VpnConsentOutcome>,
        val mustAsk: Boolean,
    )

    private val lock = Any()
    private var pending: CompletableDeferred<VpnConsentOutcome>? = null
    private var waiters = 0
    private var launched = false

    /** True while a request exists that the next caller would join instead of asking again. */
    val inFlight: Boolean
        get() = synchronized(lock) { pending != null }

    /** Joins the request in flight, or registers the single one a new dialog will answer. */
    fun begin(): Ticket = synchronized(lock) {
        val existing = pending
        if (existing != null) {
            waiters += 1
            return Ticket(existing, mustAsk = false)
        }
        val created = CompletableDeferred<VpnConsentOutcome>()
        pending = created
        waiters = 1
        launched = false
        Ticket(created, mustAsk = true)
    }

    /**
     * The dialog was actually posted: the request now outlives its last waiter, because an
     * on-screen consent still has an answer to give and the next caller should join it.
     */
    fun markLaunched(ticket: Ticket) = synchronized(lock) {
        if (pending === ticket.result) launched = true
    }

    /**
     * Completes the request every waiter shares. Returns false when nothing is in flight, so a
     * stray answer cannot resurrect a request that already finished (a second `parseResult`
     * delivery after a configuration change is the concrete case).
     *
     * A late answer that lands on a **newer** request is benign by construction: every answer is
     * about the same app-level permission, so "granted" stays true and "denied" stays a refusal
     * of the same start.
     */
    fun complete(outcome: VpnConsentOutcome): Boolean = synchronized(lock) {
        val current = pending ?: return false
        pending = null
        waiters = 0
        launched = false
        current.complete(outcome)
        true
    }

    /**
     * A waiter gave up (its coroutine was cancelled). A dialog already on screen keeps the
     * request — it will answer. One that was never shown is dropped, so the next caller is
     * not left joining a result nobody can produce.
     */
    fun abandon(ticket: Ticket) {
        synchronized(lock) {
            if (pending !== ticket.result) return
            if (waiters > 0) waiters -= 1
            if (waiters == 0 && !launched) {
                pending = null
                launched = false
            }
        }
    }
}
