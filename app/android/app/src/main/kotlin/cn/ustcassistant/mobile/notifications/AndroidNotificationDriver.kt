package cn.ustcassistant.mobile.notifications

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import cn.ustcassistant.mobile.MainActivity
import cn.ustcassistant.mobile.R

internal class AndroidNotificationDriver(private val context: Context) : NotificationDriver {
    companion object {
        const val CHANNEL = "ustc_reminders_v1"
        const val TAG_PREFIX = "ustc_reminder_v1/"
        const val CLICK = "cn.ustcassistant.mobile.NOTIFICATION_OPEN_V1"
        const val FIRE = "cn.ustcassistant.mobile.NOTIFICATION_FIRE_V1"

        fun identity(intent: Intent?, action: String): Triple<String, String, Long>? = try {
            if (intent?.action != action) null else {
                val uri = intent.data
                val parts = uri?.pathSegments
                if (uri?.scheme != "ustc-reminder" || uri.host != "v1" || parts?.size != 3 ||
                    uri.query != null || uri.fragment != null) null else {
                    Triple(opaque(parts[0], 1, 16), opaque(parts[2], 32, 32),
                        integer(parts[1].toLongOrNull()))
                }
            }
        } catch (_: Exception) { null }
    }

    private val manager get() = context.getSystemService(NotificationManager::class.java)
    private val alarms get() = context.getSystemService(AlarmManager::class.java)
    override fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "日程与任务提醒", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "按本机日程和任务的提醒设置通知"
                lockscreenVisibility = android.app.Notification.VISIBILITY_PRIVATE
            })
        }
    }
    override fun notificationsAllowed(): Boolean = manager.areNotificationsEnabled() &&
        (Build.VERSION.SDK_INT < 33 || context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) &&
        (Build.VERSION.SDK_INT < 26 || manager.getNotificationChannel(CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE)
    override fun exactAllowed(): Boolean = Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms()

    private fun uri(entry: NativeEntry) = Uri.Builder().scheme("ustc-reminder").authority("v1")
        .appendPath(entry.request.identity.id).appendPath(entry.generation.toString()).appendPath(entry.nonce).build()
    private fun alarm(entry: NativeEntry): PendingIntent = PendingIntent.getBroadcast(context, 0,
        Intent(context, ReminderAlarmReceiver::class.java).setAction(FIRE).setData(uri(entry)),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    override fun schedule(entry: NativeEntry, exact: Boolean) {
        val pending = alarm(entry)
        if (exact) alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, entry.request.identity.due, pending)
        else alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, entry.request.identity.due, pending)
    }
    override fun cancel(entry: NativeEntry) {
        val pending = alarm(entry)
        alarms.cancel(pending)
        pending.cancel()
        cancelDisplayed(entry.request.identity.id)
    }
    override fun cancelDisplayed(id: String) { manager.cancel(TAG_PREFIX + id, 1) }
    override fun show(entry: NativeEntry) {
        val click = PendingIntent.getActivity(context, 0,
            Intent(context, MainActivity::class.java).setAction(CLICK).setData(uri(entry))
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val body = listOf(entry.request.detail, entry.request.location).filter { it.isNotBlank() }.joinToString(" · ")
        val notification = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_reminder)
            .setContentTitle(entry.request.title).setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(click).setAutoCancel(true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setCategory(NotificationCompat.CATEGORY_REMINDER).setOnlyAlertOnce(true).build()
        manager.notify(TAG_PREFIX + entry.request.identity.id, 1, notification)
    }
    override fun clearDisplayed() {
        manager.activeNotifications.filter { it.tag?.startsWith(TAG_PREFIX) == true }.forEach { manager.cancel(it.tag, it.id) }
    }
    override fun displayedAreClear() = manager.activeNotifications.none { it.tag?.startsWith(TAG_PREFIX) == true }
}

internal object AndroidReminderRuntime {
    private var instance: NotificationManagerCore? = null
    fun manager(context: Context): NotificationManagerCore = synchronized(NotificationSerialization.monitor) {
        instance ?: NotificationManagerCore(NotificationLedger.forApplication(context.applicationContext),
            AndroidNotificationDriver(context.applicationContext)).also { instance = it }
    }
}
