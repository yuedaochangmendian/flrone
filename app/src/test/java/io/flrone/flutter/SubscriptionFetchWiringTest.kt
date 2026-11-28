package io.flrone.flutter

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * S6 fetch seam: `content://` and front/landing-proxy subscription bodies are
 * no longer a reason to skip the Dart owner. The service engine's
 * `subscription.fetch` host call runs Kotlin's own `SubscriptionFetch`
 * (ContentResolver path, RequestIdentity, OkHttp/proxy path) and answers the
 * Dart result shape, so the routing predicate can send those groups to Dart.
 *
 * The Android pieces need a device engine/ContentResolver, so — like the other
 * S6 wiring tests — this pins the source contract on both ends of the channel.
 */
class SubscriptionFetchWiringTest {

    private fun source(path: String): String {
        val file = File(path)
        assertTrue("source not found: ${file.absolutePath}", file.exists())
        return file.readText()
    }

    private val host by lazy {
        source("src/main/java/io/flrone/flutter/SubscriptionHostFetch.kt")
    }
    private val fetch by lazy {
        source("src/main/java/io/nekohasekai/sagernet/group/SubscriptionFetch.kt")
    }
    private val nets by lazy {
        source("src/main/java/io/nekohasekai/sagernet/ktx/Nets.kt")
    }
    private val bridge by lazy { source("src/main/java/io/flrone/flutter/ServiceBridge.kt") }
    private val commands by lazy {
        source("src/main/java/io/flrone/bridge/FlroneCommands.kt")
    }
    private val profiles by lazy {
        source("src/main/java/io/flrone/bridge/FlroneProfiles.kt")
    }
    private val entry by lazy { source("../flutter/lib/service_entry.dart") }
    private val refresh by lazy { source("../flutter/lib/services/subscription_refresh.dart") }
    private val transport by lazy {
        source("../flutter/lib/services/subscription_transport.dart")
    }

    @Test
    fun `the host fetch reuses Kotlin's own reader instead of a second one`() {
        assertTrue(
            "the body must come from the production reader (cap, compression, metadata)",
            host.contains("SubscriptionFetch.fetch(url, name, identity)"),
        )
        assertTrue(
            "the per-group identity is resolved the legacy way",
            host.contains("RequestIdentity.resolve(identitySource)"),
        )
        assertTrue(
            "a create has no group row yet, so its editor options stand in",
            host.contains("SubscriptionOptions.parse(subOptionsJson)"),
        )
        assertTrue(
            "a stored group is the identity source when gid is present",
            host.contains("GroupRepo.get(gid)"),
        )
        assertFalse(
            "the host must not duplicate the ContentResolver read (and its 64 MiB cap)",
            host.contains("openInputStream"),
        )
        assertFalse(
            "the host must not log a subscription URL or body",
            host.contains("Logs.i("),
        )
    }

    @Test
    fun `the host reply carries the whole result shape Dart needs`() {
        for (key in listOf(
            "\"supported\"",
            "\"body\"",
            "\"error\"",
            "\"headers\"",
            "\"finalUrl\"",
            "\"statusCode\"",
            "\"fileName\"",
            "\"contentDisposition\"",
            "\"metadata\"",
        )) {
            assertTrue("host reply is missing $key", host.contains(key))
        }
        assertTrue(
            "a scheme outside http(s)/content is refused precisely",
            host.contains("Unsupported subscription scheme"),
        )
        assertTrue(
            "the reader keeps the 64 MiB cap for content:// too",
            fetch.contains("const val MAX_BYTES = 64L * 1024 * 1024"),
        )
        assertTrue(nets.contains("fun headerMap(): Map<String, String>"))
        assertTrue(nets.contains("@JvmField val finalUrl: String"))
        assertTrue(nets.contains("@JvmField val statusCode: Int"))
    }

    @Test
    fun `the service bridge exposes the host fetch on its background queue`() {
        assertTrue(
            "subscription.fetch must have a service-channel handler",
            bridge.contains("\"subscription.fetch\" -> result.respond"),
        )
        assertTrue(
            "the blocking OkHttp/ContentResolver read runs off the channel thread",
            bridge.contains("withContext(Dispatchers.IO) { SubscriptionHostFetch.fetch(arguments) }"),
        )
    }

    @Test
    fun `the routing predicate leaves an unfetchable URL as an error`() {
        assertTrue(
            commands.contains("SubscriptionHostFetch.unsupportedReason(group)"),
        )
        assertFalse(commands.contains("startsWith(\"content://\", ignoreCase = true)"))
        assertFalse(commands.contains("group.frontProxyId > 0"))
        assertFalse(commands.contains("group.landingProxyId > 0"))
        assertTrue(
            "a save's URL-change refresh takes the same Dart-only path",
            profiles.contains("ServiceBridge.requestSubscription("),
        )
        assertFalse(
            "the legacy predicate and Kotlin queue are gone",
            profiles.contains("subscriptionNeedsLegacyPath") ||
                profiles.contains("SubscriptionQueue") ||
                commands.contains("SubscriptionQueue"),
        )
    }

    @Test
    fun `Dart routes content and proxy groups through the injected host seam`() {
        assertTrue(
            "the host call is a literal at the service boundary",
            entry.contains("host.call('subscription.fetch'"),
        )
        assertTrue(
            "the call only carries the URL, gid and editor options",
            entry.contains("'url': url") &&
                entry.contains("'gid': gid") &&
                entry.contains("'subOptionsJson': subOptionsJson"),
        )
        assertTrue(entry.contains("hostFetcher: hostSubscriptionFetch"))
        assertTrue(entry.contains("SubscriptionHostFetchReply.parse"))
        assertTrue(refresh.contains("typedef SubscriptionHostFetcher"))
        assertTrue(refresh.contains("_hostFetcher"))
        assertTrue(refresh.contains("_hostFetchNeeded"))
        assertTrue(
            "a content:// URL is a host input",
            refresh.contains("subscriptionUrlNeedsHost(group.url)"),
        )
        assertTrue(
            "front/landing proxy groups use the host identity/proxy path",
            refresh.contains("group.frontProxyId > 0") &&
                refresh.contains("group.landingProxyId > 0"),
        )
        assertTrue(
            "the host seam is only reported missing, never silently ignored",
            refresh.contains("if (!hostCoversFetch)"),
        )
        assertTrue(transport.contains("abstract final class SubscriptionHostFetchReply"))
        assertTrue(transport.contains("bool subscriptionUrlNeedsHost(String url)"))
        assertTrue(
            "Dart re-applies the redaction contract to host errors",
            transport.contains("SubscriptionHttpTransport.redact(error)"),
        )
    }
}
