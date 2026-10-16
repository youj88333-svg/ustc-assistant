package cn.ustcassistant.mobile.qa

import android.content.Context
import android.content.ContextWrapper
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NotificationProbeTest {
    @Test
    fun rejectsEveryOperationOutsideTheQaApplicationIdentity() {
        val appContext = ApplicationProvider.getApplicationContext<Context>()
        val nonQaContext = object : ContextWrapper(appContext) {
            override fun getPackageName(): String = "cn.ustcassistant.mobile"
        }

        val results = listOf(
            NotificationProbe.capabilities(nonQaContext),
            NotificationProbe.schedule(nonQaContext),
            NotificationProbe.cancel(nonQaContext),
            NotificationProbe.report(nonQaContext),
            NotificationProbe.clear(nonQaContext),
        )
        results.forEach { result ->
            assertSafeResultShape(result)
            assertFalse(result.getBoolean("success"))
            assertEquals(NotificationProbe.FAILURE_WRONG_PACKAGE, result.getString("failure"))
        }
    }

    @Test
    fun reportsPermissionGatesAndPerformsRealScheduleCancelWhenAvailable() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        try {
            val capabilities = NotificationProbe.capabilities(context)
            assertSafeResultShape(capabilities)
            assertTrue(capabilities.getBoolean("success"))
            assertEquals(NotificationProbe.FAILURE_NONE, capabilities.getString("failure"))

            if (!capabilities.getBoolean("notificationsEnabled")) {
                val gated = NotificationProbe.schedule(context)
                assertSafeResultShape(gated)
                assertFalse(gated.getBoolean("success"))
                assertEquals(
                    NotificationProbe.FAILURE_NOTIFICATIONS_DISABLED,
                    gated.getString("failure"),
                )
                assertFalse(gated.getBoolean("scheduled"))
                return
            }

            val scheduled = NotificationProbe.schedule(context)
            assertSafeResultShape(scheduled)
            assertTrue(scheduled.getBoolean("success"))
            assertEquals(NotificationProbe.FAILURE_NONE, scheduled.getString("failure"))
            assertTrue(scheduled.getBoolean("scheduled"))
            assertEquals(
                capabilities.getBoolean("exactAlarmsAllowed"),
                scheduled.getBoolean("exactUsed"),
            )

            val report = NotificationProbe.report(context)
            assertSafeResultShape(report)
            assertTrue(report.getBoolean("success"))
            assertTrue(report.getBoolean("scheduled"))
            assertEquals(0, report.getInt("receiverCount"))
            assertFalse(report.getBoolean("notificationPosted"))

            val canceled = NotificationProbe.cancel(context)
            assertSafeResultShape(canceled)
            assertTrue(canceled.getBoolean("success"))
            assertFalse(canceled.getBoolean("scheduled"))
            assertFalse(canceled.getBoolean("notificationPosted"))
        } finally {
            val cleared = NotificationProbe.clear(context)
            assertSafeResultShape(cleared)
            assertTrue(cleared.getBoolean("success"))
            assertEquals(0, cleared.getInt("receiverCount"))
        }
    }

    private fun assertSafeResultShape(result: JSONObject) {
        val expectedKeys = setOf(
            "kind",
            "success",
            "failure",
            "notificationsEnabled",
            "exactAlarmsAllowed",
            "scheduled",
            "receiverCount",
            "notificationPosted",
            "exactUsed",
        )
        val actualKeys = result.keys().asSequence().toSet()
        assertEquals(expectedKeys, actualKeys)
        assertEquals(NotificationProbe.KIND, result.getString("kind"))
        assertTrue(
            result.getString("failure") in setOf(
                NotificationProbe.FAILURE_NONE,
                NotificationProbe.FAILURE_WRONG_PACKAGE,
                NotificationProbe.FAILURE_NOTIFICATIONS_DISABLED,
                NotificationProbe.FAILURE_ALARM_SERVICE_UNAVAILABLE,
                NotificationProbe.FAILURE_NOTIFICATION_SERVICE_UNAVAILABLE,
                NotificationProbe.FAILURE_SCHEDULE_FAILED,
                NotificationProbe.FAILURE_CANCEL_FAILED,
                NotificationProbe.FAILURE_CLEAR_FAILED,
                NotificationProbe.FAILURE_REPORT_FAILED,
            ),
        )
        assertTrue(result.get("notificationsEnabled") is Boolean)
        assertTrue(result.get("exactAlarmsAllowed") is Boolean)
        assertTrue(result.get("scheduled") is Boolean)
        assertTrue(result.get("notificationPosted") is Boolean)
        assertTrue(result.get("exactUsed") is Boolean)
        assertTrue(result.getInt("receiverCount") >= 0)
    }
}
