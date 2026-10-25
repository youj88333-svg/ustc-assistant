package cn.ustcassistant.mobile.files

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.graphics.Bitmap
import android.provider.MediaStore
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.FlutterException
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.nio.ByteBuffer
import java.io.ByteArrayOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Exercises method-channel routing and activity-result ownership without opening system UI. */
@RunWith(AndroidJUnit4::class)
class FilesChannelLifecycleTest {
    @Test fun imageSelectionReturnsEncodedCopiesThroughTheRealCodecThenReleasesItsSlot() {
        val fixture = Fixture.create()
        val resolver = InstrumentationRegistry.getInstrumentation().targetContext.contentResolver
        val bitmap = Bitmap.createBitmap(2, 3, Bitmap.Config.ARGB_8888)
        val bytes = try { ByteArrayOutputStream().use { output ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
            output.toByteArray()
        } } finally { bitmap.recycle() }
        val uri = SyntheticFilesProvider.create(resolver, bytes)
        try {
            val pending = fixture.invoke("pickImages", mapOf("maximumCount" to 3))
            val request = fixture.host.nextRequest()
            fixture.activityResult(request.requestCode, Activity.RESULT_OK, Intent().setData(uri))
            pending.await()
            assertTrue((pending.value as List<*>).single() is ByteArray)
            assertTrue(((pending.value as List<*>).single() as ByteArray).contentEquals(bytes))
            assertEquals(1, pending.replyCount)
            val next = fixture.invoke("pickImages", mapOf("maximumCount" to 1))
            fixture.activityResult(fixture.host.nextRequest().requestCode, Activity.RESULT_CANCELED, null)
            next.await()
            assertEquals(emptyList<ByteArray>(), next.value)
        } finally { fixture.close(); bytes.fill(0); SyntheticFilesProvider.remove(resolver, uri) }
    }

    @Test fun providerTimeoutRepliesOnceAndDoesNotReleaseTheSlotUntilIODrains() {
        val fixture = Fixture.create(ioTimeoutMillis = 200)
        val resolver = InstrumentationRegistry.getInstrumentation().targetContext.contentResolver
        val uri = SyntheticFilesProvider.createBlocked(resolver, byteArrayOf())
        try {
            val pending = fixture.invoke("saveDiagnosticLog", mapOf("contents" to validEnvelope()))
            fixture.activityResult(fixture.host.nextRequest().requestCode, Activity.RESULT_OK, Intent().setData(uri))
            assertTrue(SyntheticFilesProvider.awaitOpen(resolver, uri))
            pending.await()
            assertEquals("timeout", pending.errorCode)
            val blocked = fixture.invoke("pickImages", mapOf("maximumCount" to 1))
            blocked.await()
            assertEquals("busy", blocked.errorCode)
            SyntheticFilesProvider.releaseOpen(resolver, uri)
            assertTrue(SyntheticFilesProvider.awaitDeleted(resolver, uri))
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            assertEquals(1, pending.replyCount)
        } finally { SyntheticFilesProvider.releaseOpen(resolver, uri); fixture.close(); SyntheticFilesProvider.remove(resolver, uri) }
    }
    @Test fun methodChannelExposesOnlyTheTwoFixedMethodsAndExactArgumentShapes() {
        val fixture = Fixture.create()
        try {
            val unknown = fixture.invoke("pickImage", emptyMap<String, Any?>())
            unknown.await()
            assertTrue(unknown.notImplemented)

            val badPicker = fixture.invoke("pickImages", mapOf("maximumCount" to 4))
            badPicker.await()
            assertEquals("invalid_request", badPicker.errorCode)

            val badSaver = fixture.invoke("saveDiagnosticLog", mapOf(
                "contents" to validEnvelope(), "path" to "/tmp/anything",
            ))
            badSaver.await()
            assertEquals("invalid_request", badSaver.errorCode)
            assertFalse(fixture.host.hasPendingRequest())

            val fallback = fixture.channel.imagePickerIntent(3, usePhotoPicker = false)
            assertEquals(Intent.ACTION_OPEN_DOCUMENT, fallback.action)
            assertTrue(fallback.hasCategory(Intent.CATEGORY_OPENABLE))
            assertTrue(fallback.getBooleanExtra(Intent.EXTRA_ALLOW_MULTIPLE, false))
            assertTrue(fallback.getStringArrayExtra(Intent.EXTRA_MIME_TYPES)!!.toSet() ==
                setOf("image/png", "image/jpeg", "image/webp"))
        } finally {
            fixture.close()
        }
    }

    @Test fun pickerCancellationCompletesEmptyAndWrongOrLateRequestCodesCannotConsumeNextOperation() {
        val fixture = Fixture.create()
        try {
            val firstCall = fixture.invoke("pickImages", mapOf("maximumCount" to 1))
            val firstRequest = fixture.host.nextRequest()
            assertTrue(firstRequest.requestCode in 0x4a00..0x59ff)
            assertEquals("image/*", firstRequest.intent.type)
            assertTrue(firstRequest.intent.action == MediaStore.ACTION_PICK_IMAGES ||
                firstRequest.intent.action == Intent.ACTION_OPEN_DOCUMENT)
            assertEquals(0, firstRequest.intent.flags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            fixture.hostStopped()
            assertFalse("Opening a picker must not cancel its selection", firstCall.isComplete())

            assertTrue(fixture.activityResult(firstRequest.requestCode, Activity.RESULT_CANCELED, null))
            firstCall.await()
            assertEquals(emptyList<ByteArray>(), firstCall.value)

            val secondCall = fixture.invoke("pickImages", mapOf("maximumCount" to 1))
            val secondRequest = fixture.host.nextRequest()
            assertNotEquals(firstRequest.requestCode, secondRequest.requestCode)

            val staleFileUri = Uri.parse("file:///tmp/stale-synthetic.png")
            assertTrue(fixture.activityResult(firstRequest.requestCode, Activity.RESULT_OK,
                Intent().setData(staleFileUri)))
            assertFalse("A late result must leave the newer call pending", secondCall.isComplete())
            assertFalse(fixture.activityResult(0x6000, Activity.RESULT_OK, Intent().setData(staleFileUri)))

            assertTrue(fixture.activityResult(secondRequest.requestCode, Activity.RESULT_CANCELED, null))
            secondCall.await()
            assertEquals(emptyList<ByteArray>(), secondCall.value)
            assertEquals(1, secondCall.replyCount)
        } finally {
            fixture.close()
        }
    }

    @Test fun savePickerCancellationReturnsNotSavedAndDisposeRejectsLateCompletion() {
        val fixture = Fixture.create()
        try {
            val cancelledSave = fixture.invoke("saveDiagnosticLog", mapOf("contents" to validEnvelope()))
            val cancelledRequest = fixture.host.nextRequest()
            assertEquals(Intent.ACTION_CREATE_DOCUMENT, cancelledRequest.intent.action)
            assertEquals("application/json", cancelledRequest.intent.type)
            assertEquals(0, cancelledRequest.intent.flags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            assertTrue(fixture.activityResult(cancelledRequest.requestCode, Activity.RESULT_CANCELED, null))
            cancelledSave.await()
            assertEquals(false, cancelledSave.value)

            val pending = fixture.invoke("pickImages", mapOf("maximumCount" to 1))
            val request = fixture.host.nextRequest()
            fixture.dispose()
            pending.await()
            assertEquals("cancelled", pending.errorCode)
            assertFalse(fixture.messenger.hasHandler("ustc_assistant/files_v1"))

            val lateUri = Uri.parse("content://cn.ustcassistant.mobile.qa.synthetic-files/document/synthetic_00000000000000000000000000000000")
            assertTrue(fixture.activityResult(request.requestCode, Activity.RESULT_OK, Intent().setData(lateUri)))
            assertEquals(1, pending.replyCount)
            assertFalse(fixture.host.hasPendingRequest())
        } finally {
            fixture.close()
        }
    }

    @Test fun disposeCancelsAnInFlightProviderWriteAndSuppressesItsLateReply() {
        val fixture = Fixture.create()
        val resolver = InstrumentationRegistry.getInstrumentation().targetContext.contentResolver
        var uri: Uri? = null
        try {
            val document = SyntheticFilesProvider.createBlocked(resolver, byteArrayOf())
            uri = document
            val pending = fixture.invoke("saveDiagnosticLog", mapOf("contents" to validEnvelope()))
            val request = fixture.host.nextRequest()
            assertTrue(fixture.activityResult(request.requestCode, Activity.RESULT_OK, Intent().setData(document)))
            assertTrue("Synthetic provider should have the write open", SyntheticFilesProvider.awaitOpen(resolver, document))

            fixture.hostStopped()
            pending.await()
            assertEquals("cancelled", pending.errorCode)
            assertEquals(1, pending.replyCount)
            fixture.dispose()

            // Let the blocked provider return so the worker can observe cancellation and drain.
            SyntheticFilesProvider.releaseOpen(resolver, document)
            assertTrue("Canceled partial document should be deleted", SyntheticFilesProvider.awaitDeleted(resolver, document))
            val state = SyntheticFilesProvider.state(resolver, document)
            assertFalse(state.getBoolean(SyntheticFilesProvider.EXTRA_EXISTS))
            assertEquals(1, state.getInt(SyntheticFilesProvider.EXTRA_DELETE_CALLS))
            assertEquals(1, pending.replyCount)
        } finally {
            uri?.let { SyntheticFilesProvider.remove(resolver, it) }
            fixture.close()
        }
    }

    private class Fixture private constructor(
        val host: FilesBridgeHostActivity,
        val messenger: FakeMessenger,
        val channel: FilesChannel,
    ) : AutoCloseable {
        private var closed = false

        fun invoke(method: String, args: Any?): CapturedCall {
            var result: CapturedCall? = null
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                result = messenger.invoke(CHANNEL, method, args)
            }
            return requireNotNull(result)
        }

        fun activityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
            var handled = false
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                handled = channel.onActivityResult(requestCode, resultCode, data)
            }
            return handled
        }

        fun dispose() {
            InstrumentationRegistry.getInstrumentation().runOnMainSync { channel.dispose() }
        }

        fun hostStopped() {
            InstrumentationRegistry.getInstrumentation().runOnMainSync { channel.onHostStopped() }
        }

        override fun close() {
            if (closed) return
            closed = true
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                channel.dispose()
                host.finish()
            }
        }

        companion object {
            private const val CHANNEL = "ustc_assistant/files_v1"

            fun create(ioTimeoutMillis: Long = 30_000): Fixture {
                val instrumentation = InstrumentationRegistry.getInstrumentation()
                val intent = Intent(instrumentation.targetContext, FilesBridgeHostActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                val host = instrumentation.startActivitySync(intent) as FilesBridgeHostActivity
                val messenger = FakeMessenger()
                var channel: FilesChannel? = null
                instrumentation.runOnMainSync { channel = FilesChannel(host, messenger, ioTimeoutMillis) }
                return Fixture(host, messenger, requireNotNull(channel))
            }
        }
    }

    private class CapturedCall {
        private val completed = CountDownLatch(1)
        @Volatile var value: Any? = null
            private set
        @Volatile var errorCode: String? = null
            private set
        @Volatile var notImplemented = false
            private set
        @Volatile var replyCount = 0
            private set

        fun reply(envelope: ByteBuffer?) {
            replyCount += 1
            if (envelope == null) {
                notImplemented = true
            } else {
                try {
                    value = StandardMethodCodec.INSTANCE.decodeEnvelope(readable(envelope))
                } catch (error: FlutterException) {
                    errorCode = error.code
                }
            }
            completed.countDown()
        }

        fun await(): CapturedCall {
            assertTrue("MethodChannel result was not completed", completed.await(3, TimeUnit.SECONDS))
            return this
        }

        fun isComplete(): Boolean = completed.count == 0L
    }

    private class FakeMessenger : BinaryMessenger {
        private val handlers = mutableMapOf<String, BinaryMessenger.BinaryMessageHandler>()

        override fun send(channel: String, message: ByteBuffer?) = Unit

        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            callback?.reply(null)
        }

        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            if (handler == null) handlers.remove(channel) else handlers[channel] = handler
        }

        fun hasHandler(channel: String): Boolean = handlers.containsKey(channel)

        fun invoke(channel: String, method: String, arguments: Any?): CapturedCall {
            val handler = handlers[channel]
            assertNotNull("No method handler is registered for $channel", handler)
            val result = CapturedCall()
            handler!!.onMessage(
                readable(StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall(method, arguments))),
                BinaryMessenger.BinaryReply(result::reply),
            )
            return result
        }
    }

    companion object {
        private fun readable(buffer: ByteBuffer): ByteBuffer = buffer.duplicate().apply {
            val written = position()
            position(0)
            limit(written)
        }

        private fun validEnvelope(): String = """
            {"kind":"ustc-diagnostics-export-v1","exportedAtUtc":"2026-10-16T00:00:00Z",
            "retentionDays":7,"versions":{},"coverage":"retained_recent_events",
            "selectionTruncated":false,"complete":true,"dropped":0,"invalid":0,"records":[]}
        """.trimIndent()
    }
}
