package io.nekohasekai.sagernet.bg

import androidx.core.app.NotificationCompat
import io.flrone.core.CoreHost
import io.nekohasekai.sagernet.R
import io.nekohasekai.sagernet.SagerNet
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.ktx.app
import io.nekohasekai.sagernet.ktx.readableMessage
import java.io.File

/**
 * The core's performance capture (core/mobile/diagnostics.go): the core profiles the process it runs in, which is this
 * one. Keeps the service in the foreground for the window, so the capture survives the app going to the background
 * while the user reproduces a problem. Offered as an in-process facade; call it off the main thread.
 */
object CoreDiagnostics {

    private const val FOREGROUND_REASON = "diagnostics"

    /** Blocks the binder thread for the window; returns "" or the error. */
    fun capture(
        durationMs: Int,
        contention: Boolean,
        trace: Boolean,
        attachmentPaths: Array<String>,
        outputPath: String,
    ): String = try {
        CoreForeground.acquire(FOREGROUND_REASON, notification())
        try {
            CoreHost.captureDiagnostics(
                durationMs = durationMs,
                contention = contention,
                trace = trace,
                attachmentPaths = attachmentPaths.filter { File(it).isFile },
                outputPath = outputPath,
            )
        } finally {
            CoreForeground.release(FOREGROUND_REASON)
        }
        ""
    } catch (e: Throwable) {
        Logs.w(e)
        e.readableMessage
    }

    fun stop() = CoreHost.stopDiagnostics()

    private fun notification() = NotificationCompat.Builder(app, CoreForeground.CHANNEL)
        .setSmallIcon(R.drawable.ic_throne_tile)
        .setContentTitle(app.getString(R.string.app_name))
        .setContentText(app.getString(R.string.diagnostics_notification))
        .setProgress(0, 0, true)
        .setOngoing(true)
        .setSilent(true)
        .setShowWhen(false)
        .setCategory(NotificationCompat.CATEGORY_PROGRESS)
        .setContentIntent(SagerNet.configureIntent(app))
        .build()
}
