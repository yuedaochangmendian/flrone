package io.flrone.flutter

import android.content.Intent
import com.google.zxing.Result
import com.king.camera.scan.AnalyzeResult
import com.king.camera.scan.CameraScan
import com.king.zxing.BarcodeCameraScanActivity
import io.flrone.bridge.FlroneScanChunks

/**
 * The QR scan screen, hosted by Throne instead of by a Flutter plugin.
 *
 * ZXingLite's [BarcodeCameraScanActivity] owns the CameraX preview, the viewfinder and ZXing's
 * decoder. This subclass only decides when the payload is complete and hands it back to
 * [FlroneActivity]; the analyzer keeps running until [CameraScan.setAnalyzeImage] is turned
 * off, so a QR too large for one symbol can arrive as several frames. [FlroneScanChunks] is the same
 * assembler the old frame-by-frame Dart path fed, so multi-frame imports keep their behaviour.
 */
class FlroneQrScanActivity : BarcodeCameraScanActivity() {

    private val chunks = FlroneScanChunks()

    override fun onScanResultCallback(result: AnalyzeResult<Result>) {
        val text = result.result?.text.orEmpty()
        if (text.isEmpty()) return
        val decision = chunks.accept(SESSION, text)
        if (decision.complete && decision.text.isNotEmpty()) {
            cameraScan.setAnalyzeImage(false)
            setResult(RESULT_OK, Intent().putExtra(CameraScan.SCAN_RESULT, decision.text))
            finish()
        }
    }

    private companion object {
        const val SESSION = "qr-scan"
    }
}
