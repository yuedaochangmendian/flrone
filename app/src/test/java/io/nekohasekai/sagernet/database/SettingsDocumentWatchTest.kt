package io.nekohasekai.sagernet.database

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The read-driven settings document watch: one stat pair per interval, a quiet first baseline,
 * and a single callback per detected change. Pure JVM — the clock and the stamp source are
 * injected, so no file, no Android types.
 */
class SettingsDocumentWatchTest {

    private val interval = 2_000_000_000L
    private var now = 0L
    private var stamp: SettingsStamp? = SettingsStamp(1L, 100L)
    private var stats = 0
    private var fires = 0

    private fun watch() = SettingsDocumentWatch(
        clock = { now },
        stampSource = {
            stats++
            stamp
        },
        intervalNanos = interval,
        onChanged = { fires++ },
    )

    @Test
    fun `construction neither stats nor fires`() {
        watch()
        assertEquals(0, stats)
        assertEquals(0, fires)
    }

    @Test
    fun `first check records the baseline without firing`() {
        val watch = watch()
        watch.check()
        assertEquals(1, stats)
        assertEquals(0, fires)
    }

    @Test
    fun `an unchanged stamp never fires`() {
        val watch = watch()
        watch.check()
        now += interval
        watch.check()
        now += interval
        watch.check()
        assertEquals(3, stats)
        assertEquals(0, fires)
    }

    @Test
    fun `a changed stamp fires once`() {
        val watch = watch()
        watch.check()
        now += interval
        stamp = SettingsStamp(2L, 100L)
        watch.check()
        assertEquals(1, fires)
        now += interval
        watch.check()
        assertEquals("the new stamp is the baseline now", 1, fires)
    }

    @Test
    fun `prime records the baseline without firing`() {
        val watch = watch()
        watch.prime()
        assertEquals(1, stats)
        assertEquals(0, fires)
        now += interval
        watch.check()
        assertEquals(0, fires)
    }

    @Test
    fun `a change after prime fires`() {
        val watch = watch()
        watch.prime()
        now += interval
        stamp = SettingsStamp(2L, 100L)
        watch.check()
        assertEquals(1, fires)
    }

    @Test
    fun `a null stamp is a no-op and keeps the last seen stamp`() {
        val watch = watch()
        watch.check()
        now += interval
        stamp = null
        watch.check()
        assertEquals(0, fires)
        now += interval
        stamp = SettingsStamp(1L, 100L)
        watch.check()
        assertEquals("the baseline was not cleared by the null stat", 0, fires)
        now += interval
        stamp = SettingsStamp(3L, 100L)
        watch.check()
        assertEquals(1, fires)
    }

    @Test
    fun `a null prime keeps the previous baseline`() {
        val watch = watch()
        watch.prime()
        now += interval
        stamp = null
        watch.prime()
        now += interval
        stamp = SettingsStamp(1L, 100L)
        watch.check()
        assertEquals(0, fires)
    }

    @Test
    fun `at most one stat per interval`() {
        val watch = watch()
        watch.check()
        assertEquals(1, stats)
        now = interval - 1
        watch.check()
        assertEquals(1, stats)
        now = interval
        watch.check()
        assertEquals(2, stats)
    }

    @Test
    fun `a change after the interval fires again`() {
        val watch = watch()
        watch.check()
        now += interval
        stamp = SettingsStamp(2L, 100L)
        watch.check()
        now += interval
        stamp = SettingsStamp(3L, 100L)
        watch.check()
        assertEquals(2, fires)
    }
}
