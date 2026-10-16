package cn.ustcassistant.mobile

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.io.File

/** Only sandbox metadata. No caller path, user files, or business database access. */
internal class PlatformChannel(context: Context, messenger: BinaryMessenger) {
    private val application = context.applicationContext
    private val channel = MethodChannel(messenger, "ustc_assistant/platform_v1",
        StandardMethodCodec.INSTANCE,
        messenger.makeBackgroundTaskQueue(BinaryMessenger.TaskQueueOptions().setIsSerial(true)))

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "privateDataRoot") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            if (call.arguments != null) {
                result.error("invalid_request", null, null)
                return@setMethodCallHandler
            }
            try {
                val parent = application.noBackupFilesDir.canonicalFile
                val root = File(parent, "ustc_assistant_v1")
                if ((!root.isDirectory && !root.mkdir()) || root.canonicalPath != root.absolutePath) {
                    result.error("unsafe_directory", null, null)
                } else {
                    result.success(root.canonicalPath)
                }
            } catch (_: Exception) {
                result.error("storage_failed", null, null)
            }
        }
    }

    fun dispose() { channel.setMethodCallHandler(null) }
}
