package io.flrone.flutter

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * S6 new-subscription create: the common HTTP(S) case must be dispatched to the
 * Dart document owner through `subscription.create`, while content:// and
 * front/landing proxies keep the Kotlin legacy path. Name include/exclude
 * filters are implemented in the Dart refresh. These pieces need a device
 * engine/looper, so — like [SubscriptionPollWiringTest] — this test pins the
 * source contract on both ends of the channel.
 */
class SubscriptionCreateWiringTest {

    private fun source(path: String): String {
        val file = File(path)
        assertTrue("source not found: ${file.absolutePath}", file.exists())
        return file.readText()
    }

    private val profiles by lazy {
        source("src/main/java/io/flrone/bridge/FlroneProfiles.kt")
    }
    private val commands by lazy {
        source("src/main/java/io/flrone/bridge/FlroneCommands.kt")
    }
    private val bridge by lazy { source("src/main/java/io/flrone/flutter/ServiceBridge.kt") }
    private val entry by lazy { source("../flutter/lib/service_entry.dart") }
    private val engine by lazy { source("../flutter/lib/services/subscription_engine.dart") }
    private val refresh by lazy { source("../flutter/lib/services/subscription_refresh.dart") }

    @Test
    fun `the editor routes common subscriptions to the host request`() {
        assertTrue(
            "the create branch must ask the Dart owner",
            profiles.contains("requestSubscriptionAwait(\"subscription.create\", payload)"),
        )
        assertTrue(
            "a common URL must be gated on http/https",
            profiles.contains("trimmedUrl.startsWith(\"http://\", ignoreCase = true)") &&
                profiles.contains("trimmedUrl.startsWith(\"https://\", ignoreCase = true)"),
        )
        assertTrue(
            "Kotlin-only features must keep the legacy path",
            profiles.contains("!FlroneCommands.subscriptionNeedsLegacyPath(group)"),
        )
        assertTrue(
            "the group id must come back from the Dart reply",
            profiles.contains("?.get(\"gid\") as? Number"),
        )
        assertTrue(
            "the payload carries the editor options without credentials",
            profiles.contains("\"subOptionsJson\" to group.subOptions.toJsonString()") &&
                profiles.contains("\"autoUpdate\" to !group.skipAutoUpdate"),
        )
        assertTrue(
            "the legacy create must remain for the unsupported features",
            profiles.contains("SubscriptionRefresh.createValidated(group)"),
        )
    }

    @Test
    fun `the legacy predicate covers content and proxies`() {
        assertTrue(commands.contains("fun subscriptionNeedsLegacyPath(group: ProxyGroup): Boolean"))
        assertTrue(commands.contains("startsWith(\"content://\", ignoreCase = true)"))
        assertTrue(commands.contains("group.frontProxyId > 0"))
        assertTrue(commands.contains("group.landingProxyId > 0"))
    }

    @Test
    fun `the Dart service entry has a request-reply create command`() {
        assertTrue(entry.contains("case 'subscription.create':"))
        assertTrue(entry.contains("'kind': 'commandResult'"))
        assertTrue(entry.contains("subscriptionEngine.create("))
        assertTrue(entry.contains("'gid': created.gid"))
        assertTrue(engine.contains("Future<SubscriptionCreateResult> create("))
        assertTrue(engine.contains("SubscriptionCreateRunner"))
        assertTrue(refresh.contains("Future<SubscriptionCreateResult> create({"))
        assertTrue(refresh.contains("createSubscriptionGroup("))
    }
}
