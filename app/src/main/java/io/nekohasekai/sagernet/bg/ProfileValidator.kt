package io.nekohasekai.sagernet.bg

import io.flrone.core.CoreHost
import io.nekohasekai.sagernet.bg.proto.TestConfigBuilder
import io.nekohasekai.sagernet.data.config.GeneratedConfig
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.ProfileManager
import io.nekohasekai.sagernet.database.ProxyEntity
import io.nekohasekai.sagernet.database.StoredProfile
import io.nekohasekai.sagernet.document.json.JsonInput
import io.nekohasekai.sagernet.document.json.JsonObject
import io.nekohasekai.sagernet.document.json.jsonObjectOf
import io.nekohasekai.sagernet.ktx.Logs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Configs::IsValid (generate.cpp:2425-2535) in the :bg process: the core's CheckConfig on the profile's own build.
 * A call that cannot reach the core (the library failed to load) is [Verdict.coreUnreachable], never a verdict.
 *
 * S8: the build itself is Go's `build_test_config` (the one config builder left), so the validator reads the row's
 * two contract columns instead of parsing it into the Kotlin outbound model. The builder answers the *test* config
 * of one candidate — the profile and its chain hops under `proxy-<id>`, an endpoint in `endpoints` — so the config
 * the core is asked to accept is the one the builder itself would hand it.
 */
object ProfileValidator {

    /** Parallel core calls on the phone (the desktop uses 10 threads). */
    private const val PARALLELISM = 4

    class Verdict(@JvmField val valid: Boolean, @JvmField val coreUnreachable: Boolean, @JvmField val message: String) {
        companion object {
            @JvmField
            val VALID = Verdict(true, false, "")

            fun invalid(message: String) = Verdict(false, false, message)
        }
    }

    /** The result of [findInvalid]: nothing may be removed while [coreUnreachable]. */
    class Scan(@JvmField val invalid: Set<Long>, @JvmField val coreUnreachable: Boolean)

    /**
     * The two host calls a verdict is made of. Production is [CoreHostCore]; JVM tests install a fake (the native
     * library and the documents the builder reads do not exist there). A *build* failure the builder reports is
     * part of [GeneratedConfig]; an exception here is a call that never reached the builder.
     */
    internal interface Core {
        fun buildTest(profileIds: List<Long>): GeneratedConfig
        fun checkConfig(config: String)
    }

    private object CoreHostCore : Core {
        override fun buildTest(profileIds: List<Long>): GeneratedConfig = TestConfigBuilder.buildTestOrThrow(profileIds)

        override fun checkConfig(config: String) {
            CoreHost.checkConfig(config)
        }
    }

    /** Not a `val`: tests put a fake in and restore this one. */
    @Volatile
    internal var core: Core = CoreHostCore

    /** The globals a verdict reads, taken once per scan: the settings document, not the outbound model. */
    private class Globals(
        val logLevel: String,
        val fragmentSettingsInvalid: Boolean,
        val fragmentDefaultOn: Boolean,
    )

    /** invalidProfiles (GroupUpdater.cpp:183-206): stops asking once the core is unreachable. */
    suspend fun findInvalid(profiles: List<ProxyEntity>): Scan {
        val invalid = ConcurrentHashMap.newKeySet<Long>()
        val unreachable = AtomicBoolean(false)
        if (profiles.isEmpty()) return Scan(invalid, false)
        val globals = globals()
        val next = AtomicInteger()
        coroutineScope {
            repeat(PARALLELISM) {
                launch(Dispatchers.IO) {
                    while (!unreachable.get()) {
                        val profile = profiles.getOrNull(next.getAndIncrement()) ?: break
                        val verdict = validate(profile, globals, HashSet())
                        if (verdict.coreUnreachable) unreachable.set(true)
                        else if (!verdict.valid) invalid.add(profile.id)
                    }
                }
            }
        }
        return Scan(invalid, unreachable.get())
    }

    /** One profile's verdict with the mounted settings document; the unit tests' entry ([findInvalid] runs it per profile). */
    internal fun verdict(profile: ProxyEntity): Verdict = validate(profile, globals(), HashSet())

    private fun globals(): Globals = Globals(
        logLevel = DataStore.logLevel,
        fragmentSettingsInvalid = fragmentSettingsError(),
        fragmentDefaultOn = DataStore.fragmentDefaultOn,
    )

    private fun validate(profile: ProxyEntity, globals: Globals, visiting: MutableSet<Long>): Verdict {
        val canonical = StoredProfile.canonicalType(profile.type)
        // Auto selectors are planned by the generator; desktop-only types cannot be judged by this core: both are kept.
        if (canonical == "autoselector") return Verdict.VALID
        if (StoredProfile.isInvalidDocument(profile.type, profile.outboundJson)) {
            if (!StoredProfile.isKnownType(profile.type)) return Verdict.VALID
            return invalid("Corrupted data in isValid: ${profile.displayName()}")
        }

        if (canonical == "chain") {
            if (!visiting.add(profile.id)) return invalid("Invalid ent in chain: ID=${profile.id}")
            for (hopId in StoredProfile.chainHops(profile.type, profile.outboundJson)) {
                val hop = ProfileManager.getProfile(hopId) ?: return invalid("Null ent in validator")
                val verdict = validate(hop, globals, visiting)
                if (verdict.coreUnreachable) return verdict
                if (!verdict.valid) return invalid("Invalid ent in chain: ID=$hopId")
            }
            visiting.remove(profile.id)
            return Verdict.VALID
        }

        val fullConfig = StoredProfile.fullConfigText(profile.type, profile.outboundJson)
        if (fullConfig != null) {
            val conf = runCatching { JsonInput.parseObject(fullConfig) }
                .getOrElse { return invalid("Invalid ent ${profile.displayName()}: ${it.message.orEmpty()}") }
            conf["log"] = jsonObjectOf("level" to globals.logLevel)
            return check(conf.toCompact()) { invalid("Invalid ent ${profile.displayName()}: $it") }
        }

        return when (val built = build(profile)) {
            is Build.Unreachable -> {
                Logs.w("Failed to Call the Core: ${built.message}")
                Verdict(false, true, built.message)
            }

            is Build.Failed -> {
                // A bad global fragment setting fails every fragmenting profile alike; "invalid" here would delete them all.
                if (globals.fragmentSettingsInvalid && fragments(profile, globals.fragmentDefaultOn)) {
                    Logs.i("Could not check ent ${profile.displayName()}: ${built.reason}")
                    return Verdict.VALID
                }
                invalid("Invalid ent ${profile.displayName()}: ${built.reason}")
            }

            is Build.Config -> check(built.config) { invalid("Invalid ent ${profile.displayName()}: $it") }
        }
    }

    /** One build, three answers: a config to check, a reason the row is invalid, or a call that never arrived. */
    private sealed class Build {
        class Config(val config: String) : Build()
        class Failed(val reason: String) : Build()
        class Unreachable(val message: String) : Build()
    }

    /** The builder's test config for [profile] alone, its spoken reason for skipping it, or the failed call. */
    private fun build(profile: ProxyEntity): Build {
        val generated = try {
            core.buildTest(listOf(profile.id))
        } catch (e: LinkageError) {
            return Build.Unreachable(e.message.orEmpty())
        } catch (e: Exception) {
            // The call never reached the builder (an unreadable document, an outdated core): not this row's fault.
            return Build.Unreachable(e.message.orEmpty())
        }
        generated.error?.let { return Build.Failed(it) }
        generated.skipped[profile.id]?.let { return Build.Failed(it) }
        // A single-id batch only answers the row's own full config (the pass-through path above handles the row itself).
        generated.fullConfigs[profile.id]?.let { return Build.Config(it) }
        if (generated.coreConfig.isEmpty()) return Build.Failed("build_test_config answered no config")
        return Build.Config(generated.coreConfig)
    }

    private inline fun check(config: String, onError: (String) -> Verdict): Verdict {
        try {
            core.checkConfig(config)
        } catch (e: LinkageError) {
            Logs.w("Failed to Call the Core: ${e.message}")
            return Verdict(false, true, e.message.orEmpty())
        } catch (e: Exception) {
            return onError(e.message.orEmpty())
        }
        return Verdict.VALID
    }

    private fun invalid(message: String): Verdict {
        Logs.i(message)
        return Verdict.invalid(message)
    }

    // ------------------------------------------------------------------------------------------------ global fragment

    /**
     * The types the Go builder emits the dialer-level fragment for (the `configApplyCustomFragment` callers): every
     * one of them dials TCP, so the fragment block is the first thing their build writes.
     */
    private val FRAGMENT_TYPES = setOf("http", "vmess", "vless", "trojan", "anytls", "shadowtls")

    /** sing-box common/dialer/fragment.go: chunks go through a 1024-byte buffer. */
    private const val FRAGMENT_MAX_CHUNK = 1019L

    /**
     * FragmentSettingsError (Outbound.cpp) as a yes/no over the settings document: whether the global custom
     * TLS-fragment size/sleep fails every fragmenting build. Only the verdict is needed; the failure text the
     * profile's build reports comes from the builder itself.
     */
    private fun fragmentSettingsError(): Boolean {
        if (DataStore.fragmentImplementation != "custom") return false
        val size = DataStore.fragmentSize.trim().ifEmpty { "10-100" }
        val sleep = DataStore.fragmentSleep.trim().ifEmpty { "2-5" }
        if (!fragmentSizeUsable(size)) return true
        return !fragmentSleepUsable(sleep)
    }

    /** tlsFragmentSize: `n` or `min-max` bytes within 0..1019, and a max of 0 never advances. */
    private fun fragmentSizeUsable(spec: String): Boolean {
        val max = rangeMax(spec, FRAGMENT_MAX_CHUNK) ?: return false
        return spec.isBlank() || max > 0
    }

    /** tlsFragmentSleep: `n` or `min-max`, both non-negative. */
    private fun fragmentSleepUsable(spec: String): Boolean = rangeMax(spec, Long.MAX_VALUE) != null

    /**
     * Validation.intOrRange (empty allowed, no reversed ranges) reduced to its bound: the larger number, or null
     * when the text is not `n` / `min-max` with both integers in 0..[maximum].
     */
    private fun rangeMax(text: String, maximum: Long): Long? {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return maximum
        val dash = trimmed.indexOf('-')
        val first = if (dash < 0) trimmed else trimmed.substring(0, dash)
        val second = if (dash < 0) trimmed else trimmed.substring(dash + 1)
        val values = LongArray(2)
        for ((index, part) in listOf(first, second).withIndex()) {
            if (!digits(part) || part.startsWith('-')) return null
            val value = part.toLongOrNull() ?: return null
            if (value < 0 || value > maximum) return null
            values[index] = value
        }
        return if (values[0] > values[1]) null else values[1]
    }

    /** Validation.signedDigits: an optional sign and at least one digit. */
    private fun digits(text: String): Boolean {
        val body = if (text.startsWith('+') || text.startsWith('-')) text.substring(1) else text
        return body.isNotEmpty() && body.all { it in '0'..'9' }
    }

    /**
     * OutboundChecks.customFragmentApplies from the stored document: the row's build emits the dialer-level TLS
     * fragment, so an unusable global fragment setting is exactly what its build fails on. The type set is the Go
     * builder's; the row's TLS block is on and fragmenting (an absent `fragment` is "keep default"), and a QUIC
     * transport dials no TCP.
     */
    private fun fragments(profile: ProxyEntity, fragmentDefaultOn: Boolean): Boolean {
        if (StoredProfile.canonicalType(profile.type) !in FRAGMENT_TYPES) return false
        val document = if (profile.outboundJson.isBlank()) null else JsonInput.parseObjectOrNull(profile.outboundJson)
        val tls = document?.obj("tls") ?: JsonObject()
        if (!tls.bool("enabled")) return false
        if (document?.obj("transport")?.string("type") == "quic") return false
        return if (tls.contains("fragment")) tls.bool("fragment") else fragmentDefaultOn
    }
}