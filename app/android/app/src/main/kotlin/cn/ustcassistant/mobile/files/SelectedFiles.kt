package cn.ustcassistant.mobile.files

import android.content.ContentResolver
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.CancellationSignal
import android.provider.DocumentsContract
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.InputStream

internal class FileAccessFailure(val code: String) : Exception(code)

/** Never trusts SIZE, MIME, a display name, or a filesystem path from a provider. */
internal class SelectedImageReader(private val resolver: ContentResolver) {
    companion object {
        const val MAX_BYTES = 10 * 1024 * 1024
        const val MAX_PIXELS = 16_000_000L

        fun readBounded(input: InputStream, checkActive: () -> Unit = {}): ByteArray {
            val output = WipingBuffer()
            val chunk = ByteArray(32 * 1024)
            try {
                while (true) {
                    checkActive()
                    // One extra byte distinguishes exactly-at-limit from oversized input.
                    val count = input.read(chunk, 0, minOf(chunk.size, MAX_BYTES - output.size() + 1))
                    if (count < 0) break
                    if (count == 0) throw FileAccessFailure("image_rejected")
                    if (count > MAX_BYTES - output.size()) throw FileAccessFailure("resource_limit")
                    output.write(chunk, 0, count)
                }
                if (output.size() == 0) throw FileAccessFailure("image_rejected")
                return output.toByteArray()
            } finally {
                chunk.fill(0)
                output.wipe()
            }
        }

        fun validateImage(bytes: ByteArray) {
            if (bytes.isEmpty() || bytes.size > MAX_BYTES) throw FileAccessFailure("resource_limit")
            fun prefix(vararg expected: Int) = bytes.size >= expected.size &&
                expected.indices.all { bytes[it].toInt() and 0xff == expected[it] }
            val png = prefix(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)
            val jpeg = prefix(0xff, 0xd8, 0xff)
            val webp = prefix(0x52, 0x49, 0x46, 0x46) && bytes.size >= 12 &&
                bytes.copyOfRange(8, 12).contentEquals(byteArrayOf(0x57, 0x45, 0x42, 0x50))
            if (!png && !jpeg && !webp) throw FileAccessFailure("image_rejected")
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0 ||
                bounds.outWidth.toLong() * bounds.outHeight > MAX_PIXELS ||
                bounds.outMimeType !in setOf("image/png", "image/jpeg", "image/webp")) {
                throw FileAccessFailure("image_rejected")
            }
        }
    }

    fun read(uri: Uri, cancellation: CancellationSignal, checkActive: () -> Unit): ByteArray {
        requireContentUri(uri)
        val descriptor = resolver.openAssetFileDescriptor(uri, "r", cancellation)
            ?: throw FileAccessFailure("read_failed")
        val bytes = descriptor.use { asset ->
            asset.createInputStream().use { readBounded(it, checkActive) }
        }
        try {
            checkActive()
            validateImage(bytes)
            return bytes
        } catch (error: Throwable) {
            bytes.fill(0)
            throw error
        }
    }
}

internal class DiagnosticDocumentWriter(private val resolver: ContentResolver) {
    companion object {
        const val MAX_BYTES = 2 * 1024 * 1024
        private val fields = setOf("kind", "exportedAtUtc", "retentionDays", "versions", "coverage",
            "selectionTruncated", "complete", "dropped", "invalid", "records")

        fun validate(contents: String): ByteArray {
            if (contents.length > MAX_BYTES) throw FileAccessFailure("invalid_request")
            val bytes = contents.toByteArray(Charsets.UTF_8)
            try {
                if (bytes.size > MAX_BYTES) throw FileAccessFailure("resource_limit")
                val json = JSONObject(contents)
                if (json.keys().asSequence().toSet() != fields ||
                    json.getString("kind") != "ustc-diagnostics-export-v1" ||
                    json.getInt("retentionDays") != 7 ||
                    json.getString("coverage") !in setOf("retained_recent_events", "startup_error_only") ||
                    json.get("selectionTruncated") !is Boolean || json.get("complete") !is Boolean ||
                    json.getLong("dropped") < 0 || json.getLong("invalid") < 0 ||
                    json.getJSONArray("records").length() > 1000) {
                    throw FileAccessFailure("invalid_request")
                }
                // The Dart boundary reconstructs every record through DiagnosticRecord.
                // This second envelope guard prevents this bridge becoming a generic saver.
                json.getJSONObject("versions")
                if (json.getString("coverage") == "startup_error_only" && json.getBoolean("complete")) {
                    throw FileAccessFailure("invalid_request")
                }
                if (!json.getString("exportedAtUtc").endsWith("Z")) throw FileAccessFailure("invalid_request")
                return bytes
            } catch (error: Throwable) {
                bytes.fill(0)
                if (error is FileAccessFailure) throw error
                throw FileAccessFailure("invalid_request")
            }
        }
    }

    fun write(uri: Uri, bytes: ByteArray, cancellation: CancellationSignal, checkActive: () -> Unit) {
        requireContentUri(uri)
        try {
            checkActive()
            val descriptor = resolver.openAssetFileDescriptor(uri, "wt", cancellation)
                ?: throw FileAccessFailure("write_failed")
            descriptor.use { asset ->
                asset.createOutputStream().use { output ->
                    var offset = 0
                    while (offset < bytes.size) {
                        checkActive()
                        val length = minOf(32 * 1024, bytes.size - offset)
                        output.write(bytes, offset, length)
                        offset += length
                    }
                    output.flush()
                }
            }
            checkActive()
        } catch (error: Throwable) {
            // Only this newly created, explicitly selected document may be removed.
            try { DocumentsContract.deleteDocument(resolver, uri) } catch (_: Throwable) { }
            throw error
        }
    }
}

internal fun requireContentUri(uri: Uri) {
    if (uri.scheme != "content" || uri.authority.isNullOrBlank() || uri.isOpaque || uri.fragment != null) {
        throw FileAccessFailure("invalid_request")
    }
}

private class WipingBuffer : ByteArrayOutputStream(32 * 1024) {
    override fun write(bytes: ByteArray, offset: Int, length: Int) {
        val previous = buf
        super.write(bytes, offset, length)
        if (previous !== buf) previous.fill(0)
    }
    fun wipe() { buf.fill(0); reset() }
}
