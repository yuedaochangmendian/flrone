package io.flrone.bridge

import android.content.pm.PackageManager
import android.os.Build
import io.nekohasekai.sagernet.ktx.app
import io.nekohasekai.sagernet.utils.PackageCache
import java.io.ByteArrayInputStream
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.util.concurrent.ConcurrentHashMap

/**
 * Which installed apps belong to the mainland market — the access screen's smart selection.
 *
 * One tap should fill the per-app list with a sane default, the way Bettbox's 智能选择 does:
 * in "proxy selected apps" that means everything that is *not* a mainland app, in "bypass
 * selected apps" exactly the mainland ones. The user still edits the result.
 *
 * The rules are a port of Bettbox's `AppPlugin.isChinaPackage` (GPL-3, like this project) and
 * are deliberately simple:
 *
 *  1. [SKIP_PREFIXES] — foreign publishers whose names would otherwise match a rule below
 *     (a browser a Chinese OEM ships for the global market still goes through the tunnel).
 *  2. [PREFIXES] — publisher and app prefixes of the mainland market.
 *  3. The signing certificate's country (`C=CN` / `C=86`) when the package name says nothing,
 *     then the declared component names for wrapper apps.
 *
 * Steps 1–2 are pure and unit-tested; step 3 costs one package-manager query per app and is
 * cached per install (package name + last update time), so a repeat tap is instant.
 */
internal object ChinaAppRules {

    /** Foreign publishers, checked before the prefixes: these must never count as mainland. */
    val SKIP_PREFIXES: List<String> = listOf(
        "com.google", "com.android.chrome", "com.android.vending", "com.facebook",
        "com.instagram", "com.whatsapp", "com.twitter", "com.linkedin", "com.snapchat",
        "com.amazon", "com.microsoft", "com.apple", "com.dropbox", "com.mozilla",
        "com.brave", "com.duckduckgo", "com.vivaldi", "com.kiwibrowser", "com.opera",
        "org.torproject", "net.waterfox", "us.spotco", "app.grapheneos", "org.ironfoxoss",
        "org.thoughtcrime.securesms", "org.telegram", "ch.protonmail",
        "com.surfshark", "com.netflix", "com.spotify", "tv.twitch", "com.hulu",
        "com.disney", "com.hbo", "com.primevideo", "com.zhiliaoapp.musically",
        "com.nytimes", "bbc.mobile", "com.wsj", "com.bloomberg", "com.medium",
        "com.quora", "com.github", "io.github", "com.slack", "com.notion", "us.zoom",
        "com.discord", "com.reddit", "com.pinterest", "com.tumblr", "jp.naver.line",
        "com.skype", "com.box", "org.wikipedia", "com.gitlab", "com.openai",
        "com.valvesoftware", "com.roblox", "com.ea.gp", "com.ubisoft",
        "com.samsung.android.app.sbrowser", "com.mi.global.browser", "com.huawei.browser",
        "com.hihonor.browser", "com.heytap.browser", "com.coloros.browser", "com.oppo.browser",
        "com.vivo.browser", "com.bbk.browser", "com.meizu.browser", "com.meizu.mbrowser",
        "com.lenovo.browser", "com.zte.browser", "com.gionee.browser", "com.android.browser",
        "mark.via", "com.xbrowser.play", "com.quark.browser", "com.liebao", "com.mx.browser",
    )

    /** Mainland publishers and apps. Exact match or a `.<child>` of the prefix. */
    val PREFIXES: List<String> = listOf(
        "com.tencent", "com.qq", "com.alibaba", "com.ali", "com.alipay", "com.eg.android",
        "com.taobao", "com.tmall", "com.baidu", "com.iqiyi", "com.qiyi", "com.bytedance",
        "com.ss.android", "com.kuaishou", "com.smile.gifmaker", "com.xunmeng", "com.pinduoduo",
        "com.sankuai", "com.meituan", "com.dianping", "com.jingdong", "com.jd", "tv.danmaku",
        "com.sina", "com.weibo", "com.sohu", "com.netease", "com.zhihu", "com.xingin",
        "com.huawei", "com.hihonor", "com.xiaomi", "com.miui", "com.oppo", "com.coloros",
        "com.oplus", "andes.oplus", "com.heytap", "com.vivo", "com.bbk", "com.iqoo",
        "com.meizu", "com.flyme", "com.gionee", "cn.nubia", "com.zte", "com.lenovo",
        "com.oneplus", "com.qihoo", "com.qihoo360", "com.360", "com.ijinshan", "com.ijiami",
        "com.bangcle", "com.secneo", "com.kiwisec", "cn.securitystack", "com.mogosec",
        "com.secoen", "com.secshell", "com.umeng", "com.igexin", "cn.jpush", "cn.jiguang",
        "com.bugly", "com.mob", "cn.wps", "com.kingsoft", "com.xunlei", "com.unionpay",
        "com.cainiao", "com.sf", "com.sdu", "com.xiaojukeji", "com.autonavi", "com.amap",
        "com.chinamobile", "com.chinaunicom", "com.chinatelecom", "com.icbc", "com.ccb",
        "com.cmbchina", "com.achievo", "com.cubic.autohome", "com.gotokeep", "com.hunantv",
        "com.ximalaya", "com.youdao", "com.smartisan", "com.jifen", "com.kugou",
        "com.tencentmusic", "com.dingtalk", "com.taobao.idlefish", "cn.soulapp.android",
        "org.localsend.localsend_app", "app.eleven.com.fastfiletransfer",
    )

    /** Foreign publishers that must not be picked up by a prefix — checked first. */
    fun isSkipped(packageName: String): Boolean =
        SKIP_PREFIXES.any { packageName == it || packageName.startsWith("$it.") }

    /** The package-name half of the rule: skip list wins, then a prefix (exact or child). */
    fun matchesPackage(packageName: String): Boolean =
        !isSkipped(packageName) && matchesPrefix(packageName)

    /** A declared component class named after a mainland publisher (wrapper apps). */
    fun matchesComponent(componentName: String): Boolean = matchesPrefix(componentName)

    private fun matchesPrefix(name: String): Boolean =
        PREFIXES.any { name == it || name.startsWith("$it.") }
}

/** The Android half: one cached package-manager query per install. */
internal object ChinaApps {

    /** `package@lastUpdateTime` → verdict; a reinstall reclassifies instead of trusting the cache. */
    private val cache = ConcurrentHashMap<String, Boolean>()

    /** Every installed package the rules call mainland, from Throne's own package cache. */
    fun packages(): List<String> {
        val manager = app.packageManager ?: return emptyList()
        val installed = runCatching { PackageCache.snapshot().installedApps }.getOrDefault(emptyMap())
        val china = ArrayList<String>()
        for ((name, info) in installed) {
            val key = "$name@${info.lastUpdateTime}"
            val verdict = cache[key] ?: classify(manager, name).also { cache[key] = it }
            if (verdict) china += name
        }
        china.sort()
        return china
    }

    /** Pure name rules first; the expensive pass only for names the table does not answer. */
    private fun classify(manager: PackageManager, packageName: String): Boolean {
        if (ChinaAppRules.isSkipped(packageName)) return false
        if (ChinaAppRules.matchesPackage(packageName)) return true
        return deepMatch(manager, packageName)
    }

    /**
     * One query carries both remaining signals: the declared components (a wrapper app's
     * components are named after the publisher whose SDK it embeds) and the signer certificate
     * (a mainland publisher's certificate says `C=CN`).
     */
    private fun deepMatch(manager: PackageManager, packageName: String): Boolean = runCatching {
        val modern = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
        var flags = PackageManager.GET_ACTIVITIES or PackageManager.GET_SERVICES or
            PackageManager.GET_RECEIVERS or PackageManager.GET_PROVIDERS
        flags = flags or if (modern) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            @Suppress("DEPRECATION") PackageManager.GET_SIGNATURES
        }
        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            manager.getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(flags.toLong()))
        } else {
            @Suppress("DEPRECATION") manager.getPackageInfo(packageName, flags)
        }
        val components = buildList {
            info.activities?.forEach { add(it.name) }
            info.services?.forEach { add(it.name) }
            info.receivers?.forEach { add(it.name) }
            info.providers?.forEach { add(it.name) }
        }
        if (components.any(ChinaAppRules::matchesComponent)) return@runCatching true
        val signers = if (modern) {
            info.signingInfo?.apkContentsSigners.orEmpty()
        } else {
            @Suppress("DEPRECATION") info.signatures.orEmpty()
        }
        signers.any { signer ->
            val certificate = CertificateFactory.getInstance("X.509")
                .generateCertificate(ByteArrayInputStream(signer.toByteArray())) as? X509Certificate
            val dn = certificate?.subjectX500Principal?.name.orEmpty()
            dn.contains("C=CN", ignoreCase = true) || dn.contains("C=86", ignoreCase = true)
        }
    }.getOrDefault(false)
}
