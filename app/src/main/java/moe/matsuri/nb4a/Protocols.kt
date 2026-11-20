package moe.matsuri.nb4a

import android.content.Context
import io.nekohasekai.sagernet.R
import io.nekohasekai.sagernet.ktx.getColorAttr

// Settings for all protocols
object Protocols {

    // Display

    @Suppress("UNUSED_PARAMETER")
    fun Context.getProtocolColor(type: String): Int {
        return getColorAttr(R.attr.accentOrTextSecondary)
    }

}
