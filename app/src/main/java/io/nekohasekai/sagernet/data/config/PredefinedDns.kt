package io.nekohasekai.sagernet.data.config

import io.nekohasekai.sagernet.document.link.Hosts

/** PredefinedDNSEntry (generate.h:72-76). */
internal class PredefinedDnsEntry(val domain: String) {
    val v4 = ArrayList<String>()
    val v6 = ArrayList<String>()
}

/** ParsePredefinedDNS (generate.cpp:2263-2295): hosts-file lines of an address followed by domains, `#` comments. */
internal object PredefinedDns {
    private val WHITESPACE = Regex("\\s+")

    /** Null when any non-empty line is malformed (the caller then emits no predefined rules at all, :934). */
    @JvmStatic
    fun parse(lines: List<String>): List<PredefinedDnsEntry>? {
        val out = ArrayList<PredefinedDnsEntry>()
        val indexOf = HashMap<String, Int>()
        for (rawLine in lines) {
            var line = rawLine
            val hash = line.indexOf('#')
            if (hash != -1) line = line.substring(0, hash)
            val fields = line.trim().split(WHITESPACE).filter { it.isNotEmpty() }
            if (fields.isEmpty()) continue
            if (fields.size < 2) return null
            val address = normalizeAddress(fields[0]) ?: return null
            for (i in 1 until fields.size) {
                var domain = fields[i].lowercase()
                while (domain.endsWith('.')) domain = domain.dropLast(1)
                if (domain.isEmpty()) return null
                val index = indexOf.getOrPut(domain) {
                    out.add(PredefinedDnsEntry(domain))
                    out.size - 1
                }
                val bucket = if (address.second) out[index].v6 else out[index].v4
                if (!bucket.contains(address.first)) bucket.add(address.first)
            }
        }
        return out
    }

    /** QHostAddress::setAddress + setScopeId({}) + toString: the normalised text and whether it is IPv6. */
    private fun normalizeAddress(text: String): Pair<String, Boolean>? {
        val bare = text.removePrefix("[").removeSuffix("]")
        val percent = bare.indexOf('%')
        val withoutZone = if (percent >= 0) bare.substring(0, percent) else bare
        if (withoutZone.contains(':')) {
            val v6 = Hosts.parseIpv6(withoutZone) ?: return null
            return Hosts.formatIpv6(v6) to true
        }
        val v4 = Hosts.parseIpv4(withoutZone) ?: return null
        return Hosts.formatIpv4(v4) to false
    }
}
