// The SSRF fence in front of every runtime URL fetch.
//
// A routing profile is an importable document, so its `remote_url` — and a rule's rule-set
// URL — is attacker-controlled input. The classes below are the ones a fence that only checks
// for "localhost" would let through: `127.0.0.1` written as decimal, `[::1]`, a 10/8 address,
// CGNAT, and an IPv4-mapped loopback. Each case here is a request the app must refuse before
// opening a socket.

import io.nekohasekai.sagernet.route.UrlSafety
import java.net.InetAddress
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class UrlSafetyTest {

    private fun refused(url: String) {
        try {
            UrlSafety.requirePublicHttp(url)
            fail("$url must be refused")
        } catch (expected: IllegalArgumentException) {
            // The message is the user-facing reason; it must name one.
            assertTrue("the refusal must explain itself", expected.message.orEmpty().isNotEmpty())
        }
    }

    // --- scheme and shape -------------------------------------------------------

    @Test
    fun onlyHttpAndHttpsAreAllowed() {
        for (url in listOf(
            "file:///etc/passwd",
            "ftp://example.com/x",
            "content://x",
            "javascript:alert(1)",
            "//example.com/x",
            "",
            "   ",
        )) {
            refused(url)
        }
    }

    @Test
    fun credentialsInTheUrlAreRefused() {
        // `http://public.example@127.0.0.1/` reads as a public host and dials loopback.
        refused("http://user:pass@example.com/routing")
        refused("https://example.com@127.0.0.1/routing")
    }

    @Test
    fun publicHttpsUrlsPassAndAreTrimmed() {
        assertEquals(
            "https://raw.githubusercontent.com/throneproj/routeprofiles/rule-set/srslist.h",
            UrlSafety.requirePublicHttp(
                "  https://raw.githubusercontent.com/throneproj/routeprofiles/rule-set/srslist.h  ",
            ),
        )
        assertEquals("http://example.com/a", UrlSafety.requirePublicHttp("http://example.com/a"))
    }

    // --- host names -------------------------------------------------------------

    @Test
    fun localhostSpellingsAreRefused() {
        for (url in listOf(
            "http://localhost/routing",
            "http://LOCALHOST/routing",
            "http://localhost.localdomain/",
            "http://ip6-localhost/",
            "http://anything.localhost/",
            "http://metadata/",
        )) {
            refused(url)
        }
    }

    @Test
    fun aSingleLabelHostIsRefused() {
        // Only a LAN search domain can resolve this; it is exactly the case the fence exists for.
        refused("http://intranet/routing")
    }

    @Test
    fun aPublicNameIsNotRefusedForItsShape() {
        UrlSafety.requirePublicHttp("https://example.com/routing")
        UrlSafety.requirePublicHttp("https://sub.example.co.uk/routing")
    }

    // --- IPv4 literals ----------------------------------------------------------

    @Test
    fun ipv4SpecialRangesAreRefused() {
        for (host in listOf(
            "127.0.0.1",       // loopback
            "127.255.255.254", // loopback, upper end
            "0.0.0.0",         // this host
            "10.0.0.1",        // private 10/8
            "172.16.0.1",      // private 172.16/12
            "172.31.255.254",  // private, upper end
            "192.168.1.1",     // private 192.168/16
            "169.254.169.254", // link-local (cloud metadata)
            "100.64.0.1",      // CGNAT 100.64/10
            "100.127.255.254", // CGNAT, upper end
            "198.18.0.1",      // benchmark 198.18/15
            "198.19.255.254",  // benchmark, upper end
            "224.0.0.1",       // multicast
            "240.0.0.1",       // reserved
            "255.255.255.255", // limited broadcast
        )) {
            refused("http://$host/routing")
        }
    }

    @Test
    fun ordinaryPublicIpv4Passes() {
        // 100.63 and 100.128 are outside CGNAT; 198.17 and 198.20 outside the benchmark block.
        for (host in listOf("1.1.1.1", "8.8.8.8", "100.63.255.254", "100.128.0.1", "198.17.0.1", "198.20.0.1")) {
            UrlSafety.requirePublicHttp("http://$host/routing")
        }
    }

    // --- IPv6 literals ----------------------------------------------------------

    @Test
    fun ipv6SpecialRangesAreRefused() {
        for (url in listOf(
            "http://[::1]/routing",           // loopback
            "http://[::]/routing",            // unspecified
            "http://[fe80::1]/routing",       // link-local fe80::/10
            "http://[fc00::1]/routing",       // ULA fc00::/7
            "http://[fd12:3456::1]/routing",  // ULA, the fd00::/8 half
            "http://[ff02::1]/routing",       // multicast
            "http://[::ffff:127.0.0.1]/routing", // IPv4-mapped loopback
            "http://[::ffff:192.168.1.1]/routing", // IPv4-mapped private
        )) {
            refused(url)
        }
    }

    @Test
    fun anOrdinaryPublicIpv6Passes() {
        UrlSafety.requirePublicHttp("http://[2606:4700:4700::1111]/routing")
    }

    // --- the address predicate --------------------------------------------------

    @Test
    fun isPublicAddressAnswersTheSameClasses() {
        for (literal in listOf("127.0.0.1", "10.1.2.3", "192.168.0.1", "169.254.1.1", "::1", "fd00::1")) {
            assertFalse(literal, UrlSafety.isPublicAddress(InetAddress.getByName(literal)))
        }
        for (literal in listOf("1.1.1.1", "8.8.8.8", "2606:4700:4700::1111")) {
            assertTrue(literal, UrlSafety.isPublicAddress(InetAddress.getByName(literal)))
        }
    }

    // --- resolution -------------------------------------------------------------

    @Test
    fun aLiteralIsValidatedWithoutAResolver() {
        // requirePublicResolution must refuse a literal directly rather than hand it to DNS.
        for (literal in listOf("127.0.0.1", "10.0.0.1", "::1", "::ffff:127.0.0.1")) {
            try {
                UrlSafety.requirePublicResolution(literal)
                fail("$literal must be refused")
            } catch (expected: IllegalArgumentException) {
                // expected
            }
        }
    }

    @Test
    fun aPublicLiteralResolvesToItself() {
        UrlSafety.requirePublicResolution("1.1.1.1")
        UrlSafety.requirePublicResolution("2606:4700:4700::1111")
    }
}
