package io.nekohasekai.sagernet.group

import io.nekohasekai.sagernet.database.ProxyEntity
import io.nekohasekai.sagernet.database.StoredProfile
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * S8: `SubscriptionFilters.removeFlagged`'s two profile-derived predicates — duplicates and insecure
 * nodes — over stored rows instead of parsed outbounds (the third, invalid nodes, comes from the
 * validator). These pin the decisions on the helper the filter now uses.
 */
class SubscriptionFilterRulesTest {

    private fun insecure(profile: ProxyEntity, skipCert: Boolean): Boolean =
        StoredProfile.security(profile.type, profile.outboundJson, skipCert).insecure

    @Test
    fun `removeInsecure claims the profiles without a safe transport`() {
        val rawHttp = ProxyEntity(id = 1, type = "http", name = "H", outboundJson = """{"type":"http","server":"h.example.com","server_port":80}""")
        val tlsTrojan = ProxyEntity(id = 2, type = "trojan", name = "T", outboundJson = """{"type":"trojan","tls":{"enabled":true}}""")

        assertTrue(insecure(rawHttp, skipCert = false))
        assertEquals(false, insecure(tlsTrojan, skipCert = false))
        // A global skip_cert setting is not the profile's fault, so it is not removed for it.
        assertEquals(false, insecure(tlsTrojan, skipCert = true))
    }

    @Test
    fun `removeDuplicates keeps the first row of each tag-less content`() {
        val first = ProxyEntity(id = 1, type = "trojan", name = "A", outboundJson = """{"type":"trojan","tag":"A","server":"t.example","server_port":443}""")
        val renamed = ProxyEntity(id = 2, type = "trojan", name = "B", outboundJson = """{"type":"trojan","tag":"B","server":"t.example","server_port":443}""")
        val other = ProxyEntity(id = 3, type = "trojan", name = "C", outboundJson = """{"type":"trojan","tag":"C","server":"u.example","server_port":443}""")

        val keys = HashSet<String>()
        val kept = ArrayList<Long>()
        for (profile in listOf(first, renamed, other)) {
            if (keys.add(StoredProfile.dedupKey(profile.type, profile.outboundJson))) kept.add(profile.id)
        }

        // keep_last = false: the first copy survives, the renamed duplicate goes.
        assertEquals(listOf(1L, 3L), kept)
    }

    @Test
    fun `removeDuplicates keeps differently named chains apart`() {
        val a = ProxyEntity(id = 1, type = "chain", name = "A", outboundJson = """{"type":"chain","name":"A","list":[1]}""")
        val b = ProxyEntity(id = 2, type = "chain", name = "B", outboundJson = """{"type":"chain","name":"B","list":[1]}""")

        assertEquals(false, StoredProfile.dedupKey(a.type, a.outboundJson) == StoredProfile.dedupKey(b.type, b.outboundJson))
    }
}
