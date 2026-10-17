package cn.ustcassistant.mobile.speech

import android.system.Os
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.FlutterException
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** Uses only small synthetic assets and isolated cache directories. */
@RunWith(AndroidJUnit4::class)
class SpeechModelStoreTest {
    @Test
    fun extractsFixedAssetsOnceAndReusesOnlyVerifiedFiles() = withFixture { fixture ->
        val opens = AtomicInteger()
        val store = fixture.store(SpeechAssetSource { path ->
            opens.incrementAndGet()
            ByteArrayInputStream(fixture.contents.getValue(path))
        })

        val directory = store.prepare()
        assertEquals("sensevoice-int8-2024-07-17", store.version)
        assertEquals(3, opens.get())
        for ((path, bytes) in fixture.contents) {
            val name = path.substringAfterLast('/')
            assertTrue(File(directory, name).readBytes().contentEquals(bytes))
        }

        assertEquals(directory, store.prepare())
        assertEquals("A warm preparation must not reopen verified assets", 3, opens.get())
    }

    @Test
    fun truncatedAndWrongDigestAssetsAreNeverPromoted() = withFixture { fixture ->
        val truncate = AtomicBoolean(true)
        val source = SpeechAssetSource { path ->
            val original = fixture.contents.getValue(path)
            if (path.endsWith("model.int8.onnx") && truncate.compareAndSet(true, false)) {
                ByteArrayInputStream(original.copyOf(original.size - 1))
            } else ByteArrayInputStream(original)
        }
        val store = fixture.store(source)
        assertFails { store.prepare() }
        val modelFile = File(fixture.modelDirectory, "model.int8.onnx")
        assertFalse(modelFile.exists())
        assertFalse(File(fixture.modelDirectory, "model.int8.onnx.tmp").exists())
        assertTrue(File(store.prepare(), "model.int8.onnx").isFile)

        val wrongManifest = fixture.manifest.map { entry ->
            if (entry.fileName == "tokens.txt") entry.copy(sha256 = "0".repeat(64)) else entry
        }
        val wrongDigestStore = fixture.store(
            SpeechAssetSource { path -> ByteArrayInputStream(fixture.contents.getValue(path)) },
            wrongManifest,
        )
        assertFails { wrongDigestStore.prepare() }
        // A rejected replacement must preserve the previously verified file;
        // failure is not permission to delete the last usable public asset.
        assertTrue(File(fixture.modelDirectory, "tokens.txt").readBytes().contentEquals(
            fixture.contents.getValue("speech/sensevoice/tokens.txt"),
        ))
        assertFalse(File(fixture.modelDirectory, "tokens.txt.tmp").exists())

        // The correct fixed manifest repairs a partially prepared directory on retry.
        assertTrue(File(fixture.store().prepare(), "tokens.txt").isFile)
    }

    @Test
    fun sourceFailureCanBeRetriedWithoutReportingReady() = withFixture { fixture ->
        val failOnce = AtomicBoolean(true)
        val source = SpeechAssetSource { path ->
            if (failOnce.compareAndSet(true, false)) throw IOException("synthetic open failure")
            ByteArrayInputStream(fixture.contents.getValue(path))
        }
        val store = fixture.store(source)
        assertFails { store.prepare() }
        assertFalse(File(fixture.modelDirectory, "model.int8.onnx").exists())

        val directory = store.prepare()
        assertTrue(File(directory, "model.int8.onnx").isFile)
        assertTrue(File(directory, "tokens.txt").isFile)
        assertTrue(File(directory, "LICENSE").isFile)
    }

    @Test
    fun concurrentPreparationSerializesExtraction() = withFixture { fixture ->
        val opens = AtomicInteger()
        val store = fixture.store(SpeechAssetSource { path ->
            opens.incrementAndGet()
            ByteArrayInputStream(fixture.contents.getValue(path))
        })
        val pool = Executors.newFixedThreadPool(6)
        try {
            val results = (1..6).map { pool.submit<String> { store.prepare() } }
            val directories = results.map { it.get(5, TimeUnit.SECONDS) }.toSet()
            assertEquals(1, directories.size)
            assertEquals(3, opens.get())
        } finally {
            pool.shutdownNow()
        }
    }

    @Test
    fun separateStoreInstancesShareTheSameExtractionLock() = withFixture { fixture ->
        val opens = AtomicInteger()
        val firstStarted = CountDownLatch(1)
        val releaseFirst = CountDownLatch(1)
        fun newStore() = fixture.store(SpeechAssetSource { path ->
            if (opens.incrementAndGet() == 1) {
                firstStarted.countDown()
                releaseFirst.await(3, TimeUnit.SECONDS)
            }
            ByteArrayInputStream(fixture.contents.getValue(path))
        })

        val first = newStore()
        val second = newStore()
        val pool = Executors.newFixedThreadPool(2)
        try {
            val firstResult = pool.submit<String> { first.prepare() }
            assertTrue(firstStarted.await(3, TimeUnit.SECONDS))
            val secondResult = pool.submit<String> { second.prepare() }
            releaseFirst.countDown()
            assertEquals(firstResult.get(5, TimeUnit.SECONDS), secondResult.get(5, TimeUnit.SECONDS))
            assertEquals("Only one instance should extract the three assets", 3, opens.get())
        } finally {
            releaseFirst.countDown()
            pool.shutdownNow()
        }
    }

    @Test
    fun symlinkedParentAndAssetTargetsAreRejected() = withFixture { fixture ->
        val outsideDirectory = File(fixture.root, "outside").apply { assertTrue(mkdir()) }
        val parentLink = File(fixture.root, "speech_v1")
        Os.symlink(outsideDirectory.absolutePath, parentLink.absolutePath)
        try {
            assertFails { fixture.store().prepare() }
            assertTrue(outsideDirectory.list().orEmpty().isEmpty())
        } finally {
            parentLink.delete()
        }

        val versionDirectory = File(fixture.root, "speech_v1/sensevoice-int8-2024-07-17")
        assertTrue(versionDirectory.mkdirs())
        val outsideFile = File(fixture.root, "outside-model.bin").apply { writeBytes(byteArrayOf(7, 8, 9)) }
        val targetLink = File(versionDirectory, "model.int8.onnx")
        Os.symlink(outsideFile.absolutePath, targetLink.absolutePath)
        try {
            assertFails { fixture.store().prepare() }
            assertTrue(outsideFile.readBytes().contentEquals(byteArrayOf(7, 8, 9)))
        } finally {
            targetLink.delete()
        }
    }

    @Test
    fun noBackupRootAliasesAreRejectedBeforeCanonicalization() = withFixture { fixture ->
        val actualRoot = File(fixture.root, "actual-root").apply { assertTrue(mkdir()) }
        val linkedRoot = File(fixture.root, "linked-root")
        Os.symlink(actualRoot.absolutePath, linkedRoot.absolutePath)
        try {
            val store = SpeechModelStore(
                linkedRoot,
                SpeechAssetSource { path -> ByteArrayInputStream(fixture.contents.getValue(path)) },
                fixture.manifest,
            )
            assertFails { store.prepare() }
            assertTrue(actualRoot.list().orEmpty().isEmpty())
        } finally {
            linkedRoot.delete()
        }
    }

    @Test
    fun channelAcceptsOnlyFixedNoArgumentMethodAndReturnsVerifiedMetadata() = withFixture { fixture ->
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val messenger = FakeMessenger()
        val channel = SpeechModelChannel(context, messenger, fixture.store())
        try {
            val unsupported = messenger.invoke("ustc_assistant/android_speech_v1", "downloadModel", null)
            unsupported.await()
            assertTrue(unsupported.notImplemented)

            val badArguments = messenger.invoke(
                "ustc_assistant/android_speech_v1",
                "prepareModel",
                mapOf("directory" to "/tmp/arbitrary"),
            )
            badArguments.await()
            assertEquals("invalid_request", badArguments.errorCode)

            val prepared = messenger.invoke("ustc_assistant/android_speech_v1", "prepareModel", null).await()
            @Suppress("UNCHECKED_CAST")
            val value = prepared.value as Map<String, Any?>
            assertEquals(setOf("version", "directory"), value.keys)
            assertEquals("sensevoice-int8-2024-07-17", value["version"])
            assertEquals(fixture.modelDirectory.canonicalPath, value["directory"])
        } finally {
            channel.dispose()
        }
    }

    @Test
    fun disposeSuppressesTheResultOfAnInterruptedPreparation() = withFixture { fixture ->
        val entered = CountDownLatch(1)
        val store = fixture.store(SpeechAssetSource {
            entered.countDown()
            try {
                CountDownLatch(1).await()
            } catch (interrupted: InterruptedException) {
                Thread.currentThread().interrupt()
                throw IOException("synthetic interrupted asset open", interrupted)
            }
            ByteArrayInputStream(byteArrayOf())
        })
        val messenger = FakeMessenger()
        val channel = SpeechModelChannel(
            InstrumentationRegistry.getInstrumentation().targetContext,
            messenger,
            store,
        )
        val pending = messenger.invoke("ustc_assistant/android_speech_v1", "prepareModel", null)
        assertTrue(entered.await(3, TimeUnit.SECONDS))
        channel.dispose()

        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
        while (Thread.getAllStackTraces().keys.any { it.name == "speech-model-store" } &&
            System.nanoTime() < deadline
        ) {
            Thread.sleep(5)
        }
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        assertEquals("dispose should complete the request once with a closed result", "closed", pending.await().errorCode)
        assertEquals(1, pending.replyCount)
    }

    private fun withFixture(block: (Fixture) -> Unit) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.cacheDir.canonicalFile, "speech-model-test-${UUID.randomUUID()}")
        assertTrue(root.mkdir())
        val fixture = Fixture(root)
        try {
            block(fixture)
        } finally {
            fixture.cleanup()
        }
    }

    private class Fixture(val root: File) {
        val contents = linkedMapOf(
            "${ASSET_ROOT}model.int8.onnx" to "synthetic model weights\n".toByteArray(),
            "${ASSET_ROOT}tokens.txt" to "<blank>\n你好\n".toByteArray(),
            "${ASSET_ROOT}LICENSE" to "synthetic license\n".toByteArray(),
        )
        val manifest = buildManifest(contents)
        val modelDirectory: File
            get() = File(root, "speech_v1/sensevoice-int8-2024-07-17")

        fun store(
            source: SpeechAssetSource = SpeechAssetSource { path ->
                ByteArrayInputStream(contents.getValue(path))
            },
            suppliedManifest: List<SpeechModelAsset> = manifest,
        ) = SpeechModelStore(root, source, suppliedManifest)

        fun cleanup() {
            root.deleteRecursively()
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
            assertTrue("MethodChannel result was not completed", completed.await(5, TimeUnit.SECONDS))
            return this
        }
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

    private fun assertFails(action: () -> Unit) {
        try {
            action()
            throw AssertionError("Expected synthetic model preparation to fail")
        } catch (_: IOException) {
            // Expected integrity, path, or source failure.
        }
    }

    private companion object {
        const val ASSET_ROOT = "speech/sensevoice/"

        fun buildManifest(contents: Map<String, ByteArray>): List<SpeechModelAsset> =
            listOf("model.int8.onnx", "tokens.txt", "LICENSE").map { fileName ->
                val path = "$ASSET_ROOT$fileName"
                val bytes = contents.getValue(path)
                SpeechModelAsset(path, fileName, bytes.size.toLong(), sha256(bytes))
            }

        fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
            .digest(bytes)
            .joinToString(separator = "") { byte -> "%02x".format(byte.toInt() and 0xff) }

        fun readable(buffer: ByteBuffer): ByteBuffer = buffer.duplicate().apply {
            val written = position()
            position(0)
            limit(written)
        }
    }
}
