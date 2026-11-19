package io.flrone.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The main-thread dispatch rule of the Kotlin -> Dart write bridge (#154).
 *
 * `MethodChannel.invokeMethod` is `@UiThread`, while every profile write runs on
 * an IO worker (GroupSort's queue, saveTestResult, a subscription refresh). The
 * bridge therefore posts the invoke to the main looper. These tests pin the
 * three branches — main inline, worker post, and the no-looper fallback —
 * without touching MethodChannel, BinaryMessenger or the mockable android.jar:
 * the repository has no channel-test harness, and the production hooks are the
 * only thing that may consult Looper.
 */
class DispatchToMainTest {

    @Test
    fun `a main-thread call runs inline and never posts`() {
        var posts = 0
        var runs = 0

        dispatchToMain(isMain = true, post = { _ -> posts++; false }) { runs++ }

        assertEquals("the main thread must not post to the looper it is already on", 0, posts)
        assertEquals(1, runs)
    }

    @Test
    fun `a worker call posts once and runs the block inside the post`() {
        var posts = 0
        var runs = 0
        var inPost = false
        var ranInsidePost = false

        dispatchToMain(
            isMain = false,
            post = { runnable ->
                posts++
                inPost = true
                runnable.run()
                inPost = false
                true
            },
        ) {
            ranInsidePost = inPost
            runs++
        }

        assertEquals("an IO write must be marshalled exactly once", 1, posts)
        assertEquals(1, runs)
        assertTrue("the invoke must run on the thread the post targeted", ranInsidePost)
    }

    @Test
    fun `a post without a main looper falls back to running in place`() {
        var posts = 0
        var runs = 0

        dispatchToMain(isMain = false, post = { _ -> posts++; false }) { runs++ }

        assertEquals(1, posts)
        assertEquals("a missing looper must not lose the write", 1, runs)
    }
}
