// The JNI face of the self-owned kernel bridge (libcore.so + the Go shared
// library). Kernel control itself goes Dart -> dart:ffi; this object covers the
// Android duties only: the fd push and the platform callbacks.
package io.flrone.core

object Core {

    init {
        System.loadLibrary("core")
    }

    /**
     * Feed the VpnService fd and its [TunInterface] to the kernel before the
     * core starts (the bettbox flow): establish() -> fd -> startTun(fd, tun).
     */
    external fun startTun(fd: Int, tun: TunInterface)

    external fun stopTun()

    /**
     * A TunOptions handle as JSON (mtu, addresses, routes, dns, packages, http
     * proxy) — the fields VpnService.Builder needs when the kernel asks for the
     * VPN mid-start through CorePlatform.openTun.
     */
    external fun tunSpecJson(handle: Long): String

    /**
     * Dispatch one JSON Action synchronously and return the encoded
     * ActionResult. This is the Kotlin twin of the async `throne_invoke_action`
     * entry: host-side writers (route documents) have no Dart reply port and
     * need the answer on their own thread. Call off the main thread.
     */
    external fun runAction(actionJson: String): String

    /**
     * JSON host bridge for the stateless kernel helpers (version checks, config
     * validation, DNS resolve, WARP registration, diagnostics). The request is
     * `{"method","params"}` and the answer `{"ok","data"|"error"}`. Several
     * methods block; call off the main thread.
     */
    external fun hostCall(requestJson: String): String

    // The former `suspend` extern had zero callers and its throne_suspend C export
    // has been removed from the ABI; device doze now goes through the setDoze action.
    /** Register the platform-wide duties implementation (once). */
    external fun setPlatform(platform: CorePlatform)

    /** Report a default-interface change to a Go InterfaceUpdateListener. */
    external fun updateDefaultInterface(
        listener: Long,
        name: String,
        index: Int,
        isExpensive: Boolean,
        isConstrained: Boolean,
    )

    // P5: the former `updateNetworkPath` extern had zero callers; its
    // throne_InterfaceUpdateListener_updateNetworkPath export stays for the same reason.
    /** ExchangeContext completions (the local-DNS transport's answers, called while the call blocks). */
    external fun exchangeSuccess(handle: Long, result: String)

    external fun exchangeRawSuccess(handle: Long, result: ByteArray)

    external fun exchangeErrorCode(handle: Long, code: Int)

    external fun exchangeErrnoCode(handle: Long, code: Int)

    external fun exchangeOnCancel(handle: Long)
}
