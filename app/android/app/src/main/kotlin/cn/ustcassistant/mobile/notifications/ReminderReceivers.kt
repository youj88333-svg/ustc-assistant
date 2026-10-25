package cn.ustcassistant.mobile.notifications

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/** A receiver does not construct Flutter, the business DB or any network client. */
class ReminderAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val identity = AndroidNotificationDriver.identity(intent, AndroidNotificationDriver.FIRE) ?: return
        val pending = goAsync()
        NotificationSerialization.worker.execute {
            try { AndroidReminderRuntime.manager(context).deliver(identity.first, identity.second, identity.third) }
            catch (_: Exception) { Log.w("UstcReminder", "delivery_failed") }
            finally { pending.finish() }
        }
    }
}

class ReminderRestoreReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action !in setOf(Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED,
                Intent.ACTION_TIME_CHANGED, Intent.ACTION_TIMEZONE_CHANGED, Intent.ACTION_USER_UNLOCKED,
                "android.app.action.SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED")) return
        val pending = goAsync()
        NotificationSerialization.worker.execute {
            try { AndroidReminderRuntime.manager(context).restore() }
            catch (_: Exception) { Log.w("UstcReminder", "restore_failed") }
            finally { pending.finish() }
        }
    }
}
