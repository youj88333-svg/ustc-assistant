package cn.ustcassistant.mobile.qa

import android.annotation.SuppressLint
import android.security.NetworkSecurityPolicy
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import cn.ustcassistant.mobile.browser.FramePolicy
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.Assume.assumeTrue
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/** A synthetic loopback probe for the AndroidX isolated-world frame policy primitive. */
@RunWith(AndroidJUnit4::class)
class A2FramePolicyTest {
    @Test
    fun svgSubdocumentFailsClosedBeforeForeignObjectCanCreateAFrame() = withHarness { harness ->
        harness.secondary.respond("GET", "/unsupported.svg", SyntheticResponse(
            contentType = "image/svg+xml",
            body = """<svg xmlns="http://www.w3.org/2000/svg"><foreignObject width="100" height="100">
              <iframe xmlns="http://www.w3.org/1999/xhtml" src="${harness.deniedOrigin}/svg-child"/>
              </foreignObject></svg>"""))
        harness.open("/unsupported-frame", """<!doctype html><body>
            <iframe src="${harness.secondaryOrigin}/unsupported.svg"></iframe><p>synthetic</p></body>""")
        assertTrue(harness.secondary.awaitCount("GET", "/unsupported.svg", 1))
        harness.denied.awaitQuiet()
        assertEquals(0, harness.denied.count("GET", "/svg-child"))
        assertTrue("A non-HTML frame must report unavailable, not installed.", harness.guardFailures.get() > 0)
    }
    @Test
    fun documentStartPolicyBlocksParserAndDynamicFramesAndKeepsOrdinaryFetch() =
        withHarness { harness ->
            val html = """
                <!doctype html>
                <html><head><title>synthetic frame policy</title></head><body>
                  <p id="body-marker">original body survived</p>
                  <iframe id="parser-frame" src="${harness.deniedOrigin}/parser-frame"></iframe>
                  <script>
                    window.__inlineScriptRan = true;
                    var policy = document.querySelector('meta[http-equiv="Content-Security-Policy"]');
                    window.__policyWasVisible = !!policy;
                    if (policy) policy.parentNode.removeChild(policy);
                    window.__policyWasRemoved = !document.querySelector('meta[http-equiv="Content-Security-Policy"]');

                    var dynamicFrame = document.createElement('iframe');
                    dynamicFrame.src = '${harness.deniedOrigin}/dynamic-frame';
                    document.body.appendChild(dynamicFrame);

                    window.__fetchSucceeded = false;
                    fetch('${harness.deniedOrigin}/ordinary-fetch')
                      .then(function(response) { return response.text(); })
                      .then(function(body) { window.__fetchSucceeded = body === 'synthetic-fetch-ok'; })
                      .catch(function() { window.__fetchSucceeded = false; });

                    window.__imageLoaded = false;
                    var image = document.createElement('img');
                    image.onload = function() { window.__imageLoaded = true; };
                    image.src = '${harness.deniedOrigin}/ordinary-image.svg';
                    document.body.appendChild(image);

                    window.__scriptLoaded = false;
                    var externalScript = document.createElement('script');
                    externalScript.onload = function() { window.__scriptLoaded = true; };
                    externalScript.src = '${harness.deniedOrigin}/ordinary-script.js';
                    document.body.appendChild(externalScript);

                    window.__probeReady = true;
                  </script>
                </body></html>
            """.trimIndent()
            harness.open("/parser-dynamic", html)

            assertTrue(
                "Inline page JavaScript and the ordinary cross-origin fetch must still run.",
                harness.awaitJavaScriptTrue(
                    "window.__probeReady && window.__fetchSucceeded && window.__imageLoaded && " +
                        "window.__scriptLoaded && window.__externalScriptRan",
                ),
            )
            harness.denied.awaitQuiet()

            assertEquals(0, harness.denied.count("GET", "/parser-frame"))
            assertEquals(0, harness.denied.count("GET", "/dynamic-frame"))
            assertEquals(1, harness.denied.count("GET", "/ordinary-fetch"))
            assertEquals(1, harness.denied.count("GET", "/ordinary-image.svg"))
            assertEquals(1, harness.denied.count("GET", "/ordinary-script.js"))

            val dom = harness.evaluateJson(
                """JSON.stringify({
                  inlineRan: window.__inlineScriptRan === true,
                  policyWasRemoved: window.__policyWasRemoved === true,
                  bodyText: document.getElementById('body-marker') && document.getElementById('body-marker').textContent,
                  htmlCount: document.getElementsByTagName('html').length,
                  headCount: document.getElementsByTagName('head').length,
                  bodyCount: document.getElementsByTagName('body').length
                })""",
            )
            assertTrue("The original inline script must execute.", dom.getBoolean("inlineRan"))
            assertTrue("The page's attempted meta removal must complete.", dom.getBoolean("policyWasRemoved"))
            assertEquals("original body survived", dom.getString("bodyText"))
            assertEquals("Temporary parser scaffolding must not leave duplicate roots.", 1, dom.getInt("htmlCount"))
            assertEquals(1, dom.getInt("headCount"))
            assertEquals(1, dom.getInt("bodyCount"))
        }

    @Test
    fun exactAllowedOriginsCoverSubframesRedirectsSrcdocAndAboutBlank() =
        withHarness { harness ->
            val html = """
                <!doctype html>
                <html><head><title>synthetic allowed origins</title></head><body>
                  <p id="body-marker">allowed origins page survived</p>
                  <script>
                    window.__inlineScriptRan = true;
                    var policy = document.querySelector('meta[http-equiv="Content-Security-Policy"]');
                    if (policy) policy.parentNode.removeChild(policy);

                    var dynamicFrame = document.createElement('iframe');
                    dynamicFrame.src = '${harness.deniedOrigin}/dynamic-frame';
                    document.body.appendChild(dynamicFrame);

                    var allowedFrame = document.createElement('iframe');
                    allowedFrame.src = '${harness.secondaryOrigin}/allowed-frame';
                    document.body.appendChild(allowedFrame);

                    var redirectFrame = document.createElement('iframe');
                    redirectFrame.src = '${harness.secondaryOrigin}/redirect-to-denied';
                    document.body.appendChild(redirectFrame);

                    var selfNavigatingFrame = document.createElement('iframe');
                    selfNavigatingFrame.src = '${harness.secondaryOrigin}/self-nav-page';
                    document.body.appendChild(selfNavigatingFrame);

                    window.__sandboxSrcdocRan = false;
                    window.addEventListener('message', function(event) {
                      if (event.data === 'sandbox-srcdoc-ran') window.__sandboxSrcdocRan = true;
                    });
                    var sandboxFrame = document.createElement('iframe');
                    sandboxFrame.setAttribute('sandbox', 'allow-scripts');
                    sandboxFrame.srcdoc = '<!doctype html><html><body><script>parent.postMessage("sandbox-srcdoc-ran","*");var child=document.createElement("iframe");child.src="${harness.deniedOrigin}/sandbox-srcdoc-child";document.body.appendChild(child);<\/script></body></html>';
                    document.body.appendChild(sandboxFrame);

                    var aboutBlankFrame = document.createElement('iframe');
                    aboutBlankFrame.src = 'about:blank';
                    document.body.appendChild(aboutBlankFrame);
                    var blankDocument = aboutBlankFrame.contentDocument;
                    if (blankDocument) {
                      var blankBody = blankDocument.body;
                      if (!blankBody && blankDocument.documentElement) {
                        blankBody = blankDocument.createElement('body');
                        blankDocument.documentElement.appendChild(blankBody);
                      }
                      if (blankBody) {
                        var aboutBlankChild = blankDocument.createElement('iframe');
                        aboutBlankChild.src = '${harness.deniedOrigin}/aboutblank-child';
                        blankBody.appendChild(aboutBlankChild);
                        window.__aboutBlankConfigured = true;
                      }
                    }
                    window.__probeReady = true;
                  </script>
                </body></html>
            """.trimIndent()
            harness.open("/allowed-origins", html)

            assertTrue(
                "The top page and sandboxed opaque srcdoc script must execute.",
                harness.awaitJavaScriptTrue("window.__probeReady && window.__sandboxSrcdocRan"),
            )
            assertTrue(
                "Both explicitly allowed loopback origins must remain navigable.",
                harness.secondary.awaitCount("GET", "/allowed-frame", expected = 1) &&
                    harness.secondary.awaitCount("GET", "/redirect-to-denied", expected = 1) &&
                    harness.secondary.awaitCount("GET", "/self-nav-page", expected = 1) &&
                    harness.secondary.awaitCount("GET", "/self-nav-ran", expected = 1),
            )
            harness.denied.awaitQuiet()

            assertEquals(0, harness.denied.count("GET", "/dynamic-frame"))
            assertEquals(0, harness.denied.count("GET", "/nested-child"))
            assertEquals(0, harness.denied.count("GET", "/redirect-target"))
            assertEquals(0, harness.denied.count("GET", "/self-navigation-target"))
            assertEquals(0, harness.denied.count("GET", "/sandbox-srcdoc-child"))
            assertEquals(0, harness.denied.count("GET", "/aboutblank-child"))

            val dom = harness.evaluateJson(
                """JSON.stringify({
                  inlineRan: window.__inlineScriptRan === true,
                  aboutBlankConfigured: window.__aboutBlankConfigured === true,
                  bodyText: document.getElementById('body-marker') && document.getElementById('body-marker').textContent,
                  htmlCount: document.getElementsByTagName('html').length,
                  headCount: document.getElementsByTagName('head').length,
                  bodyCount: document.getElementsByTagName('body').length
                })""",
            )
            assertTrue(dom.getBoolean("inlineRan"))
            assertTrue("The inherited about:blank context must be exercised.", dom.getBoolean("aboutBlankConfigured"))
            assertEquals("allowed origins page survived", dom.getString("bodyText"))
            assertEquals(1, dom.getInt("htmlCount"))
            assertEquals(1, dom.getInt("headCount"))
            assertEquals(1, dom.getInt("bodyCount"))
        }

    @Test
    fun documentStartPolicyBlocksIframeTargetedPostAfterPageMetaRemoval() =
        withHarness { harness ->
            val html = """
                <!doctype html>
                <html><head><title>synthetic form target</title></head><body>
                  <p id="body-marker">form target page survived</p>
                  <iframe name="post-target"></iframe>
                  <script>
                    window.__inlineScriptRan = true;
                    window.addEventListener('load', function() {
                      var policy = document.querySelector('meta[http-equiv="Content-Security-Policy"]');
                      if (policy) policy.parentNode.removeChild(policy);
                      window.__policyRemoved = !document.querySelector('meta[http-equiv="Content-Security-Policy"]');

                      var form = document.createElement('form');
                      form.method = 'POST';
                      form.target = 'post-target';
                      form.action = '${harness.deniedOrigin}/form-post';
                      var field = document.createElement('input');
                      field.name = 'synthetic';
                      field.value = 'loopback-only';
                      form.appendChild(field);
                      document.body.appendChild(form);
                      form.submit();
                      window.__formSubmitted = true;
                    });
                  </script>
                </body></html>
            """.trimIndent()
            harness.open("/form-target", html)

            assertTrue(
                "Meta removal, when present, and the synthetic form submission must complete.",
                harness.awaitJavaScriptTrue(
                    "window.__policyRemoved && window.__formSubmitted",
                ),
            )
            harness.denied.awaitQuiet()
            assertEquals("A targeted form POST to a denied frame origin must not reach the endpoint.",
                0, harness.denied.count("POST", "/form-post"))

            val dom = harness.evaluateJson(
                """JSON.stringify({
                  inlineRan: window.__inlineScriptRan === true,
                  bodyText: document.getElementById('body-marker') && document.getElementById('body-marker').textContent,
                  htmlCount: document.getElementsByTagName('html').length,
                  headCount: document.getElementsByTagName('head').length,
                  bodyCount: document.getElementsByTagName('body').length
                })""",
            )
            assertTrue(dom.getBoolean("inlineRan"))
            assertEquals("form target page survived", dom.getString("bodyText"))
            assertEquals(1, dom.getInt("htmlCount"))
            assertEquals(1, dom.getInt("headCount"))
            assertEquals(1, dom.getInt("bodyCount"))
        }

    @Test
    fun documentOpenWriteKeepsPolicyForFramesCreatedByTheRewrittenDocument() =
        withHarness { harness ->
            harness.pageServer.respond(
                "GET",
                "/document-write-ran",
                SyntheticResponse(contentType = "text/plain; charset=utf-8", body = "ran"),
            )
            val html = """
                <!doctype html>
                <html><head><title>synthetic document rewrite</title></head><body>
                  <p id="original-body">original page survived until rewrite</p>
                  <script>
                    window.__originalInlineRan = true;
                    window.addEventListener('load', function() {
                      var policy = document.querySelector('meta[http-equiv="Content-Security-Policy"]');
                      if (policy) policy.parentNode.removeChild(policy);
                      window.__rewriteAttempted = true;
                      document.open();
                      document.write('<!doctype html><html><head><title>rewritten</title></head><body><p id="rewritten-body">rewritten body survived</p><script>fetch("${harness.pageOrigin}/document-write-ran").then(function(){var frame=document.createElement("iframe");frame.src="${harness.deniedOrigin}/document-write-frame";document.body.appendChild(frame);window.__rewrittenInlineRan=true;window.__rewriteReady=true;});<\/script></body></html>');
                      document.close();
                    });
                  </script>
                </body></html>
            """.trimIndent()
            harness.open("/document-open", html)

            assertTrue(
                "The document written after document.open must execute its script.",
                harness.awaitJavaScriptTrue("window.__rewriteReady && window.__rewrittenInlineRan"),
            )
            assertTrue(
                "A same-origin marker request proves the rewritten document executed before the frame check.",
                harness.pageServer.awaitCount("GET", "/document-write-ran", expected = 1),
            )
            harness.denied.awaitQuiet()
            assertEquals(0, harness.denied.count("GET", "/document-write-frame"))

            val dom = harness.evaluateJson(
                """JSON.stringify({
                  originalInlineRan: window.__originalInlineRan === true,
                  rewriteAttempted: window.__rewriteAttempted === true,
                  rewrittenInlineRan: window.__rewrittenInlineRan === true,
                  bodyText: document.getElementById('rewritten-body') && document.getElementById('rewritten-body').textContent,
                  htmlCount: document.getElementsByTagName('html').length,
                  headCount: document.getElementsByTagName('head').length,
                  bodyCount: document.getElementsByTagName('body').length
                })""",
            )
            assertTrue(dom.getBoolean("originalInlineRan"))
            assertTrue(dom.getBoolean("rewriteAttempted"))
            assertTrue(dom.getBoolean("rewrittenInlineRan"))
            assertEquals("rewritten body survived", dom.getString("bodyText"))
            assertEquals(1, dom.getInt("htmlCount"))
            assertEquals(1, dom.getInt("headCount"))
            assertEquals(1, dom.getInt("bodyCount"))
        }

    @Test
    fun backNavigationKeepsFramePolicyAndReportsWhetherBfcacheWasUsed() =
        withHarness { harness ->
            harness.pageServer.respond(
                "GET",
                "/history-bfcache-marker",
                SyntheticResponse(contentType = "text/plain; charset=utf-8", body = "bfcache"),
            )
            harness.pageServer.respond(
                "GET",
                "/history-reload-marker",
                SyntheticResponse(contentType = "text/plain; charset=utf-8", body = "reload"),
            )
            harness.pageServer.respond(
                "GET",
                "/history-second",
                SyntheticResponse(
                    body = """
                        <!doctype html><html><head><title>history second</title></head><body>
                          <p id="second-page">second history entry</p>
                          <script>window.__secondPageReady = true;</script>
                        </body></html>
                    """.trimIndent(),
                ),
            )
            val html = """
                <!doctype html>
                <html><head><title>history first</title></head><body>
                  <p id="first-page">first history entry</p>
                  <script>
                    window.__historyProbeDone = false;
                    window.__bfcacheHit = false;
                    window.addEventListener('pageshow', function(event) {
                      var navigation = performance.getEntriesByType('navigation')[0];
                      var returned = event.persisted || (navigation && navigation.type === 'back_forward');
                      if (!returned) return;
                      var policy = document.querySelector('meta[http-equiv="Content-Security-Policy"]');
                      if (policy) policy.parentNode.removeChild(policy);
                      window.__bfcacheHit = event.persisted === true;
                      var marker = event.persisted ? '/history-bfcache-marker' : '/history-reload-marker';
                      fetch(marker).then(function() {
                        var frame = document.createElement('iframe');
                        frame.src = '${harness.deniedOrigin}/history-after-back';
                        document.body.appendChild(frame);
                        window.__historyProbeDone = true;
                      });
                    });
                  </script>
                </body></html>
            """.trimIndent()
            harness.open("/history-first", html)
            assertTrue("Second history entry must load.", harness.navigateAndWait("/history-second", "window.__secondPageReady"))
            harness.goBack()
            assertTrue(
                "Back navigation must restore or reload the first document and execute its pageshow check.",
                harness.awaitJavaScriptTrue("window.__historyProbeDone"),
            )
            harness.denied.awaitQuiet()

            val bfcacheRequests = harness.pageServer.count("GET", "/history-bfcache-marker")
            val reloadRequests = harness.pageServer.count("GET", "/history-reload-marker")
            assertEquals("The test must identify exactly one restoration path.", 1, bfcacheRequests + reloadRequests)
            assertEquals(0, harness.denied.count("GET", "/history-after-back"))
            val state = harness.evaluateJson(
                """JSON.stringify({
                  bfcacheHit: window.__bfcacheHit === true,
                  bodyText: document.getElementById('first-page') && document.getElementById('first-page').textContent,
                  htmlCount: document.getElementsByTagName('html').length,
                  headCount: document.getElementsByTagName('head').length,
                  bodyCount: document.getElementsByTagName('body').length
                })""",
            )
            assertEquals(bfcacheRequests == 1, state.getBoolean("bfcacheHit"))
            assertEquals("first history entry", state.getString("bodyText"))
            assertEquals(1, state.getInt("htmlCount"))
            assertEquals(1, state.getInt("headCount"))
            assertEquals(1, state.getInt("bodyCount"))
            android.util.Log.i("A2FramePolicyTest", "history restoration bfcacheHit=${state.getBoolean("bfcacheHit")}")
        }

    @Test
    fun removingRetainedMetaAfterDocumentEndDoesNotRelaxFramePolicy() =
        withHarness { harness ->
            val html = """
                <!doctype html>
                <html><head><title>synthetic retained policy</title></head><body>
                  <p id="body-marker">retained policy page survived</p>
                  <script>
                    window.__inlineScriptRan = true;
                    window.addEventListener('load', function() {
                      var policy = document.querySelector('meta[http-equiv="Content-Security-Policy"]');
                      window.__policyWasPresent = !!policy;
                      if (policy) policy.parentNode.removeChild(policy);
                      window.__policyWasRemoved = !document.querySelector('meta[http-equiv="Content-Security-Policy"]');

                      var frame = document.createElement('iframe');
                      frame.src = '${harness.deniedOrigin}/after-meta-removal';
                      document.body.appendChild(frame);
                      window.__probeReady = true;
                    });
                  </script>
                </body></html>
            """.trimIndent()
            harness.open(
                "/retained-meta",
                html,
                injectionEvent = WebViewCompat.INJECTION_EVENT_DOCUMENT_END,
            )

            assertTrue(
                "The retained candidate meta must be visible and removable by page code.",
                harness.awaitJavaScriptTrue("window.__policyWasPresent && window.__policyWasRemoved && window.__probeReady"),
            )
            harness.denied.awaitQuiet()
            assertEquals(0, harness.denied.count("GET", "/after-meta-removal"))

            val dom = harness.evaluateJson(
                """JSON.stringify({
                  inlineRan: window.__inlineScriptRan === true,
                  bodyText: document.getElementById('body-marker') && document.getElementById('body-marker').textContent,
                  htmlCount: document.getElementsByTagName('html').length,
                  headCount: document.getElementsByTagName('head').length,
                  bodyCount: document.getElementsByTagName('body').length
                })""",
            )
            assertTrue(dom.getBoolean("inlineRan"))
            assertEquals("retained policy page survived", dom.getString("bodyText"))
            assertEquals(1, dom.getInt("htmlCount"))
            assertEquals(1, dom.getInt("headCount"))
            assertEquals(1, dom.getInt("bodyCount"))
        }

    private fun withHarness(block: (Harness) -> Unit) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assertEquals("cn.ustcassistant.mobile.qa", context.packageName)
        assumeTrue("This is an explicit missing-provider capability, not a source pass.",
            WebViewFeature.isFeatureSupported(WebViewFeature.JS_INJECTION_IN_FRAME_AND_WORLD))
        assertTrue(
            "Cleartext loopback is enabled only in the isolated QA target.",
            NetworkSecurityPolicy.getInstance().isCleartextTrafficPermitted("127.0.0.1"),
        )
        val harness = Harness(instrumentation, context)
        try {
            block(harness)
        } finally {
            harness.close()
        }
    }

    private inner class Harness(
        private val instrumentation: android.app.Instrumentation,
        private val context: android.content.Context,
    ) : Closeable {
        val pageServer = LoopbackServer()
        val secondary = LoopbackServer()
        val denied = LoopbackServer()
        val guardFailures = AtomicInteger(0)
        val pageOrigin: String get() = pageServer.origin
        val secondaryOrigin: String get() = secondary.origin
        val deniedOrigin: String get() = denied.origin
        private val allowedOrigins = linkedSetOf(pageOrigin, secondaryOrigin)
        private val pageFinished = CountDownLatch(1)
        private val finishedUrl = AtomicReference<String?>()
        private val pendingNavigation = AtomicReference<Pair<String, CountDownLatch>?>(null)
        private var webView: WebView? = null

        init {
            secondary.respond(
                "GET",
                "/allowed-frame",
                SyntheticResponse(
                    body = """
                        <!doctype html><html><head><title>allowed second origin</title></head><body>
                          <p>allowed frame rendered</p>
                          <iframe src="$deniedOrigin/nested-child"></iframe>
                        </body></html>
                    """.trimIndent(),
                ),
            )
            secondary.respond(
                "GET",
                "/redirect-to-denied",
                SyntheticResponse(
                    status = "302 Found",
                    headers = mapOf("Location" to "$deniedOrigin/redirect-target"),
                ),
            )
            secondary.respond(
                "GET",
                "/self-nav-page",
                SyntheticResponse(
                    body = """
                        <!doctype html><html><head></head><body>
                          <script>
                            fetch('/self-nav-ran').then(function() {
                              location.replace('$deniedOrigin/self-navigation-target');
                            });
                          </script>
                        </body></html>
                    """.trimIndent(),
                ),
            )
            secondary.respond(
                "GET",
                "/self-nav-ran",
                SyntheticResponse(contentType = "text/plain; charset=utf-8", body = "ran"),
            )
            denied.respond(
                "GET",
                "/ordinary-fetch",
                SyntheticResponse(
                    body = "synthetic-fetch-ok",
                    headers = mapOf("Access-Control-Allow-Origin" to "*"),
                ),
            )
            denied.respond(
                "GET",
                "/ordinary-image.svg",
                SyntheticResponse(
                    contentType = "image/svg+xml",
                    body = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1\" height=\"1\"></svg>",
                ),
            )
            denied.respond(
                "GET",
                "/ordinary-script.js",
                SyntheticResponse(
                    contentType = "application/javascript; charset=utf-8",
                    body = "window.__externalScriptRan = true;",
                ),
            )
        }

        @SuppressLint("SetJavaScriptEnabled")
        fun open(path: String, html: String, injectionEvent: Int = WebViewCompat.INJECTION_EVENT_DOCUMENT_START) {
            val mainUrl = "$pageOrigin$path"
            pageServer.respond("GET", path, SyntheticResponse(body = html))
            assertTrue(WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT))
            assertTrue(WebViewFeature.isFeatureSupported(WebViewFeature.JS_INJECTION_IN_FRAME_AND_WORLD))
            val provider = WebViewCompat.getCurrentWebViewPackage(context)
            assertNotNull("The selected WebView provider must be identifiable.", provider)

            pageServer.start()
            secondary.start()
            denied.start()
            instrumentation.runOnMainSync {
                webView = WebView(context).also { view ->
                    view.settings.javaScriptEnabled = true
                    val world = WebViewCompat.getExecutionWorld(view, "ustc.a2.frame-policy.probe")
                    WebViewCompat.addWebMessageListener(view, "__ustcFramePolicy", setOf("*"), world) {
                            _, message, _, _, _ -> if (message.data == "unavailable") guardFailures.incrementAndGet()
                    }
                    WebViewCompat.addJavaScriptOnEvent(
                        view,
                        documentStartPolicyScript(allowedOrigins),
                        injectionEvent,
                        setOf("*"),
                        world,
                    )
                    view.webViewClient = object : WebViewClient() {
                        override fun onPageFinished(view: WebView, url: String) {
                            if (url == mainUrl) {
                                finishedUrl.set(url)
                                pageFinished.countDown()
                            }
                            val pending = pendingNavigation.get()
                            if (pending != null && pending.first == url && pendingNavigation.compareAndSet(pending, null)) {
                                pending.second.countDown()
                            }
                        }
                    }
                    view.loadUrl(mainUrl)
                }
            }
            assertTrue("The synthetic loopback page did not finish loading.", pageFinished.await(15, TimeUnit.SECONDS))
            assertEquals(mainUrl, finishedUrl.get())
        }

        fun navigateAndWait(path: String, readyExpression: String): Boolean {
            val url = "$pageOrigin$path"
            val loaded = CountDownLatch(1)
            pendingNavigation.set(url to loaded)
            instrumentation.runOnMainSync { checkNotNull(webView).loadUrl(url) }
            return pageServer.awaitCount("GET", path, expected = 1) &&
                loaded.await(15, TimeUnit.SECONDS) && awaitJavaScriptTrue(readyExpression)
        }

        fun goBack() {
            val loaded = CountDownLatch(1)
            pendingNavigation.set("$pageOrigin/history-first" to loaded)
            instrumentation.runOnMainSync {
                val browser = checkNotNull(webView)
                check(browser.canGoBack())
                browser.goBack()
            }
            assertTrue("Back navigation must finish before evaluating the restored context.",
                loaded.await(15, TimeUnit.SECONDS))
        }

        fun awaitJavaScriptTrue(expression: String, timeoutSeconds: Long = 15): Boolean {
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(timeoutSeconds)
            while (System.nanoTime() < deadline) {
                if (evaluate(expression) == "true") return true
                Thread.sleep(40)
            }
            return false
        }

        fun evaluateJson(expression: String): JSONObject {
            val encoded = evaluate(expression)
            assertNotNull("WebView returned no JavaScript value.", encoded)
            return JSONObject(JSONArray("[$encoded]").getString(0))
        }

        private fun evaluate(expression: String): String? {
            val completed = CountDownLatch(1)
            val result = AtomicReference<String?>()
            instrumentation.runOnMainSync {
                checkNotNull(webView).evaluateJavascript(expression) { raw ->
                    result.set(raw)
                    completed.countDown()
                }
            }
            assertTrue("Synthetic JavaScript evaluation timed out.", completed.await(5, TimeUnit.SECONDS))
            return result.get()
        }

        override fun close() {
            try {
                instrumentation.runOnMainSync {
                    webView?.apply {
                        stopLoading()
                        destroy()
                    }
                    webView = null
                }
            } finally {
                try {
                    denied.close()
                } finally {
                    try {
                        secondary.close()
                    } finally {
                        pageServer.close()
                    }
                }
            }
        }
    }

    /** The candidate is kept synchronous and DOM-based; it does not inspect URLs or observe mutations. */
    private fun documentStartPolicyScript(allowedOrigins: Set<String>): String {
        return FramePolicy.script(allowedOrigins)
    }

    private data class SyntheticResponse(
        val status: String = "200 OK",
        val contentType: String = "text/html; charset=utf-8",
        val body: String = "",
        val headers: Map<String, String> = emptyMap(),
    )

    /** Stores only fixed method/path counters; it never retains headers, bodies, or query values. */
    private class LoopbackServer : Closeable {
        private val socket = ServerSocket(
            0,
            16,
            InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)),
        )
        private val executor = Executors.newSingleThreadExecutor()
        private val responses = ConcurrentHashMap<String, SyntheticResponse>()
        private val counts = ConcurrentHashMap<String, AtomicInteger>()
        private val lastRequestNanos = AtomicLong(System.nanoTime())
        private val started = AtomicInteger(0)
        val origin: String get() = "http://127.0.0.1:${socket.localPort}"

        fun respond(method: String, path: String, response: SyntheticResponse) {
            responses[requestKey(method, path)] = response
        }

        fun start() {
            if (!started.compareAndSet(0, 1)) return
            executor.execute {
                while (!socket.isClosed) {
                    val client = try {
                        socket.accept()
                    } catch (_: Exception) {
                        break
                    }
                    try {
                        client.use(::serve)
                    } catch (_: Exception) {
                        // Only fixed endpoint counters are observed by the test.
                    }
                }
            }
        }

        fun count(method: String, path: String): Int =
            counts[requestKey(method, path)]?.get() ?: 0

        fun awaitCount(method: String, path: String, expected: Int, timeoutSeconds: Long = 10): Boolean {
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(timeoutSeconds)
            while (System.nanoTime() < deadline) {
                if (count(method, path) >= expected) return true
                Thread.sleep(25)
            }
            return false
        }

        fun awaitQuiet(quietMillis: Long = 600, timeoutSeconds: Long = 5) {
            val quietNanos = TimeUnit.MILLISECONDS.toNanos(quietMillis)
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(timeoutSeconds)
            var quietSince = System.nanoTime()
            while (System.nanoTime() < deadline) {
                val now = System.nanoTime()
                if (lastRequestNanos.get() > quietSince) quietSince = lastRequestNanos.get()
                if (now - quietSince >= quietNanos) return
                Thread.sleep(25)
            }
        }

        private fun serve(client: Socket) {
            client.soTimeout = 3_000
            val input = client.getInputStream()
            val requestLine = readAsciiLine(input) ?: return
            val pieces = requestLine.split(' ')
            if (pieces.size < 2) return
            val method = pieces[0].uppercase(Locale.ROOT)
            val path = pieces[1].substringBefore('?')
            var contentLength = 0
            var headerCount = 0
            while (headerCount++ < 80) {
                val header = readAsciiLine(input) ?: return
                if (header.isEmpty()) break
                if (header.substringBefore(':').equals("content-length", ignoreCase = true)) {
                    contentLength = header.substringAfter(':').trim().toIntOrNull()?.coerceIn(0, 16 * 1024) ?: 0
                }
            }
            counts.computeIfAbsent(requestKey(method, path)) { AtomicInteger() }.incrementAndGet()
            lastRequestNanos.set(System.nanoTime())
            discardBody(input, contentLength)

            val response = responses[requestKey(method, path)] ?: SyntheticResponse(
                contentType = "text/plain; charset=utf-8",
                body = "synthetic endpoint",
            )
            val body = response.body.toByteArray(StandardCharsets.UTF_8)
            val headers = buildString {
                append("HTTP/1.1 ").append(response.status).append("\r\n")
                append("Content-Type: ").append(response.contentType).append("\r\n")
                append("Content-Length: ").append(body.size).append("\r\n")
                append("Cache-Control: no-store\r\n")
                append("Connection: close\r\n")
                response.headers.forEach { (name, value) ->
                    append(name).append(": ").append(value).append("\r\n")
                }
                append("\r\n")
            }.toByteArray(StandardCharsets.US_ASCII)
            client.getOutputStream().apply {
                write(headers)
                write(body)
                flush()
            }
        }

        private fun discardBody(input: InputStream, length: Int) {
            var remaining = length
            val discard = ByteArray(1024)
            while (remaining > 0) {
                val read = input.read(discard, 0, minOf(discard.size, remaining))
                if (read <= 0) return
                remaining -= read
            }
        }

        private fun readAsciiLine(input: InputStream): String? {
            val bytes = ByteArrayOutputStream()
            while (bytes.size() <= 8 * 1024) {
                val value = input.read()
                if (value < 0) return if (bytes.size() == 0) null else bytes.toString("US-ASCII")
                if (value == '\n'.code) break
                if (value != '\r'.code) bytes.write(value)
            }
            return if (bytes.size() > 8 * 1024) null else bytes.toString("US-ASCII")
        }

        private fun requestKey(method: String, path: String): String =
            "${method.uppercase(Locale.ROOT)} $path"

        override fun close() {
            try {
                socket.close()
            } finally {
                executor.shutdownNow()
                executor.awaitTermination(2, TimeUnit.SECONDS)
            }
        }
    }
}
