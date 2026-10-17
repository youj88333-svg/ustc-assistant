package cn.ustcassistant.mobile.notifications

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Fixed application operations; no caller-provided component, URL or path. */
internal class NotificationsChannel(private val activity: Activity, messenger: BinaryMessenger) {
    companion object { const val PERMISSION_REQUEST = 5815 }
    private val main = Handler(Looper.getMainLooper())
    private val manager = AndroidReminderRuntime.manager(activity)
    private val channel = MethodChannel(messenger, "ustc_assistant/android_notifications_v1")
    @Volatile private var disposed = false
    private var permissionResult: MethodChannel.Result? = null

    init { channel.setMethodCallHandler(::handle) }

    private fun background(result: MethodChannel.Result, operation: () -> Any?) {
        NotificationSerialization.worker.execute {
            try {
                if (disposed) throw NotificationFailure("closed")
                val value = operation()
                main.post { if (disposed) result.error("closed", null, null) else result.success(value) }
            } catch (error: Exception) {
                val code = (error as? NotificationFailure)?.code ?: "platform_unavailable"
                main.post { result.error(code, null, null) }
            }
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) { result.error("closed", null, null); return }
        if (call.method in setOf("requestNotifications", "requestExactAlarms", "openSystemSettings")) {
            if (call.arguments != null) { result.error("invalid_input", null, null); return }
            when (call.method) {
                "requestNotifications" -> {
                    if (permissionResult != null) { result.error("busy", null, null); return }
                    if (Build.VERSION.SDK_INT >= 33 && activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                        permissionResult = result
                        try { activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST) }
                        catch (_: Exception) { permissionResult = null; result.error("platform_unavailable", null, null) }
                    } else background(result) { manager.initialize() }
                }
                "requestExactAlarms" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= 31 && !activity.getSystemService(android.app.AlarmManager::class.java).canScheduleExactAlarms()) {
                            activity.startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:${activity.packageName}")))
                        }
                        // Settings is user-owned. Read again after return via initialize.
                        background(result) { manager.capability() }
                    } catch (_: Exception) { result.error("platform_unavailable", null, null) }
                }
                else -> {
                    try {
                        val target = if (Build.VERSION.SDK_INT >= 26) {
                            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
                        } else Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${activity.packageName}"))
                        activity.startActivity(target)
                        result.success(null)
                    } catch (_: Exception) { result.error("platform_unavailable", null, null) }
                }
            }
            return
        }
        background(result) {
            when (call.method) {
                "initialize" -> { requireNull(call); manager.initialize() }
                "bindPublication" -> {
                    val map = call.arguments as? Map<*, *> ?: throw NotificationFailure("invalid_input")
                    exactKeys(map, setOf("authority", "allowed"))
                    val raw = map["allowed"] as? List<*> ?: throw NotificationFailure("invalid_input")
                    if (raw.size > NotificationMirror.MAX_ENTRIES) throw NotificationFailure("invalid_input")
                    manager.bind(PublicationAuthority.parse(map["authority"]), raw.map { RequestIdentity.parse(it) })
                    null
                }
                "blockDelivery" -> { requireNull(call); manager.block(); null }
                "pending" -> { requireNull(call); manager.pending() }
                "schedule" -> { manager.schedule(NativeRequest.parse(call.arguments)); null }
                "cancel" -> {
                    val map = call.arguments as? Map<*, *> ?: throw NotificationFailure("invalid_input")
                    exactKeys(map, setOf("id")); manager.cancel(opaque(map["id"], 1, 16)); null
                }
                "clear" -> { requireNull(call); manager.clear(); null }
                "takeActivations" -> { requireNull(call); manager.takeActivations() }
                else -> throw NotificationFailure("invalid_input")
            }
        }
    }

    private fun requireNull(call: MethodCall) { if (call.arguments != null) throw NotificationFailure("invalid_input") }

    fun onPermissionResult(requestCode: Int): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        val result = permissionResult ?: return true
        permissionResult = null
        background(result) { manager.initialize() }
        return true
    }

    fun onIntent(intent: Intent?) {
        val identity = AndroidNotificationDriver.identity(intent, AndroidNotificationDriver.CLICK) ?: return
        NotificationSerialization.worker.execute {
            try {
                if (manager.click(identity.first, identity.second, identity.third)) {
                    main.post { if (!disposed) channel.invokeMethod("activationsChanged", null) }
                }
            } catch (_: Exception) { android.util.Log.w("UstcReminder", "activation_failed") }
        }
    }

    fun dispose() {
        disposed = true
        channel.setMethodCallHandler(null)
        permissionResult?.error("closed", null, null)
        permissionResult = null
        // Ordinary activity/engine closure deliberately retains native schedules.
    }
}
