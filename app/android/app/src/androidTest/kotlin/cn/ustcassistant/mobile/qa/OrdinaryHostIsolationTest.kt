package cn.ustcassistant.mobile.qa

import android.app.Activity
import android.app.ActivityManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Message
import android.os.Messenger
import android.os.Process
import android.os.SystemClock
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.system.StructStat
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import cn.ustcassistant.mobile.browser.BrowserProtocol
import cn.ustcassistant.mobile.browser.SchoolHostService
import cn.ustcassistant.mobile.browser.SchoolHostSlot
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.BufferedReader
import java.io.Closeable
import java.io.File
import java.io.InputStreamReader
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Exercises actual :school_host WebViews with only synthetic loopback pages and random suffixes. */
@RunWith(AndroidJUnit4::class)
class OrdinaryHostIsolationTest {
    @Test
    fun cookieDomIndexedDbAndCacheStorageStayInsideTheirSuffix() {
        assumeTrue("setDataDirectorySuffix requires API 28+; device API=${Build.VERSION.SDK_INT}",
            Build.VERSION.SDK_INT >= 28)
        withQaActivity { activity, context ->
            val server = LoopbackFixtureServer()
            val suffixA = newSuffix(context)
            val suffixB = newSuffix(context)
            assertNotEquals(suffixA, suffixB)
            val cleaned = mutableSetOf<String>()
            var active: HostSession? = null
            server.start()
            try {
                val seedHost = HostSession(activity, context, server, suffixA, "/seed-storage", 101L)
                active = seedHost
                seedHost.start()
                val seed = server.awaitStorageReport("storage-seed")
                assertTrue(
                    "Loopback storage capabilities: secureContext=${seed.secureContext}, " +
                        "indexedDB=${seed.indexedDbApi}, CacheStorage=${seed.cacheStorageApi}.",
                    seed.secureContext && seed.indexedDbApi && seed.cacheStorageApi,
                )
                assertTrue("Suffix A must write its own cookie.", seed.cookie)
                assertTrue("Suffix A must write its own DOM storage marker.", seed.domStorage)
                assertTrue("Suffix A must commit its IndexedDB marker.", seed.indexedDb)
                assertTrue("Suffix A must commit its CacheStorage marker.", seed.cacheStorage)
                drain(seedHost, cleaned)
                active = null

                val suffixBHost = HostSession(activity, context, server, suffixB, "/verify-storage-b", 202L)
                active = suffixBHost
                suffixBHost.start()
                val isolated = server.awaitStorageReport("storage-b")
                assertTrue(
                    "Suffix B loopback storage capabilities: secureContext=${isolated.secureContext}, " +
                        "indexedDB=${isolated.indexedDbApi}, CacheStorage=${isolated.cacheStorageApi}.",
                    isolated.secureContext && isolated.indexedDbApi && isolated.cacheStorageApi,
                )
                assertFalse("Cookie crossed from suffix A to B.", isolated.cookie)
                assertFalse("DOM storage crossed from suffix A to B.", isolated.domStorage)
                assertFalse("IndexedDB crossed from suffix A to B.", isolated.indexedDb)
                assertFalse("CacheStorage crossed from suffix A to B.", isolated.cacheStorage)
                drain(suffixBHost, cleaned)
                active = null

                val retainedHost = HostSession(activity, context, server, suffixA, "/verify-storage-a", 303L)
                active = retainedHost
                retainedHost.start()
                val retained = server.awaitStorageReport("storage-a")
                assertTrue("Suffix A cookie did not survive host process exit.", retained.cookie)
                assertTrue("Suffix A DOM storage did not survive host process exit.", retained.domStorage)
                assertTrue("Suffix A IndexedDB did not survive host process exit.", retained.indexedDb)
                assertTrue("Suffix A CacheStorage did not survive host process exit.", retained.cacheStorage)
                drain(retainedHost, cleaned)
                active = null
            } finally {
                try {
                    active?.let { if (it.shutdownAndDrain()) cleaned.add(it.suffix) }
                } finally {
                    try {
                        server.close()
                    } finally {
                        cleaned.forEach { deleteOnlySuffixTrees(context, it) }
                    }
                }
            }
        }
    }

    @Test
    fun serviceWorkerRegistrationIsSuffixIsolatedAndWorkerPingsStopWithHost() {
        assumeTrue("setDataDirectorySuffix requires API 28+; device API=${Build.VERSION.SDK_INT}",
            Build.VERSION.SDK_INT >= 28)
        withQaActivity { activity, context ->
            val server = LoopbackFixtureServer()
            val suffixA = newSuffix(context)
            val suffixB = newSuffix(context)
            val cleaned = mutableSetOf<String>()
            var active: HostSession? = null
            server.start()
            try {
                val seedHost = HostSession(activity, context, server, suffixA, "/seed-worker", 404L)
                active = seedHost
                seedHost.start()
                val workerSeed = server.awaitWorkerReport("worker-seed")
                val supported = workerSeed.secureContext && workerSeed.serviceWorkerApi
                if (!supported) {
                    drain(seedHost, cleaned)
                    active = null
                    assumeTrue(
                        "Worker isolation is explicitly skipped: loopback secureContext=${workerSeed.secureContext}, " +
                            "serviceWorkerApi=${workerSeed.serviceWorkerApi}.",
                        supported,
                    )
                }
                assertTrue("The synthetic Service Worker did not register and control its loopback page.",
                    workerSeed.registered && workerSeed.controlled)
                assertTrue("The Service Worker fixture did not produce two loopback pings.",
                    server.awaitWorkerPings(2, 10_000L))
                drain(seedHost, cleaned)
                active = null
                assertTrue("Worker pings continued after the actual host PID exited and its slot drained.",
                    server.noWorkerPingsFor(1_200L))

                val suffixBHost = HostSession(activity, context, server, suffixB, "/verify-worker-b", 505L)
                active = suffixBHost
                suffixBHost.start()
                val workerB = server.awaitWorkerReport("worker-b")
                assertTrue(workerB.secureContext && workerB.serviceWorkerApi)
                assertFalse("The service-worker registration crossed from suffix A to B.", workerB.registered)
                assertFalse("A page in suffix B was controlled by suffix A's worker.", workerB.controlled)
                drain(suffixBHost, cleaned)
                active = null

                val retainedHost = HostSession(activity, context, server, suffixA, "/verify-worker-a", 606L)
                active = retainedHost
                retainedHost.start()
                val workerA = server.awaitWorkerReport("worker-a")
                assertTrue("Suffix A's service-worker registration did not survive host process exit.",
                    workerA.registered)
                assertTrue("Suffix A's page was not controlled by its retained service worker.",
                    workerA.controlled)
                drain(retainedHost, cleaned)
                active = null
            } finally {
                try {
                    active?.let { if (it.shutdownAndDrain()) cleaned.add(it.suffix) }
                } finally {
                    try {
                        server.close()
                    } finally {
                        cleaned.forEach { deleteOnlySuffixTrees(context, it) }
                    }
                }
            }
        }
    }

    @Test
    fun killingTheQaParentProcessDrainsItsChildAndStopsWorkerPings() {
        assumeTrue("setDataDirectorySuffix requires API 28+; device API=${Build.VERSION.SDK_INT}",
            Build.VERSION.SDK_INT >= 28)
        withQaActivity { activity, context ->
            val server = LoopbackFixtureServer()
            val suffix = newSuffix(context)
            var parent: QaBrowserParentSession? = null
            var parentPid = -1
            var parentStamp: ProcessStamp? = null
            var hostPid = -1
            var hostStamp: ProcessStamp? = null
            var hostDrainProven = false
            server.start()
            try {
                val activeParent = QaBrowserParentSession(context, server, suffix).start()
                parent = activeParent
                parentPid = activeParent.parentPid
                assertNotEquals("The synthetic parent must not be instrumentation.", Process.myPid(), parentPid)
                val parentInfo = waitForNamedProcess(
                    context,
                    parentPid,
                    "${context.packageName}:qa_browser_parent",
                    5_000L,
                ) ?: throw AssertionError("The QA parent PID was not visible in its dedicated process.")
                assertEquals(context.applicationInfo.uid, parentInfo.uid)
                val originalParentStamp = readProcessStamp(parentPid)
                    ?: throw AssertionError("Could not record the synthetic parent process identity.")
                parentStamp = originalParentStamp

                val connected = activeParent.awaitConnected()
                hostPid = connected["hostPid"].asNumber("hostPid").toInt()
                assertEquals(true, connected["suffixMatched"])
                assertNotEquals("The school host must not be instrumentation.", Process.myPid(), hostPid)
                assertNotEquals("The child host must differ from its synthetic parent.", parentPid, hostPid)
                val hostInfo = waitForHostProcess(context, hostPid, 5_000L)
                    ?: throw AssertionError("The connected PID was not visible as :school_host.")
                assertEquals(context.applicationInfo.uid, hostInfo.uid)
                hostStamp = readProcessStamp(hostPid)
                    ?: throw AssertionError("Could not record the child host process identity.")

                val opened = activeParent.awaitOpened()
                assertEquals(true, opened["opened"])
                assertEquals(true, opened["layoutObserved"])
                assertEquals(true, activeParent.awaitReady()["ready"])
                val worker = server.awaitWorkerReport("worker-seed")
                val supported = worker.secureContext && worker.serviceWorkerApi
                if (!supported) {
                    activeParent.killAbruptly()
                    assertTrue("The synthetic parent process did not die.",
                        waitForNamedProcessGoneOrReplaced(
                            context, parentPid, originalParentStamp,
                            "${context.packageName}:qa_browser_parent", 10_000L,
                        ))
                    activeParent.unbind()
                    assertTrue("The school host did not drain after unsupported Worker capability.",
                        waitForHostDrain(context, hostPid, hostStamp, HOST_DRAIN_TIMEOUT_MS))
                    hostDrainProven = true
                    assumeTrue(
                        "Worker strong-kill check is skipped: loopback secureContext=${worker.secureContext}, " +
                            "serviceWorkerApi=${worker.serviceWorkerApi}.",
                        supported,
                    )
                }
                assertTrue("The worker fixture did not register and control its loopback page.",
                    worker.registered && worker.controlled)
                assertTrue("The autonomous Worker did not produce two loopback pings.",
                    server.awaitWorkerPings(2, 10_000L))
                val pingsBeforeKill = server.workerPingCount()
                assertTrue("The Worker stopped before the parent-kill check.",
                    server.awaitWorkerPings(pingsBeforeKill + 1, 2_000L))

                activeParent.killAbruptly()
                assertTrue("The original QA parent process did not exit.",
                    waitForNamedProcessGoneOrReplaced(
                        context, parentPid, originalParentStamp,
                        "${context.packageName}:qa_browser_parent", 10_000L,
                    ))
                activeParent.unbind()
                assertTrue("The child host PID or its process slot survived parent death.",
                    waitForHostDrain(context, hostPid, hostStamp, HOST_DRAIN_TIMEOUT_MS))
                hostDrainProven = true
                assertTrue("Autonomous Worker pings continued after parent-death drain.",
                    server.noWorkerPingsFor(1_500L))
            } finally {
                try {
                    parent?.let { activeParent ->
                        if (!activeParent.killSent) activeParent.tryKillForCleanup()
                        activeParent.unbind()
                        parentStamp?.let { original ->
                            if (parentPid > 0) {
                                waitForNamedProcessGoneOrReplaced(
                                    context, parentPid, original,
                                    "${context.packageName}:qa_browser_parent", 10_000L,
                                )
                            }
                        }
                        activeParent.close()
                    }
                } finally {
                    try {
                        if (!hostDrainProven) {
                            hostDrainProven = waitForHostDrain(
                                context, hostPid, hostStamp, HOST_DRAIN_TIMEOUT_MS,
                            )
                        }
                    } finally {
                        server.close()
                        if (hostDrainProven) deleteOnlySuffixTrees(context, suffix)
                    }
                }
            }
        }
    }

    @Test
    fun forceKillingSchoolHostDrainsWorkerAndAllowsAFreshSuffix() {
        assumeTrue("setDataDirectorySuffix requires API 28+; device API=${Build.VERSION.SDK_INT}",
            Build.VERSION.SDK_INT >= 28)
        withQaActivity { activity, context ->
            val server = LoopbackFixtureServer()
            val suffix = newSuffix(context)
            val cleaned = mutableSetOf<String>()
            var active: HostSession? = null
            var hardKillRequested = false
            server.start()
            try {
                val host = HostSession(activity, context, server, suffix, "/seed-worker", 808L)
                active = host
                host.start()
                val worker = server.awaitWorkerReport("worker-seed")
                val supported = worker.secureContext && worker.serviceWorkerApi
                if (!supported) {
                    drain(host, cleaned)
                    active = null
                    assumeTrue(
                        "Worker strong-kill check is skipped: loopback secureContext=${worker.secureContext}, " +
                            "serviceWorkerApi=${worker.serviceWorkerApi}.",
                        supported,
                    )
                }
                assertTrue("The worker fixture did not register and control its loopback page.",
                    worker.registered && worker.controlled)
                assertTrue("The autonomous Worker did not produce two loopback pings.",
                    server.awaitWorkerPings(2, 10_000L))
                val pingsBeforeKill = server.workerPingCount()
                assertTrue("The Worker stopped before the child-kill check.",
                    server.awaitWorkerPings(pingsBeforeKill + 1, 2_000L))

                val pid = host.pid
                assertNotEquals("The school host must not be instrumentation.", Process.myPid(), pid)
                val process = waitForHostProcess(context, pid, 5_000L)
                    ?: throw AssertionError("The exact host PID was not visible as :school_host.")
                assertEquals(context.applicationInfo.uid, process.uid)
                assertEquals("${context.packageName}:school_host", process.name)
                val original = readProcessStamp(pid)
                    ?: throw AssertionError("Could not record the exact host process identity.")
                val current = waitForHostProcess(context, pid, 2_000L)
                    ?: throw AssertionError("The host exited before its requested hard kill.")
                assertEquals(context.applicationInfo.uid, current.uid)
                assertEquals(original, readProcessStamp(pid))

                hardKillRequested = true
                Process.killProcess(pid)
                assertTrue("The exact killed child PID or host slot survived.",
                    host.unbindAfterHardKillAndDrain())
                cleaned.add(suffix)
                active = null
                assertTrue("Autonomous Worker pings continued after child-process death.",
                    server.noWorkerPingsFor(1_500L))

                val freshSuffix = newSuffix(context)
                assertNotEquals("Restart must use a fresh random partition suffix.", suffix, freshSuffix)
                val replacement = HostSession(
                    activity, context, server, freshSuffix, "/verify-worker-b", 909L,
                )
                hardKillRequested = false
                active = replacement
                replacement.start()
                val freshWorker = server.awaitWorkerReport("worker-b")
                assertTrue(freshWorker.secureContext && freshWorker.serviceWorkerApi)
                assertFalse("A new suffix inherited the old worker registration.", freshWorker.registered)
                assertFalse("A new suffix was controlled by the old worker.", freshWorker.controlled)
                drain(replacement, cleaned)
                active = null
            } finally {
                try {
                    active?.let {
                        val drained = if (hardKillRequested) {
                            it.unbindAfterHardKillAndDrain()
                        } else {
                            it.shutdownAndDrain()
                        }
                        if (drained) cleaned.add(it.suffix)
                    }
                } finally {
                    try {
                        server.close()
                    } finally {
                        cleaned.forEach { deleteOnlySuffixTrees(context, it) }
                    }
                }
            }
        }
    }

    private fun drain(host: HostSession, cleaned: MutableSet<String>) {
        assertTrue("Host process ${host.pid} did not exit with the shared host slot available.",
            host.shutdownAndDrain())
        cleaned.add(host.suffix)
    }

    private inline fun withQaActivity(block: (Activity, Context) -> Unit) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assertEquals("cn.ustcassistant.mobile.qa", context.packageName)
        val qaIntent = Intent(context, QaProbeActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        assertFalse("The QA Activity must not receive a command or start its network probe.",
            qaIntent.hasExtra("qa_command"))
        var activity: Activity? = null
        try {
            activity = instrumentation.startActivitySync(qaIntent)
            assertNotNull(activity)
            block(activity!!, context)
        } finally {
            activity?.let { opened -> instrumentation.runOnMainSync { opened.finish() } }
        }
    }

    private inner class HostSession(
        private val activity: Activity,
        private val context: Context,
        private val server: LoopbackFixtureServer,
        val suffix: String,
        private val path: String,
        private val session: Long,
    ) {
        private val instance = randomHex(24)
        private val peer = ParentPeer(instance, context.applicationInfo.uid)
        private val bound = CountDownLatch(1)
        private var service: Messenger? = null
        private var boundToService = false
        private var stopped = false
        private var drained = false
        var pid: Int = -1
            private set
        private var processStamp: ProcessStamp? = null

        private val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                service = Messenger(binder)
                bound.countDown()
            }

            override fun onServiceDisconnected(name: ComponentName) {
                bound.countDown()
            }

            override fun onNullBinding(name: ComponentName) {
                bound.countDown()
            }
        }

        fun start(): HostSession {
            val intent = Intent(activity, SchoolHostService::class.java)
                .putExtra("instance", instance)
                .putExtra("suffix", suffix)
            check(activity.bindService(intent, connection, Context.BIND_AUTO_CREATE)) {
                "Could not bind the synthetic school host service."
            }
            boundToService = true
            check(bound.await(10, TimeUnit.SECONDS)) { "SchoolHostService did not bind." }
            val remote = service ?: throw AssertionError("SchoolHostService returned a null Binder.")
            val open = mapOf<String, Any?>(
                "session" to session,
                "source" to "jw",
                "testMode" to true,
                "initialUrl" to (server.origin + path),
                "allowedOrigins" to listOf(server.origin),
                "recoveryOnly" to false,
                "background" to false,
            )
            val wrongInstance = if (instance[0] == '0') "1" + instance.substring(1)
                else "0" + instance.substring(1)
            BrowserProtocol.send(remote, BrowserProtocol.CONNECT, wrongInstance, CONNECT_CALL + 1_000,
                open, peer.messenger)
            BrowserProtocol.send(remote, BrowserProtocol.CONNECT, instance, CONNECT_CALL, open, peer.messenger)

            val connected = peer.await(BrowserProtocol.CONNECTED, 0L, 15_000L).value.asMap()
            pid = connected["pid"].asNumber("pid").toInt()
            assertNotEquals("The WebView host must run in a child process.", Process.myPid(), pid)
            assertEquals("The service must return the bound random suffix.", suffix, connected["suffix"])
            val process = waitForHostProcess(context, pid, 5_000L)
                ?: throw AssertionError("The connected PID was not visible as :school_host.")
            assertEquals(context.applicationInfo.uid, process.uid)
            processStamp = readProcessStamp(pid)

            val opened = peer.await(BrowserProtocol.RESULT, CONNECT_CALL, 20_000L).value.asMap()
            assertEquals(true, opened["ok"])
            assertEquals("The service must report the actual suffix WebView directory.", true,
                opened["layoutObserved"])
            val ready = peer.awaitMatching(20_000L) { packet ->
                packet.what == BrowserProtocol.EVENT && packet.value.asMap()["kind"] == "ready" &&
                    packet.value.asMap()["session"] == session
            }
            val document = ready.value.asMap()["document"].asNumber("document").toLong()
            BrowserProtocol.send(remote, BrowserProtocol.CALL, instance, INSPECT_CALL,
                mapOf("method" to "inspect", "args" to mapOf("session" to session, "document" to document)),
                peer.messenger)
            val inspected = peer.await(BrowserProtocol.RESULT, INSPECT_CALL, 10_000L).value.asMap()
            assertEquals(true, inspected["ok"])
            val snapshot = inspected["value"].asMap()
            assertEquals(true, snapshot["ready"])
            assertEquals(server.origin, snapshot["origin"])
            peer.assertNoProtocolFailure()
            return this
        }

        fun shutdownAndDrain(): Boolean {
            if (!stopped) {
                stopped = true
                service?.let { remote ->
                    try {
                        BrowserProtocol.send(remote, BrowserProtocol.SHUTDOWN, instance, 0L,
                            emptyMap<String, Any?>(), peer.messenger)
                    } catch (_: Exception) { }
                }
                if (boundToService) {
                    try { activity.unbindService(connection) } catch (_: Exception) { }
                    boundToService = false
                }
            }
            val success = waitForHostDrain(context, pid, processStamp, HOST_DRAIN_TIMEOUT_MS)
            if (success) drained = true
            peer.close()
            return drained
        }

        fun unbindAfterHardKillAndDrain(): Boolean {
            stopped = true
            if (boundToService) {
                try { activity.unbindService(connection) } catch (_: Exception) { }
                boundToService = false
            }
            val success = waitForHostDrain(context, pid, processStamp, HOST_DRAIN_TIMEOUT_MS)
            if (success) drained = true
            peer.close()
            return drained
        }

    }

    private inner class QaBrowserParentSession(
        private val context: Context,
        private val server: LoopbackFixtureServer,
        val suffix: String,
    ) : Closeable {
        private val instance = randomHex(24)
        private val peer = ParentPeer(instance, context.applicationInfo.uid)
        private val serviceIntent = Intent(context, QaBrowserParentService::class.java)
        private val bound = CountDownLatch(1)
        private var service: Messenger? = null
        private var boundToService = false
        var parentPid = -1
            private set
        var killSent = false
            private set

        private val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                service = Messenger(binder)
                bound.countDown()
            }

            override fun onServiceDisconnected(name: ComponentName) {
                service = null
                bound.countDown()
            }

            override fun onNullBinding(name: ComponentName) {
                bound.countDown()
            }

            override fun onBindingDied(name: ComponentName) {
                service = null
                bound.countDown()
            }
        }

        fun start(): QaBrowserParentSession {
            check(context.startService(serviceIntent) != null) {
                "Could not start the debug QA browser parent service."
            }
            check(context.bindService(serviceIntent, connection, Context.BIND_AUTO_CREATE)) {
                "Could not bind the debug QA browser parent service."
            }
            boundToService = true
            check(bound.await(10, TimeUnit.SECONDS)) {
                "The QA browser parent service did not bind."
            }
            val remote = service ?: throw AssertionError("The QA parent returned a null Binder.")
            val command = Message.obtain(null, QaBrowserParentService.START).apply {
                data = Bundle().apply {
                    putString("instance", instance)
                    putString("suffix", suffix)
                    putString("origin", server.origin)
                }
                replyTo = peer.messenger
            }
            remote.send(command)
            val accepted = awaitReport(
                QaBrowserParentService.REPORT_PARENT,
                QaBrowserParentService.REPORT_START_CALL,
                10_000L,
            )
            parentPid = accepted["pid"].asNumber("parent pid").toInt()
            return this
        }

        fun awaitConnected(): Map<*, *> = awaitReport(
            QaBrowserParentService.REPORT_CONNECTED,
            0L,
            15_000L,
        )

        fun awaitOpened(): Map<*, *> = awaitReport(
            QaBrowserParentService.REPORT_OPENED,
            QaBrowserParentService.REPORT_OPEN_CALL,
            20_000L,
        )

        fun awaitReady(): Map<*, *> = awaitReport(
            QaBrowserParentService.REPORT_READY,
            0L,
            20_000L,
        )

        private fun awaitReport(what: Int, call: Long, timeoutMs: Long): Map<*, *> {
            val incoming = peer.awaitMatching(timeoutMs) {
                it.what == QaBrowserParentService.REPORT_FAILURE ||
                    (it.what == what && it.call == call)
            }
            val value = incoming.value.asMap()
            if (incoming.what == QaBrowserParentService.REPORT_FAILURE) {
                throw AssertionError("The QA parent reported a safe failure state.")
            }
            return value
        }

        fun killAbruptly() {
            check(!killSent) { "The QA parent kill command was already sent." }
            val remote = service ?: throw AssertionError("The QA parent Binder is unavailable.")
            remote.send(Message.obtain(null, QaBrowserParentService.KILL_PARENT).apply {
                replyTo = peer.messenger
            })
            killSent = true
        }

        fun tryKillForCleanup() {
            if (killSent) return
            try {
                val remote = service ?: return
                remote.send(Message.obtain(null, QaBrowserParentService.KILL_PARENT).apply {
                    replyTo = peer.messenger
                })
                killSent = true
            } catch (_: Exception) {
                // Cleanup below will retain the suffix unless host drain is proven.
            }
        }

        fun unbind() {
            if (!boundToService) return
            try { context.unbindService(connection) } catch (_: Exception) { }
            boundToService = false
        }

        override fun close() {
            unbind()
            context.stopService(serviceIntent)
            peer.close()
        }
    }

    private class ParentPeer(instance: String, private val expectedUid: Int) : Closeable {
        private val thread = HandlerThread("ordinary-host-peer").apply { start() }
        private val packets = LinkedBlockingQueue<Incoming>()
        private val assembly = BrowserProtocol.Assembly()
        private val protocolFailure = java.util.concurrent.atomic.AtomicReference<String?>(null)
        val messenger = Messenger(Handler(thread.looper) { message ->
            try {
                val data = message.data
                val payload = data.getByteArray("payload") ?: throw IllegalArgumentException("missing payload")
                if (message.sendingUid != expectedUid) throw IllegalArgumentException("unexpected service UID")
                if (data.getString("instance") != instance) throw IllegalArgumentException("unexpected service instance")
                if (data.keySet() != setOf("instance", "call", "index", "parts", "length", "payload"))
                    throw IllegalArgumentException("unexpected IPC metadata")
                val decoded = assembly.add(data)
                if (decoded !== BrowserProtocol.Incomplete) {
                    packets.offer(Incoming(message.what, data.getLong("call", -1), decoded))
                }
            } catch (error: Exception) {
                message.data.getByteArray("payload")?.fill(0)
                protocolFailure.compareAndSet(null, error.message ?: "Malformed host IPC packet")
                packets.offer(Incoming(-1, -1L, null))
            }
            true
        })

        fun await(what: Int, call: Long, timeoutMs: Long): Incoming = awaitMatching(timeoutMs) {
            it.what == what && it.call == call
        }

        fun awaitMatching(timeoutMs: Long, predicate: (Incoming) -> Boolean): Incoming {
            val deferred = mutableListOf<Incoming>()
            val deadline = SystemClock.elapsedRealtime() + timeoutMs
            try {
                while (true) {
                    protocolFailure.get()?.let { throw AssertionError(it) }
                    val remaining = deadline - SystemClock.elapsedRealtime()
                    if (remaining <= 0) throw AssertionError("Timed out waiting for school host IPC.")
                    val packet = packets.poll(remaining, TimeUnit.MILLISECONDS)
                        ?: throw AssertionError("Timed out waiting for school host IPC.")
                    if (packet.what < 0) {
                        protocolFailure.get()?.let { throw AssertionError(it) }
                        throw AssertionError("Malformed school host IPC packet.")
                    }
                    if (predicate(packet)) return packet
                    deferred.add(packet)
                }
            } finally {
                deferred.forEach(packets::offer)
            }
        }

        fun assertNoProtocolFailure() {
            protocolFailure.get()?.let { throw AssertionError(it) }
        }

        override fun close() {
            try { assembly.clear() } catch (_: Exception) { }
            thread.quitSafely()
            thread.join(5_000L)
        }
    }

    private data class Incoming(val what: Int, val call: Long, val value: Any?)
    private data class ProcessStamp(val pid: Int, val startTicks: String)
    private data class ProcessInfo(val pid: Int, val uid: Int, val name: String)
    private data class StorageReport(
        val secureContext: Boolean,
        val indexedDbApi: Boolean,
        val cacheStorageApi: Boolean,
        val cookie: Boolean,
        val domStorage: Boolean,
        val indexedDb: Boolean,
        val cacheStorage: Boolean,
    )
    private data class WorkerReport(
        val secureContext: Boolean,
        val serviceWorkerApi: Boolean,
        val registered: Boolean,
        val controlled: Boolean,
    )

    private inner class LoopbackFixtureServer : Closeable {
        private val listener = ServerSocket(0, 16, InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)))
        private val workers = Executors.newCachedThreadPool()
        private val acceptThread = Thread(::acceptLoop, "ordinary-host-loopback").apply { isDaemon = true }
        private val reports = ConcurrentHashMap<String, Map<String, Boolean>>()
        private val reportWaiters = ConcurrentHashMap<String, CountDownLatch>()
        private val workerPings = AtomicInteger(0)
        private val workerPingEvents = LinkedBlockingQueue<Unit>()
        private val markerKey = randomHex(12)
        private val markerValue = randomHex(16)
        private val databaseName = "ordinary_host_" + randomHex(8)
        private val cacheName = "ordinary_host_" + randomHex(8)
        private val workerMessage = "ordinary_host_ping_" + randomHex(8)
        private val cacheUrl by lazy { "$origin/__cache/$markerKey" }
        val origin = "http://127.0.0.1:${listener.localPort}"

        fun start() { acceptThread.start() }

        fun awaitStorageReport(name: String): StorageReport {
            val values = awaitReport(name)
            return StorageReport(
                secureContext = values.flag("secure"),
                indexedDbApi = values.flag("indexedDbApi"),
                cacheStorageApi = values.flag("cacheApi"),
                cookie = values.flag("cookie"),
                domStorage = values.flag("domStorage"),
                indexedDb = values.flag("indexedDb"),
                cacheStorage = values.flag("cacheStorage"),
            )
        }

        fun awaitWorkerReport(name: String): WorkerReport {
            val values = awaitReport(name)
            return WorkerReport(
                secureContext = values.flag("secure"),
                serviceWorkerApi = values.flag("workerApi"),
                registered = values.flag("registered"),
                controlled = values.flag("controlled"),
            )
        }

        private fun awaitReport(name: String): Map<String, Boolean> {
            reports[name]?.let { return it }
            val latch = reportWaiters.getOrPut(name) { CountDownLatch(1) }
            check(latch.await(REPORT_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                "Synthetic browser page did not report $name."
            }
            return reports[name] ?: throw AssertionError("Synthetic browser report $name was empty.")
        }

        fun awaitWorkerPings(minimum: Int, timeoutMs: Long): Boolean {
            val deadline = SystemClock.elapsedRealtime() + timeoutMs
            while (workerPings.get() < minimum) {
                val remaining = deadline - SystemClock.elapsedRealtime()
                if (remaining <= 0 || workerPingEvents.poll(remaining, TimeUnit.MILLISECONDS) == null) return false
            }
            return true
        }

        fun workerPingCount(): Int = workerPings.get()

        fun noWorkerPingsFor(windowMs: Long): Boolean {
            while (workerPingEvents.poll() != null) { }
            val baseline = workerPings.get()
            return workerPingEvents.poll(windowMs, TimeUnit.MILLISECONDS) == null && workerPings.get() == baseline
        }

        private fun acceptLoop() {
            while (!listener.isClosed) {
                val client = try { listener.accept() } catch (_: Exception) { break }
                workers.execute { client.use(::serve) }
            }
        }

        private fun serve(client: Socket) {
            val reader = BufferedReader(InputStreamReader(client.getInputStream(), StandardCharsets.US_ASCII))
            val requestLine = reader.readLine() ?: return
            while (reader.readLine()?.isNotEmpty() == true) { }
            val target = requestLine.split(' ').getOrNull(1) ?: "/"
            val path = target.substringBefore('?')
            when (path) {
                "/seed-storage" -> respond(client, 200, "text/html; charset=utf-8", storagePage("storage-seed", true))
                "/verify-storage-b" -> respond(client, 200, "text/html; charset=utf-8", storagePage("storage-b", false))
                "/verify-storage-a" -> respond(client, 200, "text/html; charset=utf-8", storagePage("storage-a", false))
                "/seed-worker" -> respond(client, 200, "text/html; charset=utf-8", workerPage("worker-seed", true))
                "/verify-worker-b" -> respond(client, 200, "text/html; charset=utf-8", workerPage("worker-b", false))
                "/verify-worker-a" -> respond(client, 200, "text/html; charset=utf-8", workerPage("worker-a", false))
                "/__ordinary_worker.js" -> respond(client, 200, "application/javascript; charset=utf-8", workerSource(),
                    "Service-Worker-Allowed: /\r\n")
                "/__worker_ping" -> {
                    workerPings.incrementAndGet()
                    workerPingEvents.offer(Unit)
                    respond(client, 204, "text/plain", "")
                }
                else -> if (path.startsWith("/__report/")) {
                    val name = path.removePrefix("/__report/")
                    if (name in REPORT_NAMES) {
                        reports[name] = parseFlags(target)
                        reportWaiters.getOrPut(name) { CountDownLatch(1) }.countDown()
                    }
                    respond(client, 204, "text/plain", "")
                } else {
                    respond(client, 204, "text/plain", "")
                }
            }
        }

        private fun storagePage(reportName: String, seed: Boolean): String {
            val js = """
                (async function(){
                  const key=${JSONObject.quote(markerKey)}, marker=${JSONObject.quote(markerValue)};
                  const dbName=${JSONObject.quote(databaseName)}, cacheName=${JSONObject.quote(cacheName)};
                  const cacheUrl=${JSONObject.quote(cacheUrl)};
                  const secure=window.isSecureContext===true;
                  const indexedDbApi=!!window.indexedDB, cacheApi=!!window.caches;
                  let cookie=false, domStorage=false, indexedDb=false, cacheStorage=false;
                  try {
                    if(${seed}) document.cookie=key+'='+marker+'; Path=/; SameSite=Lax';
                    cookie=document.cookie.split(';').some(function(part){return part.trim()===key+'='+marker;});
                  } catch(_) {}
                  try {
                    if(${seed}) localStorage.setItem(key,marker);
                    domStorage=localStorage.getItem(key)===marker;
                  } catch(_) {}
                  try {
                    if(indexedDbApi){
                      const db=await new Promise(function(resolve,reject){
                        const request=indexedDB.open(dbName,1);
                        request.onupgradeneeded=function(){if(${seed}&&!request.result.objectStoreNames.contains('kv'))request.result.createObjectStore('kv');};
                        request.onsuccess=function(){resolve(request.result);};
                        request.onerror=function(){reject(request.error);};
                      });
                      if(db.objectStoreNames.contains('kv')){
                        if(${seed}) await new Promise(function(resolve,reject){
                          const tx=db.transaction('kv','readwrite');tx.objectStore('kv').put(marker,key);
                          tx.oncomplete=resolve;tx.onerror=function(){reject(tx.error);};tx.onabort=function(){reject(tx.error);};
                        });
                        indexedDb=await new Promise(function(resolve,reject){
                          const tx=db.transaction('kv','readonly'), request=tx.objectStore('kv').get(key);
                          request.onsuccess=function(){resolve(request.result===marker);};
                          request.onerror=function(){reject(request.error);};
                        });
                      }
                      db.close();
                    }
                  } catch(_) {}
                  try {
                    if(cacheApi){
                      const cache=await caches.open(cacheName);
                      if(${seed}) await cache.put(cacheUrl,new Response(marker));
                      const response=await cache.match(cacheUrl);
                      cacheStorage=!!response&&await response.text()===marker;
                    }
                  } catch(_) {}
                  const flags=new URLSearchParams({secure:String(secure),indexedDbApi:String(indexedDbApi),
                    cacheApi:String(cacheApi),cookie:String(cookie),domStorage:String(domStorage),
                    indexedDb:String(indexedDb),cacheStorage:String(cacheStorage)});
                  try { await fetch('/__report/${reportName}?'+flags.toString(),{cache:'no-store'}); } catch(_) {}
                })();
            """.trimIndent()
            return "<!doctype html><meta charset=utf-8><body>synthetic storage fixture</body><script>$js</script>"
        }

        private fun workerPage(reportName: String, seed: Boolean): String {
            val js = """
                (async function(){
                  const secure=window.isSecureContext===true;
                  const workerApi=!!(navigator.serviceWorker&&navigator.serviceWorker.register);
                  let registered=false, controlled=false;
                  try {
                    if(${seed}&&secure&&workerApi){
                      await navigator.serviceWorker.register('/__ordinary_worker.js',{scope:'/'});
                      await Promise.race([navigator.serviceWorker.ready,new Promise(function(_,reject){
                        setTimeout(function(){reject(new Error('ready-timeout'));},8000);
                      })]);
                      controlled=await new Promise(function(resolve){
                        if(navigator.serviceWorker.controller){resolve(true);return;}
                        let settled=false;
                        const finish=function(){if(settled)return;settled=true;
                          navigator.serviceWorker.removeEventListener('controllerchange',changed);resolve(!!navigator.serviceWorker.controller);};
                        const changed=function(){if(navigator.serviceWorker.controller)finish();};
                        navigator.serviceWorker.addEventListener('controllerchange',changed);
                        setTimeout(finish,5000);
                      });
                      registered=!!(await navigator.serviceWorker.getRegistration('/'));
                      if(controlled)setInterval(function(){
                        const controller=navigator.serviceWorker.controller;
                        if(controller)controller.postMessage(${JSONObject.quote(workerMessage)});
                      },250);
                    } else if(workerApi){
                      registered=!!(await navigator.serviceWorker.getRegistration('/'));
                      controlled=!!navigator.serviceWorker.controller;
                    }
                  } catch(_) {}
                  const flags=new URLSearchParams({secure:String(secure),workerApi:String(workerApi),
                    registered:String(registered),controlled:String(controlled)});
                  try { await fetch('/__report/${reportName}?'+flags.toString(),{cache:'no-store'}); } catch(_) {}
                })();
            """.trimIndent()
            return "<!doctype html><meta charset=utf-8><body>synthetic worker fixture</body><script>$js</script>"
        }

        private fun workerSource(): String = """
            self.addEventListener('install',function(event){event.waitUntil(self.skipWaiting());});
            self.addEventListener('activate',function(event){event.waitUntil(self.clients.claim());});
            self.addEventListener('message',function(event){
              if(event.data===${JSONObject.quote(workerMessage)}&&!self.__syntheticRunning){
                self.__syntheticRunning=true;
                // Keep a bounded event alive independently of the page. A
                // page-driven ping alone would not prove Worker drain.
                event.waitUntil(new Promise(function(resolve){
                  const timer=setInterval(function(){
                    fetch('/__worker_ping',{cache:'no-store'}).catch(function(){});
                  },200);
                  setTimeout(function(){clearInterval(timer);resolve();},20000);
                }));
              }
            });
        """.trimIndent()

        private fun parseFlags(target: String): Map<String, Boolean> = target.substringAfter('?', "")
            .split('&').mapNotNull { part ->
                val pieces = part.split('=', limit = 2)
                if (pieces.size != 2) null else URLDecoder.decode(pieces[0], "UTF-8") to
                    (URLDecoder.decode(pieces[1], "UTF-8") == "true")
            }.toMap()

        private fun respond(
            client: Socket,
            status: Int,
            contentType: String,
            body: String,
            extraHeaders: String = "",
        ) {
            val reason = when (status) { 200 -> "OK"; 204 -> "No Content"; else -> "Not Found" }
            val bytes = body.toByteArray(StandardCharsets.UTF_8)
            val headers = buildString {
                append("HTTP/1.1 ").append(status).append(' ').append(reason).append("\r\n")
                append("Content-Type: ").append(contentType).append("\r\n")
                append("Content-Length: ").append(bytes.size).append("\r\n")
                append("Connection: close\r\nCache-Control: no-store\r\n")
                append(extraHeaders).append("\r\n")
            }.toByteArray(StandardCharsets.US_ASCII)
            client.getOutputStream().apply { write(headers); write(bytes); flush() }
        }

        private fun Map<String, Boolean>.flag(key: String) = this[key]
            ?: throw AssertionError("Synthetic loopback report omitted $key.")

        override fun close() {
            try { listener.close() } catch (_: Exception) { }
            workers.shutdownNow()
            workers.awaitTermination(3, TimeUnit.SECONDS)
            if (acceptThread.isAlive) acceptThread.join(3_000L)
        }

    }

    private fun waitForHostProcess(context: Context, pid: Int, timeoutMs: Long): ProcessInfo? {
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val expectedName = context.packageName + ":school_host"
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (SystemClock.elapsedRealtime() < deadline) {
            val found = manager.runningAppProcesses?.firstOrNull {
                it.pid == pid && it.uid == context.applicationInfo.uid && it.processName == expectedName
            }
            if (found != null) return ProcessInfo(found.pid, found.uid, found.processName)
            SystemClock.sleep(25L)
        }
        return null
    }

    private fun waitForNamedProcess(
        context: Context,
        pid: Int,
        processName: String,
        timeoutMs: Long,
    ): ProcessInfo? {
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (SystemClock.elapsedRealtime() < deadline) {
            val found = manager.runningAppProcesses?.firstOrNull {
                it.pid == pid && it.uid == context.applicationInfo.uid && it.processName == processName
            }
            if (found != null) return ProcessInfo(found.pid, found.uid, found.processName)
            SystemClock.sleep(25L)
        }
        return null
    }

    private fun waitForNamedProcessGoneOrReplaced(
        context: Context,
        pid: Int,
        original: ProcessStamp?,
        processName: String,
        timeoutMs: Long,
    ): Boolean {
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (SystemClock.elapsedRealtime() < deadline) {
            val running = manager.runningAppProcesses
            val originalStillRunning = running?.any {
                it.pid == pid && it.uid == context.applicationInfo.uid && it.processName == processName
            } == true
            if (!originalStillRunning) return running != null
            if (original != null && readProcessStamp(pid) != original) return true
            SystemClock.sleep(25L)
        }
        return false
    }

    private fun waitForHostDrain(
        context: Context,
        pid: Int,
        original: ProcessStamp?,
        timeoutMs: Long,
    ): Boolean {
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val expectedName = context.packageName + ":school_host"
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (SystemClock.elapsedRealtime() < deadline) {
            val running = manager.runningAppProcesses
            val noHostProcess = running != null && running.none {
                it.uid == context.applicationInfo.uid && it.processName == expectedName
            }
            val pidAbsent = pid <= 0 || (running != null && running.none { it.pid == pid })
            val originalPidGone = original == null || readProcessStamp(pid) != original
            if (noHostProcess && pidAbsent && originalPidGone && SchoolHostSlot.available(context)) return true
            SystemClock.sleep(25L)
        }
        return false
    }

    private fun readProcessStamp(pid: Int): ProcessStamp? {
        if (pid <= 0) return null
        return try {
            val stat = File("/proc/$pid/stat").readText(Charsets.US_ASCII)
            val close = stat.lastIndexOf(')')
            if (close < 0) null else {
                val fields = stat.substring(close + 1).trim().split(Regex("\\s+"))
                fields.getOrNull(19)?.let { ProcessStamp(pid, it) }
            }
        } catch (_: Exception) { null }
    }

    private fun newSuffix(context: Context): String {
        repeat(8) {
            val candidate = "ustc_${randomHex(16)}"
            val data = File(context.applicationInfo.dataDir, "app_webview_$candidate")
            val cache = File(context.cacheDir, "webview_$candidate")
            if (!lstatExists(data) && !lstatExists(cache)) return candidate
        }
        throw AssertionError("Could not allocate an unused random WebView suffix.")
    }

    private fun deleteOnlySuffixTrees(context: Context, suffix: String) {
        check(Regex("^ustc_[0-9a-f]{32}$").matches(suffix))
        removeSuffixTree(File(context.applicationInfo.dataDir), "app_webview_$suffix")
        removeSuffixTree(context.cacheDir, "webview_$suffix")
    }

    private fun removeSuffixTree(parentPath: File, expectedName: String) {
        val parent = parentPath.canonicalFile
        val target = File(parent, expectedName)
        check(target.name == expectedName && target.parentFile?.canonicalFile == parent)
        val stat = lstatOrNull(target) ?: return
        check((stat.st_mode and OsConstants.S_IFMT) == OsConstants.S_IFDIR) {
            "Refusing to remove a non-directory suffix root."
        }
        check(target.canonicalFile == target.absoluteFile) { "Refusing a redirected suffix root." }
        deleteNodeWithoutFollowingLinks(target)
        check(!lstatExists(target)) { "The test-owned suffix tree remains after cleanup." }
    }

    private fun deleteNodeWithoutFollowingLinks(node: File) {
        val stat = lstatOrNull(node) ?: return
        if ((stat.st_mode and OsConstants.S_IFMT) == OsConstants.S_IFDIR) {
            check(node.canonicalFile == node.absoluteFile) { "Refusing to traverse a redirected child directory." }
            val children = node.listFiles() ?: throw AssertionError("Could not list the test-owned suffix tree.")
            children.forEach { child -> deleteNodeWithoutFollowingLinks(child) }
        }
        check(node.delete()) { "Could not unlink a node from the test-owned suffix tree." }
    }

    private fun lstatExists(file: File): Boolean = lstatOrNull(file) != null

    private fun lstatOrNull(file: File): StructStat? = try {
        Os.lstat(file.path)
    } catch (error: ErrnoException) {
        if (error.errno == OsConstants.ENOENT) null else throw error
    }

    private fun randomHex(byteCount: Int): String = ByteArray(byteCount).also {
        SecureRandom().nextBytes(it)
    }.joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private fun Any?.asMap(): Map<*, *> = this as? Map<*, *>
        ?: throw AssertionError("Expected a map from SchoolHostService.")

    private fun Any?.asNumber(name: String): Number = this as? Number
        ?: throw AssertionError("SchoolHostService omitted numeric $name.")

    private companion object {
        private const val HOST_DRAIN_TIMEOUT_MS = 20_000L
        private const val CONNECT_CALL = 1L
        private const val INSPECT_CALL = 2L
        private const val REPORT_TIMEOUT_MS = 25_000L
        private val REPORT_NAMES = setOf(
            "storage-seed", "storage-b", "storage-a", "worker-seed", "worker-b", "worker-a",
        )
    }
}
