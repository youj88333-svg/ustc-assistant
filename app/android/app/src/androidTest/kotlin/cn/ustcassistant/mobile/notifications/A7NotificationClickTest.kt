package cn.ustcassistant.mobile.notifications

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationManager
import android.graphics.Bitmap
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * A7 end-to-end click check. The root A7 runner creates the synthetic C3 target,
 * waits for its real AlarmManager notification, then invokes this single case.
 * Ordinary instrumentation runs skip unless a supported target kind is passed.
 */
@RunWith(AndroidJUnit4::class)
class A7NotificationClickTest {
    @Test
    fun realNotificationClickOpensTheMatchingSyntheticTarget() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val arguments = InstrumentationRegistry.getArguments()
        val kind = arguments.getString(ARG_KIND)
        assumeTrue("Run only from the A7 synthetic notification harness", kind in TARGETS)
        val target = TARGETS.getValue(kind!!)
        val context = instrumentation.targetContext
        assertEquals(QA_PACKAGE, context.packageName)

        val resultFile = File(context.filesDir, "a7-notification-click-$kind.json")
        val screenshotFile = File(context.cacheDir, "a7-click-$kind.png")
        writeSafeResult(resultFile, kind, success = false)

        var success = false
        try {
            val manager = context.getSystemService(NotificationManager::class.java)
            val notification = waitForUniqueNotification(manager, target.title)
            val contentIntent = notification.contentIntent
            assertNotNull("The matching reminder has no content intent", contentIntent)

            val automation = instrumentation.uiAutomation
            val serviceInfo = automation.serviceInfo
            val originalFlags = serviceInfo.flags
            serviceInfo.flags = originalFlags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
            automation.serviceInfo = serviceInfo
            try {
                // Exercise the actual notification PendingIntent/MainActivity path.
                contentIntent!!.send()
                assertTrue(
                    "The notification did not open the matching QA MainActivity target",
                    waitForTarget(automation, context, target),
                )
                saveScreenshot(automation, screenshotFile)
                success = true
            } finally {
                serviceInfo.flags = originalFlags
                automation.serviceInfo = serviceInfo
            }
        } finally {
            writeSafeResult(resultFile, kind, success)
        }
    }

    private fun waitForUniqueNotification(
        manager: NotificationManager,
        title: String,
    ): Notification {
        val deadline = SystemClock.uptimeMillis() + NOTIFICATION_TIMEOUT_MS
        while (SystemClock.uptimeMillis() < deadline) {
            // Only the notification title is inspected; no other notification
            // payload, token, body, or app data is read or recorded.
            val matches = manager.activeNotifications.filter { active ->
                active.notification.extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString() == title
            }
            if (matches.size > 1) {
                throw AssertionError("Expected one A7 reminder with the fixed synthetic title")
            }
            if (matches.size == 1) return matches.single().notification
            SystemClock.sleep(POLL_INTERVAL_MS)
        }
        throw AssertionError("The fixed A7 reminder notification did not appear")
    }

    private fun waitForTarget(
        automation: android.app.UiAutomation,
        context: android.content.Context,
        target: ClickTarget,
    ): Boolean {
        val deadline = SystemClock.uptimeMillis() + UI_TIMEOUT_MS
        while (SystemClock.uptimeMillis() < deadline) {
            val activeWindowText = activeQaApplicationWindowText(automation, context.packageName)
            if (isMainActivityTop(context) && activeWindowText != null &&
                activeWindowText.any { it.contains(target.title) } &&
                activeWindowText.any { it.contains(target.sectionLabel) }) {
                return true
            }
            SystemClock.sleep(POLL_INTERVAL_MS)
        }
        return false
    }

    private fun activeQaApplicationWindowText(
        automation: android.app.UiAutomation,
        expectedPackage: String,
    ): Set<String>? {
        val windows = automation.windows
        for (window in windows) {
            try {
                if (!window.isActive || window.type != AccessibilityWindowInfo.TYPE_APPLICATION) continue
                val root = window.root ?: continue
                try {
                    // Refuse to treat notification shade, test UI, or another
                    // package's window as evidence of successful routing.
                    if (root.packageName?.toString() != expectedPackage) return null
                    return collectVisibleText(root)
                } finally {
                    root.recycle()
                }
            } finally {
                window.recycle()
            }
        }
        return null
    }

    private fun collectVisibleText(root: AccessibilityNodeInfo): Set<String> {
        val result = linkedSetOf<String>()
        collectVisibleText(root, result)
        return result
    }

    private fun collectVisibleText(node: AccessibilityNodeInfo, result: MutableSet<String>) {
        node.text?.toString()?.trim()?.takeIf(String::isNotEmpty)?.let(result::add)
        node.contentDescription?.toString()?.trim()?.takeIf(String::isNotEmpty)?.let(result::add)
        for (index in 0 until node.childCount) {
            val child = node.getChild(index) ?: continue
            try {
                collectVisibleText(child, result)
            } finally {
                child.recycle()
            }
        }
    }

    private fun isMainActivityTop(context: android.content.Context): Boolean {
        val activityManager = context.getSystemService(ActivityManager::class.java)
        return activityManager.appTasks.any { task ->
            val top = task.taskInfo.topActivity
            top != null && top.packageName == context.packageName && top.className == MAIN_ACTIVITY
        }
    }

    private fun saveScreenshot(automation: android.app.UiAutomation, file: File) {
        val screenshot = automation.takeScreenshot()
            ?: throw AssertionError("Could not capture the QA target screen")
        try {
            val saved = file.outputStream().use { output ->
                screenshot.compress(Bitmap.CompressFormat.PNG, 100, output)
            }
            assertTrue("Could not save the QA target screenshot", saved)
        } finally {
            screenshot.recycle()
        }
    }

    private fun writeSafeResult(file: File, kind: String, success: Boolean) {
        file.writeText(
            JSONObject()
                .put("kind", kind)
                .put("success", success)
                .toString(),
        )
    }

    private data class ClickTarget(val title: String, val sectionLabel: String)

    companion object {
        private const val ARG_KIND = "a7ClickKind"
        private const val QA_PACKAGE = "cn.ustcassistant.mobile.qa"
        private const val MAIN_ACTIVITY = "cn.ustcassistant.mobile.MainActivity"
        private const val NOTIFICATION_TIMEOUT_MS = 45_000L
        private const val UI_TIMEOUT_MS = 45_000L
        private const val POLL_INTERVAL_MS = 250L
        private val TARGETS = mapOf(
            "event" to ClickTarget("A7合成日程定位", "日程详情"),
            "task" to ClickTarget("A7合成任务定位", "设置截止提醒"),
        )
    }
}
