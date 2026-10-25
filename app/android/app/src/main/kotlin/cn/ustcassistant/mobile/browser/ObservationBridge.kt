package cn.ustcassistant.mobile.browser

import android.app.Activity
import android.app.ActivityManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.Process
import android.os.SystemClock
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.SecureRandom
import java.util.concurrent.Executors

/** C2 broker only. The main/Flutter process never initializes a school WebView. */
internal class ObservationBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "ustc_assistant/observation_v1")
    private val ui = Handler(Looper.getMainLooper())
    private val receiver = Messenger(Handler(Looper.getMainLooper()) { packet -> receive(packet); true })
    private val io = Executors.newSingleThreadExecutor()
    private val ledger: SchoolPartitionLedger
        get() = platformLedger ?: SchoolPartitionLedger(activity.applicationContext).also { platformLedger = it }
    private val qa = activity.packageName == "cn.ustcassistant.mobile.qa" &&
        (activity.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
    private var active: Host? = null
    private var recovery: Pair<Long, SchoolPartitionLedger.Entry>? = null
    private var closedSession: Long? = null
    private var mainVisible = true
    private var disposed = false
    private var maintenance = false
    private class Rejected(val code: String) : RuntimeException()
    private class Pending(val result: MethodChannel.Result) {
        val assembly = BrowserProtocol.Assembly()
    }
    private class Host(val id: Long, val instance: String, val entry: SchoolPartitionLedger.Entry,
        val source: String, val fixture: Boolean) {
        var peer: Messenger? = null
        var connection: ServiceConnection? = null
        var binder: IBinder? = null
        var pid = 0
        var bound = false
        var visible = false
        var closing = false
        var draining = false
        var sequence = 0L
        var document = 0L
        val pending = mutableMapOf<Long, Pending>()
        val closeResults = mutableListOf<MethodChannel.Result>()
    }
    init { channel.setMethodCallHandler(::handle) }

    private fun error(result: MethodChannel.Result, code: String, reason: String? = null) {
        result.error("app_failure", null, if (reason == null) code else mapOf("code" to code, "reason" to reason))
    }
    private fun number(args: Map<*, *>, key: String): Long {
        val value = args[key]
        if (value !is Long && value !is Int) throw Rejected("invalidSnapshot")
        return (value as Number).toLong().also { if (it !in 1..9007199254740991L) throw Rejected("invalidSnapshot") }
    }
    private fun empty(args: Map<*, *>) { if (args.isNotEmpty()) throw Rejected("invalidSnapshot") }
    private fun ensureSupported() {
        if (Build.VERSION.SDK_INT < 28 || !activity.packageManager.hasSystemFeature(PackageManager.FEATURE_WEBVIEW))
            throw Rejected("unsupportedPlatform")
        if (owner != null && owner !== this) throw Rejected("busy")
    }
    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) { error(result, "closed"); return }
        val args = call.arguments as? Map<*, *> ?: run { error(result, "invalidSnapshot"); return }
        try {
            when (call.method) {
                "checkSupport" -> { empty(args); ensureSupported(); result.success(null) }
                "getCleanupStatus" -> { empty(args); result.success(ledger.status()) }
                "retryBrowserCleanup" -> {
                    empty(args)
                    if ((owner != null && owner !== this) || active != null || recovery != null || maintenance ||
                        ownHostRunning() || !SchoolHostSlot.available(activity))
                        throw Rejected("busy")
                    maintenance = true; owner = this
                    io.execute {
                        try { val status = ledger.cleanupRetired(); ui.post { maintenance = false; releaseOwner(); result.success(status) } }
                        catch (_: Exception) { ui.post { maintenance = false; releaseOwner(); error(result, "cleanupPending") } }
                    }
                }
                "isCurrentPartitionBackend" -> {
                    if (args.keys != setOf("profilePath", "source", "testMode")) throw Rejected("invalidSnapshot")
                    result.success(ledger.isCurrentBackend(args["profilePath"] as? String ?: throw Rejected("invalidSnapshot"),
                        args["source"] as? String ?: throw Rejected("invalidSnapshot"), args["testMode"] as? Boolean ?: throw Rejected("invalidSnapshot")))
                }
                "open" -> open(args, result)
                "close" -> {
                    if (args.keys != setOf("session")) throw Rejected("invalidSnapshot")
                    val id = number(args, "session")
                    val retired = recovery
                    if (retired != null && retired.first == id) closeRecovery(retired, result)
                    else if (active?.id == id) close(active!!, result)
                    else if (closedSession == id) result.success(null)
                    else throw Rejected("staleResult")
                }
                "drained" -> {
                    if (args.keys != setOf("session")) throw Rejected("invalidSnapshot")
                    result.success(active == null && recovery == null && !maintenance &&
                        closedSession == number(args, "session") && !ownHostRunning() && SchoolHostSlot.available(activity))
                }
                else -> {
                    val host = active ?: throw Rejected("closed")
                    if (host.id != number(args, "session") || host.closing || host.peer == null) throw Rejected("staleResult")
                    if (call.method !in OPERATIONS) { result.notImplemented(); return }
                    request(host, call.method, args, result)
                }
            }
        } catch (failure: Rejected) { error(result, failure.code) }
        catch (_: SchoolPartitionLedger.CapacityExceeded) { error(result, "resourceLimit") }
        catch (_: IllegalArgumentException) { error(result, "invalidSnapshot") }
        catch (_: Exception) { error(result, "cleanupPending") }
        finally { (args["credentialBytes"] as? ByteArray)?.fill(0) }
    }

    private fun open(args: Map<*, *>, result: MethodChannel.Result) {
        ensureSupported()
        if (active != null || recovery != null || maintenance || ownHostRunning() || !SchoolHostSlot.available(activity)) throw Rejected("busy")
        val fields = setOf("session", "profilePath", "initialUrl", "source", "allowedOrigins", "testMode", "recoveryOnly", "background")
        if (args.keys != fields || listOf("testMode", "recoveryOnly", "background").any { args[it] !is Boolean }) throw Rejected("invalidSnapshot")
        val id = number(args, "session")
        val policy = SchoolPolicy.fromArguments(args, qa)
        val path = args["profilePath"] as? String ?: throw Rejected("unsafeDirectory")
        val recovering = args["recoveryOnly"] == true
        val entry = ledger.claim(path, policy.source, policy.fixture, recovering)
        owner = this; closedSession = null
        if (recovering) {
            // No old/new browser is opened for recovery. The platform ledger
            // takes durable ownership before Dart may remove its placeholder.
            ledger.revoke(entry); ledger.quarantine(entry)
            recovery = id to entry; result.success(null); return
        }
        val instance = ByteArray(24).also { SecureRandom().nextBytes(it) }
            .joinToString("") { "%02x".format(it.toInt() and 255) }
        val host = Host(id, instance, entry, policy.source, policy.fixture)
        active = host
        val call = ++host.sequence
        host.pending[call] = Pending(result)
        val remoteArgs = args.filterKeys { it != "profilePath" }
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                if (active !== host || host.closing) return
                host.binder = binder; host.peer = Messenger(binder)
                try {
                    binder.linkToDeath({ ui.post { connectionLost(host) } }, 0)
                    BrowserProtocol.send(host.peer!!, BrowserProtocol.CONNECT, host.instance, call, remoteArgs, receiver)
                } catch (_: Exception) { connectionLost(host) }
            }
            override fun onServiceDisconnected(name: ComponentName) { connectionLost(host) }
            override fun onBindingDied(name: ComponentName) { connectionLost(host) }
            override fun onNullBinding(name: ComponentName) { connectionLost(host) }
        }
        host.connection = connection
        try {
            ledger.started(entry)
            host.bound = activity.bindService(Intent(activity, SchoolHostService::class.java)
                .putExtra("instance", instance).putExtra("suffix", entry.suffix), connection, Context.BIND_AUTO_CREATE)
            if (!host.bound) { failPending(host, "sourceFailed"); close(host, null) }
        } catch (_: Exception) {
            // This result is still registered here; only this path may answer it.
            // Keep a close/drain barrier for any partially started host.
            failPending(host, "sourceFailed")
            close(host, null)
            return
        }
        ui.postDelayed({
            if (active === host && host.pending.containsKey(call)) {
                host.pending.remove(call)?.let { it.assembly.clear(); error(it.result, "sourceFailed") }
                close(host, null)
            }
        }, 15000)
    }

    private fun request(host: Host, method: String, args: Map<*, *>, result: MethodChannel.Result) {
        val peer = host.peer ?: throw Rejected("closed")
        val call = ++host.sequence
        host.pending[call] = Pending(result)
        try { BrowserProtocol.send(peer, BrowserProtocol.CALL, host.instance, call, mapOf("method" to method, "args" to args), receiver) }
        catch (_: Exception) { host.pending.remove(call); error(result, "sourceFailed"); connectionLost(host); return }
        ui.postDelayed({
            if (active === host) host.pending.remove(call)?.let {
                it.assembly.clear(); error(it.result, "sourceFailed")
            }
        }, 15000)
    }
    private fun receive(packet: Message) {
        val host = active ?: return
        if (packet.sendingUid != Process.myUid() || packet.data.getString("instance") != host.instance) return
        try {
            when (packet.what) {
                BrowserProtocol.CONNECTED -> {
                    val data = single(packet) as? Map<*, *> ?: throw IllegalArgumentException()
                    check(data["suffix"] == host.entry.suffix)
                    host.pid = (data["pid"] as? Number)?.toInt() ?: throw IllegalArgumentException()
                    check(host.pid > 0 && host.pid != Process.myPid())
                }
                BrowserProtocol.EVENT -> {
                    val data = single(packet) as? Map<*, *> ?: throw IllegalArgumentException()
                    (data["document"] as? Number)?.toLong()?.let { host.document = maxOf(host.document, it) }
                    when (data["kind"]) {
                        "hostVisibility" -> { host.visible = data["visible"] == true; checkVisibility(host) }
                        "returnToApp" -> activity.startActivity(Intent().setClassName(activity.packageName,
                            "cn.ustcassistant.mobile.MainActivity").addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP))
                        else -> if (!disposed && data["session"] == host.id) channel.invokeMethod("event", data)
                    }
                }
                BrowserProtocol.RESULT -> {
                    val id = packet.data.getLong("call")
                    val pending = host.pending[id] ?: return
                    val assembled = pending.assembly.add(packet.data)
                    if (assembled === BrowserProtocol.Incomplete) return
                    val value = assembled as? Map<*, *> ?: throw IllegalArgumentException()
                    require(value["ok"] is Boolean)
                    if (value["layoutObserved"] is Boolean) ledger.layoutObserved(host.entry, value["layoutObserved"] == true,
                        value["providerName"] as? String, value["providerVersion"] as? String)
                    host.pending.remove(id)
                    if (value["ok"] == true) pending.result.success(value["value"])
                    else error(pending.result, value["code"] as? String ?: "sourceFailed", value["reason"] as? String)
                }
            }
        } catch (_: Exception) { failPending(host, "invalidSnapshot"); close(host, null) }
    }
    private fun single(packet: Message): Any? {
        val assembler = BrowserProtocol.Assembly()
        return assembler.add(packet.data).also { require(it !== BrowserProtocol.Incomplete) }
    }
    private fun connectionLost(host: Host) {
        if (active !== host) return
        host.peer = null
        if (!host.closing) {
            failPending(host, "sourceFailed")
            if (!disposed) channel.invokeMethod("event", mapOf("session" to host.id, "document" to host.document + 1, "kind" to "failed"))
            close(host, null)
        }
    }
    private fun failPending(host: Host, code: String) {
        val calls = host.pending.values.toList(); host.pending.clear()
        calls.forEach { it.assembly.clear(); error(it.result, code) }
    }
    private fun closeRecovery(retired: Pair<Long, SchoolPartitionLedger.Entry>, result: MethodChannel.Result) {
        if (maintenance) throw Rejected("busy")
        if (ownHostRunning() || !SchoolHostSlot.available(activity)) throw Rejected("cleanupPending")
        maintenance = true
        io.execute {
            try {
                ledger.cleanup(retired.second)
                ui.post { maintenance = false; recovery = null; closedSession = retired.first; releaseOwner(); result.success(null) }
            } catch (_: Exception) { ui.post { maintenance = false; error(result, "cleanupPending") } }
        }
    }
    private fun close(host: Host, result: MethodChannel.Result?) {
        result?.let { host.closeResults.add(it) }
        if (host.draining) return
        host.closing = true; host.draining = true
        failPending(host, "staleResult")
        try {
            if (host.entry.ephemeral) ledger.revoke(host.entry)
            host.peer?.let { BrowserProtocol.send(it, BrowserProtocol.SHUTDOWN, host.instance, 0, emptyMap<String, Any>(), receiver) }
        } catch (_: Exception) { /* Poll process/slot; metadata failure is rechecked before release. */ }
        if (host.bound) {
            try { host.connection?.let { activity.unbindService(it) } } catch (_: Exception) {}
            host.bound = false
        }
        val began = SystemClock.elapsedRealtime()
        var stoppedSamples = 0
        var forced = false
        fun poll() {
            if (active !== host) return
            if (!forced && SystemClock.elapsedRealtime() - began > 5000) {
                // A hung provider must not keep executing after cancellation.
                // Only the exact same-UID, app-owned browser process is eligible.
                forced = true
                val manager = activity.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                manager.runningAppProcesses?.filter {
                    it.uid == Process.myUid() && it.processName == activity.packageName + ":school_host" &&
                        (host.pid == 0 || host.pid == it.pid)
                }?.forEach { Process.killProcess(it.pid) }
            }
            val stopped = !ownHostRunning() && (host.pid == 0 || !processAlive(host.pid)) && SchoolHostSlot.available(activity)
            stoppedSamples = if (stopped) stoppedSamples + 1 else 0
            if (stoppedSamples >= 3) {
                io.execute {
                    try {
                        if (host.entry.ephemeral) { ledger.revoke(host.entry); ledger.quarantine(host.entry); ledger.cleanup(host.entry) }
                        else ledger.retained(host.entry)
                        ui.post {
                            if (active === host) active = null
                            closedSession = host.id; host.draining = false; releaseOwner()
                            host.closeResults.toList().also { host.closeResults.clear() }.forEach { it.success(null) }
                        }
                    } catch (_: Exception) { ui.post { closeFailed(host) } }
                }
            } else if (SystemClock.elapsedRealtime() - began > 15000) closeFailed(host)
            else ui.postDelayed({ poll() }, 100)
        }
        ui.postDelayed({ poll() }, 100)
    }
    private fun closeFailed(host: Host) {
        host.draining = false
        host.closeResults.toList().also { host.closeResults.clear() }.forEach { error(it, "cleanupPending") }
    }
    private fun processAlive(pid: Int): Boolean = try { Os.kill(pid, 0); true }
        catch (failure: ErrnoException) { failure.errno != OsConstants.ESRCH }
    private fun ownHostRunning(): Boolean {
        val manager = activity.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        return manager.runningAppProcesses?.any { it.uid == Process.myUid() && it.processName == activity.packageName + ":school_host" } == true
    }
    private fun checkVisibility(host: Host) {
        ui.postDelayed({
            if (active === host && !host.closing && !mainVisible && !host.visible) close(host, null)
        }, 600)
    }
    fun onHostStopped() { mainVisible = false; active?.let { checkVisibility(it) } }
    fun onHostStarted() { mainVisible = true }
    fun dispose() {
        if (disposed) return
        disposed = true; channel.setMethodCallHandler(null)
        active?.let { close(it, null) }
        recovery?.let {
            // Its durable platform tombstone survives engine teardown. No browser was opened.
            recovery = null
        }
        releaseOwner()
    }
    private fun releaseOwner() {
        if (active == null && recovery == null && !maintenance) {
            if (owner === this) owner = null
            if (disposed) io.shutdown()
        }
    }
    companion object {
        private var owner: ObservationBridge? = null
        // Activity/engine recreation must not introduce a second mutable ledger
        // snapshot while the previous broker is still finishing its close barrier.
        private var platformLedger: SchoolPartitionLedger? = null
        private val OPERATIONS = setOf("inspect", "navigateInitial", "navigateJwPage", "navigateYoungBusinessPage",
            "advanceJwLogin", "advanceYoungLogin", "submitJwLogin", "submitYoungLogin",
            "readJwProbe", "pollJwProbe", "cancelJwProbe", "readJwDataProbe", "pollJwDataProbe", "cancelJwDataProbe",
            "readJwCollection", "pollJwCollection", "cancelJwCollection", "prepareYoungBusinessPage",
            "startYoungBusiness", "dispatchYoungBusinessStep", "pollYoungBusinessStep", "finishYoungBusiness",
            "exerciseFixture", "inspectYoungPage", "startYoungReadOnly", "readYoungReadOnly", "stopYoungReadOnly")
    }
}
