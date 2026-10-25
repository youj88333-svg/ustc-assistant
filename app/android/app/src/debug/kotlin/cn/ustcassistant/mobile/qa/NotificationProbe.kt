package cn.ustcassistant.mobile.qa

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import org.json.JSONObject

/**
 * A debug-only probe for the operating system notification/alarm path.
 * It is deliberately restricted to the isolated `.qa` application identity.
 */
object NotificationProbe {
    const val KIND = "android-notification-probe-v1"

    internal const val REQUEST_CODE = 41001
    internal const val NOTIFICATION_ID = 41001
    internal const val CHANNEL_ID = "android_notification_probe_v1"
    internal const val DELAY_MILLIS = 15_000L

    internal const val FAILURE_NONE = "none"
    internal const val FAILURE_WRONG_PACKAGE = "wrong_package"
    internal const val FAILURE_NOTIFICATIONS_DISABLED = "notifications_disabled"
    internal const val FAILURE_ALARM_SERVICE_UNAVAILABLE = "alarm_service_unavailable"
    internal const val FAILURE_NOTIFICATION_SERVICE_UNAVAILABLE = "notification_service_unavailable"
    internal const val FAILURE_SCHEDULE_FAILED = "schedule_failed"
    internal const val FAILURE_CANCEL_FAILED = "cancel_failed"
    internal const val FAILURE_CLEAR_FAILED = "clear_failed"
    internal const val FAILURE_REPORT_FAILED = "report_failed"

    private const val PREFS_NAME = "android_notification_probe_v1"
    private const val KEY_SCHEDULED = "scheduled"
    private const val KEY_RECEIVER_COUNT = "receiver_count"
    private const val KEY_NOTIFICATION_COMMITTED = "notification_committed"
    private const val KEY_EXACT_USED = "exact_used"

    private data class Capabilities(
        val notificationsEnabled: Boolean,
        val exactAlarmsAllowed: Boolean,
    )

    fun capabilities(context: Context): JSONObject {
        if (!isQaPackage(context)) return rejectedResult()

        val capability = readCapabilities(context)
        return result(
            context = context,
            success = true,
            failure = FAILURE_NONE,
            notificationsEnabled = capability.notificationsEnabled,
            exactAlarmsAllowed = capability.exactAlarmsAllowed,
        )
    }

    fun schedule(context: Context): JSONObject {
        if (!isQaPackage(context)) return rejectedResult()

        val capability = readCapabilities(context)
        if (!capability.notificationsEnabled) {
            return result(
                context = context,
                success = false,
                failure = FAILURE_NOTIFICATIONS_DISABLED,
                notificationsEnabled = false,
                exactAlarmsAllowed = capability.exactAlarmsAllowed,
            )
        }

        val alarmManager = context.getSystemService(AlarmManager::class.java)
            ?: return result(
                context,
                false,
                FAILURE_ALARM_SERVICE_UNAVAILABLE,
                capability.notificationsEnabled,
                capability.exactAlarmsAllowed,
            )
        val notificationManager = context.getSystemService(NotificationManager::class.java)
            ?: return result(
                context,
                false,
                FAILURE_NOTIFICATION_SERVICE_UNAVAILABLE,
                capability.notificationsEnabled,
                capability.exactAlarmsAllowed,
            )

        val pendingIntent = createPendingIntent(context, PendingIntent.FLAG_UPDATE_CURRENT)
            ?: return result(
                context,
                false,
                FAILURE_SCHEDULE_FAILED,
                capability.notificationsEnabled,
                capability.exactAlarmsAllowed,
            )

        var exactUsed = capability.exactAlarmsAllowed
        try {
            alarmManager.cancel(pendingIntent)
            notificationManager.cancel(NOTIFICATION_ID)
            ensureNotificationChannel(context, notificationManager)
        } catch (_: SecurityException) {
            pendingIntent.cancel()
            return result(
                context,
                false,
                FAILURE_SCHEDULE_FAILED,
                capability.notificationsEnabled,
                capability.exactAlarmsAllowed,
            )
        } catch (_: RuntimeException) {
            pendingIntent.cancel()
            return result(
                context,
                false,
                FAILURE_SCHEDULE_FAILED,
                capability.notificationsEnabled,
                capability.exactAlarmsAllowed,
            )
        }

        val reset = preferences(context).edit()
            .putBoolean(KEY_SCHEDULED, false)
            .putInt(KEY_RECEIVER_COUNT, 0)
            .putBoolean(KEY_NOTIFICATION_COMMITTED, false)
            .putBoolean(KEY_EXACT_USED, false)
            .commit()
        if (!reset) {
            alarmManager.cancel(pendingIntent)
            pendingIntent.cancel()
            return result(
                context,
                false,
                FAILURE_SCHEDULE_FAILED,
                capability.notificationsEnabled,
                capability.exactAlarmsAllowed,
            )
        }

        var resultCapabilities = capability
        try {
            setAlarm(alarmManager, pendingIntent, exact = exactUsed)
        } catch (_: SecurityException) {
            // Exact-alarm access can be revoked between the capability read and
            // scheduling. Recheck, then use an inexact idle-allowed alarm only
            // when the OS now reports exact scheduling as unavailable.
            val refreshed = readCapabilities(context)
            resultCapabilities = refreshed
            if (!refreshed.notificationsEnabled) {
                pendingIntent.cancel()
                return result(
                    context,
                    false,
                    FAILURE_NOTIFICATIONS_DISABLED,
                    refreshed.notificationsEnabled,
                    refreshed.exactAlarmsAllowed,
                )
            }
            if (exactUsed && !refreshed.exactAlarmsAllowed) {
                exactUsed = false
                try {
                    setAlarm(alarmManager, pendingIntent, exact = false)
                } catch (_: RuntimeException) {
                    pendingIntent.cancel()
                    return result(
                        context,
                        false,
                        FAILURE_SCHEDULE_FAILED,
                        refreshed.notificationsEnabled,
                        refreshed.exactAlarmsAllowed,
                    )
                }
            } else {
                pendingIntent.cancel()
                return result(
                    context,
                    false,
                    FAILURE_SCHEDULE_FAILED,
                    refreshed.notificationsEnabled,
                    refreshed.exactAlarmsAllowed,
                )
            }
        } catch (_: RuntimeException) {
            pendingIntent.cancel()
            return result(
                context,
                false,
                FAILURE_SCHEDULE_FAILED,
                capability.notificationsEnabled,
                capability.exactAlarmsAllowed,
            )
        }

        val recorded = preferences(context).edit()
            .putBoolean(KEY_SCHEDULED, true)
            .putBoolean(KEY_NOTIFICATION_COMMITTED, false)
            .putBoolean(KEY_EXACT_USED, exactUsed)
            .commit()
        if (!recorded) {
            alarmManager.cancel(pendingIntent)
            pendingIntent.cancel()
            return result(
                context,
                false,
                FAILURE_SCHEDULE_FAILED,
                resultCapabilities.notificationsEnabled,
                resultCapabilities.exactAlarmsAllowed,
            )
        }

        return result(
            context,
            true,
            FAILURE_NONE,
            resultCapabilities.notificationsEnabled,
            resultCapabilities.exactAlarmsAllowed,
        )
    }

    fun cancel(context: Context): JSONObject {
        if (!isQaPackage(context)) return rejectedResult()

        val capability = readCapabilities(context)
        val canceled = cancelOwnedState(context, resetReceiverCount = false)
        return result(
            context,
            canceled,
            if (canceled) FAILURE_NONE else FAILURE_CANCEL_FAILED,
            capability.notificationsEnabled,
            capability.exactAlarmsAllowed,
        )
    }

    fun report(context: Context): JSONObject {
        if (!isQaPackage(context)) return rejectedResult()

        val capability = readCapabilities(context)
        val notificationManager = context.getSystemService(NotificationManager::class.java)
            ?: return result(
                context,
                false,
                FAILURE_REPORT_FAILED,
                capability.notificationsEnabled,
                capability.exactAlarmsAllowed,
            )

        return try {
            // NotificationManager.activeNotifications is scoped to this calling
            // application. Filter again by our package and fixed probe ID.
            val active = notificationManager.activeNotifications.any {
                it.packageName == context.packageName &&
                    it.id == NOTIFICATION_ID &&
                    it.tag == null
            }
            result(
                context,
                true,
                FAILURE_NONE,
                capability.notificationsEnabled,
                capability.exactAlarmsAllowed,
                notificationActiveOverride = active,
            )
        } catch (_: RuntimeException) {
            result(
                context,
                false,
                FAILURE_REPORT_FAILED,
                capability.notificationsEnabled,
                capability.exactAlarmsAllowed,
            )
        }
    }

    fun clear(context: Context): JSONObject {
        if (!isQaPackage(context)) return rejectedResult()

        val capability = readCapabilities(context)
        val canceled = cancelOwnedState(context, resetReceiverCount = true)
        val cleared = canceled && preferences(context).edit().clear().commit()
        return result(
            context,
            cleared,
            if (cleared) FAILURE_NONE else FAILURE_CLEAR_FAILED,
            capability.notificationsEnabled,
            capability.exactAlarmsAllowed,
        )
    }

    internal fun isQaPackage(context: Context): Boolean =
        context.packageName.endsWith(".qa")

    internal fun notificationsEnabled(context: Context): Boolean =
        isQaPackage(context) && readCapabilities(context).notificationsEnabled

    internal fun ensureNotificationChannel(
        context: Context,
        notificationManager: NotificationManager,
    ) {
        if (!isQaPackage(context)) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = android.app.NotificationChannel(
                CHANNEL_ID,
                "QA notification probe",
                NotificationManager.IMPORTANCE_DEFAULT,
            )
            notificationManager.createNotificationChannel(channel)
        }
    }

    /** Persist the fact that Android invoked this receiver before posting. */
    internal fun recordReceiverDelivery(context: Context): Boolean {
        if (!isQaPackage(context)) return false
        return preferences(context).let { prefs ->
            synchronized(receiverStateLock) {
                prefs.edit()
                    .putInt(KEY_RECEIVER_COUNT, prefs.getInt(KEY_RECEIVER_COUNT, 0) + 1)
                    .putBoolean(KEY_SCHEDULED, false)
                    .putBoolean(KEY_NOTIFICATION_COMMITTED, false)
                    .commit()
            }
        }
    }

    /** Persist only after NotificationManager.notify() returned successfully. */
    internal fun recordNotificationCommitted(context: Context): Boolean {
        if (!isQaPackage(context)) return false
        return preferences(context).edit()
            .putBoolean(KEY_NOTIFICATION_COMMITTED, true)
            .commit()
    }

    private fun readCapabilities(context: Context): Capabilities {
        val notificationManager = context.getSystemService(NotificationManager::class.java)
        val appNotificationsEnabled = try {
            notificationManager?.areNotificationsEnabled() == true
        } catch (_: RuntimeException) {
            false
        }
        val channelEnabled = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                val channel = notificationManager?.getNotificationChannel(CHANNEL_ID)
                channel == null || channel.importance != NotificationManager.IMPORTANCE_NONE
            } catch (_: RuntimeException) {
                false
            }
        } else {
            true
        }
        val runtimePermissionGranted = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        val alarmManager = context.getSystemService(AlarmManager::class.java)
        val exactAlarmsAllowed = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                alarmManager?.canScheduleExactAlarms() == true
            } catch (_: RuntimeException) {
                false
            }
        } else {
            true
        }
        return Capabilities(
            notificationsEnabled =
                appNotificationsEnabled && channelEnabled && runtimePermissionGranted,
            exactAlarmsAllowed = exactAlarmsAllowed,
        )
    }

    private fun setAlarm(
        alarmManager: AlarmManager,
        pendingIntent: PendingIntent,
        exact: Boolean,
    ) {
        val triggerAt = SystemClock.elapsedRealtime() + DELAY_MILLIS
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            if (exact) {
                alarmManager.setExactAndAllowWhileIdle(
                    AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    triggerAt,
                    pendingIntent,
                )
            } else {
                alarmManager.setAndAllowWhileIdle(
                    AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    triggerAt,
                    pendingIntent,
                )
            }
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT && exact) {
            alarmManager.setExact(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                triggerAt,
                pendingIntent,
            )
        } else {
            alarmManager.set(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                triggerAt,
                pendingIntent,
            )
        }
    }

    private fun createPendingIntent(context: Context, additionalFlags: Int): PendingIntent? {
        val intent = Intent(context, QaAlarmReceiver::class.java)
            .setPackage(context.packageName)
            .setAction(QaAlarmReceiver.ACTION)
        val flags = PendingIntent.FLAG_IMMUTABLE or additionalFlags
        return PendingIntent.getBroadcast(context, REQUEST_CODE, intent, flags)
    }

    private fun cancelOwnedState(context: Context, resetReceiverCount: Boolean): Boolean {
        val alarmManager = context.getSystemService(AlarmManager::class.java)
            ?: return false
        val notificationManager = context.getSystemService(NotificationManager::class.java)
            ?: return false

        try {
            val pendingIntent = createPendingIntent(context, PendingIntent.FLAG_NO_CREATE)
            if (pendingIntent != null) {
                alarmManager.cancel(pendingIntent)
                pendingIntent.cancel()
            }
            notificationManager.cancel(NOTIFICATION_ID)
        } catch (_: RuntimeException) {
            return false
        }

        val editor = preferences(context).edit()
            .putBoolean(KEY_SCHEDULED, false)
            .putBoolean(KEY_NOTIFICATION_COMMITTED, false)
        if (resetReceiverCount) editor.putInt(KEY_RECEIVER_COUNT, 0)
        return editor.commit()
    }

    private fun result(
        context: Context,
        success: Boolean,
        failure: String,
        notificationsEnabled: Boolean,
        exactAlarmsAllowed: Boolean,
        notificationActiveOverride: Boolean? = null,
    ): JSONObject {
        val prefs = preferences(context)
        val notificationActive = notificationActiveOverride ?: isProbeNotificationActive(context)
        return JSONObject()
            .put("kind", KIND)
            .put("success", success)
            .put("failure", failure)
            .put("notificationsEnabled", notificationsEnabled)
            .put("exactAlarmsAllowed", exactAlarmsAllowed)
            .put("scheduled", prefs.getBoolean(KEY_SCHEDULED, false))
            .put("receiverCount", prefs.getInt(KEY_RECEIVER_COUNT, 0).coerceAtLeast(0))
            // This is the notification's current OS-active state. The separate
            // persisted notify-committed marker stays private to this QA probe.
            .put("notificationPosted", notificationActive)
            .put("exactUsed", prefs.getBoolean(KEY_EXACT_USED, false))
    }

    private fun rejectedResult(): JSONObject = JSONObject()
        .put("kind", KIND)
        .put("success", false)
        .put("failure", FAILURE_WRONG_PACKAGE)
        .put("notificationsEnabled", false)
        .put("exactAlarmsAllowed", false)
        .put("scheduled", false)
        .put("receiverCount", 0)
        .put("notificationPosted", false)
        .put("exactUsed", false)

    private fun isProbeNotificationActive(context: Context): Boolean {
        val notificationManager = context.getSystemService(NotificationManager::class.java)
            ?: return false
        return try {
            notificationManager.activeNotifications.any {
                it.packageName == context.packageName &&
                    it.id == NOTIFICATION_ID &&
                    it.tag == null
            }
        } catch (_: RuntimeException) {
            false
        }
    }

    private fun preferences(context: Context) =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private val receiverStateLock = Any()
}
