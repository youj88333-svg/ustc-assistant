package cn.ustcassistant.mobile.notifications

import android.app.Activity
import android.app.NotificationManager
import android.app.Notification
import android.os.Bundle
import org.json.JSONObject
import java.io.File

/** Debug-only fixed synthetic operations for the isolated emulator, not a
 * product API. It never opens school sessions or a business database. */
class ReminderOsProbeActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (packageName != "cn.ustcassistant.mobile.qa") { finish(); return }
        val command = intent.getStringExtra("operation")
        val run = intent.getStringExtra("run")?.takeIf { it.matches(Regex("[0-9a-f]{32}")) } ?: run { finish(); return }
        NotificationSerialization.worker.execute {
            val result = JSONObject().put("kind", "android-a5-os-reminder-v1").put("run", run)
            try {
                val core = AndroidReminderRuntime.manager(this)
                when (command) {
                    "schedule", "schedule-reboot" -> {
                        core.initialize(); core.clear()
                        val request = NativeRequest(RequestIdentity("a5-os-probe", System.currentTimeMillis() + if (command == "schedule-reboot") 120_000 else 20_000,
                            "a".repeat(64), "b".repeat(32)), "A5 合成提醒", "退出后系统投递验证", "QA-ONLY")
                        core.bind(PublicationAuthority("a5-os-probe", 1, 1, System.currentTimeMillis(), true), listOf(request.identity))
                        core.schedule(request)
                    }
                    "cancel" -> core.cancel("a5-os-probe")
                    "block" -> core.block()
                    "restore" -> core.restore()
                    "initialize" -> core.initialize()
                    "clear" -> core.clear()
                    "report" -> Unit
                    "click-a7-event", "click-a7-task" -> {
                        // Fixed synthetic titles only. A shell UI driver uses
                        // this ordinary Activity because am instrument would
                        // force-stop the target and cancel the tested alarms.
                        val title = if (command == "click-a7-event") "A7合成日程定位" else "A7合成任务定位"
                        val matches = getSystemService(NotificationManager::class.java).activeNotifications.filter {
                            it.tag?.startsWith(AndroidNotificationDriver.TAG_PREFIX) == true &&
                                it.notification.extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString() == title
                        }
                        if (matches.size != 1) throw NotificationFailure("qa_notification_absent")
                        (matches.single().notification.contentIntent ?: throw NotificationFailure("qa_notification_absent")).send()
                        result.put("a7Click", if (command == "click-a7-event") "event" else "task")
                    }
                    else -> throw NotificationFailure("invalid_input")
                }
                val mirror = NotificationLedger.forApplication(this).read()
                val active = getSystemService(NotificationManager::class.java).activeNotifications
                    .count { it.tag == AndroidNotificationDriver.TAG_PREFIX + "a5-os-probe" }
                result.put("success", true).put("blocked", mirror.blocked).put("entries", mirror.entries.size)
                    .put("pending", mirror.entries.values.count { it.state == DeliveryState.pending && it.registered })
                    .put("delivered", mirror.entries.values.count { it.state == DeliveryState.delivered })
                    .put("active", active).put("exact", AndroidNotificationDriver(this).exactAllowed())
                    .put("notifications", AndroidNotificationDriver(this).notificationsAllowed())
                    .put("entryExact", mirror.entries["a5-os-probe"]?.exact ?: false)
            } catch (error: Exception) {
                result.put("success", false).put("failure", (error as? NotificationFailure)?.code ?: "platform_unavailable")
            }
            File(filesDir, "a5-os-reminder-report.json").writeText(result.toString(), Charsets.UTF_8)
            runOnUiThread { finish() }
        }
    }
}
