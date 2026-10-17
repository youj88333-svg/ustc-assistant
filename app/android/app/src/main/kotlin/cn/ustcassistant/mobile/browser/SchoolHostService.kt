package cn.ustcassistant.mobile.browser

import android.app.Activity
import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.Process
import android.webkit.WebView
import java.io.File

/** Same-UID, non-exported, one-partition browser process. No business database or FlutterEngine. */
class SchoolHostService : Service() {
    private val ui = Handler(Looper.getMainLooper())
    private val receiver = Messenger(Handler(Looper.getMainLooper()) { packet -> receive(packet); true })
    private var parent: Messenger? = null
    private var parentDeath: IBinder.DeathRecipient? = null
    private var slot: SchoolHostSlot? = null
    private var instance = ""
    private var suffix = ""
    private var openCall = 0L
    private var openArguments: Map<*, *>? = null
    private var engine: SchoolBrowserEngine? = null
    private var hostActivity: SchoolHostActivity? = null
    private var ending = false

    override fun onBind(intent: Intent): IBinder? {
        val requested = intent.getStringExtra("instance") ?: return null
        val directory = intent.getStringExtra("suffix") ?: return null
        if (Build.VERSION.SDK_INT < 28 || !Regex("[0-9a-f]{48}").matches(requested) ||
            !Regex("ustc_[0-9a-f]{32}").matches(directory)) return null
        if (instance.isNotEmpty()) {
            if (requested != instance || suffix != directory || ending) { terminate(); return null }
            return receiver.binder
        }
        try {
            slot = SchoolHostSlot.acquire(this) ?: run { terminate(); return null }
            // This is deliberately the first android.webkit call in this process.
            WebView.setDataDirectorySuffix(directory)
            instance = requested; suffix = directory
            current = this
            return receiver.binder
        } catch (_: Exception) { terminate(); return null }
    }

    private fun receive(packet: Message) {
        if (ending || packet.sendingUid != Process.myUid() || packet.data.getString("instance") != instance) return
        val payload = packet.data.getByteArray("payload") ?: return
        if (payload.size > BrowserProtocol.MAX_REQUEST_BYTES || packet.data.getInt("parts") != 1 ||
            packet.data.getInt("index") != 0 || packet.data.getInt("length") != payload.size) {
            payload.fill(0); terminate(); return
        }
        var value: Map<*, *>? = null
        try {
            value = BrowserProtocol.decode(payload) as? Map<*, *> ?: throw IllegalArgumentException()
            val call = packet.data.getLong("call")
            when (packet.what) {
                BrowserProtocol.CONNECT -> {
                    check(parent == null && call > 0)
                    val peer = packet.replyTo ?: throw IllegalArgumentException()
                    val death = IBinder.DeathRecipient { ui.post { terminate() } }
                    peer.binder.linkToDeath(death, 0)
                    parent = peer; parentDeath = death; openCall = call
                    openArguments = value
                    send(BrowserProtocol.CONNECTED, 0, mapOf("pid" to Process.myPid(), "suffix" to suffix))
                    startActivity(Intent(this, SchoolHostActivity::class.java)
                        .putExtra("instance", instance).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                }
                BrowserProtocol.CALL -> {
                    check(parent?.binder == packet.replyTo?.binder && call > 0)
                    val method = value["method"] as? String ?: throw IllegalArgumentException()
                    val args = value["args"] as? Map<*, *> ?: throw IllegalArgumentException()
                    val live = engine ?: throw IllegalStateException()
                    live.handle(method, args, result(call))
                    (args["credentialBytes"] as? ByteArray)?.fill(0)
                }
                BrowserProtocol.SHUTDOWN -> { check(parent?.binder == packet.replyTo?.binder); terminate() }
                else -> throw IllegalArgumentException()
            }
        } catch (_: Exception) {
            val call = packet.data.getLong("call")
            if (call > 0) send(BrowserProtocol.RESULT, call, mapOf("ok" to false, "code" to "sourceFailed"))
            if (packet.what == BrowserProtocol.CONNECT) terminate()
        } finally {
            payload.fill(0)
            ((value?.get("args") as? Map<*, *>)?.get("credentialBytes") as? ByteArray)?.fill(0)
        }
    }

    internal fun accepts(candidate: String?) = !ending && candidate == instance && parent != null
    internal fun background() = openArguments?.get("background") == true
    internal fun attach(activity: SchoolHostActivity) {
        if (ending || engine != null) { activity.finish(); return }
        hostActivity = activity
        val args = openArguments ?: run { terminate(); return }
        val created = SchoolBrowserEngine(activity) { event ->
            send(BrowserProtocol.EVENT, 0, event)
        }
        engine = created; openArguments = null
        created.handle("open", args, object : BrowserResult {
            override fun success(value: Any?) {
                val observed = File(applicationInfo.dataDir, "app_webview_$suffix").isDirectory
                val provider = if (Build.VERSION.SDK_INT >= 26) WebView.getCurrentWebViewPackage() else null
                // Audit metadata is optional; an unusual vendor version string
                // must not turn into a new compatibility qualification gate.
                val providerKnown = provider?.packageName?.let {
                    it.length in 1..160 && Regex("[A-Za-z0-9_.]+").matches(it)
                } == true && provider.versionName?.let {
                    it.length in 1..128 && Regex("[A-Za-z0-9_.+\\-]+").matches(it)
                } == true
                send(BrowserProtocol.RESULT, openCall, mapOf("ok" to true, "value" to value, "layoutObserved" to observed,
                    "providerName" to if (providerKnown) provider?.packageName else null,
                    "providerVersion" to if (providerKnown) provider?.versionName else null))
            }
            override fun error(code: String, reason: String?) {
                result(openCall).error(code, reason)
            }
        })
    }
    internal fun visibility(visible: Boolean) {
        if (!ending) {
            if (visible) engine?.showWindow()
            send(BrowserProtocol.EVENT, 0, mapOf("kind" to "hostVisibility", "visible" to visible))
        }
    }
    internal fun destroyed(activity: SchoolHostActivity) {
        if (hostActivity === activity && !ending) terminate()
    }
    internal fun back() { engine?.onHostStopped(); terminate() }

    private fun result(call: Long) = object : BrowserResult {
        private var answered = false
        override fun success(value: Any?) {
            if (answered) return; answered = true
            send(BrowserProtocol.RESULT, call, mapOf("ok" to true, "value" to value))
        }
        override fun error(code: String, reason: String?) {
            if (answered) return; answered = true
            send(BrowserProtocol.RESULT, call, mapOf("ok" to false, "code" to code, "reason" to reason))
        }
    }
    private fun send(what: Int, call: Long, value: Any?) {
        val peer = parent ?: return
        try { BrowserProtocol.send(peer, what, instance, call, value) }
        catch (_: Exception) { terminate() }
    }
    private fun terminate() {
        if (ending) return
        ending = true; current = null
        try { parentDeath?.let { parent?.binder?.unlinkToDeath(it, 0) } } catch (_: Exception) {}
        try { engine?.dispose() } catch (_: Exception) {}
        engine = null; openArguments = null
        hostActivity?.finish(); hostActivity = null
        // Keep the OS slot locked until actual death. Activity.finish()/destroy()
        // alone must never make the parent report a drained browser process.
        // WebView has asynchronous DOM-storage commits and no public all-store
        // flush acknowledgement. Allow its normal detach/commit tasks to run;
        // the parent keeps the lease/slot barrier until actual process death.
        // This is best effort for recent writes, never a disk-durability proof.
        ui.postDelayed({ Process.killProcess(Process.myPid()) }, 1500)
    }
    override fun onUnbind(intent: Intent): Boolean { terminate(); return false }
    override fun onDestroy() { terminate(); super.onDestroy() }
    companion object { internal var current: SchoolHostService? = null; private set }
}
