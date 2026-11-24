package io.nekohasekai.sagernet.bg

import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.ProfileManager
import io.nekohasekai.sagernet.database.ProxyEntity
import io.nekohasekai.sagernet.database.SettingsMapper
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.outbound.BuildContext
import io.nekohasekai.sagernet.outbound.OutboundChecks
import io.flrone.core.CoreHost
import io.nekohasekai.sagernet.outbound.OutboundFactory
import io.nekohasekai.sagernet.outbound.json.JsonArray
import io.nekohasekai.sagernet.outbound.json.JsonInput
import io.nekohasekai.sagernet.outbound.json.jsonObjectOf
import io.nekohasekai.sagernet.outbound.types.Chain
import io.nekohasekai.sagernet.outbound.types.Custom
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Configs::IsValid (generate.cpp:2425-2535) in the :bg process: the core's CheckConfig on the profile's own build.
 * A call that cannot reach the core (the library failed to load) is [Verdict.coreUnreachable], never a verdict.
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

    fun validate(profile: ProxyEntity): Verdict = validate(profile, SettingsMapper.buildContext(), DataStore.logLevel, HashSet())

    /** invalidProfiles (GroupUpdater.cpp:183-206): stops asking once the core is unreachable. */
    suspend fun findInvalid(profiles: List<ProxyEntity>): Scan {
        val invalid = ConcurrentHashMap.newKeySet<Long>()
        val unreachable = AtomicBoolean(false)
        if (profiles.isEmpty()) return Scan(invalid, false)
        val ctx = SettingsMapper.buildContext()
        val logLevel = DataStore.logLevel
        val next = AtomicInteger()
        coroutineScope {
            repeat(PARALLELISM) {
                launch(Dispatchers.IO) {
                    while (!unreachable.get()) {
                        val profile = profiles.getOrNull(next.getAndIncrement()) ?: break
                        val verdict = validate(profile, ctx, logLevel, HashSet())
                        if (verdict.coreUnreachable) unreachable.set(true)
                        else if (!verdict.valid) invalid.add(profile.id)
                    }
                }
            }
        }
        return Scan(invalid, unreachable.get())
    }

    private fun validate(profile: ProxyEntity, ctx: BuildContext, logLevel: String, visiting: MutableSet<Long>): Verdict {
        val outbound = profile.outbound
        // Auto selectors are planned by the generator; desktop-only types cannot be judged by this core: both are kept.
        if (profile.type == "autoselector") return Verdict.VALID
        if (outbound.invalid) {
            val canonical = OutboundFactory.canonicalType(profile.type)
            if (canonical !in OutboundFactory.ALL_TYPES || canonical in OutboundFactory.UNSUPPORTED_TYPES) return Verdict.VALID
            return invalid("Corrupted data in isValid: ${profile.displayName()}")
        }

        if (outbound is Chain) {
            if (!visiting.add(profile.id)) return invalid("Invalid ent in chain: ID=${profile.id}")
            for (hopId in outbound.list) {
                val hop = ProfileManager.getProfile(hopId) ?: return invalid("Null ent in validator")
                val verdict = validate(hop, ctx, logLevel, visiting)
                if (verdict.coreUnreachable) return verdict
                if (!verdict.valid) return invalid("Invalid ent in chain: ID=$hopId")
            }
            visiting.remove(profile.id)
            return Verdict.VALID
        }

        var fullConfig = false
        var conf = jsonObjectOf()
        if (outbound is Custom && outbound.subtype == Custom.CUSTOM_FULL_CONFIG) {
            conf = JsonInput.parseObject(outbound.config)
            fullConfig = true
        }
        if (!fullConfig) {
            val built = outbound.buildChecked(ctx)
            if (!built.ok) {
                // A bad global fragment setting fails every fragmenting profile alike; "invalid" here would delete them all.
                if (built.error == OutboundChecks.fragmentSettingsError(ctx)) {
                    Logs.i("Could not check ent ${outbound.name}: ${built.error}")
                    return Verdict.VALID
                }
                return invalid("Invalid ent ${outbound.name}: ${built.error}")
            }
            conf = jsonObjectOf((if (outbound.isEndpoint()) "endpoints" else "outbounds") to JsonArray.of(built.json))
        }
        conf["log"] = jsonObjectOf("level" to logLevel)
        return check(conf.toCompact()) { error -> invalid("Invalid ent ${outbound.name}: $error") }
    }

    private inline fun check(config: String, onError: (String) -> Verdict): Verdict {
        try {
            CoreHost.checkConfig(config)
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
}
