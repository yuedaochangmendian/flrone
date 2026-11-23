package io.nekohasekai.sagernet.bg

/**
 * What each [BaseService.State] *means* to the surfaces that only have room for a
 * yes/no. Kept in one pure place because the rule is the same everywhere and the
 * surfaces (tile, notification, widget) are not testable on their own:
 *
 * - `Connected` is the only state that claims a tunnel is up. Since the Dart kernel
 *   owns the core, the service reaches it only through `state.markRunning` — the
 *   report that `worker.start()` succeeded — never because a start was merely asked
 *   for. `Connecting` is a start that is still preparing (the service sits there from
 *   the end of `startProxyBody` until that report arrives), so it must read as
 *   in-progress or off, not as on.
 * - `Connecting` and `Stopping` are transitions: something is being brought up or
 *   taken down, and any answer derived from the previous run is stale.
 */
object ServiceStateRules {

    /** A live tunnel. Everything else — including [BaseService.State.Connecting] — is not. */
    fun isActiveState(state: BaseService.State): Boolean = state == BaseService.State.Connected

    /** A lifecycle change in flight: `Connecting` (start preparing) or `Stopping` (stop running). */
    fun isTransitioningState(state: BaseService.State): Boolean =
        state == BaseService.State.Connecting || state == BaseService.State.Stopping

    /**
     * Whether a `state.markRunning` may promote the service to `Connected`.
     *
     * Only a start that is waiting for that report: if the service already moved on
     * (a stop landed, or it is already connected) the report describes a run that is
     * no longer the current one and must not be resurrected.
     */
    fun canPromoteToConnected(state: BaseService.State): Boolean =
        state == BaseService.State.Connecting

    /**
     * Whether a `state.clearRunning` should take the service down.
     *
     * It means the kernel side has nothing running. While the service is still
     * `Connecting` that is a start which never held, and nothing else will ever move
     * it out of that state — leaving it there would keep the notification and the VPN
     * icon up for a tunnel that does not exist. Any other state is either already
     * going down or not starting at all, so it is left alone.
     */
    fun shouldStopAfterKernelStopped(state: BaseService.State): Boolean =
        state == BaseService.State.Connecting
}
