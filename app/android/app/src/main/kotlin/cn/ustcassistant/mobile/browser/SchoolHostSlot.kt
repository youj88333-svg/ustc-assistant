package cn.ustcassistant.mobile.browser

import android.content.Context
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.RandomAccessFile
import java.nio.channels.FileChannel
import java.nio.channels.FileLock
import java.nio.channels.OverlappingFileLockException

/** A host holds this OS lock until process exit, including after its Activity is hidden. */
internal class SchoolHostSlot private constructor(
    private val file: RandomAccessFile,
    private val channel: FileChannel,
    private val lock: FileLock,
) {
    fun release() { try { lock.release() } finally { try { channel.close() } finally { file.close() } } }
    companion object {
        fun root(context: Context): File {
            val base = context.noBackupFilesDir.canonicalFile
            val root = File(base, "ustc_assistant_v1/platform_webview_v2")
            var current = base
            for (part in listOf("ustc_assistant_v1", "platform_webview_v2")) {
                current = File(current, part)
                if (!current.exists()) check(current.mkdir())
                val stat = Os.lstat(current.path)
                check((stat.st_mode and OsConstants.S_IFMT) == OsConstants.S_IFDIR)
                check(current.canonicalFile == current.absoluteFile)
            }
            return root
        }
        fun acquire(context: Context): SchoolHostSlot? {
            val path = File(root(context), "host.lock")
            if (path.exists()) check((Os.lstat(path.path).st_mode and OsConstants.S_IFMT) == OsConstants.S_IFREG)
            val file = RandomAccessFile(path, "rw")
            val channel = file.channel
            val lock = try { channel.tryLock() } catch (_: OverlappingFileLockException) { null }
            if (lock == null) { channel.close(); file.close(); return null }
            return SchoolHostSlot(file, channel, lock)
        }
        fun available(context: Context): Boolean = acquire(context)?.let { it.release(); true } ?: false
    }
}
