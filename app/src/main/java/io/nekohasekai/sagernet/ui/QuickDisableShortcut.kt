/*******************************************************************************
 *                                                                             *
 *  Copyright (C) 2017 by Max Lv <max.c.lv@gmail.com>                          *
 *  Copyright (C) 2017 by Mygod Studio <[Email1]>  *
 *                                                                             *
 *  This program is free software: you can redistribute it and/or modify       *
 *  it under the terms of the GNU General Public License as published by       *
 *  the Free Software Foundation, either version 3 of the License, or          *
 *  (at your option) any later version.                                        *
 *                                                                             *
 *  This program is distributed in the hope that it will be useful,            *
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of             *
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the              *
 *  GNU General Public License for more details.                               *
 *                                                                             *
 *  You should have received a copy of the GNU General Public License          *
 *  along with this program. If not, see <http://www.gnu.org/licenses/>.       *
 *                                                                             *
 *******************************************************************************/

package io.nekohasekai.sagernet.ui

import android.app.Activity
import android.content.pm.ShortcutManager
import android.os.Build
import android.os.Bundle
import androidx.core.content.getSystemService
import io.nekohasekai.sagernet.SagerNet
import io.nekohasekai.sagernet.database.DataStore

class QuickDisableShortcut : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Same process as the service (P6): read the shared state directly, no AIDL bind.
        if (DataStore.serviceState.canStop) {
            SagerNet.stopService()
        }
        if (Build.VERSION.SDK_INT >= 25) {
            getSystemService<ShortcutManager>()!!.reportShortcutUsed("disable")
        }
        finish()
    }
}
