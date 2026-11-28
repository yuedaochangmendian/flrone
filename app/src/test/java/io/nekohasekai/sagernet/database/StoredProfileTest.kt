package io.nekohasekai.sagernet.database

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * S8: the stored row's display and security facts, derived from `type` + `outbound_json` instead of
 * a parsed outbound. The expectations are the old model's answers (`displayType()`, `displayName()`,
 * `displayAddress()`, `effectiveSecurity()`, the dedup key), pinned here so the final model deletion
 * cannot drift them.
 *
 * The validator's decision inputs (`isInvalidDocument`, `isKnownType`, `fullConfigText`,
 * `chainHops`, `isEndpoint`) and the sync filters' predicates (insecure, duplicate key) are covered
 * in the same terms.
 */
class StoredProfileTest {

    // ------------------------------------------------------------------------------------------------ labels

    @Test
    fun `every known type has its display label`() {
        val expected = mapOf(
            "socks" to "Socks",
            "http" to "HTTP",
            "shadowsocks" to "Shadowsocks",
            "vmess" to "VMess",
            "vless" to "VLESS",
            "trojan" to "Trojan",
            "hysteria" to "Hysteria",
            "tuic" to "TUIC",
            "juicity" to "Juicity",
            "trusttunnel" to "TrustTunnel",
            "anytls" to "AnyTLS",
            "mieru" to "Mieru",
            "snell" to "Snell",
            "shadowtls" to "ShadowTLS",
            "wireguard" to "WireGuard",
            "masque" to "MASQUE",
            "openvpn" to "OpenVPN",
            "openconnect" to "OpenConnect",
            "ssh" to "SSH",
            "naive" to "Naive",
            "chain" to "Chain Proxy",
            "autoselector" to "Auto Selector",
            "direct" to "Direct",
        )
        for ((type, label) in expected) {
            assertEquals(type, label, StoredProfile.label(type, "{}"))
        }
    }

    @Test
    fun `the factory aliases label as their canonical type`() {
        assertEquals("Hysteria", StoredProfile.label("hysteria2", "{}"))
        assertEquals("OpenVPN", StoredProfile.label("openvpn-client", "{}"))
    }

    @Test
    fun `an unknown type keeps its stored name`() {
        assertEquals("", StoredProfile.label("xrayvless", "{}"))
        assertEquals("xrayvless", StoredProfile.displayType("xrayvless", "{}"))
        assertEquals("tailscale", StoredProfile.displayType("tailscale", "{}"))
    }

    @Test
    fun `an unreadable document labels with the stored type`() {
        // parseOutbound answers InvalidOutbound("turbo"), whose displayType() is empty.
        assertEquals("", StoredProfile.label("trojan", "not json"))
        assertEquals("trojan", StoredProfile.displayType("trojan", "not json"))
    }

    @Test
    fun `a custom row labels after its subtype and config type`() {
        assertEquals(
            "Custom Outbound",
            StoredProfile.label("custom", """{"subtype":"outbound","config":"{\"type\":\"\"}"}"""),
        )
        assertEquals(
            "Custom Trojan Outbound",
            StoredProfile.label("custom", """{"subtype":"outbound","config":"{\"type\":\"trojan\"}"}"""),
        )
        assertEquals("Custom Config", StoredProfile.label("custom", """{"subtype":"fullconfig","config":"{}"}"""))
        assertEquals("xrayoutbound", StoredProfile.label("custom", """{"subtype":"xrayoutbound","config":"{}"}"""))
        assertEquals("", StoredProfile.label("custom", """{"subtype":"","config":"{}"}"""))
    }

    @Test
    fun `the display name is the column, else the address, else the type`() {
        assertEquals("Named", StoredProfile.displayName("Named", "trojan", """{"type":"trojan","server":"t.example.com","server_port":443}"""))
        assertEquals("t.example.com:443", StoredProfile.displayName(null, "trojan", """{"type":"trojan","server":"t.example.com","server_port":443}"""))
        assertEquals("custom", StoredProfile.displayName("", "custom", "{}"))
        assertEquals("[Trojan] t.example.com:443", StoredProfile.displayTypeAndName(null, "trojan", """{"type":"trojan","server":"t.example.com","server_port":443}"""))
        // typeAndName is the raw pair, so a row with neither name nor address ends in "] " (the desktop's).
        assertEquals("[Shadowsocks] ", StoredProfile.displayTypeAndName(null, "shadowsocks", """{"method":"aes-256-gcm"}"""))
    }

    // ------------------------------------------------------------------------------------------------ addresses

    @Test
    fun `a plain type shows its server and port`() {
        assertEquals("a.example:8388", StoredProfile.displayAddress("shadowsocks", """{"server":"a.example","server_port":8388}"""))
        // Nothing to show yet.
        assertEquals("", StoredProfile.displayAddress("shadowsocks", "{}"))
        assertEquals("[2001:db8::1]:443", StoredProfile.displayAddress("vless", """{"server":"2001:db8::1","server_port":443}"""))
    }

    @Test
    fun `a chain has no address of its own`() {
        assertEquals("", StoredProfile.displayAddress("chain", """{"type":"chain","name":"c","list":[1,2]}"""))
    }

    @Test
    fun `a direct row shows its bind fields`() {
        assertEquals("Empty", StoredProfile.displayAddress("direct", """{"type":"direct"}"""))
        assertEquals("Bind NIC: wlan0", StoredProfile.displayAddress("direct", """{"type":"direct","bind_interface":"wlan0"}"""))
        assertEquals("Bind Addr4: 10.0.0.2", StoredProfile.displayAddress("direct", """{"type":"direct","inet4_bind_address":"10.0.0.2"}"""))
        // The desktop's missing ": " after "Bind Addr6" is kept.
        assertEquals("Bind Addr6fe80::1", StoredProfile.displayAddress("direct", """{"type":"direct","inet6_bind_address":"fe80::1"}"""))
    }

    @Test
    fun `a custom row shows the server of its own config`() {
        val json = """{"subtype":"outbound","config":"{\"type\":\"trojan\",\"server\":\"c.example\",\"server_port\":8443}"}"""
        assertEquals("c.example:8443", StoredProfile.displayAddress("custom", json))
        assertEquals("", StoredProfile.displayAddress("custom", """{"subtype":"fullconfig","config":"{}"}"""))
    }

    @Test
    fun `a wireguard row shows its first peer`() {
        val json = """{"type":"wireguard","peers":[{"address":"wg.example","port":51820}]}"""
        assertEquals("wg.example:51820", StoredProfile.displayAddress("wireguard", json))
    }

    @Test
    fun `an openconnect row shows the URL the server field parses to`() {
        assertEquals(
            "vpn.example/group",
            StoredProfile.displayAddress("openconnect", """{"type":"openconnect","server":"https://vpn.example/group","server_port":443}"""),
        )
        assertEquals(
            "vpn.example:8443",
            StoredProfile.displayAddress("openconnect", """{"type":"openconnect","server":"vpn.example:8443","server_port":443}"""),
        )
        assertEquals(
            "vpn.example/v2",
            StoredProfile.displayAddress(
                "openconnect",
                """{"type":"openconnect","server":"https://vpn.example/old","server_port":443,"server_path":"/v2"}""",
            ),
        )
    }

    @Test
    fun `a hysteria realm shows its rendezvous host`() {
        val json = """{"type":"hysteria2","realm":{"server_url":"https://realm.example:443","realm_id":"room"}}"""
        assertEquals("room@realm.example", StoredProfile.displayAddress("hysteria", json))
        // Without realm it is the plain server.
        assertEquals("h.example:443", StoredProfile.displayAddress("hysteria", """{"type":"hysteria","server":"h.example","server_port":443}"""))
    }

    @Test
    fun `an auto selector shows the groups it tracks`() {
        // No document store in this test: the lookup answers null for every group id.
        assertEquals("missing group", StoredProfile.displayAddress("autoselector", """{"gids":[7]}"""))
        assertEquals("no group", StoredProfile.displayAddress("autoselector", """{"gids":[]}"""))
    }

    // ------------------------------------------------------------------------------------------------ security

    @Test
    fun `a plain shadowsocks method decides its verdict`() {
        assertEquals(StoredProfile.Level.Secure, StoredProfile.security("shadowsocks", """{"method":"aes-256-gcm"}""", false).level)
        assertEquals(StoredProfile.Level.Weak, StoredProfile.security("shadowsocks", """{"method":"rc4-md5"}""", false).level)
        assertEquals(StoredProfile.Level.None, StoredProfile.security("shadowsocks", """{"method":"none"}""", false).level)
        assertTrue(StoredProfile.security("shadowsocks", """{"method":"none"}""", false).insecure)
    }

    @Test
    fun `vmess without TLS is insecure but not raw`() {
        val verdict = StoredProfile.security("vmess", """{"type":"vmess","security":"auto"}""", false)

        assertEquals(StoredProfile.Level.Weak, verdict.level)
        assertEquals("Insecure", verdict.label)
        assertTrue(verdict.insecure)
    }

    @Test
    fun `a TLS profile is secure through the CA check`() {
        val verdict = StoredProfile.security("trojan", """{"tls":{"enabled":true},"transport":{"type":"ws"}}""", false)

        assertEquals(StoredProfile.Level.Secure, verdict.level)
        assertEquals("TLS", verdict.label)
        assertEquals("WebSocket", verdict.transport)
        assertFalse(verdict.insecure)
        // The global skip_cert setting weakens exactly that.
        val skipped = StoredProfile.security("trojan", """{"tls":{"enabled":true}}""", true)
        assertEquals(StoredProfile.Level.Weak, skipped.level)
        assertEquals("Compromised", skipped.label)
        assertFalse("a global setting is no reason to call the profile insecure", skipped.insecure)
    }

    @Test
    fun `a pinned certificate stays secure under skip_cert`() {
        val json = """{"tls":{"enabled":true,"certificate_sha256":["AAAA"]}}"""
        val skipped = StoredProfile.security("trojan", json, true)

        assertEquals(StoredProfile.Level.Secure, skipped.level)
    }

    @Test
    fun `an insecure TLS profile is weak`() {
        val verdict = StoredProfile.security("trojan", """{"tls":{"enabled":true,"insecure":true}}""", false)

        assertEquals("Insecure TLS", verdict.label)
        assertTrue(verdict.insecure)
    }

    @Test
    fun `a dangerous verdict to a private server becomes private`() {
        val verdict = StoredProfile.security("trojan", """{"server":"192.168.1.5","server_port":443}""", false)

        assertEquals(StoredProfile.Level.Secure, verdict.level)
        assertEquals("Private", verdict.label)
        assertFalse(verdict.insecure)
    }

    @Test
    fun `the per-type verdicts of the remaining protocols`() {
        assertEquals("Static Key", StoredProfile.security("openvpn", """{"mode":"static_key"}""", false).label)
        assertEquals("Unverified TLS", StoredProfile.security("openvpn", """{}""", false).label)
        assertEquals("TLS", StoredProfile.security("openvpn", """{"tls":{"certificate":["PEM"]}}""", false).label)
        assertEquals("Unverified Host Key", StoredProfile.security("ssh", """{}""", false).label)
        assertEquals("Encrypted", StoredProfile.security("ssh", """{"host_key":["key"]}""", false).label)
        assertEquals("AmneziaWG", StoredProfile.security("wireguard", """{"amnezia_wg":{"jc":4}}""", false).transport)
        assertEquals(StoredProfile.Level.Secure, StoredProfile.security("mieru", """{}""", false).level)
        // masque's peer key pins the certificate, so skip_cert leaves it alone.
        assertEquals(StoredProfile.Level.Secure, StoredProfile.security("masque", """{"peer_public_key":"k"}""", true).level)
    }

    @Test
    fun `a custom outbound takes the verdict of its config egress`() {
        val raw = """{"subtype":"outbound","config":"{\"type\":\"shadowsocks\",\"method\":\"none\"}"}"""
        assertTrue(StoredProfile.security("custom", raw, false).insecure)

        val private = """{"subtype":"outbound","config":"{\"type\":\"trojan\",\"server\":\"10.0.0.5\",\"server_port\":443}"}"""
        assertEquals("Private", StoredProfile.security("custom", private, false).label)
    }

    @Test
    fun `a custom full config follows its first outbound`() {
        val json = """{"subtype":"fullconfig","config":"{\"outbounds\":[{\"type\":\"shadowsocks\",\"method\":\"none\"}]}"}"""

        assertTrue(StoredProfile.security("custom", json, false).insecure)
    }

    @Test
    fun `an unreadable row is raw and insecure, as InvalidOutbound was`() {
        assertEquals(StoredProfile.Level.None, StoredProfile.security("trojan", "not json", false).level)
        assertTrue(StoredProfile.security("trojan", "not json", false).insecure)
        assertTrue(StoredProfile.security("xrayvless", """{"protocol":"vless"}""", false).insecure)
    }

    // ------------------------------------------------------------------------------------------------ validator inputs

    @Test
    fun `the validator keeps the types this core cannot judge`() {
        assertFalse(StoredProfile.isInvalidDocument("autoselector", """{"gids":[]}"""))
        assertFalse(StoredProfile.isInvalidDocument("hysteria2", """{"type":"hysteria2"}"""))
        // Unsupported/unknown types reach parseOutbound as InvalidOutbound, which the validator keeps.
        assertTrue(StoredProfile.isInvalidDocument("tailscale", """{}"""))
        assertTrue(StoredProfile.isInvalidDocument("extracore", """{}"""))
        assertFalse(StoredProfile.isKnownType("tailscale"))
        assertFalse(StoredProfile.isKnownType("extracore"))
    }

    @Test
    fun `the validator calls a known type with unreadable data corrupted`() {
        assertTrue(StoredProfile.isInvalidDocument("trojan", "not json"))
        assertFalse("a blank document is a fresh profile", StoredProfile.isInvalidDocument("trojan", ""))
        assertTrue(StoredProfile.isKnownType("naive"))
        assertFalse(StoredProfile.isKnownType("tailscale"))
    }

    @Test
    fun `the validator reads a full config and a chain from the columns`() {
        assertEquals("{}", StoredProfile.fullConfigText("custom", """{"subtype":"fullconfig","config":"{}"}"""))
        assertNull(StoredProfile.fullConfigText("custom", """{"subtype":"outbound","config":"{}"}"""))
        assertNull(StoredProfile.fullConfigText("trojan", """{"config":"{}"}"""))
        assertEquals(listOf(3L, 4L), StoredProfile.chainHops("chain", """{"list":[3,4]}"""))
        assertEquals(emptyList<Long>(), StoredProfile.chainHops("trojan", """{"list":[3,4]}"""))
    }

    @Test
    fun `the validator's endpoint key follows the type`() {
        assertTrue(StoredProfile.isEndpoint("openvpn", "{}"))
        assertTrue(StoredProfile.isEndpoint("openconnect", "{}"))
        assertTrue(StoredProfile.isEndpoint("masque", "{}"))
        assertTrue(StoredProfile.isEndpoint("wireguard", "{}"))
        assertTrue(StoredProfile.isEndpoint("custom", """{"subtype":"outbound","config":"{\"type\":\"wireguard\"}"}"""))
        assertFalse(StoredProfile.isEndpoint("custom", """{"subtype":"outbound","config":"{\"type\":\"trojan\"}"}"""))
        assertFalse(StoredProfile.isEndpoint("custom", """{"subtype":"fullconfig","config":"{}"}"""))
        assertFalse(StoredProfile.isEndpoint("trojan", "{}"))
    }

    // ------------------------------------------------------------------------------------------------ filters

    @Test
    fun `the duplicate key ignores the tag but keeps the rest`() {
        val first = """{"type":"trojan","tag":"A","server":"t.example","server_port":443}"""
        val renamed = """{"type":"trojan","tag":"B","server":"t.example","server_port":443}"""
        val other = """{"type":"trojan","tag":"A","server":"u.example","server_port":443}"""

        assertEquals(StoredProfile.dedupKey("trojan", first), StoredProfile.dedupKey("trojan", renamed))
        assertTrue(StoredProfile.dedupKey("trojan", first) != StoredProfile.dedupKey("trojan", other))
        // A chain's name is not a tag: renamed chains are different profiles.
        val chainA = """{"type":"chain","name":"A","list":[1]}"""
        val chainB = """{"type":"chain","name":"B","list":[1]}"""
        assertTrue(StoredProfile.dedupKey("chain", chainA) != StoredProfile.dedupKey("chain", chainB))
    }

    @Test
    fun `the duplicate key of an unreadable row is the empty export`() {
        assertEquals(StoredProfile.dedupKey("trojan", "not json"), StoredProfile.dedupKey("xrayvless", """{"protocol":"vless"}"""))
        // A blank profile exports its type key (what the old exporter wrote).
        assertEquals(StoredProfile.dedupKey("vless", ""), StoredProfile.dedupKey("vless", """{"type":"vless"}"""))
    }
}
