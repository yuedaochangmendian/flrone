package io.flrone.flutter

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * S8 residual cleanup: the automatic subscription poll dispatches every due
 * group through the service engine's owner queue. The old Kotlin
 * `SubscriptionQueue` is gone, so there is no per-scheme fallback left to
 * split off: an unfetchable URL is refused/reported by the Dart queue itself.
 *
 * These pieces need a device engine/looper, so the test pins the source shape
 * (the same contract style used elsewhere in this package).
 */
class SubscriptionPollWiringTest {

    private fun source(path: String): String {
        val file = File(path)
        assertTrue("source not found: ${file.absolutePath}", file.exists())
        return file.readText()
    }

    private val scheduler by lazy {
        source("src/main/java/io/nekohasekai/sagernet/group/SubscriptionScheduler.kt")
    }
    private val bridge by lazy { source("src/main/java/io/flrone/flutter/ServiceBridge.kt") }
    private val entry by lazy { source("../flutter/lib/service_entry.dart") }
    private val engine by lazy { source("../flutter/lib/services/subscription_engine.dart") }

    @Test
    fun `checkAutoUpdate returns due ids and the poller sends all of them to the owner`() {
        assertTrue(
            "the poller must hand due ids to the owner engine",
            scheduler.contains("private fun checkAutoUpdate(period: Long): List<Long>"),
        )
        assertFalse(
            "the removed Kotlin queue must not be referenced",
            scheduler.contains("SubscriptionQueue"),
        )
        assertFalse(
            "there is no per-scheme legacy split any more",
            scheduler.contains("subscriptionNeedsLegacyPath") || scheduler.contains("dartIds"),
        )
        assertTrue(
            "the owner must be elected before any poll dispatch",
            scheduler.contains("if (!ServiceEngineManager.ensureDocumentOwner())"),
        )
        assertTrue(
            "a failed dispatch must retry the WorkManager job",
            scheduler.contains("return Result.retry()"),
        )
    }

    @Test
    fun `the poller awaits refreshMany with foreground false`() {
        assertTrue(scheduler.contains("requestSubscriptionAwait("))
        assertTrue(scheduler.contains("\"subscription.refreshMany\""))
        assertTrue(scheduler.contains("\"gids\" to dueIds"))
        assertTrue(scheduler.contains("\"foreground\" to false"))
    }

    @Test
    fun `the host bridge exposes an awaitable subscription channel call`() {
        assertTrue(
            bridge.contains("suspend fun requestSubscriptionAwait("),
        )
        assertTrue(
            "exactly-once settlement",
            bridge.contains("ReplyGate()"),
        )
        assertTrue(
            "a missing channel must fail the caller",
            bridge.contains("no service channel"),
        )
        assertTrue(
            "the fire-and-forget UI path stays",
            bridge.contains("fun requestSubscription(action: String"),
        )
    }

    @Test
    fun `the Dart surface has a request-reply refreshMany through the worker`() {
        assertTrue(engine.contains("Future<void> refreshMany("))
        assertTrue(engine.contains("await queue.awaitIdle()"))
        assertTrue(entry.contains("case 'subscription.refreshMany':"))
        assertTrue(entry.contains("case 'commandResult':"))
        assertTrue(entry.contains("subscriptionEngine.refreshMany("))
        assertTrue(entry.contains("'kind': 'commandResult'"))
    }
}
