package io.flrone.bridge

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The name half of the access screen's mainland classifier: the skip list runs before the
 * prefixes, and a prefix only owns its own children (`com.tencent` matches `com.tencent.mm`,
 * never `com.tencentx`). The certificate/component pass is Android-side and cached per install;
 * these rules are what every tap decides with, so they are pinned here.
 */
class ChinaAppRulesTest {

    @Test
    fun `a publisher prefix owns exactly its own children`() {
        assertTrue(ChinaAppRules.matchesPackage("com.tencent.mm"))
        assertTrue(ChinaAppRules.matchesPackage("com.tencent"))
        assertTrue(ChinaAppRules.matchesPackage("tv.danmaku.bili"))
        // A dot boundary, not a string prefix: `com.miui` must not claim `com.microsoft…`.
        assertFalse(ChinaAppRules.matchesPackage("com.microsoft.office"))
        assertFalse(ChinaAppRules.matchesPackage("com.tencentx.app"))
        assertFalse(ChinaAppRules.matchesPackage("org.example.app"))
    }

    @Test
    fun `the skip list wins over a publisher prefix`() {
        // Chinese OEMs ship global-market apps under the same publisher prefix.
        assertFalse(ChinaAppRules.matchesPackage("com.huawei.browser"))
        assertFalse(ChinaAppRules.matchesPackage("com.mi.global.browser"))
        assertFalse(ChinaAppRules.matchesPackage("com.google.android.youtube"))
        // …while the same vendor's domestic apps stay classified.
        assertTrue(ChinaAppRules.matchesPackage("com.huawei.hwid"))
        assertTrue(ChinaAppRules.matchesPackage("com.miui.securitycenter"))
    }

    @Test
    fun `declared components are matched by the same prefixes`() {
        // A wrapper app whose own package says nothing, but whose components name a mainland SDK.
        assertTrue(ChinaAppRules.matchesComponent("com.tencent.smtt.WebView"))
        assertTrue(ChinaAppRules.matchesComponent("com.alipay.sdk.app.PayTask"))
        assertFalse(ChinaAppRules.matchesComponent("org.example.Sdk"))
    }
}
