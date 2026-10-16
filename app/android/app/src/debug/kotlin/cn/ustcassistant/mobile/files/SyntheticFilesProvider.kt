package cn.ustcassistant.mobile.files

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import java.io.File
import java.io.FileNotFoundException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** QA-only provider for synthetic images and newly-created diagnostic documents. */
class SyntheticFilesProvider : ContentProvider() {
    private data class Document(
        val file: File,
        @Volatile var blockOpen: Boolean = false,
        @Volatile var queries: Int = 0,
        @Volatile var opens: Int = 0,
        @Volatile var deleteCalls: Int = 0,
        @Volatile var deleted: Boolean = false,
        @Volatile var deletedLength: Long = 0L,
        val openStarted: CountDownLatch = CountDownLatch(1),
        val allowOpen: CountDownLatch = CountDownLatch(1),
        val deleteFinished: CountDownLatch = CountDownLatch(1),
    )

    private val documents = ConcurrentHashMap<String, Document>()
    private lateinit var directory: File

    override fun onCreate(): Boolean {
        directory = File(requireNotNull(context).cacheDir, "synthetic-files-provider")
        return directory.mkdirs() || directory.isDirectory
    }

    override fun getType(uri: Uri): String = "text/plain" // Deliberately unrelated to image bytes.

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        val document = document(uri)
        document.queries += 1
        val columns = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        val cursor = MatrixCursor(columns)
        cursor.addRow(columns.map { column ->
            when (column) {
                OpenableColumns.DISPLAY_NAME -> "synthetic.bin"
                OpenableColumns.SIZE -> 1L // Lie to catch unbounded preallocation based on provider metadata.
                else -> null
            }
        })
        return cursor
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        val document = document(uri)
        if (document.deleted) throw FileNotFoundException("synthetic document deleted")
        document.opens += 1
        if (document.blockOpen) {
            document.openStarted.countDown()
            var interrupted = false
            while (true) {
                try {
                    if (!document.allowOpen.await(5, TimeUnit.SECONDS)) {
                        throw FileNotFoundException("synthetic provider gate timed out")
                    }
                    break
                } catch (_: InterruptedException) {
                    // Model a provider that does not promptly honor cancellation/interruption.
                    interrupted = true
                }
            }
            if (interrupted) Thread.currentThread().interrupt()
        }
        if (document.deleted) throw FileNotFoundException("synthetic document deleted")
        return ParcelFileDescriptor.open(document.file, ParcelFileDescriptor.parseMode(mode))
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        // These framework provider wire constants are hidden from android.jar.
        if (method == "android:deleteDocument") {
            @Suppress("DEPRECATION")
            val uri = extras?.getParcelable("uri") as? Uri
                ?: throw IllegalArgumentException("delete URI missing")
            val document = documents[DocumentsContract.getDocumentId(uri)]
            val deletedLength = document?.file?.length() ?: 0L
            val deleted = document != null && document.file.delete().let { removed ->
                removed || !document.file.exists()
            }
            if (document != null) {
                document.deleteCalls += 1
                document.deleted = deleted
                document.deletedLength = deletedLength
                document.deleteFinished.countDown()
            }
            return Bundle().apply { putBoolean("result", deleted) }
        }
        val id = requireNotNull(arg)
        return when (method) {
            METHOD_CREATE -> {
                require(id.matches(Regex("synthetic_[a-f0-9]{32}")))
                val file = File(directory, id)
                file.writeBytes(byteArrayOf())
                documents[id] = Document(file)
                Bundle().apply { putString(EXTRA_ID, id) }
            }
            METHOD_SET_BLOCK_OPEN -> {
                requireNotNull(documents[id]).blockOpen = requireNotNull(extras).getBoolean(EXTRA_BLOCK_OPEN)
                Bundle()
            }
            METHOD_RESET_STATS -> {
                val document = requireNotNull(documents[id])
                document.queries = 0
                document.opens = 0
                document.deleteCalls = 0
                Bundle()
            }
            METHOD_STATE -> {
                val document = requireNotNull(documents[id])
                Bundle().apply {
                    putBoolean(EXTRA_EXISTS, document.file.exists())
                    putLong(EXTRA_LENGTH, if (document.file.exists()) document.file.length() else 0L)
                    putInt(EXTRA_QUERIES, document.queries)
                    putInt(EXTRA_OPENS, document.opens)
                    putInt(EXTRA_DELETE_CALLS, document.deleteCalls)
                    putBoolean(EXTRA_DELETED, document.deleted)
                    putLong(EXTRA_DELETED_LENGTH, document.deletedLength)
                }
            }
            METHOD_REMOVE -> {
                val document = documents.remove(id)
                document?.allowOpen?.countDown()
                document?.file?.delete()
                Bundle()
            }
            METHOD_WAIT_OPEN -> {
                val document = requireNotNull(documents[id])
                Bundle().apply {
                    putBoolean(EXTRA_OPEN_STARTED, document.openStarted.await(3, TimeUnit.SECONDS))
                }
            }
            METHOD_RELEASE_OPEN -> {
                documents[id]?.allowOpen?.countDown()
                Bundle()
            }
            METHOD_WAIT_DELETED -> {
                val document = requireNotNull(documents[id])
                Bundle().apply {
                    putBoolean(EXTRA_DELETE_FINISHED, document.deleteFinished.await(3, TimeUnit.SECONDS))
                }
            }
            else -> throw UnsupportedOperationException(method)
        }
    }

    private fun document(uri: Uri): Document =
        documents[DocumentsContract.getDocumentId(uri)] ?: throw FileNotFoundException("unknown synthetic document")

    companion object {
        const val AUTHORITY = "cn.ustcassistant.mobile.qa.synthetic-files"
        const val METHOD_CREATE = "qa.synthetic.create"
        const val METHOD_STATE = "qa.synthetic.state"
        const val METHOD_REMOVE = "qa.synthetic.remove"
        const val METHOD_SET_BLOCK_OPEN = "qa.synthetic.set_block_open"
        const val METHOD_RESET_STATS = "qa.synthetic.reset_stats"
        const val METHOD_WAIT_OPEN = "qa.synthetic.wait_open"
        const val METHOD_RELEASE_OPEN = "qa.synthetic.release_open"
        const val METHOD_WAIT_DELETED = "qa.synthetic.wait_deleted"
        const val EXTRA_ID = "id"
        const val EXTRA_BLOCK_OPEN = "block_open"
        const val EXTRA_EXISTS = "exists"
        const val EXTRA_LENGTH = "length"
        const val EXTRA_QUERIES = "queries"
        const val EXTRA_OPENS = "opens"
        const val EXTRA_DELETE_CALLS = "delete_calls"
        const val EXTRA_DELETED = "deleted"
        const val EXTRA_DELETED_LENGTH = "deleted_length"
        const val EXTRA_OPEN_STARTED = "open_started"
        const val EXTRA_DELETE_FINISHED = "delete_finished"

        fun create(resolver: android.content.ContentResolver, bytes: ByteArray): Uri {
            return create(resolver, bytes, blockOpen = false)
        }

        fun createBlocked(resolver: android.content.ContentResolver, bytes: ByteArray): Uri =
            create(resolver, bytes, blockOpen = true)

        private fun create(resolver: android.content.ContentResolver, bytes: ByteArray, blockOpen: Boolean): Uri {
            val id = "synthetic_${java.util.UUID.randomUUID().toString().replace("-", "") }"
            resolver.call(AUTHORITY, METHOD_CREATE, id, Bundle())
            val uri = DocumentsContract.buildDocumentUri(AUTHORITY, id)
            if (bytes.isNotEmpty()) {
                resolver.openOutputStream(uri, "wt")!!.use { output -> output.write(bytes) }
            }
            if (blockOpen) {
                resolver.call(AUTHORITY, METHOD_SET_BLOCK_OPEN, id,
                    Bundle().apply { putBoolean(EXTRA_BLOCK_OPEN, true) })
            }
            resolver.call(AUTHORITY, METHOD_RESET_STATS, id, null)
            return uri
        }

        fun state(resolver: android.content.ContentResolver, uri: Uri): Bundle =
            requireNotNull(resolver.call(AUTHORITY, METHOD_STATE, DocumentsContract.getDocumentId(uri), null))

        fun readContents(resolver: android.content.ContentResolver, uri: Uri): ByteArray =
            resolver.openInputStream(uri)!!.use { it.readBytes() }

        fun remove(resolver: android.content.ContentResolver, uri: Uri) {
            resolver.call(AUTHORITY, METHOD_REMOVE, DocumentsContract.getDocumentId(uri), null)
        }

        fun awaitOpen(resolver: android.content.ContentResolver, uri: Uri): Boolean =
            requireNotNull(resolver.call(AUTHORITY, METHOD_WAIT_OPEN, DocumentsContract.getDocumentId(uri), null))
                .getBoolean(EXTRA_OPEN_STARTED)

        fun releaseOpen(resolver: android.content.ContentResolver, uri: Uri) {
            resolver.call(AUTHORITY, METHOD_RELEASE_OPEN, DocumentsContract.getDocumentId(uri), null)
        }

        fun awaitDeleted(resolver: android.content.ContentResolver, uri: Uri): Boolean =
            requireNotNull(resolver.call(AUTHORITY, METHOD_WAIT_DELETED, DocumentsContract.getDocumentId(uri), null))
                .getBoolean(EXTRA_DELETE_FINISHED)
    }
}
