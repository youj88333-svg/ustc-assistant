package cn.ustcassistant.mobile.qa

import android.app.Service
import android.content.ComponentName
import android.content.Intent
import android.content.ServiceConnection
import android.net.Uri
import android.content.pm.ApplicationInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.Process
import cn.ustcassistant.mobile.browser.BrowserProtocol
import cn.ustcassistant.mobile.browser.SchoolHostService

/** Debug-QA-only synthetic parent whose process can be killed without shutdown. */
class QaBrowserParentService : Service() {
    private val assembly = BrowserProtocol.Assembly()
    private val commandMessenger = Messenger(
        Handler(Looper.getMainLooper()) { message ->
            receiveCommand(message)
            true
        },
    )
    private val hostReceiver = Messenger(
        Handler(Looper.getMainLooper()) { message ->
            receiveHostMessage(message)
            true
        },
    )

    private var started = false
    private var parentKilled = false
    private var instance = ""
    private var suffix = ""
    private var origin = ""
    private var testPeer: Messenger? = null
    private var testPeerBinder: IBinder? = null
    private var testPeerDeath: IBinder.DeathRecipient? = null
    private var host: Messenger? = null
    private var hostBound = false
    private var hostConnectSent = false

    private val hostConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            val remote = Messenger(binder)
            host = remote
            if (started && !hostConnectSent) connectHost(remote)
        }

        override fun onServiceDisconnected(name: ComponentName) {
            host = null
            if (started && !parentKilled) reportFailure("hostDisconnected")
        }

        override fun onNullBinding(name: ComponentName) {
            host = null
            if (started && !parentKilled) reportFailure("hostUnavailable")
        }

        override fun onBindingDied(name: ComponentName) {
            host = null
            if (started && !parentKilled) reportFailure("hostBindingDied")
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!isQaDebugPackage()) stopSelf(startId)
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?) =
        if (isQaDebugPackage()) commandMessenger.binder else null

    private fun isQaDebugPackage(): Boolean =
        packageName == "cn.ustcassistant.mobile.qa" &&
            (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0 &&
            Build.VERSION.SDK_INT >= 28

    private fun receiveCommand(message: Message) {
        if (!isQaDebugPackage() || message.sendingUid != Process.myUid()) return
        when (message.what) {
            START -> startSyntheticHost(message)
            KILL_PARENT -> killParent(message)
        }
    }

    private fun startSyntheticHost(message: Message) {
        if (started || message.data.keySet() != START_KEYS) return
        val peer = message.replyTo ?: return
        val requestedInstance = message.data.getString("instance") ?: return
        val requestedSuffix = message.data.getString("suffix") ?: return
        val requestedOrigin = message.data.getString("origin") ?: return
        if (!INSTANCE.matches(requestedInstance) || !SUFFIX.matches(requestedSuffix) ||
            !isFixedLoopbackOrigin(requestedOrigin)) return

        instance = requestedInstance
        suffix = requestedSuffix
        origin = requestedOrigin
        testPeer = peer
        testPeerBinder = peer.binder
        val death = IBinder.DeathRecipient {
            Process.killProcess(Process.myPid())
        }
        try {
            peer.binder.linkToDeath(death, 0)
        } catch (_: Exception) {
            Process.killProcess(Process.myPid())
            return
        }
        testPeerDeath = death

        val intent = Intent(this, SchoolHostService::class.java)
            .putExtra("instance", instance)
            .putExtra("suffix", suffix)
        if (!bindService(intent, hostConnection, BIND_AUTO_CREATE)) {
            reportFailure("hostBindFailed")
            return
        }
        hostBound = true
        started = true
        sendTestReport(REPORT_PARENT, REPORT_START_CALL, mapOf("pid" to Process.myPid()))
    }

    private fun isFixedLoopbackOrigin(value: String): Boolean {
        if (value.length !in 18..64) return false
        val uri = try {
            Uri.parse(value)
        } catch (_: Exception) {
            return false
        }
        return uri.scheme == "http" && uri.host == "127.0.0.1" &&
            uri.port in 1..65535 && uri.userInfo == null &&
            uri.path.isNullOrEmpty() && uri.encodedQuery == null &&
            uri.encodedFragment == null && uri.toString() == value
    }

    private fun connectHost(remote: Messenger) {
        hostConnectSent = true
        val arguments = mapOf<String, Any?>(
            "session" to HOST_SESSION,
            "source" to "jw",
            "testMode" to true,
            "initialUrl" to "$origin/seed-worker",
            "allowedOrigins" to listOf(origin),
            "recoveryOnly" to false,
            "background" to false,
        )
        try {
            BrowserProtocol.send(
                remote,
                BrowserProtocol.CONNECT,
                instance,
                OPEN_CALL,
                arguments,
                hostReceiver,
            )
        } catch (_: Exception) {
            reportFailure("hostConnectFailed")
        }
    }

    private fun receiveHostMessage(message: Message) {
        val data = message.data
        val payload = data.getByteArray("payload")
        try {
            if (!started || message.sendingUid != Process.myUid() ||
                data.getString("instance") != instance ||
                data.keySet() != HOST_ENVELOPE_KEYS) return
            val decoded = assembly.add(data)
            if (decoded === BrowserProtocol.Incomplete) return
            val value = decoded as? Map<*, *> ?: throw IllegalArgumentException()
            when (message.what) {
                BrowserProtocol.CONNECTED -> {
                    val pid = (value["pid"] as? Number)?.toInt() ?: 0
                    if (message.data.getLong("call", -1) != 0L || pid <= 0 ||
                        value["suffix"] != suffix) {
                        reportFailure("hostIdentityMismatch")
                        return
                    }
                    sendTestReport(
                        REPORT_CONNECTED,
                        0L,
                        mapOf(
                            "parentPid" to Process.myPid(),
                            "hostPid" to pid,
                            "suffixMatched" to true,
                        ),
                    )
                }
                BrowserProtocol.RESULT -> {
                    if (message.data.getLong("call", -1) != OPEN_CALL) return
                    sendTestReport(
                        REPORT_OPENED,
                        OPEN_CALL,
                        mapOf(
                            "opened" to (value["ok"] == true),
                            "layoutObserved" to (value["layoutObserved"] == true),
                        ),
                    )
                }
                BrowserProtocol.EVENT -> {
                    if (value["kind"] == "ready" && value["session"] == HOST_SESSION) {
                        sendTestReport(REPORT_READY, 0L, mapOf("ready" to true))
                    }
                }
            }
        } catch (_: Exception) {
            reportFailure("hostReplyInvalid")
        } finally {
            payload?.fill(0)
        }
    }

    private fun killParent(message: Message) {
        if (!started || message.sendingUid != Process.myUid() ||
            message.data.keySet().isNotEmpty() ||
            message.replyTo?.binder != testPeerBinder) return
        parentKilled = true
        Process.killProcess(Process.myPid())
    }

    private fun reportFailure(state: String) {
        val safeState = state.takeIf { it in SAFE_FAILURE_STATES } ?: "qaFailure"
        sendTestReport(REPORT_FAILURE, 0L, mapOf("state" to safeState))
    }

    private fun sendTestReport(what: Int, call: Long, state: Map<String, Any?>) {
        val peer = testPeer ?: return
        try {
            BrowserProtocol.send(peer, what, instance, call, state)
        } catch (_: Exception) {
            Process.killProcess(Process.myPid())
        }
    }

    override fun onDestroy() {
        if (!parentKilled) {
            try {
                host?.let {
                    BrowserProtocol.send(
                        it,
                        BrowserProtocol.SHUTDOWN,
                        instance,
                        0L,
                        emptyMap<String, Any?>(),
                        hostReceiver,
                    )
                }
            } catch (_: Exception) {
                // Destruction already owns helper cleanup; the child also watches Binder death.
            }
        }
        if (hostBound) {
            try {
                unbindService(hostConnection)
            } catch (_: Exception) {
                // The connection may already be gone.
            }
            hostBound = false
        }
        try {
            testPeerDeath?.let { testPeerBinder?.unlinkToDeath(it, 0) }
        } catch (_: Exception) {
            // The test peer may already be gone.
        }
        assembly.clear()
        super.onDestroy()
    }

    companion object {
        const val START = 1
        const val KILL_PARENT = 2

        const val REPORT_PARENT = 20
        const val REPORT_CONNECTED = 21
        const val REPORT_OPENED = 22
        const val REPORT_READY = 23
        const val REPORT_FAILURE = 24
        const val REPORT_START_CALL = 1L
        const val REPORT_OPEN_CALL = 2L

        private const val OPEN_CALL = 2L
        private const val HOST_SESSION = 717L
        private val INSTANCE = Regex("[0-9a-f]{48}")
        private val SUFFIX = Regex("ustc_[0-9a-f]{32}")
        private val START_KEYS = setOf("instance", "suffix", "origin")
        private val HOST_ENVELOPE_KEYS = setOf("instance", "call", "index", "parts", "length", "payload")
        private val SAFE_FAILURE_STATES = setOf(
            "hostBindFailed",
            "hostConnectFailed",
            "hostDisconnected",
            "hostIdentityMismatch",
            "hostReplyInvalid",
            "hostUnavailable",
            "hostBindingDied",
            "qaFailure",
        )
    }
}
