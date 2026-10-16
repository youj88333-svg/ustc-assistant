package cn.ustcassistant.mobile.qa

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class QaHostTest {
    @Test fun qaIdentityAndPrivateStorageAreExplicit() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        assertEquals("cn.ustcassistant.mobile.qa", context.packageName)
        assertFalse(context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_ALLOW_BACKUP != 0)
        val receiver = android.content.ComponentName(context, QaAlarmReceiver::class.java)
        @Suppress("DEPRECATION")
        val info = context.packageManager.getReceiverInfo(receiver, 0)
        assertFalse(info.exported)
    }
}
