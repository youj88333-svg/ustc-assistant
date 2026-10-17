package cn.ustcassistant.mobile.browser

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Dialog
import android.net.Uri
import android.net.http.SslError
import android.os.Handler
import android.os.Looper
import android.os.Message
import android.webkit.GeolocationPermissions
import android.webkit.PermissionRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.SslErrorHandler
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.webkit.JavaScriptExecutionException
import androidx.webkit.JavaScriptReplyProxy
import androidx.webkit.Profile
import androidx.webkit.ProfileStore
import androidx.webkit.WebStorageCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import androidx.webkit.WebViewOutcomeReceiver
import androidx.webkit.WebMessageCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

/** C2's single native owner. No generic JS/URL/browser-storage API is exported. */
internal class ObservationBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "ustc_assistant/observation_v1")
    private val ui = Handler(Looper.getMainLooper())
    private val qa = activity.packageName == "cn.ustcassistant.mobile.qa" &&
        (activity.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
    private val ledger by lazy {
        sharedLedger ?: ProfileLedger(activity.applicationContext).also { sharedLedger = it }
    }
    private var active: Session? = null
    private var clearedRecovery: Long? = null
    private var closedSession: Long? = null
    private var disposed = false
    private var coldReconciled = false

    private class Failure(val code: String, val reason: String? = null): RuntimeException()
    private class Session(
        val id: Long, val policy: SchoolPolicy, val entry: ProfileLedger.Entry,
        val profile: Profile, val view: WebView, val scripts: ScriptCatalog,
        val recovery: Boolean, val background: Boolean,
    ) {
        var document = 0L
        var ready = false
        var loading = false
        var closing = false
        var failed = false
        var url = ""
        var privateProxy: JavaScriptReplyProxy? = null
        var privateReady = false
        var privateChecking = false
        var frameProxy: JavaScriptReplyProxy? = null
        var frameReady = false
        var frameChecking = false
        var loginOperation = 0L
        var loginDocument = -1L
        var submitted = false
        var launcher = false
        var selfId = ""
        var dialog: Dialog? = null
        var originLabel: TextView? = null
        var callSequence = 0L
        var viewsDestroyed = false
        val children = mutableSetOf<WebView>()
        val pending = mutableMapOf<Long, Pending>()
    }
    private class Pending(val document: Long, val result: MethodChannel.Result, val page: Boolean,
        val preNavigation: Boolean = false,
        val consume: (JSONObject) -> Any?)

    init { channel.setMethodCallHandler(::handle) }

    private fun fail(result: MethodChannel.Result, code: String, reason: String? = null) {
        trace("failure.$code")
        result.error("app_failure", null,
            if (reason == null) code else mapOf("code" to code, "reason" to reason))
    }
    private fun trace(event: String) { if (qa) android.util.Log.d("UstcA2", event) }
    private fun args(call: MethodCall): Map<*, *> = call.arguments as? Map<*, *>
        ?: throw Failure("invalidSnapshot")
    private fun number(args: Map<*, *>, key: String, positive: Boolean = true): Long {
        val value = args[key]
        if (value !is Int && value !is Long) throw Failure("invalidSnapshot")
        return (value as Number).toLong().also {
            if (it < (if (positive) 1 else 0) || it > 9007199254740991L) throw Failure("invalidSnapshot")
        }
    }
    private fun current(a: Map<*, *>, document: Boolean = true): Session {
        val s = active ?: throw Failure("closed")
        if (s.id != number(a, "session") || s.closing || s.failed ||
            (document && s.document != number(a, "document", false))) throw Failure("staleResult")
        return s
    }
    private fun source(s: Session, expected: String) {
        if (s.policy.source != expected) throw Failure("invalidSnapshot")
    }
    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) { fail(result, "closed"); return }
        try {
            val a = args(call)
            validateArguments(call.method, a)
            when (call.method) {
                "checkSupport" -> { ensureFeatures(false); result.success(null) }
                "open" -> open(a, result)
                "close" -> {
                    val id = number(a, "session")
                    val s = active
                    if (clearedRecovery == id) {
                        clearedRecovery = null; closedSession = id; result.success(null)
                    }
                    else if (s == null && id == closedSession) result.success(null)
                    else if (s == null || s.id != id) throw Failure("staleResult")
                    else close(s, false, result)
                }
                "drained" -> result.success(active == null && clearedRecovery == null && closedSession == number(a, "session"))
                "inspect" -> {
                    val s = current(a)
                    result.success(mapOf("session" to s.id, "document" to s.document,
                        "ready" to ready(s), "origin" to s.policy.origin(s.url),
                        "windowVisible" to (s.dialog?.isShowing == true),
                        "windowForeground" to (s.dialog?.window?.decorView?.hasWindowFocus() == true)))
                }
                "navigateInitial" -> { val s = current(a, false); navigate(s, s.policy.initialUrl); result.success(null) }
                "navigateJwPage" -> {
                    val s = current(a); source(s, "jw")
                    navigate(s, s.policy.jwLauncher(a["page"] as? String ?: "")); result.success(null)
                }
                "navigateYoungBusinessPage" -> {
                    val s = current(a, false); source(s, "young")
                    // No navigation has been sent yet. A callback/SPA route may
                    // have advanced between Dart's ready event and this request.
                    if (s.document != number(a, "document", false)) throw Failure("busy")
                    val destination = s.policy.youngPage(a["page"] as? String ?: "")
                    pageCall(s, JSONObject().put("method", "navigationReady"), result, true) {
                        if (!it.getBoolean("value")) throw Failure("busy")
                        navigate(s, destination); null
                    }
                }
                "advanceJwLogin", "advanceYoungLogin" -> {
                    val s = current(a); source(s, if (call.method == "advanceJwLogin") "jw" else "young")
                    advance(s, a, result)
                }
                "submitJwLogin", "submitYoungLogin" -> {
                    val s = current(a); source(s, if (call.method == "submitJwLogin") "jw" else "young")
                    submit(s, a, result)
                }
                "readJwProbe", "pollJwProbe", "cancelJwProbe",
                "readJwDataProbe", "pollJwDataProbe", "cancelJwDataProbe",
                "readJwCollection", "pollJwCollection", "cancelJwCollection" -> probe(current(a), call.method, a, result)
                "prepareYoungBusinessPage" -> {
                    val s = current(a); source(s, "young")
                    val page = a["page"] as? String ?: throw Failure("invalidSnapshot")
                    s.policy.youngPage(page)
                    pageCall(s, JSONObject().put("method", "prepare").put("page", page), result) {
                        it.getBoolean("value")
                    }
                }
                "startYoungBusiness", "dispatchYoungBusinessStep", "pollYoungBusinessStep", "finishYoungBusiness" ->
                    young(current(a), call.method, a, result)
                "exerciseFixture" -> exercise(current(a), a, result)
                // Candidate-only historical observation is never substituted for formal C1 reads.
                "inspectYoungPage", "startYoungReadOnly", "readYoungReadOnly", "stopYoungReadOnly" ->
                    throw Failure("unsupportedPlatform")
                else -> result.notImplemented()
            }
        } catch (error: Failure) { fail(result, error.code, error.reason) }
        catch (_: IllegalArgumentException) { fail(result, "invalidSnapshot") }
        catch (_: Exception) { fail(result, "sourceFailed") }
        finally {
            // StandardMessageCodec has already copied the lease. Wipe our byte-array copy.
            ((call.arguments as? Map<*, *>)?.get("credentialBytes") as? ByteArray)?.fill(0)
            releaseProcessOwner()
        }
    }

    private fun validateArguments(method: String, args: Map<*, *>) {
        val fields = when (method) {
            "checkSupport" -> emptySet()
            "open" -> setOf("session", "profilePath", "initialUrl", "source", "allowedOrigins", "testMode", "recoveryOnly", "background")
            "close", "drained", "navigateInitial" -> setOf("session")
            "navigateJwPage", "navigateYoungBusinessPage", "prepareYoungBusinessPage" -> setOf("session", "document", "page")
            "inspect", "inspectYoungPage" -> setOf("session", "document")
            "submitJwLogin", "submitYoungLogin" -> setOf("session", "document", "operation", "credentialBytes")
            "advanceJwLogin", "advanceYoungLogin", "readJwProbe", "pollJwProbe", "cancelJwProbe",
            "pollJwDataProbe", "cancelJwDataProbe", "pollJwCollection", "cancelJwCollection",
            "startYoungBusiness", "finishYoungBusiness", "startYoungReadOnly", "readYoungReadOnly", "stopYoungReadOnly" ->
                setOf("session", "document", "operation")
            "readJwDataProbe", "readJwCollection" -> setOf("session", "document", "operation", "semesterId")
            "pollYoungBusinessStep" -> setOf("session", "document", "operation", "step")
            "dispatchYoungBusinessStep" -> setOf("session", "document", "operation", "step", "endpoint", "page", "day")
            "exerciseFixture" -> setOf("session", "document", "action")
            else -> return
        }
        val required = if (method == "dispatchYoungBusinessStep") fields - "day" else fields
        if (args.keys.any { it !in fields } || !args.keys.containsAll(required)) throw Failure("invalidSnapshot")
        if (method == "open" && listOf("testMode", "recoveryOnly", "background").any { args[it] !is Boolean })
            throw Failure("invalidSnapshot")
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun open(a: Map<*, *>, result: MethodChannel.Result) {
        if (active != null || clearedRecovery != null) throw Failure("busy")
        if (processOwner != null && processOwner !== this) throw Failure("busy")
        val id = number(a, "session")
        val policy = SchoolPolicy.fromArguments(a, qa)
        val recovery = a["recoveryOnly"] as Boolean
        try {
            ensureFeatures(recovery)
        } catch (error: Exception) {
            // This call created no source session. Its idempotent drain proof
            // says nothing about clearing an existing SDK profile or ledger.
            closedSession = id
            throw error
        }
        processOwner = this
        // Cold deletion never enumerates or deletes a profile absent from our durable ledger.
        if (!coldReconciled) {
            for (entry in ledger.pendingColdDelete()) {
                if (entry.name !in loadedProfiles) {
                    val store = ProfileStore.getInstance()
                    if (entry.name !in store.allProfileNames || store.deleteProfile(entry.name)) ledger.deleted(entry)
                }
            }
            coldReconciled = true
        }
        val entry = ledger.claim(a["profilePath"] as? String ?: throw Failure("unsafeDirectory"),
            policy.source, policy.fixture, recovery)
        if (recovery && ledger.wasCleared(entry)) {
            clearedRecovery = id; closedSession = null; result.success(null); return
        }
        loadedProfiles.add(entry.name)
        val profile = ProfileStore.getInstance().getOrCreateProfile(entry.name)
        val view = WebView(activity)
        val s = Session(id, policy, entry, profile, view, ScriptCatalog(activity), recovery,
            a["background"] as? Boolean ?: false)
        try {
            WebViewCompat.setProfile(view, entry.name)
            loadedProfiles.add(entry.name)
            view.settings.apply {
                javaScriptEnabled = true; domStorageEnabled = true
                // Business identity must be read against the current session,
                // not a previous account's HTTP cache entry in a retained profile.
                cacheMode = android.webkit.WebSettings.LOAD_NO_CACHE
                allowFileAccess = false; allowContentAccess = false
                mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW
                setSupportMultipleWindows(true); javaScriptCanOpenWindowsAutomatically = true
                mediaPlaybackRequiresUserGesture = true
                setGeolocationEnabled(false)
                saveFormData = false
            }
            active = s; closedSession = null
            attachClients(s)
            if (!recovery) {
                install(s)
                if (!s.background) show(s)
                navigate(s, policy.initialUrl)
            }
            result.success(null)
        } catch (error: Exception) {
            active = null
            view.destroy()
            // Preserve the entry for recovery; never claim a failed setup was cleared.
            throw error
        }
    }

    private fun ensureFeatures(recovery: Boolean) {
        val features = mutableListOf(WebViewFeature.MULTI_PROFILE, WebViewFeature.DELETE_BROWSING_DATA)
        if (!recovery) features.addAll(listOf(WebViewFeature.DOCUMENT_START_SCRIPT,
            WebViewFeature.JS_INJECTION_IN_FRAME_AND_WORLD))
        for (feature in features) {
            if (!WebViewFeature.isFeatureSupported(feature)) throw Failure("unsupportedPlatform")
        }
    }

    private fun install(s: Session) {
        // This world contains only a document-embedding policy and closed
        // diagnostics, including for opaque children. It has no secret sink.
        val frameWorld = WebViewCompat.getExecutionWorld(s.view, "ustc.source.frame-policy.v1")
        WebViewCompat.addWebMessageListener(s.view, "__ustcFramePolicy", setOf("*"), frameWorld) {
                _, message, origin, main, proxy ->
            if (active !== s || s.closing || s.failed || message.type != WebMessageCompat.TYPE_STRING)
                return@addWebMessageListener
            when (message.data) {
                "installed" -> if (main && s.policy.origin(s.url) == origin.toString()) {
                    s.frameProxy = proxy; s.frameReady = false; s.frameChecking = false
                    confirmReady(s, true)
                }
                "unavailable" -> { s.view.stopLoading(); invalidate(s, "failed") }
                "blocked:http", "blocked:https", "blocked:other" -> channel.invokeMethod("event",
                    mapOf("session" to s.id, "document" to s.document, "kind" to "diagnostic",
                        "diagnostic" to mapOf("code" to "frameNavigationBlocked", "site" to "unknown",
                            "scheme" to message.data!!.substringAfter(':'))))
            }
        }
        WebViewCompat.addJavaScriptOnEvent(s.view, FramePolicy.script(s.policy.origins),
            WebViewCompat.INJECTION_EVENT_DOCUMENT_START, setOf("*"), frameWorld)
        val world = WebViewCompat.getExecutionWorld(s.view, "ustc.source.auth.v1")
        WebViewCompat.addWebMessageListener(s.view, "__ustcSourceNative", s.policy.origins, world) {
                _, message, origin, main, proxy ->
            if (active !== s || s.closing || !main || s.policy.origin(s.url) != origin.toString() ||
                message.type != WebMessageCompat.TYPE_STRING || message.data != "ready") return@addWebMessageListener
            s.privateProxy = proxy; s.privateReady = false; s.privateChecking = false
            confirmReady(s, false)
        }
        WebViewCompat.addJavaScriptOnEvent(s.view, s.scripts.privateBootstrap(s.policy),
            WebViewCompat.INJECTION_EVENT_DOCUMENT_START, s.policy.origins, world)
        if (s.policy.source == "young") {
            WebViewCompat.addWebMessageListener(s.view, "__ustcSourcePage", s.policy.origins) {
                    _, message, origin, main, _ ->
                if (active !== s || s.closing || !main || s.policy.origin(s.url) != origin.toString())
                    return@addWebMessageListener
                if (message.type != WebMessageCompat.TYPE_STRING) {
                    trace("message.nonString"); return@addWebMessageListener
                }
                val raw = message.data ?: return@addWebMessageListener
                if (raw.length > 2 * 1024 * 1024) return@addWebMessageListener
                try {
                    val envelope = JSONObject(raw)
                    if (envelope.optString("reply") != s.scripts.pageReply || envelope.length() != 3) return@addWebMessageListener
                    val id = envelope.getLong("call")
                    complete(s, id, envelope)
                } catch (_: Exception) { /* Unauthenticated page messages are not evidence. */ }
            }
            WebViewCompat.addDocumentStartJavaScript(s.view, s.scripts.pageBootstrap(s.policy), s.policy.origins)
        }
    }

    private fun ready(s: Session) = s.ready && s.privateReady && s.frameReady && !s.failed

    private fun confirmReady(s: Session, frame: Boolean) {
        // A message emitted by the old document can arrive after navigation
        // starts. Re-prove through its document-bound proxy only after finish;
        // a detached/BFCache proxy cannot execute into the new document.
        if (active !== s || !s.ready || s.loading || s.closing || s.failed) return
        if (if (frame) s.frameReady || s.frameChecking else s.privateReady || s.privateChecking) return
        val proxy = (if (frame) s.frameProxy else s.privateProxy) ?: return
        val document = s.document
        if (frame) s.frameChecking = true else s.privateChecking = true
        val proof = if (frame) "globalThis.__ustcFramePolicyInstalled===true"
            else "typeof globalThis.__ustcAndroidPrivate==='function'"
        proxy.executeJavaScript(proof,
            object: WebViewOutcomeReceiver<String, JavaScriptExecutionException> {
                private fun stillCurrent() = active === s && !s.closing && !s.failed &&
                    s.document == document && s.ready && !s.loading &&
                    (if (frame) s.frameProxy else s.privateProxy) === proxy
                override fun onResult(value: String) {
                    if (!stillCurrent()) return
                    if (frame) { s.frameChecking = false; s.frameReady = value == "true" }
                    else { s.privateChecking = false; s.privateReady = value == "true" }
                    if (ready(s)) event(s, "ready")
                    else if (value != "true") invalidate(s, "failed")
                }
                override fun onError(error: JavaScriptExecutionException) {
                    if (!stillCurrent()) return
                    if (frame) s.frameChecking = false else s.privateChecking = false
                    // A stale candidate is never an authorization to use another document.
                }
            })
    }

    private fun show(s: Session) {
        val dialog = Dialog(activity)
        val layout = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
        val toolbar = LinearLayout(activity)
        val origin = TextView(activity).apply { text = s.policy.businessOrigin; setPadding(16, 12, 8, 12) }
        val done = Button(activity).apply { text = "返回应用"; setOnClickListener { dialog.hide() } }
        val close = Button(activity).apply { text = "关闭"; setOnClickListener { close(s, true, null) } }
        toolbar.addView(origin, LinearLayout.LayoutParams(0, -2, 1f)); toolbar.addView(done); toolbar.addView(close)
        layout.addView(toolbar); layout.addView(s.view, LinearLayout.LayoutParams(-1, 0, 1f))
        dialog.setContentView(layout); dialog.setOnCancelListener { close(s, true, null) }
        dialog.setOnKeyListener { _, key, e ->
            if (key == android.view.KeyEvent.KEYCODE_BACK && e.action == android.view.KeyEvent.ACTION_UP) {
                dialog.hide(); true
            } else false
        }
        s.dialog = dialog; s.originLabel = origin
        dialog.show(); dialog.window?.setLayout(-1, -1)
    }

    private fun navigate(s: Session, url: String) {
        if (s.recovery || !s.policy.navigation(url).allowed) throw Failure("invalidSnapshot")
        if (s.policy.source == "jw" && url in setOf(s.policy.jwLauncher("courseTable"), s.policy.jwLauncher("examArrange"))) {
            s.launcher = true
        }
        s.view.loadUrl(url)
    }

    private fun attachClients(s: Session) {
        s.view.setDownloadListener { _, _, _, _, _ -> diagnostic(s, "downloadBlocked", s.url) }
        s.view.webViewClient = object: WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                val url = request.url.toString()
                val decision = s.policy.navigation(url)
                if (decision.allowed) return false
                diagnostic(s, if (decision.scheme == "other") "externalProtocolBlocked" else
                    if (decision.upgradeUrl != null && request.isForMainFrame) "insecureDocumentUpgraded" else
                    if (request.isForMainFrame) "topNavigationBlocked" else "frameNavigationBlocked", url)
                if (decision.upgradeUrl != null && request.isForMainFrame) view.loadUrl(decision.upgradeUrl)
                return true
            }
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                // Only document destinations. Ordinary page background network remains ordinary WebView behavior.
                val destination = request.requestHeaders["Sec-Fetch-Dest"] ?: request.requestHeaders["sec-fetch-dest"]
                if ((request.isForMainFrame || destination == "iframe" || destination == "document") &&
                    !s.policy.navigation(request.url.toString()).allowed) {
                    ui.post { diagnostic(s, "documentRequestBlocked", request.url.toString()) }
                    return WebResourceResponse("text/plain", "UTF-8", 403, "Blocked", emptyMap(), ByteArrayInputStream(ByteArray(0)))
                }
                return null
            }
            override fun onPageStarted(view: WebView, url: String, icon: android.graphics.Bitmap?) {
                if (active !== s || s.closing) return
                if (!s.policy.navigation(url).allowed) {
                    view.stopLoading(); invalidate(s, "blocked"); return
                }
                newDocument(s, url)
                s.loading = true
                val path = Uri.parse(url).path ?: ""
                if (s.policy.origin(url) == s.policy.businessOrigin && path in
                    setOf("/for-std/course-table", "/for-std/exam-arrange")) s.launcher = true
                val match = Regex("^/for-std/(?:course-table|exam-arrange)/info/([0-9]{1,12})/?$").matchEntire(path)
                if (s.launcher && match != null && s.policy.origin(url) == s.policy.businessOrigin) {
                    s.selfId = match.groupValues[1]; s.launcher = false
                }
            }
            override fun doUpdateVisitedHistory(view: WebView, url: String, reload: Boolean) {
                if (active !== s || s.closing) return
                // Full document history is already invalidated by onPageStarted. Every later
                // top history update, including same-URL push/replace, revokes operation stamps.
                if (!s.loading && url == s.view.url) {
                    historyChanged(s, url)
                }
            }
            override fun onPageFinished(view: WebView, url: String) {
                if (active !== s || s.closing || url != s.view.url) return
                s.url = url; s.loading = false; s.ready = true
                s.originLabel?.text = s.policy.origin(url) ?: "受限页面"
                confirmReady(s, true); confirmReady(s, false)
                if (ready(s)) event(s, "ready")
            }
            override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
                handler.cancel(); invalidate(s, "failed")
            }
            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: android.webkit.WebResourceError) {
                if (request.isForMainFrame) invalidate(s, "failed")
            }
            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                invalidate(s, "failed"); close(s, false, null); return true
            }
        }
        s.view.webChromeClient = object: WebChromeClient() {
            override fun onPermissionRequest(request: PermissionRequest) {
                request.deny(); diagnostic(s, "permissionBlocked", s.url)
            }
            override fun onGeolocationPermissionsShowPrompt(origin: String, callback: GeolocationPermissions.Callback) {
                callback.invoke(origin, false, false); diagnostic(s, "permissionBlocked", s.url)
            }
            override fun onShowFileChooser(view: WebView, callback: ValueCallback<Array<Uri>>, params: FileChooserParams): Boolean {
                callback.onReceiveValue(null); diagnostic(s, "permissionBlocked", s.url); return true
            }
            override fun onCreateWindow(view: WebView, dialog: Boolean, userGesture: Boolean, message: Message): Boolean {
                if (!userGesture || s.closing || s.children.isNotEmpty()) {
                    diagnostic(s, "popupBlocked", s.url); return false
                }
                val child = WebView(activity)
                WebViewCompat.setProfile(child, s.entry.name)
                child.settings.allowFileAccess = false
                child.settings.allowContentAccess = false
                s.children.add(child)
                fun discardChild() {
                    if (s.children.remove(child)) { child.stopLoading(); child.destroy() }
                }
                child.webViewClient = object: WebViewClient() {
                    override fun shouldInterceptRequest(v: WebView, request: WebResourceRequest): WebResourceResponse {
                        // A popup is only a navigation handoff, never another live channel.
                        // In particular a target=_blank POST is not replayed or sent from this child.
                        ui.post {
                            if (child in s.children && active === s && !s.closing) {
                                val decision = s.policy.navigation(request.url.toString())
                                if (request.isForMainFrame && request.method == "GET" && decision.allowed) navigate(s, request.url.toString())
                                else diagnostic(s, "popupBlocked", request.url.toString())
                                discardChild()
                            }
                        }
                        return WebResourceResponse("text/plain", "UTF-8", 403, "Blocked", emptyMap(), ByteArrayInputStream(ByteArray(0)))
                    }
                    override fun shouldOverrideUrlLoading(v: WebView, request: WebResourceRequest): Boolean {
                        val url = request.url.toString()
                        val decision = s.policy.navigation(url)
                        if (!decision.allowed) diagnostic(s, "popupBlocked", url)
                        if (request.method != "GET") diagnostic(s, "popupBlocked", url)
                        else if (decision.allowed) navigate(s, url)
                        else if (decision.upgradeUrl != null) navigate(s, decision.upgradeUrl)
                        ui.post { discardChild() }; return true
                    }
                }
                (message.obj as WebView.WebViewTransport).webView = child
                message.sendToTarget()
                ui.postDelayed({ discardChild() }, 5000)
                return true
            }
        }
    }

    private fun newDocument(s: Session, url: String) {
        rejectPending(s, true)
        s.document++; s.url = url; s.ready = false
        s.privateProxy = null; s.privateReady = false
        s.privateChecking = false; s.frameProxy = null; s.frameReady = false; s.frameChecking = false
        s.loginOperation = 0; s.loginDocument = -1; s.submitted = false
        event(s, "navigating")
    }
    private fun historyChanged(s: Session, url: String) {
        rejectPending(s, true)
        s.document++; s.url = url
        // Same document retains its isolated-world proxy, but no prepared secret action.
        s.loginOperation = 0; s.loginDocument = -1; s.submitted = false
        s.privateChecking = false; s.frameChecking = false
        s.privateReady = false; s.frameReady = false
        confirmReady(s, true); confirmReady(s, false)
        event(s, "navigating"); if (ready(s)) event(s, "ready")
    }
    private fun rejectPending(s: Session, readinessRace: Boolean = false) {
        val pending = s.pending.values.toList(); s.pending.clear()
        pending.forEach { fail(it.result,
            if (readinessRace && it.preNavigation) "busy" else "staleResult") }
    }
    private fun invalidate(s: Session, kind: String) {
        if (active !== s || s.closing) return
        rejectPending(s); s.document++; s.ready = false; s.privateReady = false
        s.privateProxy = null; s.loginOperation = 0; s.failed = kind == "failed"
        s.frameProxy = null; s.frameReady = false; s.frameChecking = false; s.privateChecking = false
        event(s, kind)
    }
    private fun event(s: Session, kind: String) {
        if (disposed) return
        channel.invokeMethod("event", mapOf("session" to s.id, "document" to s.document,
            "kind" to kind, "origin" to s.policy.origin(s.url)))
    }
    private fun diagnostic(s: Session, code: String, url: String) {
        if (disposed || active !== s) return
        val d = s.policy.navigation(url)
        channel.invokeMethod("event", mapOf("session" to s.id, "document" to s.document,
            "kind" to "diagnostic", "diagnostic" to mapOf("code" to code, "site" to d.site, "scheme" to d.scheme)))
    }

    private fun privateCall(s: Session, args: JSONObject, result: MethodChannel.Result,
        consume: (JSONObject) -> Any?) {
        val proxy = s.privateProxy ?: throw Failure("unsupportedPlatform")
        if (!ready(s)) throw Failure("staleResult")
        val id = ++s.callSequence
        s.pending[id] = Pending(s.document, result, false, consume = consume)
        proxy.executeJavaScript(s.scripts.privateCall(args),
            object: WebViewOutcomeReceiver<String, JavaScriptExecutionException> {
                override fun onResult(value: String) {
                    try { complete(s, id, s.scripts.unwrap(value)) }
                    catch (_: Exception) { completeError(s, id, "invalidSnapshot") }
                }
                override fun onError(error: JavaScriptExecutionException) { completeError(s, id, "staleResult") }
            })
        timeout(s, id)
    }
    private fun pageCall(s: Session, args: JSONObject, result: MethodChannel.Result,
        preNavigation: Boolean = false,
        consume: (JSONObject) -> Any?) {
        val method = args.getString("method")
        trace("page.$method.begin")
        if (!ready(s)) throw Failure(if (preNavigation) "busy" else "staleResult")
        val id = ++s.callSequence
        args.put("call", id)
        s.pending[id] = Pending(s.document, result, true, preNavigation, consume)
        s.view.evaluateJavascript(s.scripts.pageCall(args), null)
        timeout(s, id)
    }
    private fun timeout(s: Session, id: Long) {
        ui.postDelayed({ if (id in s.pending) trace("callback.timeout"); completeError(s, id, "sourceFailed") }, 5000)
    }
    private fun completeError(s: Session, id: Long, code: String) {
        val pending = s.pending.remove(id) ?: return
        fail(pending.result, if (active !== s || s.closing || s.failed) "staleResult"
            else if (pending.preNavigation && (s.document != pending.document || code == "staleResult")) "busy"
            else if (s.document != pending.document) "staleResult" else code)
    }
    private fun complete(s: Session, id: Long, envelope: JSONObject) {
        val pending = s.pending.remove(id) ?: return
        if (active !== s || s.document != pending.document || s.closing) {
            fail(pending.result, if (pending.preNavigation && active === s && !s.closing && !s.failed)
                "busy" else "staleResult"); return
        }
        try {
            trace(if (envelope.has("error")) "callback.pageError" else "callback.value")
            if (envelope.has("error")) {
                val error = envelope.getJSONObject("error")
                val code = error.optString("code")
                val reason = error.optString("reason")
                if (code !in setOf("sourceFailed", "staleResult", "invalidSnapshot", "busy")) throw Failure("invalidSnapshot")
                throw Failure(if (pending.preNavigation && code == "staleResult") "busy" else code,
                    reason.takeIf { it in YOUNG_REASONS } ?: "sourceFailure")
            }
            pending.result.success(pending.consume(envelope))
        } catch (error: Failure) { fail(pending.result, error.code, error.reason) }
        catch (_: Exception) { fail(pending.result, "invalidSnapshot") }
    }

    private fun advance(s: Session, a: Map<*, *>, result: MethodChannel.Result) {
        val operation = number(a, "operation")
        // A final URL can be visible before its document and private bootstrap
        // are usable. This also matters when a retained login skips CAS.
        if (!ready(s)) { result.success("waiting"); return }
        val path = Uri.parse(s.url).path ?: ""
        if (s.policy.origin(s.url) == s.policy.businessOrigin && (path == "/" || path.isEmpty())) {
            navigate(s, s.policy.businessOrigin + if (s.policy.source == "jw") "/login" else "/login/")
            result.success("waiting"); return
        }
        if (s.policy.source == "young" && s.policy.origin(s.url) == s.policy.businessOrigin &&
            path.startsWith("/login/sc-wisdom-group-learning")) {
            // The namespace root is an authentication callback, not a usable
            // business document, even after its ticket has been removed.
            val prefix = "/login/sc-wisdom-group-learning/"
            result.success(if (path.startsWith(prefix) && path.length > prefix.length)
                "businessReady" else "waiting"); return
        }
        if (s.policy.source == "jw" && (path == "/home" || Regex("^/for-std/(?:course-table|exam-arrange)/info/[0-9]{1,12}/?$").matches(path)) && s.policy.origin(s.url) == s.policy.businessOrigin) {
            result.success("businessReady"); return
        }
        // Passport/Young portal documents can redirect asynchronously. Only
        // the exact CAS form or JW's fixed portal button receives a DOM action.
        if (!s.policy.isCas(s.url) && !(s.policy.source == "jw" &&
                s.policy.origin(s.url) == s.policy.businessOrigin && path == "/login")) {
            result.success("waiting"); return
        }
        if (s.submitted && s.loginOperation == operation) { result.success("waiting"); return }
        privateCall(s, JSONObject().put("method", "advance").put("operation", operation), result) {
            val state = it.getString("value")
            if (state !in LOGIN_STATES) throw Failure("invalidSnapshot")
            if (state == "formReady") { s.loginOperation = operation; s.loginDocument = s.document }
            state
        }
    }
    private fun submit(s: Session, a: Map<*, *>, result: MethodChannel.Result) {
        val operation = number(a, "operation")
        if (!s.policy.isCas(s.url) || !ready(s) || s.loginOperation != operation ||
            s.loginDocument != s.document || s.submitted) throw Failure("staleResult")
        val bytes = a["credentialBytes"] as? ByteArray ?: throw Failure("invalidSnapshot")
        if (bytes.isEmpty() || bytes.size > 16384) throw Failure("invalidSnapshot")
        val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
        val secret = JSONObject(text)
        require(secret.length() == 2)
        val username = secret.getString("username"); val password = secret.getString("password")
        require(username.isNotEmpty() && username.length <= 64 && password.isNotEmpty() && password.length <= 4096)
        s.submitted = true
        privateCall(s, JSONObject().put("method", "submit").put("operation", operation)
            .put("username", username).put("password", password), result) {
            it.getString("value").also { state -> if (state !in LOGIN_STATES) throw Failure("invalidSnapshot") }
        }
    }
    private fun probe(s: Session, method: String, a: Map<*, *>, result: MethodChannel.Result) {
        source(s, "jw")
        val operation = number(a, "operation")
        val action = when {
            method.startsWith("poll") -> "poll"
            method.startsWith("cancel") -> "cancel"
            method == "readJwProbe" -> "start"
            method == "readJwDataProbe" -> "data"
            else -> "collect"
        }
        val arguments = JSONObject().put("method", "probe").put("action", action)
            .put("operation", operation).put("selfRouteId", s.selfId)
        if (action in setOf("data", "collect")) {
            val semester = number(a, "semesterId"); if (semester > Int.MAX_VALUE) throw Failure("invalidSnapshot")
            arguments.put("semesterId", semester)
        }
        privateCall(s, arguments, result) {
            val value = it.getJSONArray("value")
            if (value.length() != 3 || value.get(0) !is Boolean || value.getString(1) != s.scripts.reply)
                throw Failure("invalidSnapshot")
            value.getJSONObject(2).toString()
        }
    }
    private fun young(s: Session, method: String, a: Map<*, *>, result: MethodChannel.Result) {
        source(s, "young")
        val operation = number(a, "operation")
        val args = JSONObject().put("operation", operation)
        when (method) {
            "startYoungBusiness" -> args.put("method", "start")
            "finishYoungBusiness" -> args.put("method", "finish")
            else -> {
                val step = number(a, "step"); if (step > 64000) throw Failure("invalidSnapshot")
                args.put("step", step)
                if (method == "pollYoungBusinessStep") args.put("method", "poll")
                else {
                    val endpoint = a["endpoint"] as? String ?: throw Failure("invalidSnapshot")
                    val page = number(a, "page", false)
                    if (endpoint !in setOf("profile", "activities", "schedule") || page > 1000) throw Failure("invalidSnapshot")
                    args.put("method", "dispatch").put("endpoint", endpoint).put("page", page)
                        .put("day", a["day"] ?: JSONObject.NULL)
                }
            }
        }
        pageCall(s, args, result) {
            if (method != "pollYoungBusinessStep") null
            else {
                val value = it.getJSONObject("value")
                val complete = value.getBoolean("complete")
                val reply = mutableMapOf<String, Any>("session" to s.id, "document" to s.document,
                    "operation" to operation, "step" to number(a, "step"), "complete" to complete)
                if (complete) reply["projectedJson"] = value.getString("projectedJson").also { text ->
                    if (text.toByteArray(Charsets.UTF_8).size > 1024 * 1024) throw Failure("invalidSnapshot")
                }
                reply
            }
        }
    }

    private fun exercise(s: Session, a: Map<*, *>, result: MethodChannel.Result) {
        if (!qa || !s.policy.fixture) throw Failure("unsupportedPlatform")
        val script = when (a["action"]) {
            "sameDocument", "youngSameUrlPush" -> "history.pushState({},'',location.href)"
            "youngSameUrlReplace" -> "history.replaceState({},'',location.href)"
            "nextDocument" -> "location.reload()"
            "userClose" -> { close(s, true, result); return }
            else -> throw Failure("unsupportedPlatform")
        }
        s.view.evaluateJavascript(script) { result.success(null) }
    }

    private fun close(s: Session, user: Boolean, result: MethodChannel.Result?) {
        if (s.closing) { result?.let { fail(it, "busy") }; return }
        s.closing = true; rejectPending(s); s.loginOperation = 0; s.privateProxy = null
        if (user) event(s, "userClosed")
        s.dialog?.dismiss(); s.dialog = null
        val clear = s.recovery || s.entry.ephemeral
        try {
            if (clear) ledger.revoke(s.entry)
            else { s.profile.cookieManager.flush(); ledger.retained(s.entry) }
            // stopLoading alone leaves script timers alive. There must be no
            // profile writer (including a pending popup) during SDK deletion.
            if (!s.viewsDestroyed) {
                s.children.toList().forEach { it.stopLoading(); it.destroy() }
                s.children.clear()
                s.view.stopLoading(); s.view.destroy(); s.viewsDestroyed = true
            }
            var answered = false
            val done = Runnable {
                try {
                    if (clear) ledger.cleared(s.entry)
                    if (active === s) active = null
                    closedSession = s.id
                    releaseProcessOwner()
                    if (!answered) { answered = true; result?.success(null) }
                } catch (_: Exception) {
                    s.closing = false; s.failed = true
                    if (disposed && s.viewsDestroyed && active === s) active = null
                    releaseProcessOwner()
                    if (!answered) { answered = true; result?.let { fail(it, "cleanupPending") } }
                }
            }
            if (clear) {
                WebStorageCompat.deleteBrowsingData(s.profile.webStorage, done)
                ui.postDelayed({
                    if (!answered) {
                        answered = true; s.failed = true
                        // Keep the drain barrier until the actual callback or a cold recovery.
                        result?.let { fail(it, "cleanupPending") }
                    }
                }, 15000)
            }
            else done.run()
        } catch (_: Exception) { s.closing = false; result?.let { fail(it, "cleanupPending") } }
    }
    fun dispose() {
        if (disposed) return
        // SDK clearing may finish after the engine detaches; no new engine may reuse this owner meanwhile.
        active?.let { close(it, false, null) }
        clearedRecovery = null
        disposed = true; channel.setMethodCallHandler(null)
        releaseProcessOwner()
    }
    private fun releaseProcessOwner() {
        if (processOwner === this && active == null && clearedRecovery == null) processOwner = null
    }
    fun onHostStopped() {
        active?.let { s ->
            if (!s.closing) { invalidate(s, "failed"); close(s, false, null) }
        }
    }

    companion object {
        // AndroidX's loaded-profile restriction lasts for the OS process, not the Flutter engine.
        private val loadedProfiles = mutableSetOf<String>()
        private var processOwner: ObservationBridge? = null
        private var sharedLedger: ProfileLedger? = null
        private val LOGIN_STATES = setOf("waiting", "portalActivated", "formReady", "businessReady",
            "manualRequired", "pageStructureChanged", "challengeRequired", "contextUnavailable", "submitted")
        private val YOUNG_REASONS = setOf("stampChanged", "nativeContext", "mainRoute", "contextLost",
            "compiledScript", "helperUnavailable", "preparationTimedOut", "sourceFailure")
    }
}
