package io.flrone.flutter

import io.nekohasekai.sagernet.database.GroupRepo
import io.nekohasekai.sagernet.database.ProxyGroup
import io.nekohasekai.sagernet.database.SubscriptionOptions
import io.nekohasekai.sagernet.group.RequestIdentity
import io.nekohasekai.sagernet.group.SubscriptionFetch
import io.nekohasekai.sagernet.group.SubscriptionFileName
import io.nekohasekai.sagernet.ktx.Logs

/**
 * The host half of the subscription fetch seam (`subscription.fetch`).
 *
 * Dart's subscription refresh owns the queue, the parse and the document edit,
 * but two inputs only the platform can reach: `content://` URLs (a picked file
 * needs a `ContentResolver`) and a fetch that must use the app's OkHttp/proxy
 * path and per-group [RequestIdentity] (TLS/HTTP version, HWID headers). This
 * object runs Kotlin's [SubscriptionFetch] — the same reader the legacy refresh
 * used — and answers Dart with a map shaped like its `SubscriptionFetchResult`
 * (body, headers, metadata, filename, final URL, status, redacted error).
 *
 * The identity is resolved exactly like the legacy path: from the stored group
 * when [GroupRepo] has it, or from the editor's `subOptionsJson` for a create
 * that has no group row yet. A URL scheme the host cannot fetch answers
 * `supported=false` with a precise reason; the Kotlin refresh/queue is gone
 * (S8), so callers surface that reason as a user-facing error instead of keeping
 * the group on a fallback path (see [unsupportedReason]).
 *
 * Nothing here logs a URL or a credential: [SubscriptionFetch] already redacts
 * its own error text.
 */
internal object SubscriptionHostFetch {

    /** The reply map keys, mirrored by Dart's `SubscriptionHostFetchReply.parse`. */
    private const val SUPPORTED = "supported"

    /**
     * The user-facing reason [SubscriptionFetch] is not a faithful host-facing
     * fetch for [group], or null when the host seam covers it. `content://` and
     * the group's front/landing proxy ids are covered: the legacy fetch never
     * read the ids either (they are config-build hop metadata), and `content://`
     * is read through the same ContentResolver path.
     */
    fun unsupportedReason(group: ProxyGroup): String? = unsupportedSchemeReason(group.url)

    /** `null` when [rawUrl] is an `http(s)://` or `content://` subscription URL. */
    private fun unsupportedSchemeReason(rawUrl: String?): String? {
        val url = rawUrl?.trim().orEmpty()
        if (url.isEmpty()) return "The subscription URL is empty"
        val scheme = url.substringBefore("://", "").lowercase()
        return when (scheme) {
            "http", "https", "content" -> null
            else -> "Unsupported subscription scheme: ${scheme.ifEmpty { "(none)" }}"
        }
    }

    /**
     * Runs one host fetch. [arguments] carries `url` (required), `gid` (a stored
     * group, 0 for a create), `subOptionsJson` (the editor options for a create)
     * and `name` (the report/log label, never a URL or credential).
     */
    fun fetch(arguments: Map<*, *>): Map<String, Any?> {
        val url = (arguments["url"] as? String)?.trim().orEmpty()
        unsupportedSchemeReason(url)?.let { reason ->
            return failure(reason, supported = false)
        }
        val gid = (arguments["gid"] as? Number)?.toLong() ?: 0L
        val subOptionsJson = arguments["subOptionsJson"] as? String
        val storedGroup = try {
            if (gid > 0L) GroupRepo.get(gid) else null
        } catch (e: Throwable) {
            Logs.w("subscription.fetch: cannot read the stored group", e)
            return failure(e.message ?: e.javaClass.simpleName, supported = true)
        }
        val identitySource = storedGroup ?: ProxyGroup(subOptions = SubscriptionOptions.parse(subOptionsJson))
        val name = identitySource.name.ifBlank {
            (arguments["name"] as? String).orEmpty()
        }
        val identity = try {
            RequestIdentity.resolve(identitySource)
        } catch (e: Throwable) {
            Logs.w("subscription.fetch: cannot resolve the request identity", e)
            return failure(e.message ?: e.javaClass.simpleName, supported = true)
        }
        val result = SubscriptionFetch.fetch(url, name, identity)
        if (result.error != null) {
            return mapOf(
                SUPPORTED to true,
                "body" to "",
                "error" to result.error,
                "headers" to result.headers,
                "finalUrl" to result.finalUrl,
                "statusCode" to result.statusCode,
                "fileName" to "",
                "contentDisposition" to result.contentDisposition,
                "metadata" to metadataMap(result.subInfo),
            )
        }
        return mapOf(
            SUPPORTED to true,
            "body" to result.body,
            "error" to null,
            "headers" to result.headers,
            "finalUrl" to result.finalUrl,
            "statusCode" to result.statusCode,
            "fileName" to SubscriptionFileName.fromDisposition(result.contentDisposition),
            "contentDisposition" to result.contentDisposition,
            "metadata" to metadataMap(result.subInfo),
        )
    }

    private fun failure(reason: String, supported: Boolean): Map<String, Any?> = mapOf(
        SUPPORTED to supported,
        "body" to "",
        "error" to reason,
        "headers" to emptyMap<String, String>(),
        "finalUrl" to "",
        "statusCode" to 0,
        "fileName" to "",
        "contentDisposition" to "",
        "metadata" to metadataMap(null),
    )

    private fun metadataMap(info: io.nekohasekai.sagernet.database.SubUserInfo?): Map<String, Any?> = mapOf(
        "upload" to (info?.upload ?: 0L),
        "download" to (info?.download ?: 0L),
        "total" to (info?.total ?: 0L),
        "expire" to (info?.expire ?: 0L),
        "hasQuota" to (info?.hasQuota ?: false),
        "serverInterval" to (info?.serverInterval ?: 0),
        "title" to (info?.title ?: ""),
        "webUrl" to (info?.webUrl ?: ""),
        "supportUrl" to (info?.supportUrl ?: ""),
        "announce" to (info?.announce ?: ""),
        "valid" to (info?.valid ?: false),
    )
}
