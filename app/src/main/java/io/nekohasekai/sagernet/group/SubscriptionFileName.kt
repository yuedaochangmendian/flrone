package io.nekohasekai.sagernet.group

import java.net.URLDecoder

/**
 * The subscription name a panel puts in `Content-Disposition`
 * (FlClash's `getFileNameForDisposition`, common/request.dart:233-253).
 *
 * The RFC 5987 `filename*` form wins over the plain `filename`; both are only
 * a name for the card, never a path, so any directory part is stripped. The
 * value is percent-decoded as UTF-8; `+` is kept literal because RFC 5987 uses
 * percent escapes, not form encoding.
 */
internal object SubscriptionFileName {

    private val STAR = Regex("""(?i)(?:^|;)\s*filename\*\s*=\s*([^;]*)""")
    private val PLAIN = Regex("""(?i)(?:^|;)\s*filename\s*=\s*([^;]*)""")

    fun fromDisposition(header: String?): String {
        if (header.isNullOrBlank()) return ""
        val extended = STAR.find(header)?.groupValues?.get(1)?.trim()
        if (!extended.isNullOrEmpty()) {
            val decoded = decodeExtended(extended)
            if (decoded.isNotEmpty()) return clean(decoded)
        }
        val plain = PLAIN.find(header)?.groupValues?.get(1)?.trim() ?: return ""
        return clean(plain)
    }

    /** `UTF-8''name` or a bare `name`; an unknown charset still decodes as UTF-8. */
    private fun decodeExtended(value: String): String {
        val trimmed = value.trim().trim('"')
        val parts = trimmed.split('\'', limit = 3)
        val encoded = if (parts.size == 3) parts[2] else trimmed
        return try {
            URLDecoder.decode(encoded.replace("+", "%2B"), "UTF-8")
        } catch (_: Exception) {
            ""
        }
    }

    private fun clean(value: String): String = value
        .trim()
        .trim('"')
        .trim()
        .substringAfterLast('/')
        .substringAfterLast('\\')
        .trim()
}
