package io.flrone.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The route version (S7): the status card discards a probe answer whose version moved while
 * the request was in flight, so the counter must move on every route input and *only* then —
 * over-bumping would throw away honest answers during unrelated refreshes.
 */
class RouteProvenanceTest {

    private fun signature(
        status: String = "Started",
        profile: Long = 1L,
        mode: String = "rule",
        startedAt: Long? = 100L,
        selections: List<String> = listOf("Proxy:a"),
    ) = RouteProvenance.signature(status, profile, mode, startedAt, selections)

    @Test
    fun `the first observation only records the baseline`() {
        RouteProvenance.reset()
        assertEquals(0L, RouteProvenance.observe(signature()))
        // An answer taken before the first wire is built carries version 0; re-labelling it
        // would make every first-frame probe look stale.
        assertEquals(0L, RouteProvenance.version)
    }

    @Test
    fun `an unchanged route keeps its version`() {
        RouteProvenance.reset()
        val first = RouteProvenance.observe(signature())
        assertEquals(first, RouteProvenance.observe(signature()))
        assertEquals(first, RouteProvenance.observe(signature()))
    }

    @Test
    fun `every route input moves the version`() {
        RouteProvenance.reset()
        RouteProvenance.observe(signature())
        val base = RouteProvenance.version
        val moved = listOf(
            signature(status = "Stopped"),          // service Connected -> Stopped
            signature(profile = 2L),                // profile switch / proxy selection
            signature(mode = "global"),             // mode change
            signature(startedAt = 200L),            // a restarted session
            signature(selections = listOf("Proxy:b")), // selector group's current route
        )
        var seen = base
        for (candidate in moved) {
            val next = RouteProvenance.observe(candidate)
            assertTrue("expected $candidate to move the version", next > seen)
            seen = next
        }
        assertEquals(base + moved.size, RouteProvenance.version)
    }

    @Test
    fun `an explicit bump moves the version without a new signature`() {
        RouteProvenance.reset()
        RouteProvenance.observe(signature())
        val before = RouteProvenance.version
        val bumped = RouteProvenance.bump()
        assertEquals(before + 1, bumped)
        assertNotEquals(before, bumped)
        // The snapshot that follows the bump must not move it a second time: the version
        // describes the same route the bump just announced.
        assertEquals(bumped, RouteProvenance.observe(signature()))
    }

    @Test
    fun `a null signature is a state of its own`() {
        RouteProvenance.reset()
        val missing = RouteProvenance.observe(null)
        val present = RouteProvenance.observe(signature())
        assertEquals(missing + 1, present)
        // Going back to "no signature at all" is a state change too; staying there is not.
        val moved = RouteProvenance.observe(null)
        assertEquals(present + 1, moved)
        assertEquals(moved, RouteProvenance.observe(null))
    }

    @Test
    fun `an observation reports whether it moved the version`() {
        RouteProvenance.reset()
        val first = RouteProvenance.observeMoved(signature())
        assertEquals(0L, first.version)
        assertFalse("the first observation is only a baseline", first.moved)
        val same = RouteProvenance.observeMoved(signature())
        assertEquals(first.version, same.version)
        assertFalse("an unchanged route must not invalidate the cached exit", same.moved)
        val changed = RouteProvenance.observeMoved(signature(mode = "global"))
        assertTrue("a moved route must invalidate the cached exit", changed.moved)
        assertEquals(first.version + 1, changed.version)
    }

    @Test
    fun `the signature carries every field that can move the route`() {
        assertEquals(
            "Started|7|global|99|Proxy:a|Auto:b",
            RouteProvenance.signature("Started", 7L, "global", 99L, listOf("Proxy:a", "Auto:b")),
        )
        assertEquals("Started|7|rule|0", RouteProvenance.signature("Started", 7L, "rule", null, emptyList()))
    }

    @Test
    fun `a stopped service never publishes the last session's connection count`() {
        assertEquals(3, publishedConnectionCount(running = true, counted = 3))
        assertEquals(0, publishedConnectionCount(running = false, counted = 3))
        assertEquals(0, publishedConnectionCount(running = true, counted = -1))
    }
}
