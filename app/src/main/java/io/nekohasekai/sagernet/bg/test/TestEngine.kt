package io.nekohasekai.sagernet.bg.test

import android.os.Handler
import android.os.Looper
import io.nekohasekai.sagernet.bg.proto.SpeedTestSnapshot
import io.nekohasekai.sagernet.database.ProxyEntity
import io.nekohasekai.sagernet.ktx.Logs
import io.flrone.core.CoreInstance
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger

/**
 * The in-process test engine (the desktop TestRunner): one session at a time under a lock held for the whole sweep;
 * interactive sessions are refused while it is held, [queueUrlTests] waits for it. Since P6 the service and UI share
 * one process, so the UI calls these entry points directly instead of binding CoreService's AIDL stub.
 */
object TestEngine {

    /** How long a stopped session may take to wind down before its coroutines are cancelled. */
    private const val STOP_GRACE_MS = 15_000L

    /**
     * The in-process test event sink, replacing the old oneway binder callback. Methods are dispatched on the main
     * thread, mirroring the old asynchronous callback so the UI's StateFlow sees the same delivery semantics.
     */
    interface TestSessionListener {
        fun onStarted(session: Int, kind: Int, total: Int) {}
        fun onUrlResult(profileId: Long, latency: Int, error: String) {}
        fun onIpResult(profileId: Long, ip: String, country: String, error: String) {}
        fun onSpeedProgress(snapshot: SpeedTestSnapshot) {}
        fun onSpeedResult(
            profileId: Long, dl: String, ul: String, latency: Int, country: String, error: String,
        ) {}
        fun onDone(session: Int, cancelled: Boolean) {}
    }

    /** Posts test events to the main thread; matches the old oneway AIDL callback's async delivery. */
    private val main = Handler(Looper.getMainLooper())

    /**
     * The engine's current listeners. A session's listener is added for its lifetime at [start] and removed at
     * [finish]; only one interactive session runs at a time, so a dispatch reaches exactly the requesting UI.
     */
    private val listeners = CopyOnWriteArrayList<TestSessionListener>()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val session = Mutex()
    private val sessionIds = AtomicInteger()

    @Volatile
    private var current: TestSession? = null

    private fun register(listener: TestSessionListener) {
        listeners.addIfAbsent(listener)
    }

    private fun unregister(listener: TestSessionListener) {
        listeners.remove(listener)
    }

    /**
     * Dispatch an event to all listeners on the main thread. The receiver snapshot is taken here, so unregistering a
     * listener at [finish] cannot drop an event (notably the final onDone) already on its way. A single bad listener
     * must not silence the others.
     */
    internal fun dispatch(block: (TestSessionListener) -> Unit) {
        val snapshot = listeners.toList()
        if (snapshot.isEmpty()) return
        main.post {
            for (listener in snapshot) {
                runCatching { block(listener) }.onFailure { Logs.w(it) }
            }
        }
    }

    /** Starts a session and returns its id, -1 while another session runs. */
    fun start(spec: TestSpec, listener: TestSessionListener): Int {
        if (!session.tryLock()) return -1
        register(listener)
        val test = TestSession(sessionIds.incrementAndGet(), spec, listener)
        current = test
        test.job = scope.launch {
            try {
                test.run()
            } finally {
                finish(test)
            }
        }
        return test.id
    }

    /** TestRunner::stop: the core aborts what runs, the session starts nothing new and ends with onDone(cancelled). */
    fun stop() {
        val test = current
        if (test == null) CoreInstance.stopTests() else stop(test)
    }

    /** profile_stop (mainwindow_profile_lifecycle.cpp:419-423): a test of the running box ends with the box. */
    fun onRunningClosed() {
        current?.takeIf { it.spec.testCurrent }?.let { stop(it) }
    }

    private fun stop(test: TestSession) {
        test.stop()
        scope.launch {
            delay(STOP_GRACE_MS)
            test.job?.cancel()
        }
    }

    /** The running session id, 0 when idle. */
    fun runningSession(): Int = current?.id ?: 0

    /**
     * Waits for a running session to finish, then URL-tests [ids] and persists the results (desktop queueUrlTests);
     * cancelling the caller stops the tests. [onResult] gets each stored result on a test thread, a profile possibly
     * twice (a failure, then its Connect OK verdict). No UI listener is involved in this silent sweep.
     */
    suspend fun queueUrlTests(ids: List<Long>, onResult: ((ProxyEntity) -> Unit)? = null) {
        if (ids.isEmpty()) return
        session.lock()
        val test = TestSession(sessionIds.incrementAndGet(), TestSpec(TestSpec.KIND_URL, ids.toLongArray()), null, onResult)
        current = test
        try {
            coroutineScope {
                val job = launch(Dispatchers.IO) { test.run() }
                test.job = job
                job.join()
            }
        } finally {
            finish(test)
        }
    }

    private fun finish(test: TestSession) {
        if (current === test) current = null
        test.listener?.let(::unregister)
        session.unlock()
    }
}
