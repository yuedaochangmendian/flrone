package io.nekohasekai.sagernet.database

import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.ktx.app
import io.nekohasekai.sagernet.ktx.fetchText
import io.nekohasekai.sagernet.ktx.readableMessage
import io.nekohasekai.sagernet.document.json.JsonArray
import io.nekohasekai.sagernet.document.json.JsonInput
import io.nekohasekai.sagernet.document.json.JsonObject
import io.nekohasekai.sagernet.route.RuleSetCatalog
import io.nekohasekai.sagernet.route.RuleSets
import io.nekohasekai.sagernet.route.UrlSafety
import java.io.File
import java.io.IOException
import java.util.TreeSet

/**
 * The snapshot of https://github.com/throneproj/routeprofiles: `srslist.h` from the rule-set branch and the files
 * of the profile branch. CI bundles one into the assets (`routeprofiles/`); [refresh] keeps a newer copy in
 * `filesDir/routeprofiles/`, which wins over the bundle file by file.
 */
object RouteRepo {
    const val SRS_LIST = "srslist.h"
    private const val DIR = "routeprofiles"
    private const val PROFILE_DIR = "profile"
    private const val REPO = "https://raw.githubusercontent.com/throneproj/routeprofiles"
    private const val PROFILE_URL_PREFIX = "$REPO/profile/"
    private const val SRS_LIST_URL = "$REPO/rule-set/$SRS_LIST"
    private const val LISTING_URL = "https://api.github.com/repos/throneproj/routeprofiles/contents/?ref=profile"

    private val PROFILE_URL = Regex("^(?i:https?://raw\\.githubusercontent\\.com/throneproj/routeprofiles)/profile/([^/?#]+)$")

    private val cacheDir: File get() = File(app.filesDir, DIR)

    internal fun srsListFile(): File = File(cacheDir, SRS_LIST)

    /** A bundled snapshot file (`assets/routeprofiles/<path>`), null when the build has none. */
    internal fun readAsset(path: String): String? = try {
        app.assets.open("$DIR/$path").bufferedReader().use { it.readText() }
    } catch (e: IOException) {
        null
    }

    /**
     * Makes the bundled `srslist.h` visible at [srsListFile] before the first [refresh].
     *
     * The pure-Dart rule-set picker reads only the runtime copy (ADR 0005 phase 3); a fresh
     * install that never ran a remote-profile update therefore listed nothing, although the APK
     * bundles the snapshot. [RouteManager.catalog]'s in-memory asset fallback never wrote the
     * file the Dart side reads. Returns whether the file was written.
     */
    fun ensureCatalog(): Boolean = try {
        RuleSetCatalog.seedIfMissing(srsListFile(), readAsset(SRS_LIST))
    } catch (e: Exception) {
        Logs.w("routeprofiles: cannot seed $SRS_LIST", e)
        false
    }

    /** The snapshot's content for a `raw.githubusercontent.com/throneproj/routeprofiles/profile/<file>` URL. */
    fun snapshot(url: String): String? {
        val file = PROFILE_URL.matchEntire(url.trim())?.groupValues?.get(1) ?: return null
        return profileFile(file)
    }

    /**
     * Downloads srslist.h and every profile-branch file through the rule-set mirror into the runtime copy. The
     * branch is listed through the GitHub API, or taken from the snapshot's file names when the API is unreachable.
     * Returns the errors, one per line, or null.
     */
    fun refresh(): String? {
        val mirror = DataStore.rulesetMirror
        val errors = ArrayList<String>()
        try {
            // Every URL here goes through the shared fence: the mirror setting rewrites the host,
            // and a profile-branch file name reaches this loop from the network listing.
            val target = UrlSafety.requirePublicFetch(RuleSets.mirrorLink(SRS_LIST_URL, mirror))
            val text = fetchText(target).body
            if (RuleSetCatalog.parseSrsList(text).size == 0) {
                errors.add("$SRS_LIST: no rule-sets in the download")
            } else {
                writeAtomically(srsListFile(), text)
            }
        } catch (e: Exception) {
            errors.add("$SRS_LIST: ${e.readableMessage}")
        }
        val names = try {
            listProfileBranch()
        } catch (e: Exception) {
            Logs.w("routeprofiles listing: ${e.readableMessage}")
            null
        } ?: profileFileNames()
        val profileDir = File(cacheDir, PROFILE_DIR)
        for (name in names) {
            try {
                val url = UrlSafety.requirePublicFetch(RuleSets.mirrorLink(PROFILE_URL_PREFIX + name, mirror))
                writeAtomically(File(profileDir, name), fetchText(url).body)
            } catch (e: Exception) {
                errors.add("$name: ${e.readableMessage}")
            }
        }
        RouteManager.invalidateCatalog()
        return errors.takeIf { it.isNotEmpty() }?.joinToString("\n")
    }

    private fun listProfileBranch(): List<String>? {
        val target = UrlSafety.requirePublicFetch(LISTING_URL)
        val listing = JsonInput.parseValue(fetchText(target).body) as? JsonArray ?: return null
        val names = listing.mapNotNull { item ->
            val entry = item as? JsonObject ?: return@mapNotNull null
            entry.string("name").takeIf { entry.string("type") == "file" && isPlainFileName(it) }
        }
        return names.takeIf { it.isNotEmpty() }
    }

    private fun profileFile(name: String): String? {
        if (!isPlainFileName(name)) return null
        val file = File(File(cacheDir, PROFILE_DIR), name)
        if (file.isFile) {
            try {
                return file.readText()
            } catch (e: IOException) {
                Logs.w(e)
            }
        }
        return readAsset("$PROFILE_DIR/$name")
    }

    private fun profileFileNames(): Set<String> {
        val names = TreeSet<String>()
        File(cacheDir, PROFILE_DIR).list()?.let { names.addAll(it) }
        try {
            app.assets.list("$DIR/$PROFILE_DIR")?.let { names.addAll(it) }
        } catch (e: IOException) {
            Logs.w(e)
        }
        return names.filterTo(TreeSet()) { isPlainFileName(it) && !it.endsWith(".tmp") }
    }

    private fun isPlainFileName(name: String): Boolean =
        name.isNotEmpty() && name != "." && name != ".." && name.none { it == '/' || it == '\\' }

    private fun writeAtomically(file: File, text: String) {
        file.parentFile?.mkdirs()
        val tmp = File(file.parentFile, file.name + ".tmp")
        tmp.writeText(text)
        // renameTo replaces the target atomically on POSIX but fails when it already exists on Windows; fall back to a
        // direct write there so seeding a refreshed snapshot works on every platform (Android keeps the atomic path).
        if (!tmp.renameTo(file)) {
            tmp.delete()
            file.writeText(text)
        }
    }
}
