package io.flrone.bridge

import java.security.SecureRandom

/**
 * "An open external controller always has a secret; a closed one drops it."
 *
 * The Clash API is the one setting in which an empty value is not a neutral default: the core
 * serves `experimental.clash_api` on the configured listen address, and with `secret: ""` every
 * client on that address (loopback or, with `allowLan`, the whole LAN) can read the tunnel's
 * connections and switch nodes without any credential. The settings screen lets the port be
 * toggled independently of the secret field, so both an "enabled with a blank secret" (an open
 * controller) and a "disabled with a stored secret" (a stale credential) state were reachable.
 *
 * [ensure] is the whole rule, pure and side-effect free:
 *
 *  - enabled and no secret stored  -> generate one and ask the caller to persist it;
 *  - enabled and a secret stored   -> keep it, never rotate;
 *  - disabled                      -> drop the stored secret.
 *
 * FlClash's `ensureControllerSecret` (`lib/models/clash_config.dart:2423-2428`) runs on every
 * open, so its controller secret is fresh per session and any external dashboard must re-read it
 * whenever the core restarts. This fork's secret is a persisted Throne setting
 * (`core_box_clash_api_secret`) that an external client keeps using, so the rule is applied on
 * the state transitions only — the toggle write, a blank secret write, a settings reset, the
 * config build and app start — and a second build keeps the first secret instead of rotating it
 * out from under a connected dashboard.
 *
 * Callers that hold the settings store use [apply]; the two fixed call sites are
 * `DataStore.ensureClashApiSecret` and the settings schema's controller keys.
 */
object ControllerSecret {

    /**
     * What the stored secret should be after the rule runs.
     *
     * [persist] is true exactly when [secret] differs from the text the caller passed — the write
     * the caller owes the store. A [secret] that is still blank means "no secret could be
     * produced" (a blank generator), never "an open controller": the config generator omits an
     * enabled controller without a secret, so that state fails closed.
     */
    data class Decision(val secret: String, val persist: Boolean) {
        /** An enabled controller may only be emitted when a secret is in force. */
        val available: Boolean get() = secret.isNotBlank()
    }

    /**
     * The rule over [current] (the stored text, null when there is no row).
     *
     * [generate] is injected for the tests; the default is [randomSecret]. A generator that
     * returns blank is not an error to throw on — the start path must not crash — it leaves the
     * controller unavailable, and [Decision.persist] still reports whether the stored text has to
     * be cleaned up (a whitespace-only secret is cleared).
     */
    fun ensure(enabled: Boolean, current: String?, generate: () -> String = ::randomSecret): Decision {
        val stored = current.orEmpty()
        if (!enabled) return Decision(secret = "", persist = stored.isNotEmpty())
        if (stored.isNotBlank()) return Decision(secret = stored, persist = false)
        val generated = generate()
        return if (generated.isNotBlank()) {
            Decision(secret = generated, persist = true)
        } else {
            Decision(secret = "", persist = stored.isNotEmpty())
        }
    }

    /**
     * [ensure] against the live store: reads [read], writes [write] only for a decision that
     * changes the stored text, and returns the secret now in force. Persisting is what makes a
     * second call idempotent — the generated secret is read back instead of regenerated.
     */
    fun apply(
        enabled: Boolean,
        read: () -> String?,
        write: (String) -> Unit,
        generate: () -> String = ::randomSecret,
    ): String {
        val decision = ensure(enabled, read(), generate)
        if (decision.persist) write(decision.secret)
        return decision.secret
    }

    private val secureRandom = SecureRandom()

    private const val HEX = "0123456789abcdef"

    /**
     * 32 hex characters from [SecureRandom] (128 bits). Hand-rolled rather than
     * `"%02x".format(...)`, which follows the default locale — the project has been bitten by
     * locale-dependent formatting before (`CrashStore` used `Locale.US` for the same reason).
     */
    fun randomSecret(): String {
        val bytes = ByteArray(16)
        secureRandom.nextBytes(bytes)
        return buildString(32) {
            for (byte in bytes) {
                val value = byte.toInt() and 0xff
                append(HEX[value ushr 4])
                append(HEX[value and 0x0f])
            }
        }
    }
}
