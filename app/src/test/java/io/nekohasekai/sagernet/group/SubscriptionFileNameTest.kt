package io.nekohasekai.sagernet.group

import org.junit.Assert.assertEquals
import org.junit.Test

/** The name a panel puts in Content-Disposition (FlClash's getFileNameForDisposition). */
class SubscriptionFileNameTest {

    @Test
    fun `an RFC 5987 filename wins and is decoded as UTF-8`() {
        assertEquals(
            "My Panel.yaml",
            SubscriptionFileName.fromDisposition("attachment; filename*=UTF-8''My%20Panel.yaml"),
        )
        assertEquals(
            "中文.yaml",
            SubscriptionFileName.fromDisposition("attachment; filename*=utf-8''%E4%B8%AD%E6%96%87.yaml"),
        )
    }

    @Test
    fun `a plain quoted filename is accepted`() {
        assertEquals(
            "config.yaml",
            SubscriptionFileName.fromDisposition("attachment; filename=\"config.yaml\""),
        )
        assertEquals(
            "config.yaml",
            SubscriptionFileName.fromDisposition("attachment; filename=config.yaml"),
        )
    }

    @Test
    fun `a plus stays literal in the extended form`() {
        assertEquals(
            "a+b.yaml",
            SubscriptionFileName.fromDisposition("attachment; filename*=UTF-8''a+b.yaml"),
        )
    }

    @Test
    fun `a directory part is stripped`() {
        assertEquals(
            "name.yaml",
            SubscriptionFileName.fromDisposition("attachment; filename=C:\\profiles\\name.yaml"),
        )
        assertEquals(
            "name.yaml",
            SubscriptionFileName.fromDisposition("attachment; filename=\"/tmp/name.yaml\""),
        )
    }

    @Test
    fun `an absent or empty header has no name`() {
        assertEquals("", SubscriptionFileName.fromDisposition(null))
        assertEquals("", SubscriptionFileName.fromDisposition(""))
        assertEquals("", SubscriptionFileName.fromDisposition("inline"))
        assertEquals("", SubscriptionFileName.fromDisposition("attachment; filename=\"\""))
    }
}
