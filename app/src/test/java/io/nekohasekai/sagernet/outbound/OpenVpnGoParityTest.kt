package io.nekohasekai.sagernet.outbound

import io.nekohasekai.sagernet.document.json.JsonInput
import io.nekohasekai.sagernet.outbound.types.OpenConnect
import io.nekohasekai.sagernet.outbound.types.OpenVpn
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Parity pins for the Go OpenVPN/OpenConnect slice.
 *
 * The literals below are the same ones `profile_vpn_test.go` asserts in the
 * patched core tree, and every one of them was produced by these Kotlin models:
 * a change to either side fails here or there instead of drifting. The
 * `.ovpn`/OpenConnect-profile texts are deliberately note-free (a plain JVM test
 * has no Android `Context`, so a parser that reports a note would fail on
 * `vtr()`); the Go tests cover the note-producing branches.
 */
class OpenVpnGoParityTest {

    private fun outbound(document: String): Outbound =
        OutboundFactory.fromJson(JsonInput.parseObject(document)) ?: error("document did not parse: $document")

    private class ExportVector(
        val name: String,
        val document: String,
        val json: String,
        val identity: String,
        val link: String,
    )

    private val exportVectors = listOf(

		ExportVector(
			"openvpn minimal",
			"{\"type\":\"openvpn\"}",
			"{\"only_advertised_routes\":true,\"tunnel_dns\":\"prefer\",\"type\":\"openvpn\"}",
			"{\"only_advertised_routes\":true,\"tunnel_dns\":\"prefer\",\"type\":\"openvpn\"}",
			"",
		),
		ExportVector(
			"openvpn tls block",
			"{\"type\":\"openvpn\",\"tag\":\"Ovpn\",\"server\":\"Example.COM\",\"server_port\":1194,\"username\":\"alice\",\"password\":\"secret\",\"mode\":\"tls\",\"network\":\"udp\",\"tls\":{\"certificate\":[\"-----BEGIN CERTIFICATE-----\",\"MIIB\",\"-----END CERTIFICATE-----\"],\"peer_fingerprint\":[\"AA:BB\"],\"server_name\":\"vpn.example.com\",\"server_name_type\":\"name\",\"version_min\":\"1.2\",\"version_max\":\"1.3\",\"cipher\":\"TLS-ECDHE-RSA-WITH-AES-128-GCM-SHA256\",\"groups\":\"x25519:secp256r1\",\"remote_certificate_tls\":\"server\",\"remote_certificate_ku\":[\"a0\"],\"remote_certificate_eku\":\"server\",\"certificate_profile\":\"preferred\",\"ns_certificate_type\":\"server\",\"crl_path\":\"/crl.pem\",\"control_wrap\":{\"type\":\"tls_auth\",\"key\":[\"k1\",\"k2\"],\"direction\":\"client\"}}}",
			"{\"mode\":\"tls\",\"network\":\"udp\",\"only_advertised_routes\":true,\"password\":\"secret\",\"server\":\"Example.COM\",\"server_port\":1194,\"tag\":\"Ovpn\",\"tls\":{\"certificate\":[\"-----BEGIN CERTIFICATE-----\",\"MIIB\",\"-----END CERTIFICATE-----\"],\"certificate_profile\":\"preferred\",\"cipher\":\"TLS-ECDHE-RSA-WITH-AES-128-GCM-SHA256\",\"control_wrap\":{\"direction\":\"client\",\"key\":[\"k1\",\"k2\"],\"type\":\"tls_auth\"},\"crl_path\":\"/crl.pem\",\"groups\":\"x25519:secp256r1\",\"ns_certificate_type\":\"server\",\"peer_fingerprint\":[\"AA:BB\"],\"remote_certificate_eku\":\"server\",\"remote_certificate_ku\":[\"a0\"],\"remote_certificate_tls\":\"server\",\"server_name\":\"vpn.example.com\",\"server_name_type\":\"name\",\"version_max\":\"1.3\",\"version_min\":\"1.2\"},\"tunnel_dns\":\"prefer\",\"type\":\"openvpn\",\"username\":\"alice\"}",
			"{\"server\":\"Example.COM\",\"server_port\":1194}",
			"",
		),
		ExportVector(
			"openvpn server list",
			"{\"type\":\"openvpn\",\"servers\":[{\"server\":\"a.example.com\",\"server_port\":443,\"network\":\"tcp\"},{\"server\":\"b.example.com\",\"server_port\":1194}],\"remote_random\":true,\"reuse_addr\":true,\"connect_timeout\":\"5s\"}",
			"{\"connect_timeout\":\"5s\",\"only_advertised_routes\":true,\"remote_random\":true,\"reuse_addr\":true,\"servers\":[{\"network\":\"tcp\",\"server\":\"a.example.com\",\"server_port\":443},{\"server\":\"b.example.com\",\"server_port\":1194}],\"tunnel_dns\":\"prefer\",\"type\":\"openvpn\"}",
			"{\"connect_timeout\":\"5s\",\"only_advertised_routes\":true,\"remote_random\":true,\"reuse_addr\":true,\"servers\":[{\"network\":\"tcp\",\"server\":\"a.example.com\",\"server_port\":443},{\"server\":\"b.example.com\",\"server_port\":1194}],\"tunnel_dns\":\"prefer\",\"type\":\"openvpn\"}",
			"reuse_addr=true&connect_timeout=5s",
		),
		ExportVector(
			"openvpn static key",
			"{\"type\":\"openvpn\",\"mode\":\"static_key\",\"static_key\":[\"-----BEGIN OpenVPN Static key V1-----\",\"0011\",\"-----END OpenVPN Static key V1-----\"],\"key_direction\":\"client\",\"cipher\":\"AES-256-CBC\",\"address\":[\"10.0.0.2/24\"],\"peer_address\":\"10.0.0.1\"}",
			"{\"address\":[\"10.0.0.2/24\"],\"cipher\":\"AES-256-CBC\",\"key_direction\":\"client\",\"mode\":\"static_key\",\"only_advertised_routes\":true,\"peer_address\":\"10.0.0.1\",\"static_key\":[\"-----BEGIN OpenVPN Static key V1-----\",\"0011\",\"-----END OpenVPN Static key V1-----\"],\"tunnel_dns\":\"prefer\",\"type\":\"openvpn\"}",
			"{\"address\":[\"10.0.0.2/24\"],\"cipher\":\"AES-256-CBC\",\"key_direction\":\"client\",\"mode\":\"static_key\",\"only_advertised_routes\":true,\"peer_address\":\"10.0.0.1\",\"static_key\":[\"-----BEGIN OpenVPN Static key V1-----\",\"0011\",\"-----END OpenVPN Static key V1-----\"],\"tunnel_dns\":\"prefer\",\"type\":\"openvpn\"}",
			"",
		),
		ExportVector(
			"openvpn routing and compression",
			"{\"type\":\"openvpn\",\"server\":\"h\",\"server_port\":1194,\"routes\":[\"10.0.0.0/8\",\"2001:db8::/32\"],\"route_gateway\":\"10.0.0.1\",\"route_metric\":5,\"route_no_pull\":true,\"pull_filters\":[{\"action\":\"accept\",\"text\":\"dhcp-option\"}],\"redirect_gateway\":true,\"redirect_gateway_flags\":[\"def1\",\"bypass-dhcp\"],\"block_ipv6\":true,\"compression\":\"stub\",\"compression_lzo\":\"yes\",\"allow_compression\":\"no\",\"mss_fix\":1200,\"mss_fix_mode\":\"mtu\",\"fragment\":1200,\"replay_window\":64,\"replay_window_time\":\"60s\",\"ping_interval\":\"10s\",\"ping_restart\":\"60s\",\"renegotiate_interval\":\"3600s\",\"renegotiate_bytes\":1000,\"renegotiate_packets\":100,\"tls_timeout\":\"2s\",\"handshake_window\":\"60s\",\"explicit_exit_notify\":1,\"mtu\":1400,\"udp_timeout\":\"30s\",\"udp_mapping\":\"random\",\"udp_filtering\":\"random\",\"udp_nat_max\":100}",
			"{\"allow_compression\":\"no\",\"block_ipv6\":true,\"compression\":\"stub\",\"compression_lzo\":\"yes\",\"explicit_exit_notify\":1,\"fragment\":1200,\"handshake_window\":\"60s\",\"mss_fix\":1200,\"mss_fix_mode\":\"mtu\",\"mtu\":1400,\"only_advertised_routes\":true,\"ping_interval\":\"10s\",\"ping_restart\":\"60s\",\"pull_filters\":[{\"action\":\"accept\",\"text\":\"dhcp-option\"}],\"redirect_gateway\":true,\"redirect_gateway_flags\":[\"def1\",\"bypass-dhcp\"],\"renegotiate_bytes\":1000,\"renegotiate_interval\":\"3600s\",\"renegotiate_packets\":100,\"replay_window\":64,\"replay_window_time\":\"60s\",\"route_gateway\":\"10.0.0.1\",\"route_metric\":5,\"route_no_pull\":true,\"routes\":[\"10.0.0.0/8\",\"2001:db8::/32\"],\"server\":\"h\",\"server_port\":1194,\"tls_timeout\":\"2s\",\"tunnel_dns\":\"prefer\",\"type\":\"openvpn\",\"udp_filtering\":\"random\",\"udp_mapping\":\"random\",\"udp_nat_max\":100,\"udp_timeout\":\"30s\"}",
			"{\"server\":\"h\",\"server_port\":1194}",
			"",
		),
		ExportVector(
			"openvpn alias and legacy keys",
			"{\"type\":\"openvpn-client\",\"server\":\"h\",\"server_port\":1194,\"otp_profile_id\":3,\"block_outside_dns\":true,\"system\":true,\"name\":\"tun9\",\"auth\":\"SHA256\",\"auth_retry\":\"interact\",\"static_challenge\":\"OTP:\",\"static_challenge_echo\":true,\"topology\":\"subnet\",\"address\":[\"10.0.0.2/24\"],\"peer_address_ipv6\":\"2001:db8::1\",\"data_ciphers\":[\"AES-256-GCM\",\"CHACHA20-POLY1305\"],\"data_ciphers_fallback\":\"AES-256-CBC\"}",
			"{\"address\":[\"10.0.0.2/24\"],\"auth\":\"SHA256\",\"auth_retry\":\"interact\",\"data_ciphers\":[\"AES-256-GCM\",\"CHACHA20-POLY1305\"],\"data_ciphers_fallback\":\"AES-256-CBC\",\"name\":\"tun9\",\"only_advertised_routes\":true,\"otp_profile_id\":3,\"peer_address_ipv6\":\"2001:db8::1\",\"server\":\"h\",\"server_port\":1194,\"static_challenge\":\"OTP:\",\"static_challenge_echo\":true,\"system\":true,\"topology\":\"subnet\",\"tunnel_dns\":\"strict\",\"type\":\"openvpn\"}",
			"{\"server\":\"h\",\"server_port\":1194}",
			"",
		),
		ExportVector(
			"openvpn advertised routes off",
			"{\"type\":\"openvpn\",\"server\":\"h\",\"server_port\":1194,\"only_advertised_routes\":false,\"tunnel_dns\":\"none\"}",
			"{\"only_advertised_routes\":false,\"server\":\"h\",\"server_port\":1194,\"tunnel_dns\":\"none\",\"type\":\"openvpn\"}",
			"{\"server\":\"h\",\"server_port\":1194}",
			"",
		),
		ExportVector(
			"openconnect minimal",
			"{\"type\":\"openconnect\"}",
			"{\"only_advertised_routes\":true,\"tunnel_dns\":\"prefer\",\"type\":\"openconnect\"}",
			"{\"only_advertised_routes\":true,\"tunnel_dns\":\"prefer\",\"type\":\"openconnect\"}",
			"",
		),
		ExportVector(
			"openconnect server and path",
			"{\"type\":\"openconnect\",\"server\":\"Example.COM\",\"server_port\":8443,\"server_path\":\"/portal\",\"tag\":\"OC\"}",
			"{\"only_advertised_routes\":true,\"server\":\"example.com\",\"server_path\":\"/portal\",\"server_port\":8443,\"tag\":\"OC\",\"tunnel_dns\":\"prefer\",\"type\":\"openconnect\"}",
			"{\"server\":\"example.com\",\"server_port\":8443}",
			"",
		),
		ExportVector(
			"openconnect server url",
			"{\"type\":\"openconnect\",\"server\":\"https://VPN.example.com:9443/group\"}",
			"{\"only_advertised_routes\":true,\"server\":\"vpn.example.com\",\"server_path\":\"/group\",\"server_port\":9443,\"tunnel_dns\":\"prefer\",\"type\":\"openconnect\"}",
			"{\"server\":\"vpn.example.com\",\"server_port\":9443}",
			"",
		),
		ExportVector(
			"openconnect token",
			"{\"type\":\"openconnect\",\"server\":\"vpn.example.com\",\"server_port\":8443,\"token\":{\"mode\":\"totp\",\"secret\":\"ABC\",\"pin\":\"1234\"},\"reported_os\":\"linux\",\"user_agent\":\"AnyConnect\",\"version\":\"4.10\",\"local_hostname\":\"host\"}",
			"{\"local_hostname\":\"host\",\"only_advertised_routes\":true,\"reported_os\":\"linux\",\"server\":\"vpn.example.com\",\"server_port\":8443,\"token\":{\"mode\":\"totp\",\"pin\":\"1234\",\"secret\":\"ABC\"},\"tunnel_dns\":\"prefer\",\"type\":\"openconnect\",\"user_agent\":\"AnyConnect\",\"version\":\"4.10\"}",
			"{\"server\":\"vpn.example.com\",\"server_port\":8443}",
			"",
		),
		ExportVector(
			"openconnect nested blocks",
			"{\"type\":\"openconnect\",\"server\":\"h\",\"mobile\":{\"platform_version\":\"1\",\"device_type\":\"2\",\"device_unique_id\":\"3\"},\"csd\":{\"wrapper_path\":\"/csd\"},\"hip\":{\"wrapper_path\":\"/hip\"},\"tncc\":{\"wrapper_path\":\"/tncc\",\"device_id\":\"d\",\"user_agent\":\"ua\",\"machine_identification_enabled\":true,\"certificates\":[{\"certificate\":[\"CERT\"],\"certificate_path\":\"/cert\"}]},\"fortinet_host_check\":{\"hostcheck\":\"x\",\"check_virtual_desktop\":\"1\"}}",
			"{\"csd\":{\"wrapper_path\":\"/csd\"},\"fortinet_host_check\":{\"check_virtual_desktop\":\"1\",\"hostcheck\":\"x\"},\"hip\":{\"wrapper_path\":\"/hip\"},\"mobile\":{\"device_type\":\"2\",\"device_unique_id\":\"3\",\"platform_version\":\"1\"},\"only_advertised_routes\":true,\"server\":\"h\",\"tncc\":{\"certificates\":[{\"certificate\":[\"CERT\"],\"certificate_path\":\"/cert\"}],\"device_id\":\"d\",\"machine_identification_enabled\":true,\"user_agent\":\"ua\",\"wrapper_path\":\"/tncc\"},\"tunnel_dns\":\"prefer\",\"type\":\"openconnect\"}",
			"{\"server\":\"h\",\"server_port\":0}",
			"",
		),
		ExportVector(
			"openconnect tls block",
			"{\"type\":\"openconnect\",\"server\":\"h\",\"tls\":{\"insecure\":true,\"server_name\":\"例子.测试\",\"peer_fingerprint\":[\"sha256:AB\"],\"system_trust_disabled\":true,\"certificate_authority\":[\"CA\"],\"certificate_authority_path\":\"/ca\",\"client_certificate\":[\"CC\"],\"client_certificate_path\":\"/cc\",\"client_key\":[\"CK\"],\"client_key_path\":\"/ck\",\"client_key_password\":\"kp\",\"mca_certificate\":[\"MCA\"],\"mca_certificate_path\":\"/mca\",\"mca_key\":[\"MK\"],\"mca_key_path\":\"/mk\",\"mca_key_password\":\"mkp\"}}",
			"{\"only_advertised_routes\":true,\"server\":\"h\",\"tls\":{\"certificate_authority\":[\"CA\"],\"certificate_authority_path\":\"/ca\",\"client_certificate\":[\"CC\"],\"client_certificate_path\":\"/cc\",\"client_key\":[\"CK\"],\"client_key_password\":\"kp\",\"client_key_path\":\"/ck\",\"insecure\":true,\"mca_certificate\":[\"MCA\"],\"mca_certificate_path\":\"/mca\",\"mca_key\":[\"MK\"],\"mca_key_password\":\"mkp\",\"mca_key_path\":\"/mk\",\"peer_fingerprint\":[\"sha256:AB\"],\"server_name\":\"xn--fsqu00a.xn--0zwm56d\",\"system_trust_disabled\":true},\"tunnel_dns\":\"prefer\",\"type\":\"openconnect\"}",
			"{\"server\":\"h\",\"server_port\":0}",
			"",
		),
		ExportVector(
			"openconnect flags and form entries",
			"{\"type\":\"openconnect\",\"server\":\"h\",\"form_entries\":[{\"form_id\":\"f\",\"name\":\"n\",\"value\":\"v\",\"submission_key\":\"s\",\"promote\":true}],\"no_udp\":true,\"dtls_local_port\":1234,\"compression_disabled\":true,\"compression_mode\":\"stateless\",\"ipv6_disabled\":true,\"http_keepalive_disabled\":true,\"xml_post_disabled\":true,\"external_auth_disabled\":true,\"password_authentication_disabled\":true,\"tcp_keep_alive_enabled\":true,\"pfs\":true,\"mtu\":1400,\"base_mtu\":1500,\"dpd_interval\":\"30s\",\"reconnect_timeout\":\"300s\",\"trojan_interval\":\"10s\",\"queue_length\":5,\"allow_insecure_crypto\":true,\"tunnel_dns\":\"strict\",\"only_advertised_routes\":false,\"system\":true,\"name\":\"tun0\"}",
			"{\"allow_insecure_crypto\":true,\"base_mtu\":1500,\"compression_disabled\":true,\"compression_mode\":\"stateless\",\"dpd_interval\":\"30s\",\"dtls_local_port\":1234,\"external_auth_disabled\":true,\"form_entries\":[{\"form_id\":\"f\",\"name\":\"n\",\"promote\":true,\"submission_key\":\"s\",\"value\":\"v\"}],\"http_keepalive_disabled\":true,\"ipv6_disabled\":true,\"mtu\":1400,\"name\":\"tun0\",\"no_udp\":true,\"only_advertised_routes\":false,\"password_authentication_disabled\":true,\"pfs\":true,\"queue_length\":5,\"reconnect_timeout\":\"300s\",\"server\":\"h\",\"system\":true,\"tcp_keep_alive_enabled\":true,\"trojan_interval\":\"10s\",\"tunnel_dns\":\"strict\",\"type\":\"openconnect\",\"xml_post_disabled\":true}",
			"{\"server\":\"h\",\"server_port\":0}",
			"",
		),
    )

    @Test
    fun `stored openvpn and openconnect documents export the pinned bytes`() {
        for (vector in exportVectors) {
            val outbound = outbound(vector.document)
            assertEquals(vector.name, vector.json, outbound.exportToJson().toCompact())
            assertEquals(vector.name, vector.identity, outbound.exportIdentity().toCompact())
            assertEquals(vector.name, vector.link, outbound.exportToLink())
        }
    }

    private class ProfileVector(
        val name: String,
        val text: String,
        val json: String,
        val identity: String,
    )

    private val openVpnProfiles = listOf(
ProfileVector(
			"openvpn profile with inline certificates",
			"client\ndev tun\nproto udp\nremote vpn.example.com 1194\n<ca>\n-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n</ca>\n<cert>\nCERT\n</cert>\n<key>\nKEY\n</key>\nremote-cert-tls server\nauth-user-pass\n",
			"{\"network\":\"udp\",\"only_advertised_routes\":true,\"server\":\"vpn.example.com\",\"server_port\":1194,\"tag\":\"vpn.example.com\",\"tls\":{\"certificate\":[\"-----BEGIN CERTIFICATE-----\",\"MIIB\",\"-----END CERTIFICATE-----\"],\"client_certificate\":[\"CERT\"],\"client_key\":[\"KEY\"],\"remote_certificate_tls\":\"server\"},\"tunnel_dns\":\"prefer\",\"type\":\"openvpn\"}",
			"{\"server\":\"vpn.example.com\",\"server_port\":1194}",
		),
ProfileVector(
			"openvpn profile with connection blocks",
			"client\ndev tun\n<connection>\nremote a.example.com 1194 udp\n</connection>\n<connection>\nremote b.example.com 443 tcp\nproto tcp\n</connection>\n<tls-auth>\nSTATIC\n</tls-auth>\nkey-direction 1\n",
			"{\"only_advertised_routes\":true,\"servers\":[{\"network\":\"udp\",\"server\":\"a.example.com\",\"server_port\":1194},{\"network\":\"tcp\",\"server\":\"b.example.com\",\"server_port\":443}],\"tag\":\"a.example.com\",\"tls\":{\"control_wrap\":{\"direction\":\"client\",\"key\":[\"STATIC\"],\"type\":\"tls_auth\"}},\"tunnel_dns\":\"prefer\",\"type\":\"openvpn\"}",
			"{\"only_advertised_routes\":true,\"servers\":[{\"network\":\"udp\",\"server\":\"a.example.com\",\"server_port\":1194},{\"network\":\"tcp\",\"server\":\"b.example.com\",\"server_port\":443}],\"tag\":\"a.example.com\",\"tls\":{\"control_wrap\":{\"direction\":\"client\",\"key\":[\"STATIC\"],\"type\":\"tls_auth\"}},\"tunnel_dns\":\"prefer\",\"type\":\"openvpn\"}",
		),
ProfileVector(
			"openvpn profile with routes",
			"client\ndev tun\nproto tcp\nremote h.example.com 443 tcp\nroute 10.0.0.0 255.0.0.0\nroute 192.168.1.0/24\nroute-ipv6 2001:db8::/32\nroute-gateway 10.0.0.1\nroute-metric 5\n",
			"{\"network\":\"tcp\",\"only_advertised_routes\":true,\"route_gateway\":\"10.0.0.1\",\"route_metric\":5,\"routes\":[\"10.0.0.0/8\",\"192.168.1.0/24\",\"2001:db8::/32\"],\"server\":\"h.example.com\",\"server_port\":443,\"tag\":\"h.example.com\",\"tunnel_dns\":\"prefer\",\"type\":\"openvpn\"}",
			"{\"server\":\"h.example.com\",\"server_port\":443}",
		),
	ProfileVector(
		"openvpn profile in static-key mode",
		"secret static.key 1\nifconfig 10.0.0.2 10.0.0.1\nremote 10.9.9.9\ncipher AES-256-CBC\n",
		"{\"address\":[\"10.0.0.2/32\"],\"cipher\":\"AES-256-CBC\",\"key_direction\":\"client\",\"mode\":\"static_key\",\"only_advertised_routes\":true,\"peer_address\":\"10.0.0.1\",\"server\":\"10.9.9.9\",\"server_port\":1194,\"static_key_path\":\"static.key\",\"tag\":\"10.9.9.9\",\"tunnel_dns\":\"prefer\",\"type\":\"openvpn\"}",
		"{\"server\":\"10.9.9.9\",\"server_port\":1194}",
	),
    )

    private val openConnectProfiles = listOf(
ProfileVector(
			"openconnect command line",
			"openconnect --protocol=anyconnect --user=alice --server=vpn.example.com:8443/portal --authgroup=Staff --no-dtls",
			"{\"auth_group\":\"Staff\",\"flavor\":\"anyconnect\",\"no_udp\":true,\"only_advertised_routes\":true,\"server\":\"vpn.example.com\",\"server_path\":\"/portal\",\"server_port\":8443,\"tag\":\"vpn.example.com\",\"tunnel_dns\":\"prefer\",\"type\":\"openconnect\",\"username\":\"alice\"}",
			"{\"server\":\"vpn.example.com\",\"server_port\":8443}",
		),
ProfileVector(
			"openconnect config file",
			"protocol=anyconnect\nserver=vpn.example.com/portal\nuser=alice\nauthgroup=Staff\ncertificate=/tmp/cert.pem\nsslkey=/tmp/key.pem\ncafile=/tmp/ca.pem\n",
			"{\"auth_group\":\"Staff\",\"flavor\":\"anyconnect\",\"only_advertised_routes\":true,\"server\":\"vpn.example.com\",\"server_path\":\"/portal\",\"tag\":\"vpn.example.com\",\"tls\":{\"certificate_authority_path\":\"/tmp/ca.pem\",\"client_certificate_path\":\"/tmp/cert.pem\",\"client_key_path\":\"/tmp/key.pem\"},\"tunnel_dns\":\"prefer\",\"type\":\"openconnect\",\"username\":\"alice\"}",
			"{\"server\":\"vpn.example.com\",\"server_port\":0}",
		),
ProfileVector(
			"openconnect form entry and token",
			"openconnect vpn.example.com --protocol=anyconnect --form-entry=all:pin=1234 --token-mode=totp --token-secret=ABC --os=android --compression=all --reconnect-timeout=60 --queue-len=3",
			"{\"compression_mode\":\"all\",\"flavor\":\"anyconnect\",\"form_entries\":[{\"form_id\":\"all\",\"name\":\"pin\",\"value\":\"1234\"}],\"only_advertised_routes\":true,\"queue_length\":3,\"reconnect_timeout\":\"60s\",\"reported_os\":\"android\",\"server\":\"vpn.example.com\",\"tag\":\"vpn.example.com\",\"token\":{\"mode\":\"totp\",\"secret\":\"ABC\"},\"tunnel_dns\":\"prefer\",\"type\":\"openconnect\"}",
			"{\"server\":\"vpn.example.com\",\"server_port\":0}",
		),
    )

    @Test
    fun `openvpn profile imports export the pinned bytes`() {
        for (vector in openVpnProfiles) {
            val profile = OpenVpn()
            assertTrue(vector.name, profile.parseOvpnConfig(vector.text))
            assertEquals(vector.name, vector.json, profile.exportToJson().toCompact())
            assertEquals(vector.name, vector.identity, profile.exportIdentity().toCompact())
        }
    }

    @Test
    fun `openconnect profile imports export the pinned bytes`() {
        for (vector in openConnectProfiles) {
            val profile = OpenConnect()
            assertTrue(vector.name, profile.parseOpenConnectProfile(vector.text))
            assertEquals(vector.name, vector.json, profile.exportToJson().toCompact())
            assertEquals(vector.name, vector.identity, profile.exportIdentity().toCompact())
        }
    }

    @Test
    fun `neither type has a share-link clash or singbox-table mapping`() {
        // OutboundFactory's PROTOCOLS table drives the scheme, Clash and
        // sing-box tables: neither endpoint appears in any of them, which is
        // the reason the Go importer refuses an `openvpn://` link, a Clash
        // entry of either type and a sing-box JSON body entry. A stored
        // document still converts: `throne://add/<base64>` goes through
        // OutboundFactory.newByType, which is the path the Go JSON body path
        // mirrors for these two types.
        assertEquals(null, OutboundFactory.typeForScheme("openvpn-client://x"))
        assertEquals(null, OutboundFactory.typeForScheme("openvpn://x"))
        assertEquals(null, OutboundFactory.typeForScheme("openconnect://x"))
        assertEquals(null, OutboundFactory.typeForClash("openvpn"))
        assertEquals(null, OutboundFactory.typeForClash("openconnect"))
        assertEquals(null, OutboundFactory.typeForSingBox("openvpn-client"))
        assertEquals(null, OutboundFactory.typeForSingBox("openvpn"))
        assertEquals(null, OutboundFactory.typeForSingBox("openconnect"))
        // The canonical type alias and the factory entry do resolve.
        assertEquals("openvpn", OutboundFactory.canonicalType("openvpn-client"))
        assertTrue(OutboundFactory.newByType("openvpn") is OpenVpn)
        assertTrue(OutboundFactory.newByType("openvpn-client") is OpenVpn)
        assertTrue(OutboundFactory.newByType("openconnect") is OpenConnect)
    }
}