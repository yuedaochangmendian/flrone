package io.nekohasekai.sagernet.group

import io.nekohasekai.sagernet.database.ProxyGroup
import io.nekohasekai.sagernet.database.SubUserInfo
import io.nekohasekai.sagernet.outbound.BuildContext
import io.nekohasekai.sagernet.outbound.`import`.ProfileImport
import java.nio.charset.StandardCharsets
import java.util.Base64
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * S8: a URL subscription is downloaded and validated BEFORE its group row exists (FlClash's add,
 * models/profile.dart:201-214).
 *
 * The fetch is injected, so these pin the ordering the whole change is about: a rejected body never reaches the
 * create step (that is where `GroupRepo.add` and the Dart document write sit), a usable one reaches it exactly once
 * with the answer the update path would otherwise download again. The importer is injected too, because
 * `SettingsMapper.buildContext()` reads the settings document through `DataStore`, whose Room initialisation needs
 * the Android application; the parser itself is the real one, with [BuildContext.DEFAULT]. The apply step
 * (`SubscriptionRefresh.applyNew`) is the update path's own code and needs the Dart document, so it stays out of a
 * JVM test.
 */
class SubscriptionCreateTest {

    private val link = "ss://YWVzLTI1Ni1nY206cGFzcw@example.com:8388#Node%20A"
    private val second = "ss://YWVzLTI1Ni1nY206cGFzcw@example.org:8389#Node%20B"

    /** Throne's own importer, with the global outbound settings at their defaults. */
    private val parse: (String) -> ProfileImport.Result = { ProfileImport.parse(it, ctx = BuildContext.DEFAULT) }

    /** A subscription body as a panel sends it: base64 over the share-link list. */
    private fun body(text: String): String =
        Base64.getEncoder().encodeToString(text.toByteArray(StandardCharsets.UTF_8))

    private fun subscription(name: String = "Subscription", options: (ProxyGroup) -> Unit = {}) =
        ProxyGroup(name = name, url = "https://example.test/sub").apply(options)

    private fun answer(
        text: String,
        info: SubUserInfo = SubUserInfo(),
        contentDisposition: String = "",
    ) = SubscriptionFetch.Result(text, info, null, contentDisposition = contentDisposition)

    private fun failure(message: String) = SubscriptionFetch.Result("", SubUserInfo(), message)

    /** Stands in for `GroupRepo.add` + `SubscriptionRefresh.applyNew`: records what the create step was handed. */
    private class Creator {
        val groups = ArrayList<ProxyGroup>()
        val answers = ArrayList<SubscriptionRefresh.Prepared>()
        var nextId = 1L

        suspend fun create(group: ProxyGroup, prepared: SubscriptionRefresh.Prepared): Long {
            groups.add(group)
            answers.add(prepared)
            return nextId++
        }
    }

    private fun create(
        group: ProxyGroup,
        fetched: SubscriptionFetch.Result,
        creator: Creator,
    ): Result<Long> = runCatching {
        runBlocking {
            SubscriptionRefresh.createValidated(
                group,
                fetch = { fetched },
                parseBody = parse,
                create = creator::create,
            )
        }
    }

    private fun rejected(outcome: Result<Long>): SubscriptionRefresh.Rejected {
        val error = outcome.exceptionOrNull()
        assertTrue("expected a Rejected, got $error", error is SubscriptionRefresh.Rejected)
        return error as SubscriptionRefresh.Rejected
    }

    @Test
    fun `an unreachable subscription never creates a group`() {
        val creator = Creator()

        val rejected = rejected(create(subscription(), failure("Could not connect to example.test"), creator))

        assertEquals(SubscriptionRefresh.Rejected.Reason.FETCH, rejected.reason)
        assertEquals("Could not connect to example.test", rejected.error)
        assertTrue(creator.groups.isEmpty())
    }

    @Test
    fun `an HTTP error never creates a group`() {
        val creator = Creator()

        val rejected = rejected(create(subscription(), failure("HTTP 404 Not Found"), creator))

        assertEquals(SubscriptionRefresh.Rejected.Reason.FETCH, rejected.reason)
        assertTrue(creator.groups.isEmpty())
    }

    @Test
    fun `an empty body never creates a group`() {
        val creator = Creator()

        val rejected = rejected(create(subscription(), answer(""), creator))

        assertEquals(SubscriptionRefresh.Rejected.Reason.EMPTY, rejected.reason)
        assertTrue(creator.groups.isEmpty())
    }

    @Test
    fun `a block page never creates a group`() {
        val creator = Creator()
        val page = "<!DOCTYPE html><html><body>Just a moment…</body></html>"

        val rejected = rejected(create(subscription(), answer(page), creator))

        assertEquals(SubscriptionRefresh.Rejected.Reason.WEB_PAGE, rejected.reason)
        assertTrue(creator.groups.isEmpty())
    }

    @Test
    fun `a body the name filter empties never creates a group`() {
        val creator = Creator()
        val group = subscription { it.subOptions.nameExclude = ".*" }

        val rejected = rejected(create(group, answer(body("$link\n$second")), creator))

        assertEquals(SubscriptionRefresh.Rejected.Reason.FILTERED, rejected.reason)
        assertEquals(2, rejected.result?.outbounds?.size)
        assertTrue(creator.groups.isEmpty())
    }

    @Test
    fun `a valid body creates the group once with the fetched answer`() {
        val creator = Creator()
        val group = subscription()
        val info = SubUserInfo(valid = true, total = 1_000L, download = 10L, serverInterval = 6)

        val id = create(group, answer(body("$link\n$second"), info), creator).getOrThrow()

        assertEquals(1L, id)
        assertEquals(1, creator.groups.size)
        assertSame(group, creator.groups.single())
        val prepared = creator.answers.single()
        assertEquals(listOf("Node A", "Node B"), prepared.servers.map { it.name })
        assertEquals(listOf("Node A", "Node B"), prepared.named.map { it.name })
        // The metadata the create path persists onward is the answer's own, not a second download's.
        assertEquals(6, prepared.info.serverInterval)
        assertEquals(1_000L, prepared.info.total)
        assertEquals("", prepared.routing)
    }

    @Test
    fun `a content disposition supplies the fallback subscription name`() {
        val creator = Creator()

        create(
            subscription(name = ""),
            answer(
                body(link),
                contentDisposition = "attachment; filename*=UTF-8''My%20Panel.yaml",
            ),
            creator,
        ).getOrThrow()

        assertEquals("My Panel.yaml", creator.answers.single().fileName)
    }

    @Test
    fun `a body that repeats a node is stored once`() {
        val creator = Creator()

        create(subscription(), answer(body("$link\n$link")), creator).getOrThrow()

        assertEquals(listOf("Node A"), creator.answers.single().servers.map { it.name })
    }

    @Test
    fun `adding the same URL twice still creates two groups`() {
        val creator = Creator()
        val first = subscription()
        val again = subscription()

        val ids = listOf(
            create(first, answer(body(link)), creator).getOrThrow(),
            create(again, answer(body(link)), creator).getOrThrow(),
        )

        // The URL is not a uniqueness key in this app: a second add is a second group, and the validation pass
        // neither reuses the first one nor merges into it.
        assertEquals(listOf(1L, 2L), ids)
        assertEquals(2, creator.groups.size)
        assertEquals(2, creator.answers.size)
    }

    @Test
    fun `the update path validates through the same prepare step`() {
        val group = subscription()

        // A fetch failure and an unusable body are rejected before anything is written.
        val failed = runCatching { SubscriptionRefresh.prepare(group, failure("timeout"), parse) }.exceptionOrNull()
        assertTrue(failed is SubscriptionRefresh.Rejected)
        assertEquals(SubscriptionRefresh.Rejected.Reason.FETCH, (failed as SubscriptionRefresh.Rejected).reason)

        val empty = runCatching { SubscriptionRefresh.prepare(group, answer(""), parse) }.exceptionOrNull()
        assertEquals(
            SubscriptionRefresh.Rejected.Reason.EMPTY,
            (empty as SubscriptionRefresh.Rejected).reason,
        )

        // A usable answer comes back as the node list the update sinks.
        val prepared = SubscriptionRefresh.prepare(group, answer(body("$link\n$second")), parse)
        assertEquals(2, prepared.servers.size)
    }
}
