package io.nekohasekai.sagernet.group

import io.flrone.bridge.DartProfileStore
import io.nekohasekai.sagernet.database.GroupRepo
import io.nekohasekai.sagernet.database.ProxyGroup
import io.nekohasekai.sagernet.database.SubUserInfo
import io.nekohasekai.sagernet.outbound.BuildContext
import io.nekohasekai.sagernet.outbound.import.ProfileImport
import java.io.File
import java.nio.charset.StandardCharsets
import java.util.Base64
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * "Newest intent wins" over [SubscriptionRefresh] (FlClash's rule for a slow profile download,
 * providers/actions/profiles.dart:168-179): a subscription answer that downloads slower than the user edits its
 * group must not be applied over the edit.
 *
 * The group row is a real `profiles.json` document ([DartProfileStore]), so the post-download re-read and the
 * deletion path run the production code; the fetch is a gated fake (a [CompletableDeferred] holds the answer until
 * the test lets it through), the importer is Throne's real parser and the apply step is recorded instead of running,
 * because [SubscriptionRefresh.apply] needs the Dart document writer, resources and the main looper.
 *
 * The user-edit bump is the one [io.flrone.bridge.FlroneProfiles] performs in `save`, `saveGroupSettings` and `write`
 * ([GroupRevisions.edit]); the refresh's own ticket is taken by [SubscriptionRefresh.refresh] itself.
 */
class SubscriptionRefreshRaceTest {

    private val gid = 1L
    private val subUrl = "https://example.test/sub"
    private val linkA = "ss://YWVzLTI1Ni1nY206cGFzcw@example.com:8388#Node%20A"
    private val linkB = "ss://YWVzLTI1Ni1nY206cGFzcw@example.org:8389#Node%20B"

    private lateinit var dir: File
    private var originalDirectory: File? = null
    private var originalLogger: (String, Throwable?) -> Unit = { _, _ -> }
    private var originalNotice: (ProxyGroup, SubscriptionRefresh.Surface) -> Unit = { _, _ -> }

    /** Throne's own importer with the global outbound settings at their defaults (the update path's parser). */
    private val parse: (String) -> ProfileImport.Result = { ProfileImport.parse(it, ctx = BuildContext.DEFAULT) }

    @Before
    fun setUp() {
        dir = File.createTempFile("sub-refresh-race", "").let { probe ->
            probe.delete()
            probe.mkdirs()
            probe
        }
        originalDirectory = DartProfileStore.directory
        originalLogger = DartProfileStore.logger
        DartProfileStore.directory = dir
        DartProfileStore.logger = { _, _ -> }
        DartProfileStore.invalidate()
        originalNotice = SubscriptionRefresh.supersededNotice
        GroupRevisions.forget(gid)
    }

    @After
    fun tearDown() {
        SubscriptionRefresh.supersededNotice = originalNotice
        GroupRevisions.forget(gid)
        DartProfileStore.directory = originalDirectory
        DartProfileStore.logger = originalLogger
        DartProfileStore.invalidate()
        dir.deleteRecursively()
    }

    /** Writes the Dart-owned document: the subscription group, or a catalog that no longer holds it. */
    private fun writeDocument(name: String = "sub", present: Boolean = true) {
        val groups = if (present) {
            """[{"id":$gid,"name":"$name","url":"$subUrl","display_order":1}]"""
        } else {
            "[]"
        }
        File(dir, "profiles.json").writeText(
            """{"version":1,"nextProfileId":10,"nextGroupId":10,"profiles":[],"groups":$groups}"""
        )
        DartProfileStore.invalidate()
    }

    /** A subscription body as a panel sends it: base64 over the share-link list. */
    private fun panelAnswer(links: String): SubscriptionFetch.Result = SubscriptionFetch.Result(
        Base64.getEncoder().encodeToString(links.toByteArray(StandardCharsets.UTF_8)),
        SubUserInfo(),
        null,
    )

    /** Runs the refresh with the fake fetch, recording the node names each apply would store. */
    private suspend fun refresh(
        surface: SubscriptionRefresh.Surface = SubscriptionRefresh.Surface.Diff,
        fetch: suspend (ProxyGroup) -> SubscriptionFetch.Result,
        applied: MutableList<List<String>>,
    ): Boolean = SubscriptionRefresh.refresh(
        gid = gid,
        surface = surface,
        notifyErrors = true,
        fetch = fetch,
        parseBody = parse,
        applyAnswer = { _, prepared, _ -> applied.add(prepared.servers.map { it.name }) },
    )

    @Test
    fun `a save during the download discards the stale answer`() = runBlocking {
        writeDocument()
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val applied = ArrayList<List<String>>()
        val notices = ArrayList<Pair<String, SubscriptionRefresh.Surface>>()
        SubscriptionRefresh.supersededNotice = { group, surface -> notices.add(group.name to surface) }

        val job = async(Dispatchers.Default) {
            refresh(
                fetch = {
                    entered.complete(Unit)
                    release.await()
                    panelAnswer(linkA)
                },
                applied = applied,
            )
        }
        entered.await()

        // The user saves the group form while the answer downloads. The URL is untouched, so only the revision can
        // tell that the answer is stale: FlroneProfiles.save/saveGroupSettings/write bump it in the same step as the
        // document write.
        writeDocument(name = "renamed")
        GroupRevisions.edit(gid)
        release.complete(Unit)

        assertFalse("the stale answer must not be applied", job.await())
        assertTrue("no node may be stored over the edit", applied.isEmpty())
        assertEquals(listOf("renamed" to SubscriptionRefresh.Surface.Diff), notices)
        assertEquals("the edit is what remains", "renamed", GroupRepo.get(gid)?.name)
    }

    @Test
    fun `a clean refresh applies the downloaded answer`() = runBlocking {
        writeDocument()
        val applied = ArrayList<List<String>>()
        var notices = 0
        SubscriptionRefresh.supersededNotice = { _, _ -> notices++ }

        val stored = refresh(fetch = { panelAnswer(linkA) }, applied = applied)

        assertTrue(stored)
        assertEquals(listOf(listOf("Node A")), applied)
        assertEquals("nothing is superseded when nothing was edited", 0, notices)
    }

    @Test
    fun `a refresh started after the edit applies normally`() = runBlocking {
        writeDocument()
        val applied = ArrayList<List<String>>()
        var notices = 0
        SubscriptionRefresh.supersededNotice = { _, _ -> notices++ }

        // The edit lands first; the refresh below is then the newest intent and its answer belongs to the new state.
        writeDocument(name = "renamed")
        GroupRevisions.edit(gid)

        assertTrue(refresh(fetch = { panelAnswer(linkA) }, applied = applied))
        assertEquals(listOf(listOf("Node A")), applied)
        assertEquals(0, notices)
        assertEquals("renamed", GroupRepo.get(gid)?.name)
    }

    @Test
    fun `two overlapping refreshes - only the newest applies`() = runBlocking {
        writeDocument()
        val firstEntered = CompletableDeferred<Unit>()
        val firstRelease = CompletableDeferred<Unit>()
        val secondEntered = CompletableDeferred<Unit>()
        val secondRelease = CompletableDeferred<Unit>()
        val applied = ArrayList<List<String>>()
        val notices = ArrayList<String>()
        SubscriptionRefresh.supersededNotice = { group, _ -> notices.add(group.name) }

        // A starts downloading, B starts while A is still in flight: B's ticket is the newest from that moment.
        val first = async(Dispatchers.Default) {
            refresh(
                fetch = {
                    firstEntered.complete(Unit)
                    firstRelease.await()
                    panelAnswer(linkA)
                },
                applied = applied,
            )
        }
        firstEntered.await()
        val second = async(Dispatchers.Default) {
            refresh(
                fetch = {
                    secondEntered.complete(Unit)
                    secondRelease.await()
                    panelAnswer(linkB)
                },
                applied = applied,
            )
        }
        secondEntered.await()

        firstRelease.complete(Unit)
        assertFalse("A was overtaken by B", first.await())
        secondRelease.complete(Unit)
        assertTrue(second.await())

        assertEquals(listOf(listOf("Node B")), applied)
        assertEquals(listOf("sub"), notices)
    }

    @Test
    fun `a group deleted during the download is not resurrected`() = runBlocking {
        writeDocument()
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val applied = ArrayList<List<String>>()
        var notices = 0
        SubscriptionRefresh.supersededNotice = { _, _ -> notices++ }

        val job = async(Dispatchers.Default) {
            refresh(
                fetch = {
                    entered.complete(Unit)
                    release.await()
                    panelAnswer(linkA)
                },
                applied = applied,
            )
        }
        entered.await()

        // The group is deleted while the answer downloads: nothing may re-create it or store its nodes.
        writeDocument(present = false)
        release.complete(Unit)

        assertFalse(job.await())
        assertTrue(applied.isEmpty())
        assertEquals(0, notices)
        assertNull(GroupRepo.get(gid))
        assertEquals("the counter went with the group", 0L, GroupRevisions.current(gid))
    }
}
