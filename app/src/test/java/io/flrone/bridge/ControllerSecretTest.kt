// "An open external controller always has a secret; a closed one drops it."
//
// The rule is pure, so these tests pin the four states the settings screen can reach and the
// persistence contract around them: the secret is written only when it changes, which is what
// keeps a second config build (or a second launch) from rotating the credentials an external
// dashboard is already using.

package io.flrone.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ControllerSecretTest {

    @Test
    fun `enabled with a blank secret generates one and persists it`() {
        val decision = ControllerSecret.ensure(enabled = true, current = "", generate = { "generated-1" })

        assertEquals("generated-1", decision.secret)
        assertTrue(decision.persist)
        assertTrue(decision.available)
    }

    @Test
    fun `a missing row is the same as a blank secret`() {
        val decision = ControllerSecret.ensure(enabled = true, current = null, generate = { "generated-1" })

        assertEquals("generated-1", decision.secret)
        assertTrue(decision.persist)
    }

    @Test
    fun `enabled with a secret keeps it and never calls the generator`() {
        var generated = 0
        val decision = ControllerSecret.ensure(enabled = true, current = "kept-secret", generate = {
            generated++
            "rotated"
        })

        assertEquals("kept-secret", decision.secret)
        assertFalse(decision.persist)
        assertEquals(0, generated)
    }

    @Test
    fun `a whitespace-only secret is not a secret`() {
        val decision = ControllerSecret.ensure(enabled = true, current = "   ", generate = { "generated-2" })

        assertEquals("generated-2", decision.secret)
        assertTrue(decision.persist)
    }

    @Test
    fun `disabling drops the stored secret`() {
        val decision = ControllerSecret.ensure(enabled = false, current = "stale-secret", generate = { "unused" })

        assertEquals("", decision.secret)
        assertTrue(decision.persist)
        assertFalse(decision.available)
    }

    @Test
    fun `disabled with nothing stored writes nothing`() {
        val decision = ControllerSecret.ensure(enabled = false, current = "", generate = { "unused" })

        assertEquals("", decision.secret)
        assertFalse(decision.persist)
    }

    @Test
    fun `a blank generator leaves the controller unavailable instead of open`() {
        // The default generator cannot return blank; this is the injected one, and the rule must
        // neither throw on the start path nor hand back "" as if it were a secret.
        val decision = ControllerSecret.ensure(enabled = true, current = "", generate = { "" })

        assertEquals("", decision.secret)
        assertFalse(decision.persist)
        assertFalse(decision.available)
    }

    @Test
    fun `a blank generator still cleans up a whitespace secret`() {
        val decision = ControllerSecret.ensure(enabled = true, current = " ", generate = { "" })

        assertEquals("", decision.secret)
        assertTrue(decision.persist)
        assertFalse(decision.available)
    }

    @Test
    fun `apply persists once and a second call does not rotate`() {
        // The store as the settings document holds it.
        var stored = ""
        var writes = 0
        var generated = 0
        val generate = {
            generated++
            "secret-$generated"
        }

        val first = ControllerSecret.apply(enabled = true, read = { stored }, write = { stored = it; writes++ }, generate = generate)
        val second = ControllerSecret.apply(enabled = true, read = { stored }, write = { stored = it; writes++ }, generate = generate)

        assertEquals("secret-1", first)
        // A second build (or launch) reads the persisted secret back: no new generation, no write.
        assertEquals("secret-1", second)
        assertEquals(1, generated)
        assertEquals(1, writes)
        assertEquals("secret-1", stored)
    }

    @Test
    fun `apply clears the stored secret when the API closes and stays quiet after`() {
        var stored = "stale-secret"
        var writes = 0

        val closed = ControllerSecret.apply(enabled = false, read = { stored }, write = { stored = it; writes++ })
        val again = ControllerSecret.apply(enabled = false, read = { stored }, write = { stored = it; writes++ })

        assertEquals("", closed)
        assertEquals("", again)
        assertEquals(1, writes)
    }

    @Test
    fun `apply keeps a user-chosen secret untouched`() {
        var stored = "my-secret"
        var writes = 0

        val inForce = ControllerSecret.apply(enabled = true, read = { stored }, write = { stored = it; writes++ })

        assertEquals("my-secret", inForce)
        assertEquals(0, writes)
        assertEquals("my-secret", stored)
    }

    @Test
    fun `the generated secret is 32 hex characters and distinct per call`() {
        val first = ControllerSecret.randomSecret()
        val second = ControllerSecret.randomSecret()

        assertEquals(32, first.length)
        assertTrue(first.all { it in "0123456789abcdef" })
        assertNotEquals(first, second)
    }
}
