package cn.ustcassistant.mobile.files

import android.content.ClipData
import android.content.ClipDescription
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.os.CancellationSignal
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.zip.CRC32

/** Synthetic-only coverage for the fixed image-picker and diagnostic-export bridge. */
@RunWith(AndroidJUnit4::class)
class FilesBridgeTest {
    private val resolver by lazy { InstrumentationRegistry.getInstrumentation().targetContext.contentResolver }

    @Test fun boundedReaderAcceptsTheLimitAndRejectsOneByteOverDespiteProviderSizeLie() {
        val exact = SelectedImageReader.readBounded(ByteArrayInputStream(ByteArray(SelectedImageReader.MAX_BYTES)))
        assertEquals(SelectedImageReader.MAX_BYTES, exact.size)
        exact.fill(0)

        val uri = SyntheticFilesProvider.create(resolver, ByteArray(SelectedImageReader.MAX_BYTES + 1))
        try {
            expectFailure("resource_limit") {
                SelectedImageReader(resolver).read(uri, CancellationSignal()) {}
            }
            val state = SyntheticFilesProvider.state(resolver, uri)
            assertEquals("The reader must stream rather than query external SIZE", 0,
                state.getInt(SyntheticFilesProvider.EXTRA_QUERIES))
            assertEquals(1, state.getInt(SyntheticFilesProvider.EXTRA_OPENS))
        } finally {
            SyntheticFilesProvider.remove(resolver, uri)
        }
    }

    @Test fun boundedReaderStopsWhenItsOperationIsCancelled() {
        var checks = 0
        expectFailure("cancelled") {
            SelectedImageReader.readBounded(ByteArrayInputStream(ByteArray(64 * 1024))) {
                checks += 1
                if (checks == 2) throw FileAccessFailure("cancelled")
            }
        }
        assertEquals(2, checks)
    }

    @Test fun imageReadUsesSyntheticBytesRatherThanProviderMimeOrSize() {
        val image = png(2, 3)
        val uri = SyntheticFilesProvider.create(resolver, image)
        try {
            val result = SelectedImageReader(resolver).read(uri, CancellationSignal()) {}
            assertTrue(result.contentEquals(image))
            result.fill(0)
            val state = SyntheticFilesProvider.state(resolver, uri)
            assertEquals(0, state.getInt(SyntheticFilesProvider.EXTRA_QUERIES))
        } finally {
            SyntheticFilesProvider.remove(resolver, uri)
        }
    }

    @Test fun imageReadDoesNotDeliverBytesAfterTheOperationIsCancelled() {
        val uri = SyntheticFilesProvider.create(resolver, png(2, 2))
        try {
            expectFailure("cancelled") {
                SelectedImageReader(resolver).read(uri, CancellationSignal()) {
                    throw FileAccessFailure("cancelled")
                }
            }
            assertEquals(1, SyntheticFilesProvider.state(resolver, uri)
                .getInt(SyntheticFilesProvider.EXTRA_OPENS))
        } finally {
            SyntheticFilesProvider.remove(resolver, uri)
        }
    }

    @Test fun validatesSyntheticPngAndRejectsBadHeaderAndOversizedDimensions() {
        val valid = png(2, 3)
        SelectedImageReader.validateImage(valid)

        expectFailure("image_rejected") { SelectedImageReader.validateImage("not an image".toByteArray()) }
        expectFailure("image_rejected") { SelectedImageReader.validateImage(oversizedPng(valid)) }
    }

    @Test fun selectedUrisRejectDuplicatesAndNonContentUris() {
        val uri = Uri.parse("content://${SyntheticFilesProvider.AUTHORITY}/document/synthetic_00000000000000000000000000000000")
        val duplicateClip = ClipData(
            ClipDescription("synthetic", arrayOf("text/uri-list")), ClipData.Item(uri),
        ).apply { addItem(ClipData.Item(uri)) }
        expectFailure("invalid_request") {
            FilesChannel.selectedUris(Intent().apply { clipData = duplicateClip }, 3)
        }

        expectFailure("invalid_request") {
            FilesChannel.selectedUris(Intent().setData(Uri.parse("file:///tmp/synthetic.png")), 1)
        }
        assertEquals(listOf(uri), FilesChannel.selectedUris(Intent().setData(uri), 1))
    }

    @Test fun diagnosticDocumentWriterSavesOnlyTheValidatedEnvelope() {
        val contents = diagnosticEnvelope()
        val bytes = DiagnosticDocumentWriter.validate(contents)
        val uri = SyntheticFilesProvider.create(resolver, byteArrayOf())
        try {
            DiagnosticDocumentWriter(resolver).write(uri, bytes, CancellationSignal()) {}
            val state = SyntheticFilesProvider.state(resolver, uri)
            assertTrue(state.getBoolean(SyntheticFilesProvider.EXTRA_EXISTS))
            assertTrue(SyntheticFilesProvider.readContents(resolver, uri).contentEquals(contents.toByteArray()))
            assertEquals(0, state.getInt(SyntheticFilesProvider.EXTRA_DELETE_CALLS))
        } finally {
            bytes.fill(0)
            SyntheticFilesProvider.remove(resolver, uri)
        }
    }

    @Test fun cancelledDiagnosticWriteDeletesThePartialNewDocument() {
        val longRecord = "\"records\":[{\"padding\":\"${"x".repeat(70_000)}\"}]"
        val contents = diagnosticEnvelope().replace("\"records\":[]", longRecord)
        val bytes = DiagnosticDocumentWriter.validate(contents)
        val uri = SyntheticFilesProvider.create(resolver, byteArrayOf())
        var checks = 0
        try {
            expectFailure("cancelled") {
                DiagnosticDocumentWriter(resolver).write(uri, bytes, CancellationSignal()) {
                    checks += 1
                    // Initial guard, first 32 KiB write, then cancel before the next chunk.
                    if (checks == 3) throw FileAccessFailure("cancelled")
                }
            }
            val state = SyntheticFilesProvider.state(resolver, uri)
            assertFalse(state.getBoolean(SyntheticFilesProvider.EXTRA_EXISTS))
            assertTrue(state.getBoolean(SyntheticFilesProvider.EXTRA_DELETED))
            assertEquals(1, state.getInt(SyntheticFilesProvider.EXTRA_DELETE_CALLS))
            assertTrue("Cancellation must occur after some content was written",
                state.getLong(SyntheticFilesProvider.EXTRA_DELETED_LENGTH) > 0L)
            assertTrue("Test must cancel after a partial write", checks == 3)
        } finally {
            bytes.fill(0)
            SyntheticFilesProvider.remove(resolver, uri)
        }
    }

    @Test fun diagnosticEnvelopeRejectsAdditionalFields() {
        val invalid = diagnosticEnvelope().replace("\"complete\":true", "\"complete\":true,\"extra\":\"synthetic\"")
        expectFailure("invalid_request") { DiagnosticDocumentWriter.validate(invalid) }
    }

    private fun expectFailure(code: String, action: () -> Unit) {
        try {
            action()
            throw AssertionError("Expected FileAccessFailure($code)")
        } catch (error: FileAccessFailure) {
            assertEquals(code, error.code)
        }
    }

    private fun png(width: Int, height: Int): ByteArray {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        return try {
            ByteArrayOutputStream().use { output ->
                assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output))
                output.toByteArray()
            }
        } finally {
            bitmap.recycle()
        }
    }

    private fun oversizedPng(source: ByteArray): ByteArray {
        val bytes = source.copyOf()
        fun writeInt(offset: Int, value: Int) {
            for (index in 0..3) bytes[offset + index] = (value ushr (24 - index * 8)).toByte()
        }
        writeInt(16, 4_097)
        writeInt(20, 4_096) // 16,781,312 pixels, above the 16M contract.
        val crc = CRC32().apply { update(bytes, 12, 17) }.value
        writeInt(29, crc.toInt())
        return bytes
    }

    private fun diagnosticEnvelope(): String = """
        {"kind":"ustc-diagnostics-export-v1","exportedAtUtc":"2026-10-16T00:00:00Z",
        "retentionDays":7,"versions":{},"coverage":"retained_recent_events",
        "selectionTruncated":false,"complete":true,"dropped":0,"invalid":0,"records":[]}
    """.trimIndent()
}
