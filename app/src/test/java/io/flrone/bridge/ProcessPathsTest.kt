package io.flrone.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The path->package parser is pure so these run on the JVM without an Android runtime. */
class ProcessPathsTest {

    @Test
    fun `modern data app path`() {
        assertEquals(
            "com.example.app",
            ProcessPaths.packageFromApkPath("/data/app/~~AbC123/com.example.app-XyZ9/base.apk"),
        )
    }

    @Test
    fun `legacy data app path without the hash directory`() {
        assertEquals(
            "org.example",
            ProcessPaths.packageFromApkPath("/data/app/org.example-1/base.apk"),
        )
    }

    @Test
    fun `system and product partitions`() {
        assertEquals("com.android.shell", ProcessPaths.packageFromApkPath("/system/app/com.android.shell/shell.apk"))
        assertEquals(
            "com.example.system",
            ProcessPaths.packageFromApkPath("/product/priv-app/com.example.system/app.apk"),
        )
        assertEquals("com.foo", ProcessPaths.packageFromApkPath("/vendor/app/com.foo/com.foo.apk"))
    }

    @Test
    fun `non app paths do not resolve`() {
        assertNull(ProcessPaths.packageFromApkPath(null))
        assertNull(ProcessPaths.packageFromApkPath(""))
        assertNull(ProcessPaths.packageFromApkPath("/system/bin/app_process"))
        assertNull(ProcessPaths.packageFromApkPath("/data/local/tmp/tool.so"))
        assertNull(ProcessPaths.packageFromApkPath("/data/data/com.example/files/x.apk"))
        assertNull(ProcessPaths.packageFromApkPath("/data/app/~~AbC/random-1/base.apk"))
    }

    @Test
    fun `a suffix is stripped only when present and the base must look like a package`() {
        assertEquals("com.a.b", ProcessPaths.packageFromApkPath("/data/app/com.a.b-2/base.apk"))
        // A single-label directory is not a Java package name.
        assertNull(ProcessPaths.packageFromApkPath("/data/app/tool-1/base.apk"))
    }
}
