// The `experimental.clash_api` object a build emits.
//
// The invariant these tests pin: an open controller always carries a secret, and a closed one
// emits neither `external_controller` nor `secret`. A second build of the same settings must
// produce the same secret — rotation is the settings mapper's transition-time job, not the
// generator's, so an external dashboard's credentials survive a reload.

package io.nekohasekai.sagernet.outbound.config

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ConfigGeneratorClashApiTest {

    private val enabled = GeneratorSettings(
        clashApiEnabled = true,
        clashApiListen = "127.0.0.1",
        clashApiPort = 9090,
        clashApiSecret = "s3cret-value",
    )

    @Test
    fun `an enabled controller carries its secret`() {
        val api = ConfigGenerator.clashApiObject(enabled)

        assertNotNull(api)
        assertEquals("127.0.0.1:9090", api!!.string("external_controller"))
        assertEquals("s3cret-value", api.string("secret"))
        assertEquals("dashboard", api.string("external_ui"))
    }

    @Test
    fun `a disabled controller is omitted even with a stored secret`() {
        val api = ConfigGenerator.clashApiObject(enabled.copy(clashApiEnabled = false))

        assertNull(api)
    }

    @Test
    fun `an enabled controller with a blank secret is never emitted`() {
        // Fail closed: `secret: ""` is an unauthenticated API on the listen address, which under
        // `allowLan` is the whole LAN. The mapper generates and persists one before the build;
        // a settings object assembled by hand must not slip past that.
        assertNull(ConfigGenerator.clashApiObject(enabled.copy(clashApiSecret = "")))
        assertNull(ConfigGenerator.clashApiObject(enabled.copy(clashApiSecret = "   ")))
    }

    @Test
    fun `a second build does not rotate the secret`() {
        val first = ConfigGenerator.clashApiObject(enabled)
        val second = ConfigGenerator.clashApiObject(enabled)

        assertEquals(first, second)
        assertEquals("s3cret-value", second!!.string("secret"))
    }

    @Test
    fun `an empty listen address falls back to loopback and IPv6 is bracketed`() {
        assertEquals(
            "127.0.0.1:9090",
            ConfigGenerator.clashApiObject(enabled.copy(clashApiListen = ""))!!.string("external_controller"),
        )
        assertEquals(
            "[::1]:9090",
            ConfigGenerator.clashApiObject(enabled.copy(clashApiListen = "::1"))!!.string("external_controller"),
        )
        // An already-bracketed host is left alone.
        assertEquals(
            "[::1]:9090",
            ConfigGenerator.clashApiObject(enabled.copy(clashApiListen = "[::1]"))!!.string("external_controller"),
        )
    }

    @Test
    fun `external_ui is omitted when empty`() {
        val api = ConfigGenerator.clashApiObject(enabled.copy(clashApiExternalUi = ""))!!

        assertFalse(api.contains("external_ui"))
        assertTrue(api.contains("external_controller"))
    }
}
