package io.nekohasekai.sagernet.bg

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Truth table for the two start attributes BaseService carries across a START_STICKY restart.
 * A null intent means the system restarted the service with no command: engineArgs and the
 * always-on flag must survive, or BootGate sees a "user start" and lets a boot that died
 * before the UI came up relaunch the tunnel. An explicit intent carries its own truth and
 * overrides (including clearing) the remembered values. Kept pure — no Android runtime.
 */
class StartAttributesTest {

    @Test
    fun `engineArgs from a null intent preserve the previous args`() {
        val previous = listOf("quick", "boot")
        assertEquals(previous, BaseService.StartAttributes.engineArgs(null, previous))
        // A sticky restart of a user start has nothing to preserve.
        assertEquals(emptyList<String>(), BaseService.StartAttributes.engineArgs(null, emptyList()))
    }

    @Test
    fun `engineArgs from an explicit intent override, including clearing on a user start`() {
        val previous = listOf("quick", "boot")
        assertEquals(emptyList<String>(), BaseService.StartAttributes.engineArgs(emptyList(), previous))
        assertEquals(listOf("quick"), BaseService.StartAttributes.engineArgs(listOf("quick"), previous))
        assertEquals(listOf("prewarm"), BaseService.StartAttributes.engineArgs(listOf("prewarm"), emptyList()))
    }

    @Test
    fun `alwaysOn from a null intent preserves the previous bit`() {
        assertEquals(true, BaseService.StartAttributes.alwaysOnStart(false, true, false))
        assertEquals(false, BaseService.StartAttributes.alwaysOnStart(true, false, false))
    }

    @Test
    fun `alwaysOn from an explicit intent overrides, so a user start clears it`() {
        assertEquals(false, BaseService.StartAttributes.alwaysOnStart(false, true, true))
        assertEquals(true, BaseService.StartAttributes.alwaysOnStart(true, false, true))
        assertEquals(false, BaseService.StartAttributes.alwaysOnStart(false, false, true))
    }

    @Test
    fun `full truth table sticky restart keeps both, explicit start replaces both`() {
        val previousArgs = listOf("quick", "boot")
        // START_STICKY: null intent, previous always-on start.
        assertEquals(
            previousArgs,
            BaseService.StartAttributes.engineArgs(null, previousArgs),
        )
        assertEquals(true, BaseService.StartAttributes.alwaysOnStart(false, true, false))
        // New explicit user start: no flags, not always-on.
        assertEquals(
            emptyList<String>(),
            BaseService.StartAttributes.engineArgs(emptyList(), previousArgs),
        )
        assertEquals(false, BaseService.StartAttributes.alwaysOnStart(false, true, true))
        // Platform always-on start: no args, but the action says always-on.
        assertEquals(
            emptyList<String>(),
            BaseService.StartAttributes.engineArgs(emptyList(), emptyList()),
        )
        assertEquals(true, BaseService.StartAttributes.alwaysOnStart(true, false, true))
    }
}
