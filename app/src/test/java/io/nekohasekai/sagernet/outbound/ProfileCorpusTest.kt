package io.nekohasekai.sagernet.outbound

import io.nekohasekai.sagernet.outbound.import.LegacyXray
import io.nekohasekai.sagernet.outbound.json.JsonArray
import io.nekohasekai.sagernet.outbound.json.JsonInput
import io.nekohasekai.sagernet.outbound.json.JsonObject
import io.nekohasekai.sagernet.outbound.json.jsonObjectOf
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.Locale

/**
 * Kotlin oracle for the S5 stored-form export/import/validate corpus.
 *
 * Each fixture lives under `app/src/test/resources/profile-corpus/<case>/` with:
 *  - `input.txt`    the raw input (a stored JSON document, a share link, a template type, ...)
 *  - `case.json`    the case descriptor (mode, source, format, context, formats, expectError, include)
 *  - `expected.json` produced **only** by this test in update mode, never hand-written. It
 *                    carries `generatedBy`, a SHA-256 of the canonical payload, and the payload
 *                    itself. A normal run re-derives the payload and fails on any byte drift;
 *                    an update run (`-DprofileCorpusUpdate=true` or Gradle property
 *                    `-PprofileCorpusUpdate=true`) rewrites `expected.json`.
 *
 * The payload is a small, language-neutral envelope over the exact strings the JVM oracle
 * produces. Byte-exact fields are the stored compact JSON (`json`), identity, dedup/link, name,
 * displayType and type. `flags` are semantic booleans/enums that survive a Go codec that may
 * differ in non-contract strings. Localized validation/import messages are deliberately out of
 * scope: `vtr()` reads Android string resources through [io.nekohasekai.sagernet.ktx.app], which
 * a plain JVM test has no Context for, so a case that would render one is omitted rather than
 * pinning a machine-specific fallback. See the report in the task hand-off for the deferred
 * categories.
 *
 * Modes:
 *  - `export`        JsonInput parse -> OutboundFactory.fromJson -> exportToJson/exportToLink/
 *                    exportJsonLink/exportIdentity (and the stripped dedup key).
 *  - `import`        OutboundFactory.parseLink of one share link -> the same exports.
 *  - `validate`      Outbound.parseFromJson + structural `validate` issue shape (field names,
 *                    severities) with message text omitted; the oracle only accepts documents
 *                    whose validate path does not need an Android resource.
 *  - `newOutbound`   OutboundFactory.newByType of a type string -> the blank stored document.
 *  - `migrate`       LegacyXray.migrateStored of one stored row -> the converted exports, or the
 *                    refusal reason (a plain source string, not a localized message).
 */
class ProfileCorpusTest {

    @Test
    fun `profile corpus fixtures match the kotlin oracle byte for byte`() {
        val root = fixtureRoot()
        val cases = root.listFiles { file -> file.isDirectory }?.sortedBy { it.name }.orEmpty()
        assertTrue("no profile-corpus fixtures under ${root.absolutePath}", cases.isNotEmpty())

        val update = System.getProperty(UPDATE_PROPERTY) == "true"
        val failures = ArrayList<String>()
        var produced = 0
        for (caseDir in cases) {
            val caseName = caseDir.name
            try {
                val inputFile = File(caseDir, INPUT)
                assertTrue("$caseName: input.txt is missing", inputFile.isFile)
                val metaFile = File(caseDir, CASE)
                assertTrue("$caseName: case.json is missing", metaFile.isFile)
                val input = inputFile.readText(StandardCharsets.UTF_8)
                val meta = JSONObject(metaFile.readText(StandardCharsets.UTF_8))
                val mode = meta.optString("mode")
                assertTrue("$caseName: unknown or missing mode '$mode'", mode in MODES)
                if (!meta.optBoolean("include", true)) {
                    // An explicitly excluded case is a placeholder; it has no expected.json and
                    // neither harness compares it. Document why in case.json's `source`/`format`.
                    continue
                }
                val expectError = meta.optBoolean("expectError", false)
                val payload = try {
                    val produced = generate(mode, input, meta)
                    if (expectError) {
                        failures.add("$caseName: expectError=true but the oracle produced a normal result")
                        continue
                    }
                    produced
                } catch (error: Throwable) {
                    if (!expectError) throw error
                    // A malformed/null case: the oracle refused the input. Pin only the
                    // structural fact of refusal; the exception text is JVM-specific and
                    // is not part of the cross-language contract.
                    jsonObjectOf(
                        "error" to true,
                        "mode" to mode,
                        "expectError" to true,
                    )
                }
                val envelope = expectedDocument(payload)
                val actualFile = File(outputRoot(), caseName).apply { mkdirs() }.let { File(it, ACTUAL) }
                actualFile.writeText(envelope, StandardCharsets.UTF_8)
                produced++

                if (update) {
                    File(caseDir, EXPECTED).writeText(envelope, StandardCharsets.UTF_8)
                    println("profile-corpus: wrote expected.json for $caseName")
                    continue
                }

                val expectedFile = File(caseDir, EXPECTED)
                if (!expectedFile.isFile) {
                    failures.add("$caseName: expected.json is missing; run with -DprofileCorpusUpdate=true")
                    continue
                }
                val expected = expectedFile.readText(StandardCharsets.UTF_8)
                if (expected != envelope) {
                    failures.add("$caseName: ${describeFirstDifference(expected, envelope)}")
                }
            } catch (error: Throwable) {
                failures.add("$caseName: oracle threw ${error::class.java.simpleName}: ${error.message}\n${error.stackTraceToString()}")
            }
        }
        assertTrue("no included profile-corpus cases under ${root.absolutePath}", produced > 0 || update)
        if (failures.isNotEmpty()) fail(failures.joinToString("\n\n"))
    }

    /** Runs the JVM oracle for one case and returns the canonical payload JsonObject. */
    private fun generate(mode: String, input: String, meta: JSONObject): JsonObject {
        val context = meta.optString("context")
        // Keep the oracle honest: a context that asks for localized resources cannot be frozen.
        assertTrue("context '$context' requires Android resources (unavailable in a JVM test)",
            context.isEmpty() || context == "default")
        return when (mode) {
            "export" -> exportCase(JsonInput.parseObject(input), meta)
            "import" -> importCase(input, meta)
            "validate" -> validateCase(input, meta)
            "newOutbound" -> newOutboundCase(input)
            "migrate" -> migrateCase(input)
            else -> error("unsupported mode $mode")
        }
    }

    /** One outbound, all four export surfaces. `stripMetadata` is the dedup key. */
    private fun exports(outbound: Outbound, meta: JSONObject): JsonObject {
        val json = outbound.exportToJson()
        val payload = jsonObjectOf(
            "type" to outbound.type,
            "name" to outbound.name,
            "invalid" to outbound.invalid,
            "displayType" to outbound.displayType(),
            "format" to meta.optString("format"),
            "json" to json.toCompact(),
            "identity" to outbound.exportIdentity().toCompact(),
            "exportJsonLink" to outbound.exportJsonLink(),
            "dedupKey" to outbound.exportJsonLink(stripMetadata = true),
        )
        val link = outbound.exportToLink()
        // A type with no link form (direct) exports an empty string; keep the key for the Go side.
        payload["link"] = link
        val formats = meta.optJSONArray("formats")
        if (formats != null) {
            val arr = JsonArray()
            for (i in 0 until formats.length()) arr.add(formats.optString(i))
            payload["formats"] = arr
        }
        return payload
    }

    private fun exportCase(document: JsonObject, meta: JSONObject): JsonObject {
        val outbound = OutboundFactory.fromJson(document)
            ?: error("document did not parse through OutboundFactory.fromJson")
        return exports(outbound, meta)
    }

    private fun importCase(link: String, meta: JSONObject): JsonObject {
        val outbound = OutboundFactory.parseLink(link)
            ?: error("link did not parse through OutboundFactory.parseLink")
        return exports(outbound, meta)
    }

    /**
     * Structural validation result. Message text is omitted (it comes from Android string
     * resources); only field/severity/value shape is frozen. A case whose validation path needs
     * a resource throws here instead of producing a fallback and is dropped from the corpus.
     */
    private fun validateCase(document: String, meta: JSONObject): JsonObject {
        val obj = JsonInput.parseObject(document)
        val outbound = OutboundFactory.fromJson(obj) ?: error("document did not parse")
        val issues = ArrayList<io.nekohasekai.sagernet.validation.Issue>()
        // Only the base validate is called: it is resource-free when every present value is
        // acceptable or empty (emptyMessage(Empty.Allowed) returns ""), which is what the
        // frozen cases exercise. A failing rule would call vtr() and abort this method.
        outbound.validate(issues, BuildContext.DEFAULT)
        val shape = JsonArray()
        for (value in issues) {
            shape.add(jsonObjectOf(
                "field" to value.field,
                "severity" to value.severity.name,
                // value is a user-visible datum, never a password or key; still drop the
                // localized message itself, which is the whole point of the corpus split.
                "value" to value.value,
            ))
        }
        return jsonObjectOf(
            "ok" to shape.isEmpty(),
            "type" to outbound.type,
            "issues" to shape,
            "expectError" to meta.optBoolean("expectError", false),
        )
    }

    private fun newOutboundCase(type: String): JsonObject {
        val outbound = OutboundFactory.newByType(type.trim())
        // newByType never throws: unsupported/not-yet-ported types answer an
        // InvalidOutbound. Signal that as the structural error the Go side expects.
        if (outbound.invalid) error("newByType(${type.trim()}) produced an invalid outbound")
        return jsonObjectOf(
            "type" to outbound.type,
            "invalid" to outbound.invalid,
            "json" to outbound.exportToJson().toCompact(),
            "identity" to outbound.exportIdentity().toCompact(),
            "exportJsonLink" to outbound.exportJsonLink(),
            "dedupKey" to outbound.exportJsonLink(stripMetadata = true),
            "link" to outbound.exportToLink(),
        )
    }

    /** A legacy Xray row migration; refusal text is a plain source string, not a resource. */
    private fun migrateCase(document: String): JsonObject {
        val stored = JsonInput.parseObject(document)
        val type = stored.string("storedType")
        val outbound = LegacyXray.migrateStored(type, stored)
            ?: return jsonObjectOf("migrated" to false)
        val payload = exports(outbound, JSONObject().put("format", "stored"))
        payload["migrated"] = true
        return payload
    }

    /** The frozen envelope: version + generator stamp + SHA-256 of the canonical payload. */
    private fun expectedDocument(payload: JsonObject): String {
        val canonical = payload.toCompact()
        return buildString {
            append("{\n")
            append("  \"version\": 1,\n")
            append("  \"generatedBy\": \"").append(GENERATED_BY).append("\",\n")
            append("  \"sha256\": \"").append(sha256(canonical)).append("\",\n")
            append("  \"payload\": ").append(canonical).append('\n')
            append("}\n")
        }
    }

    /**
     * Source fixtures root. The classpath copy under app/build/intermediates is read-only
     * build output; writes (update mode / the Python checker) must target the source tree.
     * A Gradle test worker runs from the app module, so the relative default is enough.
     */
    private fun fixtureRoot(): File {
        val explicit = System.getProperty(FIXTURE_PROPERTY)?.takeIf { it.isNotBlank() }
        val root = if (explicit != null) File(explicit) else File("src/test/resources/profile-corpus")
        assertTrue("profile-corpus fixtures not found at ${root.absolutePath}", root.isDirectory)
        return root
    }

    /** Gradle's test worker runs from the app module; the default keeps actuals under app/build. */
    private fun outputRoot(): File =
        System.getProperty(OUTPUT_PROPERTY)?.takeIf { it.isNotBlank() }?.let(::File)
            ?: File("build/profile-corpus")

    private fun describeFirstDifference(expected: String, actual: String): String {
        val left = expected.toByteArray(StandardCharsets.UTF_8)
        val right = actual.toByteArray(StandardCharsets.UTF_8)
        val shared = minOf(left.size, right.size)
        var offset = 0
        while (offset < shared && left[offset] == right[offset]) offset++
        fun context(bytes: ByteArray) = String(
            bytes,
            maxOf(0, offset - 32),
            minOf(bytes.size, offset + 32) - maxOf(0, offset - 32),
            StandardCharsets.UTF_8,
        ).replace("\n", "\\n")
        return "expected.json differs at byte offset $offset " +
            "(expected ${left.size} bytes, actual ${right.size} bytes)\n" +
            "  expected[..]: ${context(left)}\n" +
            "  actual[..]:   ${context(right)}"
    }

    companion object {
        const val UPDATE_PROPERTY = "profileCorpusUpdate"
        const val FIXTURE_PROPERTY = "profile.corpus.fixtures"
        const val OUTPUT_PROPERTY = "profile.corpus.outputDir"
        const val GENERATED_BY = "ProfileCorpusTest"
        const val INPUT = "input.txt"
        const val CASE = "case.json"
        const val EXPECTED = "expected.json"
        const val ACTUAL = "actual.json"
        val MODES = setOf("import", "export", "validate", "newOutbound", "migrate")

        fun sha256(text: String): String =
            MessageDigest.getInstance("SHA-256").digest(text.toByteArray(StandardCharsets.UTF_8))
                .joinToString("") { String.format(Locale.ROOT, "%02x", it) }
    }
}
