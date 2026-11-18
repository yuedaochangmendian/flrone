package io.flrone.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * The kernel's test request, on the C-ABI host path.
 *
 * Same fields as the retired gobind `TestRequest`, but the lists are ordinary
 * Kotlin mutable lists and [toJson] is the wire shape `host_test.go` decodes.
 */
class CoreTestRequest {
    var coreConfig = ""
    var xrayConfig = ""
    var needXray = false
    var xrayOutboundDNSStrategy = ""
    var url = ""
    var maxConcurrency = 0
    var timeoutMs = 0
    var useDefaultOutbound = false
    var testCurrent = false

    var testDownload = false
    var testUpload = false
    var simpleDownload = false
    var simpleDownloadAddr = ""
    var onlyCountry = false
    var countryConcurrency = 0

    var ipProvider = ""
    var serviceChecks = ""
    var skipIPInfo = false

    val outboundTags = mutableListOf<String>()
    val vpnEndpointTags = mutableListOf<String>()
    val xrayFullConfigs = mutableListOf<String>()

    fun addOutboundTag(tag: String) {
        outboundTags.add(tag)
    }

    fun addVPNEndpointTag(tag: String) {
        vpnEndpointTags.add(tag)
    }

    fun addXrayFullConfig(config: String) {
        xrayFullConfigs.add(config)
    }

    fun toJson(): JSONObject = JSONObject()
        .put("coreConfig", coreConfig)
        .put("xrayConfig", xrayConfig)
        .put("needXray", needXray)
        .put("xrayOutboundDNSStrategy", xrayOutboundDNSStrategy)
        .put("url", url)
        .put("maxConcurrency", maxConcurrency)
        .put("timeoutMs", timeoutMs)
        .put("useDefaultOutbound", useDefaultOutbound)
        .put("testCurrent", testCurrent)
        .put("testDownload", testDownload)
        .put("testUpload", testUpload)
        .put("simpleDownload", simpleDownload)
        .put("simpleDownloadAddr", simpleDownloadAddr)
        .put("onlyCountry", onlyCountry)
        .put("countryConcurrency", countryConcurrency)
        .put("ipProvider", ipProvider)
        .put("serviceChecks", serviceChecks)
        .put("skipIPInfo", skipIPInfo)
        .put("outboundTags", JSONArray(outboundTags))
        .put("vpnEndpointTags", JSONArray(vpnEndpointTags))
        .put("xrayFullConfigs", JSONArray(xrayFullConfigs))
}
