package io.nekohasekai.sagernet.database

import android.os.Parcelable
import androidx.annotation.ColorInt
import kotlinx.parcelize.Parcelize

/**
 * One stored profile: the desktop's `profiles` row (ProfilesRepo.cpp:17-43) — [type] and [outboundJson] (the
 * compact key-sorted ExportToJson that is the data contract), [name] (a copy of the outbound's name), the test
 * results and the traffic — plus the Android-only [userOrder] (the dense 0..n-1 position in the group, the desktop's
 * `profiles_json` index) and [testError]. Every derived label, address, security and dedup fact is read from those two
 * contract columns through [StoredProfile]; the parsed outbound model is gone (S8).
 */
@Parcelize
data class ProxyEntity(
    var id: Long = 0L,
    var type: String = "",
    var name: String? = null,
    var groupId: Long = 0L,
    var userOrder: Long = 0L,
    /** 0 untested, > 0 ms, -1 failed, [LATENCY_CONNECT_ONLY]; write it through [recordLatency]. */
    var latency: Int = 0,
    /** Epoch seconds of the latency measurement, 0 = never. */
    var latencyAt: Long = 0L,
    /** The core's rate strings ("12.34Mbps"), "N/A" after a failed speed test. */
    var dlSpeed: String? = null,
    var ulSpeed: String? = null,
    /** ISO country code of the egress. */
    var testCountry: String? = null,
    var ipOut: String? = null,
    var outboundJson: String = "",
    /** Downloaded bytes (`traffic_dl`). */
    var rx: Long = 0L,
    /** Uploaded bytes (`traffic_up`). */
    var tx: Long = 0L,
    /** The last test's error text; Android-only, never exported. */
    var testError: String? = null,
) : Parcelable {

    /**
     * The lowercase display name, type and address on separate lines, what the profile search matches.
     * S8: derived from the stored columns through [StoredProfile].
     */
    fun searchText(): String {
        val displayType = StoredProfile.displayType(type, outboundJson)
        return (StoredProfile.displayName(name, type, outboundJson) + "\n" + displayType + "\n" +
            StoredProfile.displayAddress(type, outboundJson)).lowercase()
    }

    fun displayName(): String = StoredProfile.displayName(name, type, outboundJson)

    fun displayAddress(): String = StoredProfile.displayAddress(type, outboundJson)

    fun displayType(): String = StoredProfile.displayType(type, outboundJson)

    fun isChain(): Boolean = type == "chain"

    /** isVpnProfile (TestRunner.cpp:41-43): an OpenVPN or OpenConnect endpoint, whose tunnel can be up while a probe fails. */
    fun isVpnProfile(): Boolean = type == "openvpn" || type == "openconnect"

    /** The desktop's duplicate key (Profile.cpp:87-90): the JSON link without the tag. */
    fun dedupKey(): String = StoredProfile.dedupKey(type, outboundJson)

    // ------------------------------------------------------------------------------------------------ test results

    /** Profile.h:64; untested profiles are neither working nor unavailable. */
    fun isWorking(): Boolean = ProxyEntity.isWorking(latency)

    fun isUnavailable(): Boolean = ProxyEntity.isUnavailable(latency)

    /** Profile::SetLatency: stamps [latencyAt], a 0 reset clears it. */
    fun recordLatency(ms: Int) {
        latency = ms
        latencyAt = if (ms == 0) 0L else System.currentTimeMillis() / 1000
    }

    fun hasTestResults(): Boolean = latency != 0 || testCountry != null || ipOut != null || dlSpeed != null ||
        ulSpeed != null || testError != null

    /** Profile::ClearTestResults, plus the Android-only error text. */
    fun clearTestResults() {
        testCountry = null
        ipOut = null
        latency = 0
        latencyAt = 0L
        dlSpeed = null
        ulSpeed = null
        testError = null
    }

    /**
     * TestRunner::applyUrlResult (TestRunner.cpp:127-142): a result is [latencyMs]; an aborted test leaves the
     * profile untested; a failed VPN profile whose tunnel is up ([connectOnly]) is [LATENCY_CONNECT_ONLY], a working
     * result that keeps no error (the desktop logs none for it); else -1.
     */
    fun applyUrlResult(latencyMs: Int, error: String, connectOnly: Boolean = false) {
        when {
            error.isEmpty() -> {
                recordLatency(latencyMs)
                testError = null
            }

            isTestAborted(error) -> {
                recordLatency(0)
                testError = null
            }

            connectOnly -> {
                recordLatency(LATENCY_CONNECT_ONLY)
                testError = null
            }

            else -> {
                recordLatency(-1)
                testError = error
            }
        }
    }

    /** TestRunner::applyIpResult (TestRunner.cpp:144-157): an error clears the egress IP and country. */
    fun applyIpResult(ip: String, country: String, error: String) {
        if (error.isEmpty()) {
            ipOut = ip
            testCountry = country
            testError = null
        } else {
            ipOut = null
            testCountry = null
            testError = if (isTestAborted(error)) null else error
        }
    }

    /**
     * The speed-test result of TestRunner.cpp:614-648: the core's rate strings, the ping only for a profile without
     * a latency, [country] (ISO code) when known; an error is "N/A", latency -1 and no country.
     */
    fun applySpeedResult(dl: String, ul: String, latencyMs: Int, country: String, error: String) {
        if (error.isEmpty()) {
            dlSpeed = dl
            ulSpeed = ul
            if (latency <= 0 && latencyMs > 0) recordLatency(latencyMs)
            if (country.isNotEmpty()) testCountry = country
            testError = null
        } else {
            dlSpeed = SPEED_NA
            ulSpeed = SPEED_NA
            recordLatency(-1)
            testCountry = null
            testError = error
        }
    }

    /** Profile::DisplayLatencyColor; 0 = no colour (untested). */
    @ColorInt
    fun latencyColor(): Int = when {
        latency == LATENCY_CONNECT_ONLY -> COLOR_CONNECT_ONLY
        latency < 0 -> COLOR_FAILED
        latency == 0 -> 0
        latency <= 100 -> COLOR_FAST
        latency <= 300 -> COLOR_MEDIUM
        else -> COLOR_SLOW
    }

    companion object {
        const val TABLE = "profiles"

        /** kLatencyConnectOnly (Profile.h:37): the egress probe failed but the VPN tunnel is up. */
        const val LATENCY_CONNECT_ONLY = -2

        /** The rate text of a failed speed test. */
        const val SPEED_NA = "N/A"

        @ColorInt private const val COLOR_CONNECT_ONLY = 0xFF00ACC1.toInt()
        @ColorInt private const val COLOR_FAILED = 0xFF9E9E9E.toInt()
        @ColorInt private const val COLOR_FAST = 0xFF43A047.toInt()
        @ColorInt private const val COLOR_MEDIUM = 0xFFF9A825.toInt()
        @ColorInt private const val COLOR_SLOW = 0xFFE53935.toInt()

        /** Profile::IsWorking for a latency code: a measured latency or a connect-only tunnel. */
        @JvmStatic
        fun isWorking(latency: Int): Boolean = latency > 0 || latency == LATENCY_CONNECT_ONLY

        /** Profile::IsUnavailable for a latency code: a failed test; connect-only counts as working. */
        @JvmStatic
        fun isUnavailable(latency: Int): Boolean = latency < 0 && latency != LATENCY_CONNECT_ONLY

        /** TestRunner.cpp:37-39. */
        @JvmStatic
        fun isTestAborted(error: String): Boolean =
            error.contains("test aborted") || error.contains("context canceled")

        /** CountryCodeToFlag: each letter shifted to its regional indicator symbol. */
        @JvmStatic
        fun countryFlag(code: String): String {
            val sb = StringBuilder()
            code.uppercase().forEach { c -> sb.appendCodePoint(c.code + 0x1F1A5) }
            return sb.toString()
        }
    }

}

/** A profile row without its data: list order, names and types. */
data class ProfileName(
    val id: Long,
    val groupId: Long,
    val type: String,
    val name: String?,
)

/** A profile's stored position in its group. */
data class ProfilePosition(
    val id: Long,
    val userOrder: Long,
)
