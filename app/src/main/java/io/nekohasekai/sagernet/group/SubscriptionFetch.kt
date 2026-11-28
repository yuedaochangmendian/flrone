package io.nekohasekai.sagernet.group

import androidx.core.net.toUri
import io.nekohasekai.sagernet.R
import io.nekohasekai.sagernet.database.SubHttpVersion
import io.nekohasekai.sagernet.database.SubUserInfo
import io.nekohasekai.sagernet.ktx.HttpGetOptions
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.ktx.app
import io.nekohasekai.sagernet.ktx.httpGet
import io.nekohasekai.sagernet.ktx.readableMessage
import java.io.ByteArrayOutputStream

/** GroupUpdater::fetch (GroupUpdater.cpp:448-463), plus the Android `content://` subscription URLs. */
object SubscriptionFetch {

    /** kMaxSubscriptionBytes (GroupUpdater.cpp:24). */
    const val MAX_BYTES = 64L * 1024 * 1024

    /** The body of an HTTP error status is logged up to this size. */
    private const val MAX_LOGGED_BODY = 4096

    /**
     * [error] is null on success; [subInfo] is what the headers and the body's head said ([SubscriptionMetadata]);
     * [contentDisposition] is the raw `Content-Disposition` header, used for the fallback name when neither the URL
     * nor the server's title names the subscription. The retired `routing` header is no longer read (one global
     * rule table); the field is kept as an empty value so existing callers/tests keep compiling. [headers],
     * [finalUrl] and [statusCode] let the host subscription seam answer Dart with the same response metadata the
     * Kotlin refresh sees; they are empty/0 for a failure that never reached a response.
     */
    class Result(
        @JvmField val body: String,
        @JvmField val subInfo: SubUserInfo,
        @JvmField val error: String?,
        @JvmField val routing: String = "",
        @JvmField val contentDisposition: String = "",
        /** Response headers with lower-cased names; empty for `content://` and for failures without a response. */
        @JvmField val headers: Map<String, String> = emptyMap(),
        /** The URL that answered after redirects; the request URL for `content://`. */
        @JvmField val finalUrl: String = "",
        /** HTTP status of [finalUrl]; 0 when no HTTP response was reached. */
        @JvmField val statusCode: Int = 0,
    )

    fun fetch(url: String, rawName: String, identity: RequestIdentity): Result {
        // ImportUrl names the request by its URL, whose userinfo is the Basic auth credential.
        val name = withoutUserInfo(rawName)
        Logs.i(">>>>>>>> " + app.getString(R.string.subs_requesting, name))
        val result = if (url.startsWith("content://", ignoreCase = true)) readContent(url) else request(url, identity)
        if (result.error != null) {
            val reason = withoutUrls(result.error, url)
            Logs.w("<<<<<<<< " + app.getString(R.string.subs_request_error, name, reason + "\n" + withoutUrls(result.body, url)))
            return Result(
                "", SubUserInfo(), reason, result.routing, result.contentDisposition,
                result.headers, result.finalUrl, result.statusCode,
            )
        }
        Logs.i("<<<<<<<< " + app.getString(R.string.subs_request_finished, name))
        if (result.subInfo.serverInterval > 0) {
            Logs.i(app.getString(R.string.subs_server_interval, result.subInfo.serverInterval))
        }
        return result
    }

    private val URL = Regex("""[A-Za-z][A-Za-z0-9+.\-]*://[^\s"'<>]+""")

    private val USER_INFO = Regex("""([A-Za-z][A-Za-z0-9+.\-]*://)[^/?#\s]*@""")

    private fun withoutUserInfo(text: String): String = USER_INFO.replace(text, "$1")

    /** withoutUrls (GroupUpdater.cpp): an HTTP error text can embed the request or redirect URL, and with it the subscription token. */
    private fun withoutUrls(text: String, url: String): String {
        fun hostOf(u: String): String = runCatching { u.toUri().host }.getOrNull()?.takeIf { it.isNotEmpty() } ?: "\u2026"
        var redacted = text
        if (url.isNotEmpty()) redacted = redacted.replace(url, hostOf(url))
        return URL.replace(redacted) { hostOf(it.value) }
    }

    private fun request(url: String, identity: RequestIdentity): Result {
        val response = httpGet(
            url,
            HttpGetOptions(
                userAgent = identity.userAgent,
                headers = identity.headers(),
                maxBytes = MAX_BYTES,
                tlsVersion = identity.tlsVersion,
                http2 = identity.httpVersion != SubHttpVersion.HTTP11,
            ),
        )
        if (!response.ok) {
            val body = String(response.data, 0, minOf(response.data.size, MAX_LOGGED_BODY), Charsets.UTF_8)
            return Result(
                body, SubUserInfo(), response.error,
                headers = response.headerMap(),
                finalUrl = response.finalUrl,
                statusCode = response.statusCode,
            )
        }
        val body = try {
            decodeBody(response.data)
        } catch (e: Exception) {
            return Result(
                "", SubUserInfo(), e.readableMessage,
                headers = response.headerMap(),
                finalUrl = response.finalUrl,
                statusCode = response.statusCode,
            )
        }
        return Result(
            body,
            SubscriptionMetadata.read(response::header, body),
            null,
            contentDisposition = response.header("Content-Disposition"),
            headers = response.headerMap(),
            finalUrl = response.finalUrl,
            statusCode = response.statusCode,
        )
    }

    private fun decodeBody(bytes: ByteArray): String =
        String(SubscriptionCompression.decode(bytes), Charsets.UTF_8)

    private fun readContent(url: String): Result = try {
        val input = app.contentResolver.openInputStream(url.toUri()) ?: error("cannot open $url")
        val out = ByteArrayOutputStream()
        input.use {
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = it.read(buffer)
                if (read < 0) break
                out.write(buffer, 0, read)
                if (out.size() > MAX_BYTES) error(app.getString(R.string.subs_response_too_large, MAX_BYTES / (1024 * 1024)))
            }
        }
        val body = decodeBody(out.toByteArray())
        Result(body, SubscriptionMetadata.read({ "" }, body), null, finalUrl = url, statusCode = 200)
    } catch (e: Exception) {
        Result("", SubUserInfo(), e.readableMessage, finalUrl = url)
    }
}
