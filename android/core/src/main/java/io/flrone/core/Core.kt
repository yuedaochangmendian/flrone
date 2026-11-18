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
     * Closes a kernel Instance the host adopted from Dart. A stop from the
     * widget/tile/notification has no Dart isolate to answer it once the Flutter
     * engine is gone, so the host owns the numeric handle until then.
     */
    external fun closeInstance(handle: Long)

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

    // P5: the former `suspend` extern had zero callers; its throne_suspend C export
    // stays in the 3-way ABI until the bindgen narrowing phase (ADR 0004 P4/P5).
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

    external fun exchangeOnCancel(handle: Long, callback: CancelToken?)
}

/**
 * Platform-side cancel token handed to [Core.exchangeOnCancel]. Owned by this
 * bridge module (io.flrone.core), not by gobind: the JNI shim resolves this
 * class by name in JNI_OnLoad. Replaces io.throneproj.mobile.Func so the
 * cancel path keeps Kotlin independent of the generated gobind proxy.
 */
fun interface CancelToken {
    fun invoke()
}
