package cn.ustcassistant.mobile.qa

import android.webkit.WebView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import androidx.webkit.JavaScriptReplyProxy
import androidx.webkit.JavaScriptExecutionException
import androidx.webkit.WebViewOutcomeReceiver
import cn.ustcassistant.mobile.browser.SchoolPolicy
import cn.ustcassistant.mobile.browser.ScriptCatalog

/** No school, authentication assets, arbitrary scripts, or network requests. */
@RunWith(AndroidJUnit4::class)
class A2ProviderTest {
    @Test fun sameUrlReplaceInsideUsernameEventStopsBeforePasswordDelivery() {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.JS_INJECTION_IN_FRAME_AND_WORLD)) return
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assertTrue(context.packageName == "cn.ustcassistant.mobile.qa")
        val origin = "http://127.0.0.1:43127"
        val policy = SchoolPolicy.fromArguments(mapOf("source" to "jw", "testMode" to true,
            "initialUrl" to "$origin/cas/login", "allowedOrigins" to listOf(origin)), true)
        val scripts = ScriptCatalog(context)
        val ready = CountDownLatch(1)
        var proxy: JavaScriptReplyProxy? = null
        var browser: WebView? = null
        instrumentation.runOnMainSync {
            browser = WebView(context).also { view ->
                view.settings.javaScriptEnabled = true
                view.measure(android.view.View.MeasureSpec.makeMeasureSpec(1080, android.view.View.MeasureSpec.EXACTLY),
                    android.view.View.MeasureSpec.makeMeasureSpec(1600, android.view.View.MeasureSpec.EXACTLY))
                view.layout(0, 0, 1080, 1600)
                val world = WebViewCompat.getExecutionWorld(view, "ustc.a2.login.history")
                WebViewCompat.addWebMessageListener(view, "__ustcSourceNative", setOf(origin), world) {
                        _, message, _, main, reply ->
                    if (main && message.data == "ready") { proxy = reply }
                }
                view.webViewClient = object: android.webkit.WebViewClient() {
                    override fun onPageFinished(v: WebView, url: String) { ready.countDown() }
                }
                WebViewCompat.addJavaScriptOnEvent(view, scripts.privateBootstrap(policy),
                    WebViewCompat.INJECTION_EVENT_DOCUMENT_START, setOf(origin), world)
                view.loadDataWithBaseURL("$origin/cas/login", """<html><body>
                    <form id="normalLoginForm"><input name="username" type="text">
                    <input type="password"><button id="submitBtn" type="submit">Login</button></form>
                    <script>
                    window.passwordTouched=false;window.clicked=false;
                    document.querySelector('[name=username]').addEventListener('input',()=>history.replaceState({},'',location.href));
                    document.querySelector('[type=password]').addEventListener('input',()=>window.passwordTouched=true);
                    document.querySelector('form').addEventListener('submit',e=>{e.preventDefault();window.clicked=true});
                    </script></body></html>""", "text/html", "UTF-8", null)
            }
        }
        assertTrue(ready.await(15, TimeUnit.SECONDS))
        fun call(args: JSONObject): String {
            val done = CountDownLatch(1)
            var result = "failed"
            instrumentation.runOnMainSync {
                proxy!!.executeJavaScript(scripts.privateCall(args),
                    object: WebViewOutcomeReceiver<String, JavaScriptExecutionException> {
                        override fun onResult(value: String) {
                            try { result = scripts.unwrap(value).getString("value") } catch (_: Exception) {}
                            done.countDown()
                        }
                        override fun onError(error: JavaScriptExecutionException) { done.countDown() }
                    })
            }
            assertTrue(done.await(5, TimeUnit.SECONDS)); return result
        }
        assertTrue("Fixed CAS form must prepare in the private world", call(JSONObject().put("method", "advance").put("operation", 1)) == "formReady")
        val submitted = call(JSONObject().put("method", "submit").put("operation", 1)
            .put("username", "SYNTHETIC").put("password", "synthetic-secret"))
        assertTrue(submitted == "manualRequired" || submitted == "pageStructureChanged")
        val inspected = CountDownLatch(1)
        var safe = false
        instrumentation.runOnMainSync {
            browser!!.evaluateJavascript("!window.passwordTouched&&!window.clicked&&document.querySelector('[type=password]').value.length===0") {
                safe = it == "true"; inspected.countDown()
            }
        }
        assertTrue(inspected.await(5, TimeUnit.SECONDS))
        instrumentation.runOnMainSync { browser!!.destroy() }
        assertTrue("A same-URL synchronous route change must revoke password delivery", safe)
    }

    @Test fun oldFrameProxyCannotDeliverIntoAReplacementDocument() {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.JS_INJECTION_IN_FRAME_AND_WORLD)) return
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assertTrue(context.packageName == "cn.ustcassistant.mobile.qa")
        val first = CountDownLatch(1)
        val second = CountDownLatch(1)
        val checked = CountDownLatch(1)
        var old: JavaScriptReplyProxy? = null
        var browser: WebView? = null
        var ordinal = 0
        var observed = false
        instrumentation.runOnMainSync {
            browser = WebView(context).also { view ->
                view.settings.javaScriptEnabled = true
                val world = WebViewCompat.getExecutionWorld(view, "ustc.a2.proxy.race")
                WebViewCompat.addWebMessageListener(view, "__a2Race", setOf("https://a2.invalid"), world) {
                        _, message, _, main, proxy ->
                    if (!main) return@addWebMessageListener
                    if (message.data == "hello") {
                        ordinal++
                        if (ordinal == 1) { old = proxy; first.countDown() } else second.countDown()
                    }
                }
                WebViewCompat.addJavaScriptOnEvent(view, "if(this===this.top)__a2Race.postMessage('hello')",
                    WebViewCompat.INJECTION_EVENT_DOCUMENT_END, setOf("https://a2.invalid"), world)
                view.loadDataWithBaseURL("https://a2.invalid/one", "<body>one</body>", "text/html", "UTF-8", null)
            }
        }
        assertTrue(first.await(15, TimeUnit.SECONDS))
        instrumentation.runOnMainSync {
            browser!!.loadDataWithBaseURL("https://a2.invalid/two", "<script>window.leaked=false</script><body>two</body>", "text/html", "UTF-8", null)
        }
        assertTrue(second.await(15, TimeUnit.SECONDS))
        instrumentation.runOnMainSync {
            old!!.executeJavaScript("document.body.dataset.secret='SYNTHETIC-OLD-PROXY'",
                object: WebViewOutcomeReceiver<String, JavaScriptExecutionException> {
                    override fun onResult(value: String) { checked.countDown() }
                    override fun onError(error: JavaScriptExecutionException) { checked.countDown() }
                })
        }
        // A stale JavaScript object may be silently discarded rather than call its receiver.
        checked.await(2, TimeUnit.SECONDS)
        val inspected = CountDownLatch(1)
        instrumentation.runOnMainSync {
            browser!!.evaluateJavascript("document.body.dataset.secret === undefined") {
                observed = it == "true"; inspected.countDown()
            }
        }
        assertTrue(inspected.await(5, TimeUnit.SECONDS))
        instrumentation.runOnMainSync { browser!!.destroy() }
        assertTrue("A stale frame proxy must not execute in the replacement document", observed)
    }

    @Test fun recordsActualProviderAndChecksIsolatedWorldWhenAvailable() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assertTrue(context.packageName == "cn.ustcassistant.mobile.qa")
        val report = JSONObject().put("kind", "android-a2-provider-v1")
        val completed = CountDownLatch(1)
        var view: WebView? = null
        var isolated = false
        instrumentation.runOnMainSync {
            try {
                report.put("provider", WebViewCompat.getCurrentWebViewPackage(context)?.versionName)
                for (feature in listOf(WebViewFeature.MULTI_PROFILE,
                        WebViewFeature.DELETE_BROWSING_DATA,
                        WebViewFeature.DOCUMENT_START_SCRIPT,
                        WebViewFeature.JS_INJECTION_IN_FRAME_AND_WORLD)) {
                    report.put(feature, WebViewFeature.isFeatureSupported(feature))
                }
                if (!WebViewFeature.isFeatureSupported(WebViewFeature.JS_INJECTION_IN_FRAME_AND_WORLD)) {
                    completed.countDown()
                } else {
                    view = WebView(context).also { browser ->
                        browser.settings.javaScriptEnabled = true
                        val world = WebViewCompat.getExecutionWorld(browser, "ustc.a2.provider.probe")
                        WebViewCompat.addWebMessageListener(browser, "__a2ProbeNative",
                            setOf("https://a2.invalid"), world) { _, message, origin, mainFrame, proxy ->
                            if (!mainFrame || origin.toString() != "https://a2.invalid") return@addWebMessageListener
                            when (message.data) {
                                "hello" -> proxy.executeJavaScript(
                                    "__a2ProbeNative.postMessage(typeof window.pageOnly === 'undefined' ? 'isolated' : 'shared')",
                                    object: WebViewOutcomeReceiver<String, JavaScriptExecutionException> {
                                        override fun onResult(value: String) {}
                                        override fun onError(error: JavaScriptExecutionException) { completed.countDown() }
                                    })
                                "isolated" -> { isolated = true; completed.countDown() }
                                else -> completed.countDown()
                            }
                        }
                        WebViewCompat.addJavaScriptOnEvent(browser,
                            "if(this===this.top)__a2ProbeNative.postMessage('hello')",
                            WebViewCompat.INJECTION_EVENT_DOCUMENT_END, setOf("https://a2.invalid"), world)
                        browser.loadDataWithBaseURL("https://a2.invalid/",
                            "<html><script>window.pageOnly=1</script><body>Synthetic</body></html>",
                            "text/html", "UTF-8", null)
                    }
                }
            } catch (_: Exception) { report.put("probeFailure", true); completed.countDown() }
        }
        val settled = completed.await(15, TimeUnit.SECONDS)
        instrumentation.runOnMainSync { view?.destroy() }
        report.put("settled", settled).put("isolatedRoundTrip", isolated)
        File(context.filesDir, "android-a2-provider.json").writeText(report.toString())
        assertTrue(settled)
        if (report.optBoolean(WebViewFeature.JS_INJECTION_IN_FRAME_AND_WORLD)) assertTrue(isolated)
    }
}
