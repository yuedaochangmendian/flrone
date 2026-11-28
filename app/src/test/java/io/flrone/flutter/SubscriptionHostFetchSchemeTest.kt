package io.flrone.flutter

import io.nekohasekai.sagernet.database.ProxyGroup
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * S8: the Dart/host fetch is the only subscription reader left, so the scheme
 * predicate's sentence is what the UI shows when a manual refresh, an automatic
 * poll or an editor create/edit is refused. It used to decide a Kotlin fallback;
 * now it is purely a user-facing error source.
 */
class SubscriptionHostFetchSchemeTest {

    private fun reason(url: String): String? =
        SubscriptionHostFetch.unsupportedReason(ProxyGroup(url = url))

    @Test
    fun `http and https are served without a reason`() {
        assertNull(reason("https://panel.example/sub?token=x"))
        assertNull(reason("http://panel.example/sub"))
        assertNull(reason("  https://panel.example/sub  "))
    }

    @Test
    fun `content urls are served by the ContentResolver seam`() {
        assertNull(reason("content://com.example.provider/subscription"))
    }

    @Test
    fun `another scheme is refused with a user-facing sentence`() {
        assertEquals("Unsupported subscription scheme: ftp", reason("ftp://panel.example/sub"))
        assertEquals("Unsupported subscription scheme: (none)", reason("panel.example/sub"))
    }

    @Test
    fun `an empty url is refused`() {
        assertEquals("The subscription URL is empty", reason(""))
        assertEquals("The subscription URL is empty", reason("   "))
    }
}
