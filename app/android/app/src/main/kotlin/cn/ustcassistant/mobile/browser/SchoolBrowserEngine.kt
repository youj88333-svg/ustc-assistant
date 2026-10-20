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
import android.webkit.WebMessage
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

/** One ordinary-system-WebView operation set. The parent owns partition and process lifetime. */
internal class SchoolBrowserEngine(
    private val activity: Activity,
    private val eventSink: (Map<String, Any?>) -> Unit,
) {
    private val ui = Handler(Looper.getMainLooper())
    private val qa = activity.packageName == "cn.ustcassistant.mobile.qa" &&
        (activity.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
    @Volatile private var active: Session? = null
    private var closedSession: Long? = null
    private var disposed = false

    private class Failure(val code: String, val reason: String? = null) : RuntimeException()
    private class Session(
        val id: Long,
        val policy: SchoolPolicy,
        val view: WebView,
        val scripts: ScriptCatalog,
        val recovery: Boolean,
        val background: Boolean,
    ) {
        var document = 0L
        var ready = false
        var loading = false
        var closing = false
        var failed = false
        var viewsDestroyed = false
        var bootstrapGeneration = -1L
        var url = ""
        var committedUrl = ""
        var loginOperation = 0L
        var loginDocument = -1L
        var submitted = false
        var launcher = false
        var selfId = ""
        var callSequence = 0L
        var dialog: Dialog? = null
        var originLabel: TextView? = null
        val children = mutableSetOf<WebView>()
        val pending = mutableMapOf<Long, Pending>()
    }
    private class Pending(
        val document: Long,
        val result: BrowserResult,
        val page: Boolean,
        val preNavigation: Boolean = false,
        val consume: (JSONObject) -> Any?,
    )

    fun isActive(): Boolean = active?.let { !it.closing } == true

    fun handle(method: String, args: Map<*, *>, result: BrowserResult) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            handleMain(method, args, result)
        } else {
            ui.post { handleMain(method, args, result) }
        }
    }

    private fun handleMain(method: String, args: Map<*, *>, result: BrowserResult) {
        try {
            if (disposed) throw Failure("closed")
            validateArguments(method, args)
            when (method) {
                "checkSupport" -> result.success(null)
                "open" -> open(args, result)
                "close" -> {
                    val id = number(args, "session")
                    val session = active
                    if (session == null && id == closedSession) result.success(null)
                    else if (session == null || session.id != id) throw Failure("staleResult")
                    else close(session, false, result)
                }
                "inspect" -> {
                    val s = current(args)
                    result.success(mapOf(
                        "session" to s.id,
                        "document" to s.document,
                        "ready" to ready(s),
                        "origin" to s.policy.origin(s.url),
                        "windowVisible" to (s.dialog?.isShowing == true),
                        "windowForeground" to (s.dialog?.window?.decorView?.hasWindowFocus() == true),
                    ))
                }
                "navigateInitial" -> {
                    val s = current(args, document = false)
                    navigate(s, s.policy.initialUrl)
                    result.success(null)
                }
                "navigateJwPage" -> {
                    val s = current(args)
                    source(s, "jw")
                    navigate(s, s.policy.jwLauncher(args["page"] as? String ?: ""))
                    result.success(null)
                }
                "navigateYoungBusinessPage" -> {
                    val s = current(args, document = false)
                    source(s, "young")
                    if (s.document != number(args, "document", false)) throw Failure("busy")
                    val destination = s.policy.youngPage(args["page"] as? String ?: "")
                    pageCall(s, JSONObject().put("method", "navigationReady"), result, preNavigation = true) {
                        if (!it.getBoolean("value")) throw Failure("busy")
                        navigate(s, destination)
                        null
                    }
                }
                "advanceJwLogin", "advanceYoungLogin" -> {
                    val s = current(args)
                    source(s, if (method == "advanceJwLogin") "jw" else "young")
                    advance(s, args, result)
                }
                "submitJwLogin", "submitYoungLogin" -> {
                    val s = current(args)
                    source(s, if (method == "submitJwLogin") "jw" else "young")
                    submit(s, args, result)
                }
                "readJwProbe", "pollJwProbe", "cancelJwProbe",
                "readJwDataProbe", "pollJwDataProbe", "cancelJwDataProbe",
                "readJwCollection", "pollJwCollection", "cancelJwCollection" ->
                    probe(current(args), method, args, result)
                "prepareYoungBusinessPage" -> {
                    val s = current(args)
                    source(s, "young")
                    val page = args["page"] as? String ?: throw Failure("invalidSnapshot")
                    s.policy.youngPage(page)
                    val route = youngRoute(s.url, page)
                    if (!route) {
                        result.success(false)
                    } else {
                        // C2 owns the bounded readiness wait. One native call
                        // samples this document once; nesting a 12s native poll
                        // inside C1's 12s drain deadline used to race to timeout.
                        pageCall(s, JSONObject().put("method", "prepare").put("page", page), result) {
                            it.getBoolean("value")
                        }
                    }
                }
                "startYoungBusiness", "dispatchYoungBusinessStep", "pollYoungBusinessStep", "finishYoungBusiness" ->
                    young(current(args), method, args, result)
                "exerciseFixture" -> exercise(current(args), args, result)
                "inspectYoungPage", "startYoungReadOnly", "readYoungReadOnly", "stopYoungReadOnly" ->
                    throw Failure("unsupportedPlatform")
                else -> throw Failure("unsupportedPlatform")
            }
        } catch (error: Failure) {
            result.error(error.code, error.reason)
        } catch (_: IllegalArgumentException) {
            result.error("invalidSnapshot")
        } catch (_: Exception) {
            result.error("sourceFailed")
        } finally {
            // The parent owns the source lease. Wipe only this engine's transient IPC copy.
            (args["credentialBytes"] as? ByteArray)?.fill(0)
        }
    }

    private fun validateArguments(method: String, args: Map<*, *>) {
        val fields = when (method) {
            "checkSupport" -> emptySet()
            // profilePath can still arrive from an older caller; it is ignored here.
            "open" -> setOf("session", "profilePath", "initialUrl", "source", "allowedOrigins", "testMode", "recoveryOnly", "background")
            "close", "navigateInitial" -> setOf("session")
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
            else -> throw Failure("unsupportedPlatform")
        }
        val required = when (method) {
            "dispatchYoungBusinessStep" -> fields - "day"
            "open" -> fields - "profilePath"
            else -> fields
        }
        if (args.keys.any { it !in fields } || !args.keys.containsAll(required)) throw Failure("invalidSnapshot")
        if (method == "open" && listOf("testMode", "recoveryOnly", "background").any { args[it] !is Boolean })
            throw Failure("invalidSnapshot")
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun open(args: Map<*, *>, result: BrowserResult) {
        if (active != null) throw Failure("busy")
        val id = number(args, "session")
        val policy = SchoolPolicy.fromArguments(args, qa)
        val recovery = args["recoveryOnly"] as Boolean
        if (recovery) {
            // Recovery/cleanup is owned by the parent ledger and never creates a WebView.
            closedSession = id
            result.success(null)
            return
        }
        val scripts = ScriptCatalog(activity)
        val view = WebView(activity)
        val s = Session(id, policy, view, scripts, false, args["background"] as Boolean)
        try {
            view.settings.apply {
                javaScriptEnabled = true
                domStorageEnabled = true
                cacheMode = android.webkit.WebSettings.LOAD_NO_CACHE
                allowFileAccess = false
                allowContentAccess = false
                mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW
                setSupportMultipleWindows(true)
                javaScriptCanOpenWindowsAutomatically = true
                mediaPlaybackRequiresUserGesture = true
                setGeolocationEnabled(false)
                saveFormData = false
            }
            active = s
            closedSession = null
            attachClients(s)
            show(s)
            if (s.background) s.dialog?.hide()
            navigate(s, policy.initialUrl)
            result.success(null)
        } catch (error: Exception) {
            active = null
            destroyViews(s)
            if (error is Failure) throw error
            throw Failure("sourceFailed")
        }
    }

    private fun current(args: Map<*, *>, document: Boolean = true): Session {
        val s = active ?: throw Failure("closed")
        if (s.id != number(args, "session") || s.closing || s.failed ||
            (document && s.document != number(args, "document", false))) throw Failure("staleResult")
        return s
    }

    private fun source(s: Session, expected: String) {
        if (s.policy.source != expected) throw Failure("invalidSnapshot")
    }

    private fun number(args: Map<*, *>, key: String, positive: Boolean = true): Long {
        val value = args[key]
        if (value !is Int && value !is Long) throw Failure("invalidSnapshot")
        return (value as Number).toLong().also {
            if (it < (if (positive) 1 else 0) || it > 9007199254740991L) throw Failure("invalidSnapshot")
        }
    }

    private fun ready(s: Session) = s.ready && !s.loading && !s.failed && !s.closing

    private fun navigate(s: Session, url: String) {
        if (s.recovery || !s.policy.navigation(url).allowed) throw Failure("invalidSnapshot")
        if (s.policy.source == "jw" && url in setOf(s.policy.jwLauncher("courseTable"), s.policy.jwLauncher("examArrange"))) {
            s.launcher = true
        }
        s.view.loadUrl(url)
    }

    private fun attachClients(s: Session) {
        s.view.setDownloadListener { _, _, _, _, _ ->
            diagnostic(s, "downloadBlocked", s.url)
            // Old providers can emit onPageStarted for an attachment without
            // ever replacing the HTML document or delivering onPageFinished.
            // Restore readiness only when the provider still reports our last
            // committed document. Its new generation keeps old reads revoked.
            ui.post {
                if (active === s && !s.closing && !s.failed && s.loading &&
                    s.committedUrl.isNotEmpty() && s.view.url == s.committedUrl) {
                    s.url = s.committedUrl
                    s.loading = false
                    installForCurrentDocument(s, s.committedUrl)
                }
            }
        }
        s.view.webViewClient = object : WebViewClient() {
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
                val destination = request.requestHeaders["Sec-Fetch-Dest"] ?: request.requestHeaders["sec-fetch-dest"]
                if ((request.isForMainFrame || destination == "iframe" || destination == "document") &&
                    !s.policy.navigation(request.url.toString()).allowed) {
                    ui.post { diagnostic(s, "documentRequestBlocked", request.url.toString()) }
                    return WebResourceResponse("text/plain", "UTF-8", 403, "Blocked", emptyMap(),
                        ByteArrayInputStream(ByteArray(0)))
                }
                return null
            }

            override fun onPageStarted(view: WebView, url: String, icon: android.graphics.Bitmap?) {
                if (active !== s || s.closing) return
                if (!s.policy.navigation(url).allowed) {
                    view.stopLoading()
                    invalidate(s, "blocked")
                    return
                }
                newDocument(s, url)
                s.loading = true
                val path = Uri.parse(url).path ?: ""
                if (s.policy.origin(url) == s.policy.businessOrigin && path in
                    setOf("/for-std/course-table", "/for-std/exam-arrange")) s.launcher = true
                val match = Regex("^/for-std/(?:course-table|exam-arrange)/info/([0-9]{1,12})/?$").matchEntire(path)
                if (s.launcher && match != null && s.policy.origin(url) == s.policy.businessOrigin) {
                    s.selfId = match.groupValues[1]
                    s.launcher = false
                }
            }

            override fun doUpdateVisitedHistory(view: WebView, url: String, reload: Boolean) {
                if (active !== s || s.closing) return
                if (!s.loading && url == s.view.url) {
                    if (isYoungStateOnlyHistory(s, url, reload)) return
                    historyChanged(s, url)
                }
            }

            override fun onPageFinished(view: WebView, url: String) {
                if (active !== s || s.closing || url != s.view.url) return
                s.url = url
                s.loading = false
                s.originLabel?.text = s.policy.origin(url) ?: "受限页面"
                installForCurrentDocument(s, url)
            }

            override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
                handler.cancel()
                invalidate(s, "failed")
            }

            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: android.webkit.WebResourceError) {
                if (request.isForMainFrame) invalidate(s, "failed")
            }

            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                invalidate(s, "failed")
                close(s, false, null)
                return true
            }
        }
        s.view.webChromeClient = object : WebChromeClient() {
            override fun onPermissionRequest(request: PermissionRequest) {
                request.deny()
                diagnostic(s, "permissionBlocked", s.url)
            }

            override fun onGeolocationPermissionsShowPrompt(origin: String, callback: GeolocationPermissions.Callback) {
                callback.invoke(origin, false, false)
                diagnostic(s, "permissionBlocked", s.url)
            }

            override fun onShowFileChooser(
                view: WebView,
                callback: ValueCallback<Array<Uri>>,
                params: FileChooserParams,
            ): Boolean {
                callback.onReceiveValue(null)
                diagnostic(s, "permissionBlocked", s.url)
                return true
            }

            override fun onCreateWindow(view: WebView, dialog: Boolean, userGesture: Boolean, message: Message): Boolean {
                if (!userGesture || s.closing || s.children.isNotEmpty()) {
                    diagnostic(s, "popupBlocked", s.url)
                    return false
                }
                val child = WebView(activity)
                child.settings.javaScriptEnabled = false
                child.settings.allowFileAccess = false
                child.settings.allowContentAccess = false
                s.children.add(child)
                fun discardChild() {
                    if (s.children.remove(child)) {
                        child.stopLoading()
                        child.destroy()
                    }
                }
                child.webViewClient = object : WebViewClient() {
                    override fun shouldInterceptRequest(v: WebView, request: WebResourceRequest): WebResourceResponse {
                        ui.post {
                            if (child in s.children && active === s && !s.closing) {
                                val decision = s.policy.navigation(request.url.toString())
                                if (request.isForMainFrame && request.method == "GET" && decision.allowed)
                                    navigate(s, request.url.toString())
                                else diagnostic(s, "popupBlocked", request.url.toString())
                                discardChild()
                            }
                        }
                        return WebResourceResponse("text/plain", "UTF-8", 403, "Blocked", emptyMap(),
                            ByteArrayInputStream(ByteArray(0)))
                    }

                    override fun shouldOverrideUrlLoading(v: WebView, request: WebResourceRequest): Boolean {
                        val url = request.url.toString()
                        val decision = s.policy.navigation(url)
                        if (!decision.allowed) diagnostic(s, "popupBlocked", url)
                        if (request.method != "GET") diagnostic(s, "popupBlocked", url)
                        else if (decision.allowed) navigate(s, url)
                        else if (decision.upgradeUrl != null) navigate(s, decision.upgradeUrl)
                        ui.post { discardChild() }
                        return true
                    }
                }
                (message.obj as WebView.WebViewTransport).webView = child
                message.sendToTarget()
                ui.postDelayed({ discardChild() }, 5000)
                return true
            }
        }
    }

    private fun installForCurrentDocument(s: Session, url: String) {
        if (s.bootstrapGeneration == s.document) {
            if (s.ready) event(s, "ready")
            return
        }
        val document = s.document
        val script = s.scripts.bootstrap(s.policy, url, document)
        s.view.evaluateJavascript(script) { raw ->
            if (active !== s || s.closing || s.document != document || s.view.url != url) return@evaluateJavascript
            if (raw != "true") {
                invalidate(s, "failed")
                return@evaluateJavascript
            }
            s.bootstrapGeneration = document
            s.committedUrl = url
            s.ready = true
            event(s, "ready")
        }
    }

    private fun show(s: Session) {
        val dialog = Dialog(activity)
        val layout = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
        val toolbar = LinearLayout(activity)
        val origin = TextView(activity).apply {
            text = s.policy.businessOrigin
            setPadding(16, 12, 8, 12)
        }
        val returnButton = Button(activity).apply {
            text = "返回应用"
            setOnClickListener {
                dialog.hide()
                event(s, "returnToApp")
            }
        }
        val closeButton = Button(activity).apply {
            text = "关闭"
            setOnClickListener { close(s, true, null) }
        }
        toolbar.addView(origin, LinearLayout.LayoutParams(0, -2, 1f))
        toolbar.addView(returnButton)
        toolbar.addView(closeButton)
        layout.addView(toolbar)
        layout.addView(s.view, LinearLayout.LayoutParams(-1, 0, 1f))
        dialog.setContentView(layout)
        dialog.setOnCancelListener { close(s, true, null) }
        dialog.setOnKeyListener { _, key, keyEvent ->
            if (key == android.view.KeyEvent.KEYCODE_BACK && keyEvent.action == android.view.KeyEvent.ACTION_UP) {
                dialog.hide()
                event(s, "returnToApp")
                true
            } else false
        }
        s.dialog = dialog
        s.originLabel = origin
        dialog.show()
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            dialog.onBackInvokedDispatcher.registerOnBackInvokedCallback(
                android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT,
            ) {
                dialog.hide()
                event(s, "returnToApp")
            }
        }
        dialog.window?.setLayout(-1, -1)
    }

    fun showWindow() {
        val action: () -> Unit = {
            active?.let { s ->
                if (!s.background && !s.closing && !activity.isFinishing) {
                    s.dialog?.show()
                    s.dialog?.window?.setLayout(-1, -1)
                }
            }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) action() else ui.post(action)
    }

    private fun newDocument(s: Session, url: String) {
        rejectPending(s, readinessRace = true, reason = "contextLost")
        s.document++
        s.url = url
        s.ready = false
        s.loading = true
        s.bootstrapGeneration = -1L
        s.loginOperation = 0
        s.loginDocument = -1L
        s.submitted = false
        event(s, "navigating")
    }

    private fun isYoungStateOnlyHistory(s: Session, url: String, reload: Boolean): Boolean =
        !reload && s.policy.source == "young" && ready(s) &&
            s.bootstrapGeneration == s.document && s.url == url && s.committedUrl == url &&
            s.policy.origin(url) == s.policy.businessOrigin &&
            (youngRoute(url, "activities") || youngRoute(url, "calendar"))

    private fun historyChanged(s: Session, url: String) {
        rejectPending(s, readinessRace = true, reason = "historyNativeChanged")
        s.document++
        s.url = url
        s.loginOperation = 0
        s.loginDocument = -1L
        s.submitted = false
        event(s, "navigating")
        s.ready = false
        s.bootstrapGeneration = -1L
        installForCurrentDocument(s, url)
    }

    private fun rejectPending(s: Session, readinessRace: Boolean = false, reason: String? = null) {
        val pending = s.pending.values.toList()
        s.pending.clear()
        pending.forEach { call ->
            call.result.error(if (readinessRace && call.preNavigation) "busy" else "staleResult",
                reason.takeIf { call.page && !call.preNavigation })
        }
    }

    private fun invalidate(s: Session, kind: String) {
        if (active !== s || s.closing) return
        rejectPending(s)
        s.document++
        s.ready = false
        s.loading = false
        s.bootstrapGeneration = -1L
        s.loginOperation = 0
        s.loginDocument = -1L
        s.submitted = false
        s.failed = kind == "failed"
        event(s, kind)
    }

    private fun event(s: Session, kind: String) {
        if (disposed) return
        try {
            eventSink(mapOf(
                "session" to s.id,
                "document" to s.document,
                "kind" to kind,
                "origin" to s.policy.origin(s.url),
            ))
        } catch (_: Exception) { }
    }

    private fun diagnostic(s: Session, code: String, url: String) {
        if (disposed || active !== s) return
        val decision = s.policy.navigation(url)
        try {
            eventSink(mapOf(
                "session" to s.id,
                "document" to s.document,
                "kind" to "diagnostic",
                "diagnostic" to mapOf("code" to code, "site" to decision.site, "scheme" to decision.scheme),
            ))
        } catch (_: Exception) { }
    }

    private fun invokeApi(
        s: Session,
        args: JSONObject,
        result: BrowserResult,
        timeoutMs: Long = CALL_TIMEOUT_MS,
        consume: (JSONObject) -> Any?,
    ) {
        if (!ready(s)) throw Failure("staleResult")
        val id = ++s.callSequence
        args.put("document", s.document)
        s.pending[id] = Pending(s.document, result, page = false, consume = consume)
        s.view.evaluateJavascript(s.scripts.apiCall(args)) { raw -> completeJavascript(s, id, raw) }
        timeout(s, id, timeoutMs)
    }

    private fun pageCall(
        s: Session,
        args: JSONObject,
        result: BrowserResult,
        preNavigation: Boolean = false,
        consume: (JSONObject) -> Any?,
    ) {
        if (!ready(s)) throw Failure(if (preNavigation) "busy" else "staleResult")
        val id = ++s.callSequence
        args.put("document", s.document).put("call", id)
        s.pending[id] = Pending(s.document, result, page = true, preNavigation = preNavigation, consume = consume)
        s.view.evaluateJavascript(s.scripts.pageCall(args)) { raw -> completeJavascript(s, id, raw) }
        timeout(s, id, CALL_TIMEOUT_MS)
    }

    private fun completeJavascript(s: Session, id: Long, raw: String?) {
        val pending = s.pending[id] ?: return
        try {
            val envelope = s.scripts.unwrap(raw, page = pending.page)
            if (pending.page && envelope.getLong("call") != id) throw Failure("invalidSnapshot")
            complete(s, id, envelope)
        } catch (failure: Failure) {
            completeError(s, id, failure.code, failure.reason)
        } catch (_: Exception) {
            completeError(s, id, "invalidSnapshot")
        }
    }

    private fun timeout(s: Session, id: Long, timeoutMs: Long) {
        ui.postDelayed({ if (id in s.pending) completeError(s, id, "sourceFailed") }, timeoutMs)
    }

    private fun completeError(s: Session, id: Long, code: String, reason: String? = null) {
        val pending = s.pending.remove(id) ?: return
        val resultCode = if (active !== s || s.closing || s.failed) "staleResult"
        else if (pending.preNavigation && (s.document != pending.document || code == "staleResult")) "busy"
        else if (s.document != pending.document) "staleResult" else code
        pending.result.error(resultCode, reason)
    }

    private fun complete(s: Session, id: Long, envelope: JSONObject) {
        val pending = s.pending.remove(id) ?: return
        if (active !== s || s.document != pending.document || s.closing) {
            pending.result.error(if (pending.preNavigation && active === s && !s.closing && !s.failed) "busy" else "staleResult")
            return
        }
        try {
            if (envelope.has("error")) {
                val error = envelope.getJSONObject("error")
                val code = error.optString("code")
                val reason = error.optString("reason")
                if (code !in setOf("sourceFailed", "staleResult", "invalidSnapshot", "busy"))
                    throw Failure("invalidSnapshot")
                throw Failure(if (pending.preNavigation && code == "staleResult") "busy" else code,
                    reason.takeIf { it in YOUNG_REASONS })
            }
            pending.result.success(pending.consume(envelope))
        } catch (error: Failure) {
            pending.result.error(error.code, error.reason)
        } catch (_: Exception) {
            pending.result.error("invalidSnapshot")
        }
    }

    private fun advance(s: Session, args: Map<*, *>, result: BrowserResult) {
        val operation = number(args, "operation")
        if (!ready(s)) { result.success("waiting"); return }
        val path = Uri.parse(s.url).path ?: ""
        if (s.policy.origin(s.url) == s.policy.businessOrigin && (path == "/" || path.isEmpty())) {
            navigate(s, s.policy.businessOrigin + if (s.policy.source == "jw") "/login" else "/login/")
            result.success("waiting")
            return
        }
        if (s.policy.source == "young" && s.policy.origin(s.url) == s.policy.businessOrigin &&
            path.startsWith("/login/sc-wisdom-group-learning")) {
            val prefix = "/login/sc-wisdom-group-learning/"
            result.success(if (path.startsWith(prefix) && path.length > prefix.length) "businessReady" else "waiting")
            return
        }
        if (s.policy.source == "jw" && (path == "/home" ||
                Regex("^/for-std/(?:course-table|exam-arrange)/info/[0-9]{1,12}/?$").matches(path)) &&
            s.policy.origin(s.url) == s.policy.businessOrigin) {
            result.success("businessReady")
            return
        }
        if (!s.policy.isCas(s.url) && !(s.policy.source == "jw" &&
                s.policy.origin(s.url) == s.policy.businessOrigin && path == "/login")) {
            result.success("waiting")
            return
        }
        if (s.submitted && s.loginOperation == operation) { result.success("waiting"); return }
        invokeApi(s, JSONObject().put("method", "advance").put("operation", operation), result) {
            val state = it.getString("value")
            if (state !in LOGIN_STATES) throw Failure("invalidSnapshot")
            if (state == "formReady") {
                s.loginOperation = operation
                s.loginDocument = s.document
            }
            state
        }
    }

    private fun submit(s: Session, args: Map<*, *>, result: BrowserResult) {
        val operation = number(args, "operation")
        if (!s.policy.isCas(s.url) || !ready(s) || s.loginOperation != operation ||
            s.loginDocument != s.document || s.submitted) throw Failure("staleResult")
        val bytes = args["credentialBytes"] as? ByteArray ?: throw Failure("invalidSnapshot")
        if (bytes.isEmpty() || bytes.size > 16384) throw Failure("invalidSnapshot")
        val chars = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString().toCharArray()
        try {
            val secret = JSONObject(String(chars))
            require(secret.length() == 2)
            val username = secret.getString("username")
            val password = secret.getString("password")
            require(username.isNotEmpty() && username.length <= 64 && password.isNotEmpty() && password.length <= 4096)
            // Consume before sending. A missing/late acknowledgement never causes a second post.
            s.submitted = true
            val document = s.document
            val id = ++s.callSequence
            s.pending[id] = Pending(document, result, page = false, consume = { it.getString("value") })
            val message = s.scripts.credentialMessage(operation, document, username, password)
            try {
                s.view.postWebMessage(WebMessage(message), Uri.parse(s.policy.casOrigin))
            } catch (_: Exception) {
                s.pending.remove(id)
                result.error("sourceFailed", "deliveryUnknown")
                return
            }
            pollSecretResult(s, id, operation, document, System.currentTimeMillis() + SECRET_ACK_BUDGET_MS)
            timeout(s, id, SECRET_ACK_BUDGET_MS)
        } finally {
            chars.fill('\u0000')
        }
    }

    private fun pollSecretResult(s: Session, id: Long, operation: Long, document: Long, deadline: Long) {
        if (id !in s.pending || active !== s || s.closing || s.document != document) return
        val args = JSONObject().put("method", "secretResult").put("operation", operation).put("document", document)
        s.view.evaluateJavascript(s.scripts.apiCall(args)) { raw ->
            if (id !in s.pending || active !== s || s.closing || s.document != document) return@evaluateJavascript
            try {
                val envelope = s.scripts.unwrap(raw)
                if (envelope.has("error")) throw Failure("sourceFailed")
                val value = envelope.opt("value")
                if (value is String) {
                    if (value !in LOGIN_STATES) throw Failure("invalidSnapshot")
                    complete(s, id, envelope)
                } else if (System.currentTimeMillis() < deadline) {
                    ui.postDelayed({ pollSecretResult(s, id, operation, document, deadline) }, SECRET_POLL_MS)
                } else {
                    completeError(s, id, "sourceFailed", "deliveryUnknown")
                }
            } catch (failure: Failure) {
                completeError(s, id, failure.code, failure.reason)
            } catch (_: Exception) {
                completeError(s, id, "sourceFailed", "deliveryUnknown")
            }
        }
    }

    private fun probe(s: Session, method: String, args: Map<*, *>, result: BrowserResult) {
        source(s, "jw")
        val operation = number(args, "operation")
        val action = when {
            method.startsWith("poll") -> "poll"
            method.startsWith("cancel") -> "cancel"
            method == "readJwProbe" -> "start"
            method == "readJwDataProbe" -> "data"
            else -> "collect"
        }
        val call = JSONObject().put("method", "probe").put("action", action)
            .put("operation", operation).put("selfRouteId", s.selfId)
        if (action in setOf("data", "collect")) {
            val semester = number(args, "semesterId")
            if (semester > Int.MAX_VALUE) throw Failure("invalidSnapshot")
            call.put("semesterId", semester)
        }
        invokeApi(s, call, result) {
            val value = it.getJSONArray("value")
            if (value.length() != 3 || value.get(0) !is Boolean || value.getString(1) != s.scripts.reply)
                throw Failure("invalidSnapshot")
            value.getJSONObject(2).toString()
        }
    }

    private fun young(
        s: Session,
        method: String,
        request: Map<*, *>,
        result: BrowserResult,
    ) {
        source(s, "young")
        val operation = number(request, "operation")
        val call = JSONObject().put("operation", operation)
        when (method) {
            "startYoungBusiness" -> call.put("method", "start")
            "finishYoungBusiness" -> call.put("method", "finish")
            else -> {
                val step = number(request, "step")
                if (step > 64000) throw Failure("invalidSnapshot")
                call.put("step", step)
                if (method == "pollYoungBusinessStep") call.put("method", "poll")
                else {
                    val endpoint = request["endpoint"] as? String ?: throw Failure("invalidSnapshot")
                    val page = number(request, "page", false)
                    if (endpoint !in setOf("profile", "activities", "schedule") || page > 1000)
                        throw Failure("invalidSnapshot")
                    call.put("method", "dispatch").put("endpoint", endpoint).put("page", page)
                        .put("day", request["day"] ?: JSONObject.NULL)
                }
            }
        }
        pageCall(s, call, result) {
            if (method != "pollYoungBusinessStep") null
            else {
                val value = it.getJSONObject("value")
                val complete = value.getBoolean("complete")
                val reply = mutableMapOf<String, Any>(
                    "session" to s.id,
                    "document" to s.document,
                    "operation" to operation,
                    "step" to number(request, "step"),
                    "complete" to complete,
                )
                if (complete) reply["projectedJson"] = value.getString("projectedJson").also { text ->
                    if (text.toByteArray(Charsets.UTF_8).size > 1024 * 1024) throw Failure("invalidSnapshot")
                }
                reply
            }
        }
    }

    private fun youngRoute(url: String, page: String): Boolean {
        val expected = when (page) {
            "activities" -> "/login/sc-wisdom-group-learning/myproject/SignUp"
            "calendar" -> "/login/sc-wisdom-group-learning/personalInformation/mySchedule"
            else -> return false
        }
        return Uri.parse(url).path == expected
    }

    private fun exercise(s: Session, args: Map<*, *>, result: BrowserResult) {
        if (!qa || !s.policy.fixture) throw Failure("unsupportedPlatform")
        val script = when (args["action"]) {
            "sameDocument", "youngSameUrlPush" -> "history.pushState({},'',location.href)"
            "youngSameUrlReplace" -> "history.replaceState({},'',location.href)"
            "nextDocument" -> "location.reload()"
            "userClose" -> { result.success(null); close(s, true, null); return }
            else -> throw Failure("unsupportedPlatform")
        }
        s.view.evaluateJavascript(script) { result.success(null) }
    }

    private fun close(s: Session, user: Boolean, result: BrowserResult?) {
        if (s.closing || s.viewsDestroyed) {
            result?.success(null)
            return
        }
        s.closing = true
        rejectPending(s)
        s.loginOperation = 0
        if (user) event(s, "userClosed")
        try {
            android.webkit.CookieManager.getInstance().flush()
            destroyViews(s)
            if (active === s) active = null
            closedSession = s.id
            result?.success(null)
        } catch (_: Exception) {
            if (active === s) active = null
            closedSession = s.id
            result?.error("cleanupPending")
        }
    }

    private fun destroyViews(s: Session) {
        if (s.viewsDestroyed) return
        s.dialog?.setOnCancelListener(null)
        s.dialog?.dismiss()
        s.dialog = null
        s.children.toList().forEach { child ->
            try { child.stopLoading(); child.destroy() } catch (_: Exception) { }
        }
        s.children.clear()
        try { s.view.stopLoading(); s.view.destroy() } finally { s.viewsDestroyed = true }
    }

    fun onHostStopped() {
        val action: () -> Unit = {
            active?.let { s ->
                if (!s.closing) {
                    invalidate(s, "failed")
                    close(s, false, null)
                }
            }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) action() else ui.post(action)
    }

    fun dispose() {
        val action: () -> Unit = {
            if (!disposed) {
                active?.let { close(it, false, null) }
                disposed = true
            }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) action() else ui.post(action)
    }

    private fun diag(s: Session, code: String, url: String) = diagnostic(s, code, url)

    companion object {
        private const val CALL_TIMEOUT_MS = 5000L
        private const val SECRET_ACK_BUDGET_MS = 5000L
        private const val SECRET_POLL_MS = 100L
        private val LOGIN_STATES = setOf(
            "waiting", "portalActivated", "formReady", "businessReady", "manualRequired",
            "pageStructureChanged", "challengeRequired", "contextUnavailable", "submitted",
        )
        private val YOUNG_REASONS = setOf(
            "stampChanged", "nativeContext", "mainRoute", "contextLost", "compiledScript",
            "historyPushChanged", "historyReplaceChanged", "historyTraversal", "historyHashChanged",
            "routeAddressChanged", "historyNativeChanged",
            "helperUnavailable", "preparationTimedOut", "sourceFailure",
            "requestTarget", "requestMethod", "transportAmbiguous", "responseTarget",
            "requestOrigin", "requestPath", "requestQueryDuplicate", "requestQueryUnexpected", "requestQueryShape",
            "responseStatus", "responseMime", "responseTooLarge", "responseFormat",
            "transportFailed", "helperRejected", "xhrConfiguration",
        )
    }
}
