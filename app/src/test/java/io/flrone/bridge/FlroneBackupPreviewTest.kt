package io.flrone.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The native `backup.open` preview used to build its `profiles` array with an
 * always-empty node-count map: every group showed "0 nodes" even when the staged
 * container carried hundreds. This pins the pure shaping helper against the
 * Dart-created envelope's shape (`name`, `type`, `url`, `nodes`) and the
 `groups_order` tab ordering.
 */
class FlroneBackupPreviewTest {

    private fun group(id: Long, name: String, url: String = "", order: Long = 0L) =
        FlroneBackup.GroupRow(id, name, url, order)

    @Test
    fun `nodes are counted from staged profile gids`() {
        val staged = FlroneBackup.StagedRows(
            groups = listOf(group(1L, "Local"), group(2L, "Sub", "https://example.com/sub")),
            gids = listOf(1L, 1L, 2L, 2L, 2L, 99L), // 99 is an orphan, ignored in the preview
        )

        val preview = FlroneBackup.groupPreview(staged)

        assertEquals(2, preview.size)
        assertEquals(
            mapOf<String, Any?>("name" to "Local", "type" to "local", "url" to "", "nodes" to 2L),
            preview[0],
        )
        assertEquals(
            mapOf<String, Any?>(
                "name" to "Sub", "type" to "subscription",
                "url" to "https://example.com/sub", "nodes" to 3L,
            ),
            preview[1],
        )
    }

    @Test
    fun `preview follows groups_order display order`() {
        val staged = FlroneBackup.StagedRows(
            groups = listOf(group(1L, "First in table", order = 5L), group(2L, "First in tabs", order = 1L)),
            gids = listOf(1L, 2L),
        )

        val preview = FlroneBackup.groupPreview(staged)

        assertEquals("First in tabs", preview[0]["name"])
        assertEquals("First in table", preview[1]["name"])
    }

    @Test
    fun `no groups means an empty preview`() {
        assertTrue(FlroneBackup.groupPreview(FlroneBackup.StagedRows(emptyList(), listOf(1L, 2L))).isEmpty())
    }
}
