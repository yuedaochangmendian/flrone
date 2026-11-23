package io.flrone.bridge

/**
 * The route's version (S7).
 *
 * A counter that moves whenever anything that decides where traffic exits changes: the
 * selected proxy, the outbound mode, the current route profile, a config reload, or the
 * service crossing Connected/Stopped. The host stamps every dashboard and egress wire with
 * the version it was built under; the status card records the version a probe started
 * under and discards an answer from a different one. That is what keeps a stale exit IP
 * from being painted under a selection the tunnel has already left — the Dart route stamp
 * cannot see a switch the host has not pushed yet, and the probe is in flight across it.
 *
 * Two ways to move it:
 *  - [bump] for an event the caller knows moved the route (a reload, a route-profile switch);
 *  - [observe] for the periodic snapshot: the first observation after a change bumps.
 *
 * Pure JVM (no Android, no clock): [RouteProvenanceTest] drives it directly.
 */
internal object RouteProvenance {

    /** One observation's outcome: the version to stamp and whether the observation moved it. */
    class Observation(val version: Long, val moved: Boolean)

    /** Monotonic; only ever increases. Read it once per wire and ship the value. */
    @Volatile
    var version: Long = 0L
        private set

    /** The last signature [observe] saw; null until the first observation. */
    private var lastSignature: String? = null

    /** Whether any signature was observed yet: a null baseline is still a baseline. */
    private var observed = false

    private val lock = Any()

    /** Moves the version unconditionally; returns the new value. */
    fun bump(): Long = synchronized(lock) {
        version += 1
        version
    }

    /**
     * Bumps when [signature] differs from the previous observation and returns the version
     * the wire must carry. The first call only records the baseline: a version of 0 is a
     * valid stamp, and bumping on the first observation would re-label every answer taken
     * before the first wire was built.
     */
    fun observe(signature: String?): Long = observeMoved(signature).version

    /**
     * [observe] plus whether this call moved the version, so the caller can react exactly once
     * per move (the host drops the cached exit identity, which belongs to the route it was
     * measured on).
     */
    fun observeMoved(signature: String?): Observation = synchronized(lock) {
        val moved = observed && signature != lastSignature
        if (moved) version++
        lastSignature = signature
        observed = true
        Observation(version, moved)
    }

    /** Test seam: forgets the baseline so a fixture starts from a clean counter. */
    internal fun reset() = synchronized(lock) {
        version = 0L
        lastSignature = null
        observed = false
    }

    /**
     * The signature [observe] compares: every fact that decides where traffic exits, taken
     * from the values the dashboard wire carries. Pure so the field set is pinned by a test;
     * a fact added to the wire but not here would leave a stale answer accepted.
     */
    fun signature(
        status: String,
        selectedProfileId: Long,
        mode: String,
        startedAt: Long?,
        selections: Iterable<String>,
    ): String = buildString {
        append(status).append('|')
        append(selectedProfileId).append('|')
        append(mode).append('|')
        append(startedAt ?: 0L)
        for (selection in selections) append('|').append(selection)
    }
}
