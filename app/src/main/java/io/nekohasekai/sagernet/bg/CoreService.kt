package io.nekohasekai.sagernet.bg

import android.app.Service
import android.content.Intent
import android.os.IBinder
import io.nekohasekai.sagernet.aidl.ICoreService
import io.nekohasekai.sagernet.aidl.ISubscriptionCallback
import io.nekohasekai.sagernet.aidl.ITestSessionCallback
import io.nekohasekai.sagernet.bg.test.TestEngine
import io.nekohasekai.sagernet.bg.test.TestSpec
import io.nekohasekai.sagernet.group.SubscriptionQueue
import java.util.IdentityHashMap

// Always-bindable :bg host for the probe boxes, so the main process never loads the core.
class CoreService : Service() {

    /**
     * AIDL subscription callbacks (kept for tests/WARP until Phase B is complete) adapted to the in-process
     * SubscriptionQueue listener. Identity-keyed so unregister removes exactly the adapter created for that binder.
     */
    private val subscriptionAdapters = IdentityHashMap<ISubscriptionCallback, SubscriptionQueue.SubscriptionListener>()

    private val binder = object : ICoreService.Stub() {

        override fun startTest(spec: TestSpec, cb: ITestSessionCallback): Int = TestEngine.start(spec, cb)

        override fun stopTests() = TestEngine.stop()

        override fun runningTestSession(): Int = TestEngine.runningSession()

        override fun refreshGroup(gid: Long, showDiff: Boolean) = SubscriptionQueue.refreshGroup(gid, showDiff)

        override fun refreshAll(onlyAllowed: Boolean) = SubscriptionQueue.refreshAll(onlyAllowed)

        override fun subscribeUrl(url: String, name: String?, autoUpdate: Boolean): Long =
            SubscriptionQueue.subscribeUrl(url, name.orEmpty(), autoUpdate)

        override fun importUrl(url: String, gid: Long) = SubscriptionQueue.importUrl(url, gid)

        override fun importFile(path: String, gid: Long) = SubscriptionQueue.importFile(path, gid)

        override fun groupAction(gid: Long, action: String): String = SubscriptionQueue.groupAction(gid, action)

        override fun resolveProfiles(ids: LongArray?): String = SubscriptionQueue.resolveProfiles(ids?.toList().orEmpty())

        // AIDL subscription callbacks remain only for any out-of-process caller left before Phase B completes;
        // the app's own path registers a SubscriptionListener directly on SubscriptionQueue.
        override fun registerSubscriptionCallback(cb: ISubscriptionCallback) {
            synchronized(subscriptionAdapters) {
                // AIDL callbacks are oneway; SubscriptionQueue dispatches on the main thread and swallows a
                // single listener's exception, so a direct delegate keeps the old delivery semantics.
                val listener = object : SubscriptionQueue.SubscriptionListener {
                    override fun onState(gid: Long, state: Int) = cb.onState(gid, state)
                    override fun onReport(gid: Long, title: String, text: String, popup: Boolean) =
                        cb.onReport(gid, title, text, popup)
                    override fun onError(gid: Long, message: String) = cb.onError(gid, message)
                    override fun onReloadNeeded(gid: Long) = cb.onReloadNeeded(gid)
                }
                subscriptionAdapters.put(cb, listener)?.let { SubscriptionQueue.unregister(it) }
                SubscriptionQueue.register(listener)
            }
        }

        override fun unregisterSubscriptionCallback(cb: ISubscriptionCallback) {
            synchronized(subscriptionAdapters) {
                subscriptionAdapters.remove(cb)?.let { SubscriptionQueue.unregister(it) }
            }
        }

        override fun warpRegister(tunnelType: String, proxy: String?, apiHosts: Array<String>?): String =
            WarpRegistration.register(tunnelType, proxy.orEmpty(), apiHosts ?: emptyArray())

        override fun genQuicSignature(domain: String?): String = QuicSignature.generate(domain.orEmpty())

        override fun captureDiagnostics(
            durationMs: Int,
            contention: Boolean,
            trace: Boolean,
            attachmentPaths: Array<String>?,
            outputPath: String?,
        ): String = CoreDiagnostics.capture(
            durationMs, contention, trace, attachmentPaths ?: emptyArray(), outputPath.orEmpty()
        )

        override fun stopDiagnostics() = CoreDiagnostics.stop()
    }

    override fun onCreate() {
        super.onCreate()
        CoreForeground.attach(this)
    }

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int =
        CoreForeground.onStartCommand(this, startId)

    override fun onTimeout(startId: Int, fgsType: Int) = CoreForeground.onTimeout(this)

    override fun onDestroy() {
        CoreForeground.detach(this)
        super.onDestroy()
    }
}
