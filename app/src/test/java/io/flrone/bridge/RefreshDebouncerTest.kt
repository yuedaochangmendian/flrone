package io.flrone.bridge

import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The lost-wakeup race in FlroneBridge.scheduleRefresh: the old code checked
 * `refreshJob?.isActive` and then launched in two steps, so concurrent callers could start two
 * readers, and a change arriving in the gap after the drain loop's final `dirty` check and before
 * coroutine completion was recorded but never consumed.
 *
 * [RefreshDebouncer] owns that logic. These tests drive it with a controllable `onRefresh` gate
 * on a background scope: (1) concurrent notifications during an in-flight pass coalesce into one
 * trailing pass; (2) a notification landing while the runner is deciding whether to exit still
 * starts another pass.
 */
class RefreshDebouncerTest {

    @Test
    fun `concurrent notifications during a refresh cause exactly one trailing refresh`() = runBlocking {
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val passes = AtomicInteger(0)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val debouncer = RefreshDebouncer(scope = scope, delayMs = 0L, onRefresh = {
            if (passes.incrementAndGet() == 1) {
                entered.complete(Unit)
                release.await() // hold the first pass open while notifications pile up
            }
        })

        debouncer.schedule(immediate = true)
        entered.await()
        assertEquals("first pass started", 1, passes.get())

        // Many concurrent notifications: each must coalesce into a single pending pass.
        val callers = (1..64).map {
            async(Dispatchers.Default) { debouncer.schedule() }
        }
        callers.awaitAll()
        release.complete(Unit)

        awaitCondition { passes.get() == 2 }
        assertEquals("all concurrent changes must coalesce into one trailing pass", 2, passes.get())
    }

    @Test
    fun `a notification in the end-of-pass window is not lost`() = runBlocking {
        // The seam fires after runner 1 has atomically released its slot but before its coroutine
        // ends — precisely the tight window the old implementation dropped a wakeup in. The
        // notification must claim a fresh runner and produce exactly one more pass.
        val passes = AtomicInteger(0)
        val secondDone = CompletableDeferred<Unit>()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val reentry = AtomicReference<RefreshDebouncer?>(null)
        var notifier: (() -> Unit)? = null
        val debouncer = RefreshDebouncer(
            scope,
            delayMs = 0L,
            onRefresh = {
                if (passes.incrementAndGet() == 2) secondDone.complete(Unit)
            },
            onBeforeExit = { notifier?.invoke() },
        )
        reentry.set(debouncer)
        notifier = { reentry.get()?.schedule() }

        debouncer.schedule(immediate = true)
        secondDone.await()
        assertEquals("the in-window notification must start a fresh runner", 2, passes.get())
    }

    @Test
    fun `sequential notifications after each completion get their own pass`() = runBlocking {
        val passes = AtomicInteger(0)
        val done = CompletableDeferred<Unit>()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val debouncer = RefreshDebouncer(scope = scope, delayMs = 0L, onRefresh = {
            if (passes.incrementAndGet() == 3) done.complete(Unit)
        })

        debouncer.schedule(immediate = true)
        awaitCondition { passes.get() >= 1 }
        debouncer.schedule(immediate = true)
        awaitCondition { passes.get() >= 2 }
        debouncer.schedule(immediate = true)
        done.await()

        assertEquals("each settled notification must be consumed", 3, passes.get())
    }

    /** Spin with yield until [condition] holds, bounded so a regression fails fast instead of hanging. */
    private suspend fun awaitCondition(condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 5_000L
        while (!condition()) {
            if (System.currentTimeMillis() > deadline) {
                throw AssertionError("condition not met within 5s")
            }
            yield()
        }
    }
}
