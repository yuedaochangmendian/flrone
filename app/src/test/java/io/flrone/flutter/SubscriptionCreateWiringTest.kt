package io.flrone.flutter

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * S8 residual cleanup: a new subscription is fetched, validated and stored only
 * by the Dart service engine (fetch → validate → create group → apply the
 * nodes), and a URL neither the Dart transport nor the `subscription.fetch` host
 * seam can read is refused with the host's own sentence — the Kotlin
 * refresh/import path is gone.
 *
 * These pieces need a device engine/looper, so — like [SubscriptionPollWiringTest]
 * — this test pins the source contract on both ends of the channel.
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
    private val host by lazy {
        source("src/main/java/io/flrone/flutter/SubscriptionHostFetch.kt")
    }
    private val bridge by lazy { source("src/main/java/io/flrone/flutter/ServiceBridge.kt") }
    private val entry by lazy { source("../flutter/lib/service_entry.dart") }
    private val engine by lazy { source("../flutter/lib/services/subscription_engine.dart") }
    private val refresh by lazy { source("../flutter/lib/services/subscription_refresh.dart") }

    @Test
    fun `the editor routes every create to the Dart owner`() {
        assertTrue(
            "the create branch must ask the Dart owner",
            profiles.contains("requestSubscriptionAwait(\"subscription.create\", payload)"),
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
        assertFalse(
            "no Kotlin create/fetch path may remain",
            profiles.contains("createValidated") || profiles.contains("SubscriptionRefresh"),
        )
        assertFalse(
            "no Kotlin content:// import sink may remain",
            profiles.contains("applyNew"),
        )
    }

    @Test
    fun `an unfetchable scheme is refused before anything is written`() {
        assertTrue(
            "the host predicate is the single scheme authority",
            commands.contains("fun subscriptionFetchError(group: ProxyGroup): String?"),
        )
        assertTrue(commands.contains("SubscriptionHostFetch.unsupportedReason(group)"))
        assertTrue(commands.contains("error(\"Cannot update \${group.displayName()}: \$reason\")"))
        assertTrue(
            "the editor validates a create/URL edit before its first write",
            profiles.contains("FlroneCommands.subscriptionFetchError(group)?.let { error(it) }") &&
                profiles.indexOf("FlroneCommands.subscriptionFetchError(group)") <
                profiles.indexOf("GroupRepo.save(group)"),
        )
        assertFalse(
            "the legacy Kotlin fetch/queue fallback is gone",
            commands.contains("subscriptionNeedsLegacyPath") ||
                commands.contains("SubscriptionQueue") ||
                profiles.contains("subscriptionNeedsLegacyPath") ||
                profiles.contains("SubscriptionQueue"),
        )
    }

    @Test
    fun `a content URL rides the host fetch seam without a Kotlin gate`() {
        assertFalse(
            "the create branch no longer splits URL schemes",
            profiles.contains("hostFetchUrl") || profiles.contains("commonUrl"),
        )
        assertTrue(
            "the host reader still accepts content:// (ContentResolver)",
            host.contains("\"http\", \"https\", \"content\" -> null"),
        )
        assertTrue(
            "a content:// create creates through the same host fetch seam",
            refresh.contains("isContent") && refresh.contains("_fetchCreate("),
        )
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
        assertTrue(
            "an unsupported create scheme fails with the same sentence",
            refresh.contains("Unsupported subscription scheme:"),
        )
    }
}
