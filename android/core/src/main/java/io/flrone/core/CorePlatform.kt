// The platform-wide Android duties. Registered once through Core.setPlatform and
// reached by the kernel via throne_callbacks_t. Object-shaped answers cross as
// JSON so the callback table stays primitive/string-shaped.
package io.flrone.core

interface CorePlatform {
    /**
     * The kernel needs the VPN while the core starts: build VpnService.Builder
     * from [optionsHandle] (Core.tunSpecJson), establish, feed the fd back with
     * Core.startTun(fd, tun) and answer the fd; -1 on failure.
     */
    fun openTun(optionsHandle: Long): Int

    fun usePlatformAutoDetectInterfaceControl(): Boolean

    fun useProcFS(): Boolean

    /** JSON {userId,userName,processPath,packageNames[]} or "" on failure. */
    fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int,
    ): String

    /** JSON string array. */
    fun packageNamesByUid(uid: Int): String

    /**
     * Start reporting default-interface changes; report them back through
     * Core.updateDefaultInterface with [listener].
     * Returns an error string or "".
     */
    fun startDefaultInterfaceMonitor(listener: Long): String

    fun closeDefaultInterfaceMonitor(listener: Long): String

    /** JSON array of {index,mtu,name,addresses[],flags,type,dnsServer[],gateway[],metered}. */
    fun getInterfaces(): String

    /** JSON {ssid,bssid} or "". */
    fun readWifiState(): String

    fun clearDnsCache()

    /** Error string or "". */
    fun sendNotification(notificationJson: String): String

    fun cancelNotification(identifier: String, typeId: Int): String

    fun localDnsRaw(): Boolean

    /** Error string or "". */
    fun localDnsLookup(ctx: Long, network: String, domain: String): String

    /** Error string or "". */
    fun localDnsExchange(ctx: Long, message: ByteArray): String

    /**
     * ADR 0004 P2: the single JSON duty facade the typed slots converge onto.
     * [method] names the duty, [payloadJson] is its JSON payload; returns a JSON
     * answer (or "" on failure). Migrated so far: use_proc_fs,
     * package_names_by_uid, clear_dns_cache. The typed methods above stay
     * registered until their own migration lands.
     */
    fun platformRequest(method: String, payloadJson: String): String
}
