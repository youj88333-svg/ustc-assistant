package cn.ustcassistant.mobile.qa

import android.net.Uri
import android.webkit.WebMessage
import android.webkit.WebView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
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

/** Synthetic loopback fixtures only; never connects to a real school or uses real credentials. */
@RunWith(AndroidJUnit4::class)
class A2ProviderTest {
    @Test fun ordinaryWorldBootstrapUsesSingleUseCredentialMessage() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assertTrue(context.packageName == "cn.ustcassistant.mobile.qa")
        val origin = "http://127.0.0.1:43127"
        val initialUrl = "$origin/cas/login"
        val policy = SchoolPolicy.fromArguments(mapOf("source" to "jw", "testMode" to true,
            "initialUrl" to initialUrl, "allowedOrigins" to listOf(origin)), true)
        val scripts = ScriptCatalog(context)
        val ready = CountDownLatch(1)
        var bootstrapResult: String? = null
        var browser: WebView? = null
        instrumentation.runOnMainSync {
            browser = WebView(context).also { view ->
                view.settings.javaScriptEnabled = true
                view.measure(android.view.View.MeasureSpec.makeMeasureSpec(1080, android.view.View.MeasureSpec.EXACTLY),
                    android.view.View.MeasureSpec.makeMeasureSpec(1600, android.view.View.MeasureSpec.EXACTLY))
                view.layout(0, 0, 1080, 1600)
                view.webViewClient = object: android.webkit.WebViewClient() {
                    override fun onPageFinished(v: WebView, url: String) {
                        if (url != initialUrl) return
                        v.evaluateJavascript(scripts.bootstrap(policy, url, 1L)) {
                            bootstrapResult = it
                            ready.countDown()
                        }
                    }
                }
                view.loadDataWithBaseURL(initialUrl, """<html><body>
                    <form id="normalLoginForm"><input name="username" type="text">
                    <input type="password"><button id="submitBtn" type="submit">Login</button></form>
                    <script>
                    window.passwordTouched=false;window.submitCount=0;
                    document.querySelector('[type=password]').addEventListener('input',()=>window.passwordTouched=true);
                    document.querySelector('form').addEventListener('submit',e=>{e.preventDefault();window.submitCount++});
                    </script></body></html>""", "text/html", "UTF-8", null)
            }
        }
        assertTrue(ready.await(15, TimeUnit.SECONDS))
        assertEquals("true", bootstrapResult)
        fun call(args: JSONObject): JSONObject {
            val done = CountDownLatch(1)
            var result: JSONObject? = null
            val source = scripts.apiCall(args.put("document", 1L))
            assertFalse("Credential text must stay out of evaluated source.",
                source.contains("SYNTHETIC") || source.contains("synthetic-secret"))
            instrumentation.runOnMainSync {
                browser!!.evaluateJavascript(source) {
                    try { result = scripts.unwrap(it) } catch (_: Exception) { }
                    done.countDown()
                }
            }
            assertTrue(done.await(5, TimeUnit.SECONDS))
            return result ?: throw AssertionError("Ordinary-world API returned no envelope")
        }
        assertEquals("formReady", call(JSONObject().put("method", "advance").put("operation", 1L))
            .getString("value"))
        val message = scripts.credentialMessage(1L, 1L, "SYNTHETIC", "synthetic-secret")
        instrumentation.runOnMainSync {
            browser!!.postWebMessage(WebMessage(message), Uri.parse(origin))
        }
        var secretResult: String? = null
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (System.nanoTime() < deadline && secretResult == null) {
            val reply = call(JSONObject().put("method", "secretResult")
                .put("operation", 1L).put("document", 1L))
            if (reply.has("value") && !reply.isNull("value")) secretResult = reply.getString("value")
            if (secretResult == null) Thread.sleep(50)
        }
        assertEquals("submitted", secretResult)
        // An exact duplicate message is ignored after the operation is consumed.
        instrumentation.runOnMainSync {
            browser!!.postWebMessage(WebMessage(message), Uri.parse(origin))
        }
        val inspected = CountDownLatch(1)
        var ordinaryWorldObserved = false
        instrumentation.runOnMainSync {
            browser!!.evaluateJavascript("window.passwordTouched&&window.submitCount===1&&document.querySelector('[type=password]').value==='synthetic-secret'") {
                ordinaryWorldObserved = it == "true"; inspected.countDown()
            }
        }
        assertTrue(inspected.await(5, TimeUnit.SECONDS))
        instrumentation.runOnMainSync { browser!!.destroy() }
        assertTrue("Same-origin page code can observe ordinary-world form values under the approved boundary.",
            ordinaryWorldObserved)
    }

    @Test fun oldFrameProxyCannotDeliverIntoAReplacementDocument() {
        assumeTrue("A missing private-world provider is not a passed stale-proxy check.",
            WebViewFeature.isFeatureSupported(WebViewFeature.JS_INJECTION_IN_FRAME_AND_WORLD))
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
