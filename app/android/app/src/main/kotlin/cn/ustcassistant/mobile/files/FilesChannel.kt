package cn.ustcassistant.mobile.files

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.MediaStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/** User-mediated, single-operation file access. No URI/path crosses into Dart. */
class FilesChannel(private val activity: Activity, messenger: BinaryMessenger,
    private val ioTimeoutMillis: Long = 30_000) {
    private val channel = MethodChannel(messenger, "ustc_assistant/files_v1")
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var pending: Pending? = null
    private var disposed = false

    private class Pending(val result: MethodChannel.Result, val images: Boolean,
        val maximumCount: Int = 3, val contents: ByteArray? = null) {
        val requestCode = FIRST_REQUEST + (nextRequest.getAndIncrement() and 0xfff)
        val cancellation = CancellationSignal()
        @Volatile var active = true
        var deadline = Long.MAX_VALUE
        var timeout: Runnable? = null
        var processing = false
        fun checkActive() {
            if (!active || cancellation.isCanceled || SystemClock.elapsedRealtime() > deadline) {
                throw FileAccessFailure("cancelled")
            }
        }
    }

    init {
        require(ioTimeoutMillis in 1..30_000)
        channel.setMethodCallHandler(::handle)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) { result.error("unavailable", null, null); return }
        if (pending != null) { result.error("busy", null, null); return }
        try {
            val args = call.arguments as? Map<*, *> ?: throw FileAccessFailure("invalid_request")
            val operation: Pending
            val intent: Intent
            when (call.method) {
                "pickImages" -> {
                    if (args.keys != setOf("maximumCount")) throw FileAccessFailure("invalid_request")
                    val count = args["maximumCount"] as? Int ?: throw FileAccessFailure("invalid_request")
                    if (count !in 1..3) throw FileAccessFailure("invalid_request")
                    operation = Pending(result, true, count)
                    intent = imagePickerIntent(count)
                }
                "saveDiagnosticLog" -> {
                    if (args.keys != setOf("contents")) throw FileAccessFailure("invalid_request")
                    val contents = args["contents"] as? String ?: throw FileAccessFailure("invalid_request")
                    operation = Pending(result, false, contents = DiagnosticDocumentWriter.validate(contents))
                    intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "application/json"
                        putExtra(Intent.EXTRA_TITLE, "USTC-Assistant-diagnostics.json")
                        addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                    }
                }
                else -> { result.notImplemented(); return }
            }
            pending = operation
            try {
                activity.startActivityForResult(intent, operation.requestCode)
            } catch (_: Exception) { finish(operation, error = "unavailable") }
        } catch (error: Exception) {
            result.error((error as? FileAccessFailure)?.code ?: "invalid_request", null, null)
        }
    }

    internal fun imagePickerIntent(count: Int, usePhotoPicker: Boolean = Build.VERSION.SDK_INT >= 33): Intent {
        if (usePhotoPicker && Build.VERSION.SDK_INT >= 33) {
            val picker = Intent(MediaStore.ACTION_PICK_IMAGES).apply {
                type = "image/*"
                if (count > 1) putExtra(MediaStore.EXTRA_PICK_IMAGES_MAX, count)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            if (picker.resolveActivity(activity.packageManager) != null) return picker
        }
        return Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "image/*"
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/png", "image/jpeg", "image/webp"))
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, count > 1)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
    }

    fun onActivityResult(request: Int, resultCode: Int, data: Intent?): Boolean {
        if (request !in FIRST_REQUEST..LAST_REQUEST) return false
        val operation = pending ?: return true
        if (request != operation.requestCode) return true
        if (resultCode != Activity.RESULT_OK) {
            finish(operation, if (operation.images) emptyList<ByteArray>() else false)
            return true
        }
        try {
            val uris = selectedUris(data, if (operation.images) operation.maximumCount else 1)
            operation.processing = true
            operation.deadline = SystemClock.elapsedRealtime() + ioTimeoutMillis
            // Time spent choosing a file is user-controlled. Only provider IO is timed.
            operation.timeout = Runnable {
                if (pending === operation && operation.active) {
                    operation.active = false
                    operation.cancellation.cancel()
                    // Keep the operation occupied until the provider drains.
                    operation.result.error("timeout", null, null)
                }
            }
            main.postDelayed(operation.timeout!!, ioTimeoutMillis)
            worker.execute {
                val images = mutableListOf<ByteArray>()
                try {
                    if (operation.images) {
                        val reader = SelectedImageReader(activity.contentResolver)
                        uris.forEach { images.add(reader.read(it, operation.cancellation, operation::checkActive)) }
                    } else {
                        DiagnosticDocumentWriter(activity.contentResolver).write(uris.single(),
                            operation.contents!!, operation.cancellation, operation::checkActive)
                    }
                    main.post {
                        finish(operation, if (operation.images) images else true)
                        images.forEach { it.fill(0) }
                    }
                } catch (error: Exception) {
                    images.forEach { it.fill(0) }
                    main.post { finish(operation, error = (error as? FileAccessFailure)?.code ?: "io_failed") }
                }
            }
        } catch (error: Exception) { finish(operation, error = (error as? FileAccessFailure)?.code ?: "invalid_request") }
        return true
    }

    private fun finish(operation: Pending, value: Any? = null, error: String? = null) {
        if (pending !== operation) return
        pending = null
        operation.timeout?.let(main::removeCallbacks)
        val deliver = operation.active && !disposed
        operation.active = false
        operation.contents?.fill(0)
        if (deliver) {
            if (error != null) operation.result.error(error, null, null)
            else operation.result.success(value)
        }
    }

    fun onHostStopped() {
        val operation = pending ?: return
        // Launching a system picker itself stops MainActivity. Keep that user
        // selection alive, but withdraw IO if the user leaves after returning.
        if (!operation.processing || !operation.active) return
        operation.active = false
        operation.result.error("cancelled", null, null)
        operation.cancellation.cancel()
        // The occupied slot is released only when provider IO has drained.
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        channel.setMethodCallHandler(null)
        pending?.let {
            it.timeout?.let(main::removeCallbacks)
            val deliver = it.active
            it.active = false
            it.cancellation.cancel()
            it.contents?.fill(0)
            if (deliver) it.result.error("cancelled", null, null)
        }
        pending = null
        worker.shutdownNow()
    }

    companion object {
        private const val FIRST_REQUEST = 0x4a00
        private const val LAST_REQUEST = FIRST_REQUEST + 0xfff
        private val nextRequest = AtomicInteger()
        internal fun selectedUris(data: Intent?, maximum: Int): List<Uri> {
            val clip = data?.clipData
            val count = clip?.itemCount ?: if (data?.data != null) 1 else 0
            if (count !in 1..maximum) throw FileAccessFailure("resource_limit")
            val uris = if (clip != null) (0 until count).map { clip.getItemAt(it).uri
                ?: throw FileAccessFailure("invalid_request") } else listOf(data!!.data!!)
            uris.forEach(::requireContentUri)
            if (uris.toSet().size != uris.size) throw FileAccessFailure("invalid_request")
            return uris
        }
    }
}
