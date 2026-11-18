// The platform-wide Android duties. Registered once through Core.setPlatform and
// reached by the kernel through the single platform_request callback; the only
// other callbacks are the tun-scoped protect/resolverProcess and release_object.
package io.flrone.core

interface CorePlatform {
    /**
     * The single JSON duty facade. [method] names the duty and [payloadJson] is
     * its JSON payload; the answer is JSON (or "" when the duty has no answer).
     *
     * Methods: open_tun, use_platform_auto_detect_interface_control, use_proc_fs,
     * find_connection_owner, package_names_by_uid, start/close_default_interface_monitor,
     * get_interfaces, read_wifi_state, clear_dns_cache, send/cancel_notification,
     * dns_raw/dns_lookup/dns_exchange, log.
     */
    fun platformRequest(method: String, payloadJson: String): String
}
