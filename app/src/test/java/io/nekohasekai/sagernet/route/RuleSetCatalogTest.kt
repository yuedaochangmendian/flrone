package io.nekohasekai.sagernet.route

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * The pure-Dart rule-set picker reads only the runtime `srslist.h`; the host
 * seeds it from the APK's bundled snapshot before answering `data.path`, so a
 * fresh install lists the bundled sets instead of an empty catalog.
 */
class RuleSetCatalogTest {

    @get:Rule
    val temporary = TemporaryFolder()

    private val bundled = """
        // routeprofiles rule-set list
        {"geosite-cn", "https://example.test/geosite-cn.srs"}
        {"geoip-cn", "https://example.test/geoip-cn.srs"}
    """.trimIndent()

    @Test
    fun `a missing runtime catalog is seeded from the bundle`() {
        val file = temporary.newFolder("files", "routeprofiles").resolve("srslist.h")

        assertTrue(RuleSetCatalog.seedIfMissing(file, bundled))
        assertEquals(bundled, file.readText())
        assertEquals(2, RuleSetCatalog.parseSrsList(file.readText()).size)
    }

    @Test
    fun `an existing runtime catalog is never overwritten`() {
        val file = temporary.newFile("srslist.h").apply {
            writeText("""{"downloaded", "https://example.test/downloaded.srs"}""")
        }

        assertFalse(RuleSetCatalog.seedIfMissing(file, bundled))
        assertTrue(file.readText().contains("downloaded"))
    }

    @Test
    fun `an empty file is treated as missing`() {
        val file = temporary.newFile("srslist.h").apply { writeText("") }

        assertTrue(RuleSetCatalog.seedIfMissing(file, bundled))
        assertTrue(file.readText().contains("geosite-cn"))
    }

    @Test
    fun `no bundled asset writes nothing`() {
        val file = temporary.root.resolve("routeprofiles/srslist.h")

        assertFalse(RuleSetCatalog.seedIfMissing(file, null))
        assertFalse(RuleSetCatalog.seedIfMissing(file, "  "))
        assertFalse(file.exists())
    }

    @Test
    fun `a bundle without entries is refused`() {
        val file = temporary.root.resolve("routeprofiles/srslist.h")

        assertFalse(RuleSetCatalog.seedIfMissing(file, "not a rule-set list"))
        assertFalse(file.exists())
    }
}
