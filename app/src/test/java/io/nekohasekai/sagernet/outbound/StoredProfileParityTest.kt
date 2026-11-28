package io.nekohasekai.sagernet.outbound

import io.nekohasekai.sagernet.database.ProxyEntity
import io.nekohasekai.sagernet.database.StoredProfile
import io.nekohasekai.sagernet.outbound.common.Tls
import io.nekohasekai.sagernet.outbound.types.AnyTls
import io.nekohasekai.sagernet.outbound.types.AutoSelector
import io.nekohasekai.sagernet.outbound.types.Chain
import io.nekohasekai.sagernet.outbound.types.Custom
import io.nekohasekai.sagernet.outbound.types.Direct
import io.nekohasekai.sagernet.outbound.types.Http
import io.nekohasekai.sagernet.outbound.types.Hysteria
import io.nekohasekai.sagernet.outbound.types.Juicity
import io.nekohasekai.sagernet.outbound.types.Masque
import io.nekohasekai.sagernet.outbound.types.Mieru
import io.nekohasekai.sagernet.outbound.types.Naive
import io.nekohasekai.sagernet.outbound.types.OpenConnect
import io.nekohasekai.sagernet.outbound.types.OpenVpn
import io.nekohasekai.sagernet.outbound.types.ShadowTls
import io.nekohasekai.sagernet.outbound.types.Shadowsocks
import io.nekohasekai.sagernet.outbound.types.Snell
import io.nekohasekai.sagernet.outbound.types.Socks
import io.nekohasekai.sagernet.outbound.types.Ssh
import io.nekohasekai.sagernet.outbound.types.Trojan
import io.nekohasekai.sagernet.outbound.types.TrustTunnel
import io.nekohasekai.sagernet.outbound.types.Tuic
import io.nekohasekai.sagernet.outbound.types.Vless
import io.nekohasekai.sagernet.outbound.types.Vmess
import io.nekohasekai.sagernet.outbound.types.WireGuard
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * S8 transitional gate: every [StoredProfile] derivation equals the outbound model's answer for the
 * same stored row, across all 24 types (43 representative rows) and both skip_cert settings.
 *
 * The row is `type` + `ExportToJson`, so the oracle is the model *re-parsed from that document* — a
 * value the export drops (a WireGuard AMNEZIA flag without its block) is absent on both sides.
 * This test lives in the model's own test package because it goes away with the model; until the
 * final deletion it is what stops the derivation from drifting.
 */
class StoredProfileParityTest {

    private fun compare(o: Outbound, type: String = o.type) {
        val json = o.exportToJson().toCompact()
        val name = o.name.ifEmpty { null }
        val model = ProxyEntity.parseOutbound(type, json)
        for (skipCert in listOf(false, true)) {
            val old = model.effectiveSecurity(skipCert)
            val new = StoredProfile.security(type, json, skipCert)
            val detail = "$type ($json, skip_cert=$skipCert)"
            assertEquals("$detail level", old.level.name, new.level.name)
            assertEquals("$detail label", old.label, new.label)
            assertEquals("$detail transport", old.transport, new.transport)
            assertEquals("$detail insecure", old.isInsecure, new.insecure)
        }
        val detail = "$type ($json)"
        assertEquals("$detail label", model.displayType().ifEmpty { type }, StoredProfile.displayType(type, json))
        assertEquals(
            "$detail name",
            model.displayName().ifEmpty { model.displayType().ifEmpty { type } },
            StoredProfile.displayName(name, type, json),
        )
        assertEquals("$detail address", model.displayAddress(), StoredProfile.displayAddress(type, json))
        assertEquals(
            "$detail type and name",
            "[${model.displayType()}] ${model.displayName()}",
            StoredProfile.displayTypeAndName(name, type, json),
        )
        assertEquals("$detail dedup key", model.exportJsonLink(stripMetadata = true), StoredProfile.dedupKey(type, json))
        assertEquals("$detail endpoint", model.isEndpoint(), StoredProfile.isEndpoint(type, json))
    }

    private fun tls(on: Boolean, insecure: Boolean = false, pin: Boolean = false): Tls = Tls().also {
        it.enabled = on
        it.insecure = insecure
        if (pin) it.certificate_sha256 = arrayListOf("AAAA")
    }

    @Test
    fun `every type derives what its stored row reproduces`() {
        // The app installs this hook in onCreate; a JVM test has no document, so answer "absent".
        val previousHook = AutoSelector.groupNames
        AutoSelector.groupNames = AutoSelector.GroupNames { null }
        try {
            // Type defaults: the export of a profile with no fields set.
            compare(Socks())
            compare(Http())
            compare(Shadowsocks())
            compare(Vmess())
            compare(Vless())
            compare(Trojan())
            compare(Hysteria())
            compare(Tuic())
            compare(Juicity())
            compare(TrustTunnel())
            compare(AnyTls())
            compare(Mieru())
            compare(Snell())
            compare(ShadowTls())
            compare(WireGuard())
            compare(Masque())
            compare(OpenVpn())
            compare(OpenConnect())
            compare(Ssh())
            compare(Naive())
            compare(Chain())
            compare(AutoSelector())
            compare(Direct())
            compare(Custom())
            compare(Socks().also { it.server = "s.example.com"; it.serverPort = 1080 })
            compare(Http().also { it.server = "h.example.com"; it.serverPort = 8080 })
            compare(Http().also { it.server = "h.example.com"; it.serverPort = 8080; it.tls = tls(true) })
            compare(Shadowsocks().also { it.server = "a.example.com"; it.serverPort = 8388; it.method = "aes-256-gcm" })
            compare(Shadowsocks().also { it.method = "rc4-md5" })
            compare(Shadowsocks().also { it.method = "none" })
            compare(Vmess().also { it.server = "v.example.com"; it.serverPort = 443 })
            compare(Vmess().also { it.server = "v.example.com"; it.serverPort = 443; it.tls = tls(true) })
            compare(Vmess().also { it.server = "v.example.com"; it.serverPort = 443; it.security = "none" })
            compare(Vless().also { it.server = "v.example.com"; it.serverPort = 443 })
            compare(Vless().also { it.server = "v.example.com"; it.serverPort = 443; it.tls = tls(true, insecure = true) })
            compare(Vless().also { it.server = "v.example.com"; it.serverPort = 443; it.tls = tls(true, pin = true) })
            compare(
                Vless().also {
                    it.server = "v.example.com"
                    it.serverPort = 443
                    it.tls = tls(true).also { t ->
                        t.reality.enabled = true
                        t.reality.public_key = "k"
                    }
                },
            )
            compare(Vless().also { it.server = "v.example.com"; it.serverPort = 443; it.tls = tls(true); it.transport.type = "ws" })
            compare(Trojan().also { it.server = "t.example.com"; it.serverPort = 443; it.tls = tls(true); it.transport.type = "grpc" })
            compare(Hysteria().also { it.server = "h.example.com"; it.serverPort = 443; it.protocol_version = "1" })
            compare(
                Hysteria().also {
                    it.protocol_version = "2"
                    it.realm_enabled = true
                    it.realm_server_url = "https://realm.example.com:443"
                    it.realm_id = "room"
                },
            )
            compare(Tuic().also { it.server = "u.example.com"; it.serverPort = 443 })
            compare(Juicity().also { it.server = "j.example.com"; it.serverPort = 443 })
            compare(TrustTunnel().also { it.server = "tt.example.com"; it.serverPort = 443 })
            compare(TrustTunnel().also { it.server = "tt.example.com"; it.serverPort = 443; it.quic = true })
            compare(AnyTls().also { it.server = "a.example.com"; it.serverPort = 443 })
            compare(Mieru().also { it.server = "m.example.com"; it.serverPort = 443 })
            compare(Snell().also { it.server = "s.example.com"; it.serverPort = 443; it.psk = "p" })
            compare(ShadowTls().also { it.server = "s.example.com"; it.serverPort = 443 })
            compare(
                WireGuard().also {
                    it.server = "w.example.com"
                    it.serverPort = 51820
                    it.peer.address = "w.example.com"
                    it.peer.port = 51820
                },
            )
            compare(
                WireGuard().also {
                    it.server = "w.example.com"
                    it.serverPort = 51820
                    it.peer.address = "w.example.com"
                    it.peer.port = 51820
                    it.enable_amnezia = true
                },
            )
            compare(Masque().also { it.server = "m.example.com"; it.serverPort = 443 })
            compare(Masque().also { it.server = "m.example.com"; it.serverPort = 443; it.peer_public_key = "k"; it.tls = tls(true) })
            compare(OpenVpn().also { it.server = "o.example.com"; it.serverPort = 1194 })
            compare(OpenVpn().also { it.server = "o.example.com"; it.serverPort = 1194; it.mode = "static_key" })
            compare(OpenVpn().also { it.server = "o.example.com"; it.serverPort = 1194; it.tls.certificate = arrayListOf("PEM") })
            compare(OpenConnect().also { it.server = "vpn.example.com"; it.serverPort = 443 })
            compare(OpenConnect().also { it.server = "vpn.example.com"; it.serverPort = 8443; it.server_path = "/group" })
            compare(OpenConnect().also { it.server = "vpn.example.com"; it.serverPort = 443; it.tls.insecure = true })
            compare(
                OpenConnect().also {
                    it.server = "vpn.example.com"
                    it.serverPort = 443
                    it.tls.insecure = true
                    it.tls.peer_fingerprint = arrayListOf("aa")
                },
            )
            compare(Ssh().also { it.server = "s.example.com"; it.serverPort = 22 })
            compare(Ssh().also { it.server = "s.example.com"; it.serverPort = 22; it.host_key = arrayListOf("key") })
            compare(Naive().also { it.server = "n.example.com"; it.serverPort = 443 })
            compare(Naive().also { it.server = "n.example.com"; it.serverPort = 443; it.quic = true })
            compare(Direct().also { it.dial.bind_interface = "wlan0" })
            compare(Direct().also { it.dial.inet6_bind_address = "fe80::1" })
            compare(Chain().also { it.name = "c"; it.list = arrayListOf(1L, 2L) })
            compare(AutoSelector().also { it.name = "auto"; it.gids = arrayListOf(2L) })
            compare(
                Custom().also {
                    it.name = "cu"
                    it.subtype = "outbound"
                    it.config = """{"type":"shadowsocks","method":"none"}"""
                },
            )
            compare(
                Custom().also {
                    it.name = "cf"
                    it.subtype = "fullconfig"
                    it.config = """{"outbounds":[{"type":"trojan","server":"10.0.0.5","server_port":443}]}"""
                },
            )
        } finally {
            AutoSelector.groupNames = previousHook
        }
    }

    @Test
    fun `a blank document derives what the model does`() {
        val types = listOf(
            "socks", "http", "shadowsocks", "vmess", "vless", "trojan", "hysteria", "tuic", "juicity",
            "trusttunnel", "anytls", "mieru", "snell", "shadowtls", "wireguard", "masque", "openvpn",
            "openconnect", "ssh", "naive", "chain", "autoselector", "direct", "custom",
        )
        for (type in types) {
            val model = ProxyEntity.parseOutbound(type, "")
            assertEquals("$type label", model.displayType().ifEmpty { type }, StoredProfile.displayType(type, ""))
            assertEquals("$type address", model.displayAddress(), StoredProfile.displayAddress(type, ""))
            // The zero-key document hashes as its type key, the same for "" and "{}".
            assertEquals(
                "$type blank key",
                StoredProfile.dedupKey(type, ""),
                StoredProfile.dedupKey(type, "{}"),
            )
        }
        // Different types never share the zero-key hash (the old defaults kept them apart too).
        val keys = types.map { StoredProfile.dedupKey(it, "") }
        assertEquals("blank keys must be distinct per type", keys.size, keys.toSet().size)
    }
}
