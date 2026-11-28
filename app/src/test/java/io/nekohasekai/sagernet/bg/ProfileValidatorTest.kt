package io.nekohasekai.sagernet.bg

import io.flrone.bridge.DartProfileStore
import io.nekohasekai.sagernet.data.config.GeneratedConfig
import io.nekohasekai.sagernet.database.ProxyEntity
import io.nekohasekai.sagernet.database.SettingsJsonStore
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File

private val DIRECT_CONFIG =
    """{"dns":{},"outbounds":[{"type":"direct","tag":"proxy-7-0"}],"endpoints":[],"route":{},"inbounds":[]}"""

private fun built(id: Long): GeneratedConfig = GeneratedConfig(
    coreConfig = DIRECT_CONFIG,
    outboundTags = listOf("proxy-$id-0"),
    tagToProfileId = mapOf("proxy-$id-0" to id),
    fullConfigs = emptyMap(),
    skipped = emptyMap(),
    error = null,
)

private fun skip(id: Long, reason: String): GeneratedConfig = GeneratedConfig(
    coreConfig = DIRECT_CONFIG,
    outboundTags = emptyList(),
    tagToProfileId = emptyMap(),
    fullConfigs = emptyMap(),
    skipped = mapOf(id to reason),
    error = null,
)

private const val VLESS = """{"type":"vless","tag":"n1","server":"v.example.com","server_port":443,"uuid":"b831381d-6324-4d53-ad4f-8cda48b30811"}"""
private const val VLESS_FRAGMENT = """{"type":"vless","tag":"n1","server":"v.example.com","server_port":443,"uuid":"b831381d-6324-4d53-ad4f-8cda48b30811","tls":{"enabled":true,"fragment":true}}"""
private const val VLESS_TLS = """{"type":"vless","tag":"n1","server":"v.example.com","server_port":443,"uuid":"b831381d-6324-4d53-ad4f-8cda48b30811","tls":{"enabled":true}}"""
private const val SHADOWSOCKS = """{"type":"shadowsocks","tag":"ss","server":"s.example.com","server_port":8388,"method":"aes-256-gcm","password":"pw"}"""
private const val WIREGUARD_ENDPOINT = """{"type":"wireguard","tag":"wg","server":"","server_port":0,"peers":[{"address":"wg.example.com","port":51820,"public_key":"AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA="}]}"""

/**
 * [ProfileValidator] over the Go builder's `build_test_config`: the verdict is the core's answer on the test
 * config of one row, a builder *build* failure is the row's reason, and a call that never reached the builder
 * is never read as "invalid".
 *
 * The build/check pair is a seam ([ProfileValidator.Core]): a JVM test has neither the native library nor the
 * documents the Go builder reads. The chain hops and the global settings are the real ones (`profiles.json`,
 * `settings.json`).
 */
class ProfileValidatorTest {

    private class FakeCore : ProfileValidator.Core {
        val builds = ArrayList<List<Long>>()
        val checked = ArrayList<String>()
        var build: (Long) -> GeneratedConfig = { id -> built(id) }
        var check: (String) -> Unit = {}

        override fun buildTest(profileIds: List<Long>): GeneratedConfig {
            builds += profileIds
            return build(profileIds.single())
        }

        override fun checkConfig(config: String) {
            checked += config
            check(config)
        }
    }

    private lateinit var dir: File
    private lateinit var settingsDir: File
    private lateinit var originalCore: ProfileValidator.Core
    private var originalProfilesDir: File? = null
    private var originalSettingsDir: File? = null
    private lateinit var originalProfileLogger: (String, Throwable?) -> Unit
    private lateinit var originalSettingsLogger: (String, Throwable?) -> Unit

    private val core = FakeCore()

    @Before
    fun setUp() {
        dir = tempDir("profile-validator")
        settingsDir = tempDir("profile-validator-settings")
        originalCore = ProfileValidator.core
        ProfileValidator.core = core
        originalProfilesDir = DartProfileStore.directory
        originalProfileLogger = DartProfileStore.logger
        DartProfileStore.directory = dir
        DartProfileStore.logger = { _, _ -> }
        DartProfileStore.invalidate()
        originalSettingsDir = SettingsJsonStore.directory
        originalSettingsLogger = SettingsJsonStore.logger
        SettingsJsonStore.directory = settingsDir
        SettingsJsonStore.logger = { _, _ -> }
    }

    @After
    fun tearDown() {
        ProfileValidator.core = originalCore
        DartProfileStore.directory = originalProfilesDir
        DartProfileStore.logger = originalProfileLogger
        DartProfileStore.invalidate()
        SettingsJsonStore.directory = originalSettingsDir
        SettingsJsonStore.logger = originalSettingsLogger
        dir.deleteRecursively()
        settingsDir.deleteRecursively()
    }

    private fun tempDir(name: String): File = File.createTempFile(name, "").let {
        it.delete()
        it.mkdirs()
        it
    }

    // ------------------------------------------------------------------------------------------------ fixtures

    private fun profile(id: Long, type: String, json: String, name: String = "n$id") = ProxyEntity(
        id = id,
        type = type,
        name = name,
        outboundJson = json,
    )

    private fun writeProfiles(vararg rows: JSONObject) {
        val profiles = JSONArray()
        rows.forEach { profiles.put(it) }
        val document = JSONObject()
            .put("version", 1)
            .put("nextProfileId", 10)
            .put("nextGroupId", 1)
            .put("profiles", profiles)
            .put("groups", JSONArray())
        File(dir, "profiles.json").writeText(document.toString())
        DartProfileStore.invalidate()
    }

    private fun row(id: Long, type: String, json: String, name: String = "n$id"): JSONObject = JSONObject()
        .put("id", id)
        .put("type", type)
        .put("name", name)
        .put("gid", 0)
        .put("user_order", id)
        .put("outbound_json", json)

    private fun setting(key: String, value: String) {
        SettingsJsonStore.put(key, value)
    }

    private fun scan(vararg profiles: ProxyEntity): ProfileValidator.Scan = runBlocking {
        ProfileValidator.findInvalid(profiles.toList())
    }

    // ------------------------------------------------------------------------------------------------ profiles

    @Test
    fun `a valid profile is the core's verdict on the builder's test config`() {
        val profile = profile(7, "vless", VLESS)
        core.build = { built(it) }

        val result = scan(profile)

        assertTrue("no profile may be removed: ${result.invalid}", result.invalid.isEmpty())
        assertFalse(result.coreUnreachable)
        assertEquals(listOf(listOf(7L)), core.builds)
        assertEquals("the builder's config is checked as it is", listOf(DIRECT_CONFIG), core.checked)
        assertTrue(ProfileValidator.verdict(profile).valid)
    }

    @Test
    fun `a core rejection makes the profile invalid with the ent message`() {
        val profile = profile(7, "vless", VLESS, name = "Tokyo")
        core.build = { built(it) }
        core.check = { throw IllegalStateException("missing server address") }

        val result = scan(profile)

        assertEquals(setOf(7L), result.invalid)
        val verdict = ProfileValidator.verdict(profile)
        assertFalse(verdict.valid)
        assertFalse(verdict.coreUnreachable)
        assertEquals("Invalid ent Tokyo: missing server address", verdict.message)
    }

    @Test
    fun `an endpoint is checked as the builder answered it, endpoints array included`() {
        val profile = profile(7, "wireguard", WIREGUARD_ENDPOINT, name = "wg")
        val endpointConfig = """{"dns":{},"outbounds":[],"endpoints":[{"type":"wireguard","tag":"proxy-7-0"}],"inbounds":[]}"""
        core.build = {
            GeneratedConfig(endpointConfig, listOf("proxy-7-0"), mapOf("proxy-7-0" to 7L), emptyMap(), emptyMap(), null)
        }

        assertTrue(ProfileValidator.verdict(profile).valid)
        assertEquals(listOf(endpointConfig), core.checked)
        assertTrue(
            "the endpoint's own wrapping is the builder's, not re-wrapped here",
            core.checked.single().contains("\"endpoints\""),
        )

        core.check = { throw IllegalStateException("bad endpoint") }
        assertEquals("Invalid ent wg: bad endpoint", ProfileValidator.verdict(profile).message)
    }

    @Test
    fun `a builder build failure is invalid with the builder's reason`() {
        val profile = profile(7, "vless", VLESS, name = "Tokyo")
        core.build = {
            GeneratedConfig.failure(
                "profile 7 cannot be built by the Go test config builder: reality short id is not hex",
            )
        }

        val verdict = ProfileValidator.verdict(profile)

        assertFalse(verdict.valid)
        assertFalse(verdict.coreUnreachable)
        assertEquals(
            "Invalid ent Tokyo: profile 7 cannot be built by the Go test config builder: reality short id is not hex",
            verdict.message,
        )
        assertTrue("a failed build must not reach the core", core.checked.isEmpty())
    }

    @Test
    fun `a skipped candidate is invalid with the skip reason`() {
        val profile = profile(7, "vless", VLESS)

        core.build = { skip(it, "Unsupported profile type: vless") }

        assertEquals("Invalid ent n7: Unsupported profile type: vless", ProfileValidator.verdict(profile).message)
        assertTrue(core.checked.isEmpty())
    }

    @Test
    fun `an autoselector is kept without asking the builder`() {
        val profile = profile(7, "autoselector", """{"type":"autoselector","name":"auto","gid":3}""")

        assertTrue(ProfileValidator.verdict(profile).valid)
        assertTrue(core.builds.isEmpty())
    }

    @Test
    fun `a corrupted known row is invalid and an unknown type is kept`() {
        assertEquals(
            "Corrupted data in isValid: bad",
            ProfileValidator.verdict(profile(7, "vless", "not json", name = "bad")).message,
        )
        assertTrue(ProfileValidator.verdict(profile(8, "tailscale", """{"type":"tailscale"}""")).valid)
        assertTrue(core.builds.isEmpty())
    }

    // ------------------------------------------------------------------------------------------------ chains

    @Test
    fun `a chain validates its hops in order`() {
        val chain = """{"type":"chain","name":"c","list":[2,3]}"""
        val hopA = """{"type":"shadowsocks","tag":"a","server":"a.example.com","server_port":8388,"method":"aes-256-gcm","password":"pw"}"""
        val hopB = """{"type":"trojan","tag":"b","server":"b.example.com","server_port":443,"password":"pw"}"""
        writeProfiles(row(1, "chain", chain, name = "c"), row(2, "shadowsocks", hopA), row(3, "trojan", hopB))
        val profile = profile(1, "chain", chain, name = "c")

        assertTrue(ProfileValidator.verdict(profile).valid)
        assertEquals(listOf(listOf(2L), listOf(3L)), core.builds)
    }

    @Test
    fun `a chain maps a failed hop to the chain's id`() {
        val chain = """{"type":"chain","name":"c","list":[2,3]}"""
        val hopA = """{"type":"shadowsocks","tag":"a","server":"a.example.com","server_port":8388,"method":"aes-256-gcm","password":"pw"}"""
        val hopB = """{"type":"trojan","tag":"b","server":"b.example.com","server_port":443,"password":"pw"}"""
        writeProfiles(row(1, "chain", chain, name = "c"), row(2, "shadowsocks", hopA), row(3, "trojan", hopB))
        val profile = profile(1, "chain", chain, name = "c")
        core.build = { id -> if (id == 3L) GeneratedConfig.failure("profile 3 cannot be built") else built(id) }

        val verdict = ProfileValidator.verdict(profile)

        assertFalse(verdict.valid)
        assertEquals("Invalid ent in chain: ID=3", verdict.message)
        assertEquals(setOf(1L), scan(profile).invalid)
    }

    @Test
    fun `a chain that lists itself is invalid and a missing hop is null ent`() {
        val self = """{"type":"chain","name":"loop","list":[1]}"""
        writeProfiles(row(1, "chain", self, name = "loop"))
        assertEquals("Invalid ent in chain: ID=1", ProfileValidator.verdict(profile(1, "chain", self)).message)

        val missing = """{"type":"chain","name":"gap","list":[9]}"""
        writeProfiles(row(1, "chain", missing, name = "gap"))
        assertEquals("Null ent in validator", ProfileValidator.verdict(profile(1, "chain", missing)).message)
    }

    // ------------------------------------------------------------------------------------------------ unreachable

    @Test
    fun `a call that cannot reach the core is a verdict only for the scan`() {
        val profile = profile(7, "vless", VLESS)
        core.build = { throw UnsatisfiedLinkError("no core in this process") }

        val result = scan(profile)

        assertTrue("nothing may be removed while the core is unreachable: ${result.invalid}", result.invalid.isEmpty())
        assertTrue(result.coreUnreachable)
        val verdict = ProfileValidator.verdict(profile)
        assertFalse(verdict.valid)
        assertTrue(verdict.coreUnreachable)
        assertEquals("no core in this process", verdict.message)
    }

    @Test
    fun `a host call that never reached the builder is unreachable, not invalid`() {
        // TestConfigBuilder.buildTestOrThrow throws on an envelope error (an unreadable document, an old core);
        // reading that as a build failure would delete every profile.
        val profile = profile(7, "vless", VLESS)
        core.build = {
            throw io.flrone.core.CoreHost.HostCallException("build_test_config: read profiles.json: denied")
        }

        val result = scan(profile)

        assertTrue(result.invalid.isEmpty())
        assertTrue(result.coreUnreachable)
    }

    @Test
    fun `a check that cannot reach the core is unreachable, not invalid`() {
        val profile = profile(7, "vless", VLESS)
        core.build = { built(it) }
        core.check = { throw UnsatisfiedLinkError("libcore.so is missing") }

        val result = scan(profile)

        assertTrue(result.invalid.isEmpty())
        assertTrue(result.coreUnreachable)
    }

    // ------------------------------------------------------------------------------------------------ global fragment

    private fun customFragment(size: String = "10-100", sleep: String = "2-5", defaultOn: Boolean = false) {
        setting("fragment_implementation", "custom")
        setting("fragment_size", size)
        setting("fragment_sleep", sleep)
        setting("fragment_default_on", if (defaultOn) "true" else "false")
    }

    private fun fragmentFailure(id: Long): GeneratedConfig = GeneratedConfig.failure(
        "profile $id cannot be built by the Go test config builder: fragment_size \"2000\" is not a size or range the core accepts",
    )

    @Test
    fun `an unusable global fragment setting keeps a fragmenting profile`() {
        customFragment(size = "2000")
        core.build = { fragmentFailure(it) }

        // The dialer-level fragment the custom implementation emits is on for this row.
        val explicit = profile(7, "vless", VLESS_FRAGMENT, name = "Tokyo")
        val verdict = ProfileValidator.verdict(explicit)
        assertTrue("a global setting is no reason to delete the row: ${verdict.message}", verdict.valid)
        assertFalse(verdict.coreUnreachable)
        assertTrue(scan(explicit).invalid.isEmpty())

        // No `fragment` in the document is "keep default", which the global default turns on.
        customFragment(size = "2000", defaultOn = true)
        val inherited = profile(7, "vless", VLESS_TLS, name = "Tokyo")
        assertTrue(ProfileValidator.verdict(inherited).valid)
    }

    @Test
    fun `an unusable global fragment setting does not keep a profile its own build fails`() {
        customFragment(size = "2000")
        core.build = { fragmentFailure(it) }

        // TLS on, but the fragment is off explicitly: no dialer-level fragment, so the build fails on the row itself.
        val noFragment = profile(
            7,
            "vless",
            """{"type":"vless","tag":"n1","server":"v.example.com","server_port":443,"uuid":"b831381d-6324-4d53-ad4f-8cda48b30811","tls":{"enabled":true,"fragment":false}}""",
        )
        assertFalse(ProfileValidator.verdict(noFragment).valid)

        // A cipher-only row never emits the fragment block at all.
        assertFalse(ProfileValidator.verdict(profile(8, "shadowsocks", SHADOWSOCKS)).valid)
    }

    @Test
    fun `a usable global fragment setting leaves a fragmenting profile's build failure its own`() {
        customFragment(size = "10-100")
        core.build = { fragmentFailure(it) }

        assertFalse(ProfileValidator.verdict(profile(7, "vless", VLESS_FRAGMENT)).valid)
    }

    // ------------------------------------------------------------------------------------------------ full config

    @Test
    fun `a custom full config is checked as it is, without the builder`() {
        val text = """{"log":{"level":"info"},"inbounds":[{"type":"tun","tag":"tun-in"}],"outbounds":[{"type":"direct","tag":"direct"}]}"""
        val profile = profile(
            7,
            "custom",
            JSONObject().put("type", "custom").put("subtype", "fullconfig").put("config", text).toString(),
            name = "full",
        )

        assertTrue(ProfileValidator.verdict(profile).valid)
        assertTrue("the full config is passed through, not built by the Go test builder", core.builds.isEmpty())
        assertTrue(core.checked.single().contains("\"tun\""))
        assertTrue("the app's log level is injected like the old build", core.checked.single().contains("\"level\":\"warn\""))

        core.check = { throw IllegalStateException("unknown inbound type") }
        assertEquals("Invalid ent full: unknown inbound type", ProfileValidator.verdict(profile).message)
    }
}