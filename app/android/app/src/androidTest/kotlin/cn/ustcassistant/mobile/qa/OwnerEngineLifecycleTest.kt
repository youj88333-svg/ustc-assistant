package cn.ustcassistant.mobile.qa

import android.content.Context
import android.os.Build
import android.os.SystemClock
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.system.StructStat
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Uses real FlutterEngine instances and only a QA-private synthetic SQLite database. */
@RunWith(AndroidJUnit4::class)
class OwnerEngineLifecycleTest {
    @Before
    fun requireDedicatedDartProbeBuild() {
        // Ordinary APKs deliberately exclude the Dart test entrypoint. Keep
        // the regular all-native suite usable, while explicit probe runs fail
        // strictly if their compiled entrypoint is missing or broken.
        assumeTrue(
            "Build tool/android_owner_lifecycle_probe.dart and opt in to this dedicated suite.",
            InstrumentationRegistry.getArguments().getString("ustc_owner_lifecycle_probe") == "true",
        )
    }

    @Test
    fun destroyingAnUnclosedOwnerReleasesItAndPreservesTheSyntheticDatabase() {
        val context = requireApi34QaContext()
        initializeFlutter(context)

        repeat(2) {
            runAbruptDestroyRound(context)
        }
    }

    @Test
    fun demoReleaseKeepsFormalOwnershipAndRepeatedOldCloseCannotReleaseANewOwner() {
        val context = requireApi34QaContext()
        initializeFlutter(context)
        val root = createPrivateRoot(context)
        val sessions = mutableListOf<EngineSession>()
        var passed = false
        try {
            val oldOwner = startEngine(context).also(sessions::add)
            assertCode(oldOwner.call("acquire", root.path), "acquired")
            assertSentinel(oldOwner.call("commitSentinel"), "committed")

            assertCode(oldOwner.call("releaseDemo"), "demoReleased")
            val contender = startEngine(context).also(sessions::add)
            assertCode(contender.call("acquire", root.path), "ownerConflict")

            // The demo database and its child lease are already closed. Repeated
            // close now releases only the remaining formal child lease once.
            assertCode(oldOwner.call("close"), "closed")
            assertCode(oldOwner.call("close"), "closed")

            val currentOwner = startEngine(context).also(sessions::add)
            assertCode(currentOwner.call("acquire", root.path), "acquired")
            assertSentinel(currentOwner.call("readSentinel"), "read")

            // A stale close and subsequent engine destruction must not release
            // a descriptor now owned by currentOwner.
            assertCode(oldOwner.call("close"), "closed")
            oldOwner.destroy()
            assertCode(contender.call("acquire", root.path), "ownerConflict")
            assertSentinel(currentOwner.call("readSentinel"), "read")

            currentOwner.destroy()
            assertEquals("acquired", acquireWithin(contender, root.path, OWNER_TIMEOUT_MS))
            assertSentinel(contender.call("readSentinel"), "read")
            assertCode(contender.call("close"), "closed")
            assertCode(contender.call("close"), "closed")
            passed = true
        } finally {
            destroyRemaining(sessions)
            if (passed) {
                assertTrue("The released QA fixture could not be safely removed.",
                    cleanupRootIfUnowned(context, root))
            } else {
                runCatching { cleanupRootIfUnowned(context, root) }
            }
        }
    }

    private fun runAbruptDestroyRound(context: Context) {
        val root = createPrivateRoot(context)
        val sessions = mutableListOf<EngineSession>()
        var passed = false
        try {
            val oldOwner = startEngine(context).also(sessions::add)
            assertCode(oldOwner.call("acquire", root.path), "acquired")
            assertSentinel(oldOwner.call("commitSentinel"), "committed")

            val successor = startEngine(context).also(sessions::add)
            assertCode(successor.call("acquire", root.path), "ownerConflict")

            // This is the lifecycle under test: do not call Dart close first.
            oldOwner.destroy()

            assertEquals("acquired", acquireWithin(successor, root.path, OWNER_TIMEOUT_MS))
            assertSentinel(successor.call("readSentinel"), "read")
            assertCode(successor.call("close"), "closed")
            assertCode(successor.call("close"), "closed")
            successor.destroy()
            passed = true
        } finally {
            destroyRemaining(sessions)
            if (passed) {
                assertTrue("The released QA fixture could not be safely removed.",
                    cleanupRootIfUnowned(context, root))
            } else {
                runCatching { cleanupRootIfUnowned(context, root) }
            }
        }
    }

    private fun acquireWithin(session: EngineSession, rootPath: String, timeoutMs: Long): String {
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        do {
            val code = replyCode(session.call("acquire", rootPath))
            if (code == "acquired") return code
            assertEquals("Only the expected owner conflict may be retried.", "ownerConflict", code)
            SystemClock.sleep(50L)
        } while (SystemClock.elapsedRealtime() < deadline)
        throw AssertionError("A fresh FlutterEngine could not acquire the released owner within five seconds.")
    }

    private fun startEngine(context: Context): EngineSession {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val loader = FlutterInjector.instance().flutterLoader()
        val ready = CountDownLatch(1)
        val handshakeValid = AtomicBoolean(false)
        val engineRef = AtomicReference<FlutterEngine>()
        val channelRef = AtomicReference<MethodChannel>()
        instrumentation.runOnMainSync {
            val engine = FlutterEngine(context.applicationContext, null, false)
            val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL_NAME)
            channel.setMethodCallHandler { call, result ->
                if (call.method != "ready") {
                    result.notImplemented()
                } else {
                    val arguments = call.arguments as? Map<*, *>
                    val valid = arguments?.keys == setOf("protocol") &&
                        arguments["protocol"] == PROTOCOL
                    handshakeValid.set(valid)
                    if (valid) result.success(null) else result.error("invalid_handshake", null, null)
                    ready.countDown()
                }
            }
            engineRef.set(engine)
            channelRef.set(channel)
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(
                    loader.findAppBundlePath(),
                    PROBE_LIBRARY,
                    PROBE_FUNCTION,
                ),
            )
        }
        if (!ready.await(ENGINE_READY_TIMEOUT_SECONDS, TimeUnit.SECONDS) || !handshakeValid.get()) {
            instrumentation.runOnMainSync { engineRef.get()?.destroy() }
            throw AssertionError("The isolated Dart lifecycle probe did not complete its ready handshake.")
        }
        return EngineSession(engineRef.get(), channelRef.get())
    }

    private fun initializeFlutter(context: Context) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(context.applicationContext)
            loader.ensureInitializationComplete(context.applicationContext, null)
        }
    }

    private fun requireApi34QaContext(): Context {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        assertEquals("Instrumentation must target the isolated QA package.", QA_PACKAGE, context.packageName)
        assertEquals("This lifecycle contract is pinned to the isolated API 34 AVD.", 34, Build.VERSION.SDK_INT)
        return context
    }

    private fun createPrivateRoot(context: Context): PrivateRoot {
        assertEquals(QA_PACKAGE, context.packageName)
        // Resolve this trusted Context root exactly as PlatformChannel does;
        // /data/user/0 and /data/data may be aliases on the system image.
        val noBackup = context.noBackupFilesDir.canonicalFile
        assertEquals(noBackup.path, noBackup.canonicalFile.path)
        assertDirectory(noBackup)

        val parent = File(noBackup, "ustc_assistant_v1")
        if (lstatOrNull(parent) == null) assertTrue("Could not create the QA private root.", parent.mkdir())
        assertDirectory(parent)
        assertEquals(noBackup.path, parent.canonicalFile.parentFile?.path)

        val root = File(parent, "owner_lifecycle_test_${UUID.randomUUID()}")
        assertTrue(ROOT_NAME.matches(root.name))
        assertEquals(parent.canonicalPath, root.parentFile?.canonicalPath)
        assertTrue("The UUID lifecycle fixture already exists.", lstatOrNull(root) == null)
        assertTrue("Could not create the UUID lifecycle fixture.", root.mkdir())
        assertDirectory(root)
        assertEquals(root.absolutePath, root.canonicalPath)
        return PrivateRoot(root, parent)
    }

    private fun cleanupRootIfUnowned(context: Context, root: PrivateRoot): Boolean {
        val verified = verifyFixturePath(context, root) ?: return false
        val verifier = startEngine(context)
        var safeToDelete = false
        try {
            val acquired = verifier.call("acquire", verified.path)
            if (replyCode(acquired) != "acquired") return false
            assertCode(verifier.call("close"), "closed")
            safeToDelete = true
        } finally {
            verifier.destroy()
        }
        if (!safeToDelete) return false
        verifyFixturePath(context, root) ?: return false
        deleteTreeWithoutFollowingLinks(verified)
        assertTrue("The exact QA fixture remains after cleanup.", lstatOrNull(verified) == null)
        return true
    }

    private fun verifyFixturePath(context: Context, root: PrivateRoot): File? {
        if (context.packageName != QA_PACKAGE || !ROOT_NAME.matches(root.file.name)) return null
        val noBackup = context.noBackupFilesDir.canonicalFile
        val parent = root.parent.canonicalFile
        if (parent.path != File(noBackup, "ustc_assistant_v1").canonicalPath) return null
        if (root.file.parentFile?.canonicalFile != parent) return null
        val stat = lstatOrNull(root.file) ?: return null
        if ((stat.st_mode and OsConstants.S_IFMT) != OsConstants.S_IFDIR) return null
        if (root.file.canonicalFile.path != root.file.absoluteFile.path) return null
        return root.file
    }

    private fun deleteTreeWithoutFollowingLinks(node: File) {
        val stat = lstatOrNull(node) ?: return
        when (stat.st_mode and OsConstants.S_IFMT) {
            OsConstants.S_IFDIR -> {
                assertEquals(node.absolutePath, node.canonicalPath)
                val children = node.listFiles() ?: throw AssertionError("Could not enumerate the test-owned fixture.")
                children.forEach(::deleteTreeWithoutFollowingLinks)
            }
            OsConstants.S_IFREG -> assertEquals(node.absolutePath, node.canonicalPath)
            else -> throw AssertionError("Refusing to remove an unexpected fixture node type.")
        }
        assertTrue("Could not remove a node from the exact QA fixture.", node.delete())
    }

    private fun assertDirectory(directory: File) {
        val stat = lstatOrNull(directory) ?: throw AssertionError("The QA private directory is missing.")
        assertEquals(OsConstants.S_IFDIR, stat.st_mode and OsConstants.S_IFMT)
        assertEquals(directory.absolutePath, directory.canonicalPath)
    }

    private fun lstatOrNull(file: File): StructStat? = try {
        Os.lstat(file.path)
    } catch (error: ErrnoException) {
        if (error.errno == OsConstants.ENOENT) null else throw AssertionError("Could not inspect the QA fixture path.")
    }

    private fun destroyRemaining(sessions: List<EngineSession>) {
        sessions.asReversed().forEach { session ->
            if (!session.destroyed) {
                runCatching { session.call("close") }
                session.destroy()
            }
        }
    }

    private fun assertCode(reply: Map<*, *>, expected: String) {
        assertEquals(setOf("code"), reply.keys)
        assertEquals(expected, reply["code"])
    }

    private fun assertSentinel(reply: Map<*, *>, expectedCode: String) {
        assertEquals(setOf("code", "sentinel"), reply.keys)
        assertEquals(expectedCode, reply["code"])
        assertEquals(SENTINEL, reply["sentinel"])
    }

    private fun replyCode(reply: Map<*, *>): String {
        assertEquals(setOf("code"), reply.keys)
        return reply["code"] as? String ?: throw AssertionError("The lifecycle probe omitted its fixed result code.")
    }

    private data class PrivateRoot(val file: File, val parent: File) {
        val path: String get() = file.canonicalPath
    }

    private class EngineSession(
        private var engine: FlutterEngine?,
        private val channel: MethodChannel,
    ) {
        private val instrumentation = InstrumentationRegistry.getInstrumentation()
        var destroyed = false
            private set

        fun call(method: String, arguments: Any? = null): Map<*, *> {
            check(!destroyed) { "A destroyed FlutterEngine cannot receive lifecycle commands." }
            val completed = CountDownLatch(1)
            val value = AtomicReference<Any?>()
            val failed = AtomicBoolean(false)
            instrumentation.runOnMainSync {
                channel.invokeMethod(method, arguments, object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        value.set(result)
                        completed.countDown()
                    }

                    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                        failed.set(true)
                        completed.countDown()
                    }

                    override fun notImplemented() {
                        failed.set(true)
                        completed.countDown()
                    }
                })
            }
            assertTrue("The Dart lifecycle command timed out.",
                completed.await(COMMAND_TIMEOUT_SECONDS, TimeUnit.SECONDS))
            assertFalse("The Dart lifecycle command returned a channel error.", failed.get())
            return value.get() as? Map<*, *>
                ?: throw AssertionError("The Dart lifecycle command did not return its fixed result map.")
        }

        fun destroy() {
            if (destroyed) return
            instrumentation.runOnMainSync {
                channel.setMethodCallHandler(null)
                engine?.destroy()
                engine = null
            }
            destroyed = true
        }
    }

    private companion object {
        private const val QA_PACKAGE = "cn.ustcassistant.mobile.qa"
        private const val CHANNEL_NAME = "ustc_assistant/qa_owner_lifecycle_v1"
        private const val PROTOCOL = "owner-lifecycle-v1"
        private const val PROBE_LIBRARY =
            "package:ustc_assistant_m0/testing/android_owner_lifecycle_probe.dart"
        private const val PROBE_FUNCTION = "ownerLifecycleProbe"
        private const val ENGINE_READY_TIMEOUT_SECONDS = 20L
        private const val COMMAND_TIMEOUT_SECONDS = 15L
        private const val OWNER_TIMEOUT_MS = 5_000L
        private const val SENTINEL = 17
        private val ROOT_NAME = Regex(
            "^owner_lifecycle_test_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
        )
    }
}
