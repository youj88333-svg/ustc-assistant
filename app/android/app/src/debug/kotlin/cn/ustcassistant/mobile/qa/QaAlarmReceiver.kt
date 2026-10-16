package cn.ustcassistant.mobile.qa

import android.app.Notification
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/** Handles only the explicit alarm created by [NotificationProbe]. */
class QaAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val incoming = intent ?: return
        if (!NotificationProbe.isQaPackage(context) ||
            incoming.action != ACTION ||
            incoming.`package` != context.packageName ||
            incoming.component?.packageName != context.packageName ||
            incoming.component?.className != QaAlarmReceiver::class.java.name
        ) {
            return
        }

        if (!NotificationProbe.recordReceiverDelivery(context)) return
        if (!NotificationProbe.notificationsEnabled(context)) return

        val notificationManager = context.getSystemService(NotificationManager::class.java)
            ?: return

        try {
            NotificationProbe.ensureNotificationChannel(context, notificationManager)
            val notification = buildNotification(context)
            notificationManager.notify(NotificationProbe.NOTIFICATION_ID, notification)
            NotificationProbe.recordNotificationCommitted(context)
        } catch (_: SecurityException) {
            // A permission may be revoked after the capability check. The
            // receiver count remains truthful and no success is synthesized.
        } catch (_: RuntimeException) {
            // Keep the receiver isolated: never launch product or network code.
        }
    }

    private fun buildNotification(context: Context): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, NotificationProbe.CHANNEL_ID)
        } else {
            Notification.Builder(context)
        }
        return builder
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("QA notification probe")
            .setContentText("Synthetic notification for isolated Android testing.")
            .setCategory(Notification.CATEGORY_REMINDER)
            .setAutoCancel(true)
            .build()
    }

    companion object {
        const val ACTION = "cn.ustcassistant.mobile.qa.action.NOTIFICATION_PROBE"
    }
}
