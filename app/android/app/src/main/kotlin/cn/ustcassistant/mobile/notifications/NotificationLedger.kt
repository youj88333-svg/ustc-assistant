package cn.ustcassistant.mobile.notifications

import android.content.Context
import android.util.AtomicFile
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File

/** A bounded scheduling projection only. No business DB, credentials or Agent. */
internal class NotificationLedger(private val directory: File) {
    companion object {
        private const val MAX_BYTES = 8 * 1024 * 1024
        fun forApplication(context: Context): NotificationLedger = NotificationLedger(
            File(context.noBackupFilesDir.canonicalFile, "ustc_assistant_v1/notifications_v1"))
    }
    private fun file(): AtomicFile {
        if ((!directory.isDirectory && !directory.mkdirs()) || directory.canonicalPath != directory.absolutePath) {
            throw NotificationFailure("storage_failed")
        }
        val base = File(directory, "reminders.json")
        for (candidate in listOf(base, File(directory, "reminders.json.bak"), File(directory, "reminders.json.new"))) {
            if (candidate.canonicalPath != candidate.absolutePath) throw NotificationFailure("storage_failed")
        }
        return AtomicFile(base)
    }
    fun read(): NotificationMirror {
        try {
            val atomic = file()
            if (!atomic.baseFile.exists() && !File(directory, "reminders.json.bak").exists()) return NotificationMirror()
            val bytes = atomic.openRead().use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(16 * 1024)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (count == 0 || output.size() + count > MAX_BYTES) throw NotificationFailure("storage_failed")
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
            return NotificationMirror.parse(JSONObject(bytes.toString(Charsets.UTF_8)))
        } catch (_: Exception) { throw NotificationFailure("storage_failed") }
    }
    fun write(state: NotificationMirror) {
        if (state.entries.size > NotificationMirror.MAX_ENTRIES || state.allowed.size > NotificationMirror.MAX_ENTRIES) {
            throw NotificationFailure("storage_failed")
        }
        val bytes = state.json().toString().toByteArray(Charsets.UTF_8)
        if (bytes.size > MAX_BYTES) throw NotificationFailure("storage_failed")
        val atomic = file()
        val output = try { atomic.startWrite() } catch (_: Exception) { throw NotificationFailure("storage_failed") }
        try {
            output.write(bytes)
            atomic.finishWrite(output)
        } catch (_: Exception) {
            atomic.failWrite(output)
            throw NotificationFailure("storage_failed")
        }
    }
}
