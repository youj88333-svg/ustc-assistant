package cn.ustcassistant.mobile.qa

import android.annotation.SuppressLint
import android.app.Instrumentation
import android.content.Context
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import cn.ustcassistant.mobile.browser.SchoolPolicy
import cn.ustcassistant.mobile.browser.ScriptCatalog
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.BufferedReader
import java.io.Closeable
import java.io.InputStreamReader
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Exercises Young transport correlation using only synthetic loopback responses. */
@RunWith(AndroidJUnit4::class)
class A2YoungTransportTest {
    @Test
    fun fixedNavigationDoesNotRequireTheDestinationsLazyReaderOnTheLandingPage() =
        withHarness(Scenario.NO_HELPER) { harness ->
            assertEquals(true, assertSuccess(harness.call(method = "navigationReady")).get("value"))
            assertEquals(false, assertSuccess(harness.call(method = "prepare", pageName = "calendar")).get("value"))
            // Navigating is not a read grant: a real read still needs its helper.
            assertClosedError(harness.call(method = "start", operation = OPERATION), "sourceFailed")
            assertEquals(0, harness.server.apiRequestCount.get())
        }

    @Test
    fun profileUsesCapturedNativeFetchAndXhrResponsesAndProjectsOnlyUsername() =
        withHarness(Scenario.SEQUENCE) { harness ->
            prepareAndStart(harness)

            assertSuccess(harness.call(
                method = "dispatch",
                operation = OPERATION,
                step = 1,
                endpoint = "profile",
                pageNumber = 0,
                day = "",
            ))
            assertProfileProjection(awaitPoll(harness, step = 1))

            assertSuccess(harness.call(
                method = "dispatch",
                operation = OPERATION,
                step = 2,
                endpoint = "profile",
                pageNumber = 0,
                day = "",
            ))
            assertProfileProjection(awaitPoll(harness, step = 2))
            assertEquals(2, harness.server.apiRequestCount.get())
            assertSuccess(harness.call(method = "finish", operation = OPERATION))
        }

    @Test
    fun fakeHelperPromiseWithoutNativeTransportCannotSupplyProfile() =
        withHarness(Scenario.FAKE) { harness ->
            prepareAndStart(harness)
            assertSuccess(harness.call(
                method = "dispatch",
                operation = OPERATION,
                step = 1,
                endpoint = "profile",
                pageNumber = 0,
                day = "",
            ))

            assertClosedError(awaitPoll(harness, step = 1), expectedCode = "sourceFailed")
            assertEquals(0, harness.server.apiRequestCount.get())
        }

    @Test
    fun backgroundSameUrlFetchCannotStandInForTheScopedHelperRequest() =
        withHarness(Scenario.BACKGROUND) { harness ->
            assertTrue(harness.server.awaitApiResponse())
            assertEquals(1, harness.server.apiRequestCount.get())
            prepareAndStart(harness)
            assertSuccess(harness.call(
                method = "dispatch",
                operation = OPERATION,
                step = 1,
                endpoint = "profile",
                pageNumber = 0,
                day = "",
            ))

            assertClosedError(awaitPoll(harness, step = 1), expectedCode = "sourceFailed")
            assertEquals("Only the unrelated page fetch reached the loopback server.",
                1, harness.server.apiRequestCount.get())
        }

    @Test
    fun redirectedFetchWithWrongFinalUrlIsRejected() =
        withHarness(Scenario.REDIRECT) { harness ->
            prepareAndStart(harness)
            assertSuccess(harness.call(
                method = "dispatch",
                operation = OPERATION,
                step = 1,
                endpoint = "profile",
                pageNumber = 0,
                day = "",
            ))

            assertClosedError(awaitPoll(harness, step = 1), expectedCode = "invalidSnapshot")
            assertEquals(1, harness.server.apiRequestCount.get())
        }

    @Test
    fun duplicateRawIdentityKeysAreRejectedBeforeProjection() =
        withHarness(Scenario.DUPLICATE) { harness ->
            prepareAndStart(harness)
            assertSuccess(harness.call(method = "dispatch", operation = OPERATION,
                step = 1, endpoint = "profile", pageNumber = 0, day = ""))
            assertClosedError(awaitPoll(harness, step = 1), expectedCode = "invalidSnapshot")
            assertEquals(1, harness.server.apiRequestCount.get())
        }

    private inline fun withHarness(scenario: Scenario, block: (Harness) -> Unit) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assertEquals("cn.ustcassistant.mobile.qa", context.packageName)
        val harness = Harness(instrumentation, context, scenario)
        try {
            harness.open()
            block(harness)
        } finally {
            harness.close()
        }
    }

    private fun prepareAndStart(harness: Harness) {
        val prepared = assertSuccess(harness.call(method = "prepare", pageName = "calendar"))
        assertEquals(true, prepared.get("value"))
        val started = assertSuccess(harness.call(method = "start", operation = OPERATION))
        assertEquals(JSONObject.NULL, started.get("value"))
    }

    private fun awaitPoll(harness: Harness, step: Long): JSONObject {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(15)
        while (System.nanoTime() < deadline) {
            val reply = harness.call(method = "poll", operation = OPERATION, step = step)
            if (reply.has("error")) return reply
            val value = assertSuccess(reply).getJSONObject("value")
            if (value.getBoolean("complete")) return reply
            Thread.sleep(25)
        }
        throw AssertionError("Synthetic Young profile did not settle")
    }

    private fun assertProfileProjection(reply: JSONObject) {
        val value = assertSuccess(reply).getJSONObject("value")
        assertEquals(setOf("complete", "projectedJson"), value.keys().asSequence().toSet())
        assertTrue(value.getBoolean("complete"))
        val projection = JSONObject(value.getString("projectedJson"))
        assertEquals(setOf("success", "code", "result"), projection.keys().asSequence().toSet())
        assertTrue(projection.getBoolean("success"))
        assertEquals(200, projection.getInt("code"))
        val result = projection.getJSONObject("result")
        assertEquals(setOf("username"), result.keys().asSequence().toSet())
        assertEquals("loopback-user", result.getString("username"))
        assertFalse(value.getString("projectedJson").contains("syntheticExtra"))
    }

    private fun assertSuccess(reply: JSONObject): JSONObject {
        assertEquals(setOf("reply", "call", "value"), reply.keys().asSequence().toSet())
        assertFalse(reply.has("error"))
        return reply
    }

    private fun assertClosedError(reply: JSONObject, expectedCode: String) {
        assertEquals(setOf("reply", "call", "error"), reply.keys().asSequence().toSet())
        assertFalse(reply.has("value"))
        val error = reply.getJSONObject("error")
        assertEquals(setOf("code", "reason"), error.keys().asSequence().toSet())
        assertEquals(expectedCode, error.getString("code"))
        assertTrue(error.getString("reason") in setOf("helperUnavailable", "sourceFailure"))
        assertNull(error.opt("raw"))
    }

    private enum class Scenario {
        NO_HELPER,
        SEQUENCE,
        FAKE,
        BACKGROUND,
        REDIRECT,
        DUPLICATE,
    }

    private class Harness(
        private val instrumentation: Instrumentation,
        private val context: Context,
        scenario: Scenario,
    ) : Closeable {
        val server = SyntheticServer(scenario)
        private val origin = "http://127.0.0.1:${server.port}"
        private val initialUrl =
            "$origin/login/sc-wisdom-group-learning/personalInformation/mySchedule"
        private val policy = SchoolPolicy.fromArguments(
            mapOf(
                "source" to "young",
                "testMode" to true,
                "initialUrl" to initialUrl,
                "allowedOrigins" to listOf(origin),
            ),
            qa = true,
        )
        private val scripts = ScriptCatalog(context)
        private val pageLoaded = CountDownLatch(1)
        private val nextCall = AtomicInteger(0)
        private var webView: WebView? = null
        @Volatile private var finishedUrl = ""
        @Volatile private var bootstrapResult: String? = null

        @SuppressLint("SetJavaScriptEnabled")
        fun open() {
            server.start()
            instrumentation.runOnMainSync {
                webView = WebView(context).also { view ->
                    view.settings.javaScriptEnabled = true
                    view.webViewClient = object : WebViewClient() {
                        override fun onPageFinished(view: WebView, url: String) {
                            if (url != initialUrl) return
                            val guardedBootstrap = "(function(){try{" +
                                scripts.bootstrap(policy, url, DOCUMENT) +
                                ";return true;}catch(error){" +
                                "const specs=[[Response.prototype,['url','status','redirected','type','headers','body']]," +
                                "[Request.prototype,['url','method']],[URL.prototype,['href','origin','pathname','hash','username','password','searchParams']]," +
                                "[XMLHttpRequest.prototype,['readyState','status','responseURL','responseType','responseText']]," +
                                "[Document.prototype,['documentElement','readyState']],[location,['origin','pathname','href']]," +
                                "[ProgressEvent.prototype,['loaded']],[window,['document','top']]];" +
                                "const missing=[];specs.forEach((s,i)=>s[1].forEach(k=>{const d=Object.getOwnPropertyDescriptor(s[0],k);" +
                                "if(!d||typeof d.get!=='function')missing.push(i+':'+k);}));" +
                                "return 'bootstrap-exception:'+(error&&typeof error.name==='string'?error.name:" +
                                "error&&error.reason==='nativeContext'?'nativeContext':'unknown')+';missing='+missing.join(',');}})()"
                            view.evaluateJavascript(guardedBootstrap) { result ->
                                bootstrapResult = result
                                finishedUrl = url
                                pageLoaded.countDown()
                            }
                        }
                    }
                    view.loadUrl(initialUrl)
                }
            }
            assertTrue("Synthetic Young page did not load.", pageLoaded.await(15, TimeUnit.SECONDS))
            assertEquals("Synthetic Young bootstrap failed (exception name only): $bootstrapResult",
                "true", bootstrapResult)
            assertEquals(initialUrl, finishedUrl)
        }

        fun call(
            method: String,
            pageName: String? = null,
            operation: Long? = null,
            step: Long? = null,
            endpoint: String? = null,
            pageNumber: Int? = null,
            day: String? = null,
        ): JSONObject {
            val id = nextCall.incrementAndGet().toLong()
            val args = JSONObject().put("method", method).put("call", id)
            pageName?.let { args.put("page", it) }
            operation?.let { args.put("operation", it) }
            step?.let { args.put("step", it) }
            endpoint?.let { args.put("endpoint", it) }
            pageNumber?.let { args.put("page", it) }
            day?.let { args.put("day", it) }

            args.put("document", DOCUMENT)
            val done = CountDownLatch(1)
            var reply: JSONObject? = null
            var failure: String? = null
            instrumentation.runOnMainSync {
                checkNotNull(webView).evaluateJavascript(scripts.pageCall(args)) { raw ->
                    try { reply = scripts.unwrap(raw, page = true) }
                    catch (error: Exception) { failure = error.message ?: "Invalid synthetic page envelope" }
                    done.countDown()
                }
            }
            assertTrue("Synthetic page call timed out", done.await(15, TimeUnit.SECONDS))
            failure?.let { throw AssertionError(it) }
            return reply ?: throw AssertionError("Synthetic page call had no reply")
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
                server.close()
            }
        }
    }

    private class SyntheticServer(private val scenario: Scenario) : Closeable {
        private val server = ServerSocket(
            0,
            8,
            InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)),
        )
        private val executor = Executors.newSingleThreadExecutor()
        private val apiResponse = CountDownLatch(1)
        val port: Int get() = server.localPort
        val apiRequestCount = AtomicInteger(0)
        @Volatile private var started = false

        fun start() {
            if (started) return
            started = true
            executor.execute {
                while (!server.isClosed) {
                    val client = try {
                        server.accept()
                    } catch (_: Exception) {
                        break
                    }
                    try {
                        client.use(::serve)
                    } catch (_: Exception) {
                        // The test asserts only closed result codes and counters.
                    }
                }
            }
        }

        fun awaitApiResponse(): Boolean = apiResponse.await(15, TimeUnit.SECONDS)

        private fun serve(client: Socket) {
            val reader = BufferedReader(InputStreamReader(client.getInputStream(), StandardCharsets.US_ASCII))
            val requestLine = reader.readLine() ?: return
            while (reader.readLine()?.isNotEmpty() == true) {
                // Read only request framing; no headers or body are retained.
            }
            val target = requestLine.split(' ').getOrNull(1) ?: "/"
            val path = target.substringBefore('?')
            val apiPath = "/login/wisdom-group-learning-bg/"
            if (path.startsWith(apiPath)) apiRequestCount.incrementAndGet()

            when {
                path.startsWith(apiPath) && scenario == Scenario.REDIRECT -> {
                    writeResponse(
                        client,
                        status = "302 Found",
                        contentType = "text/plain",
                        body = "",
                        extraHeaders = "Location: /loopback-final\r\n",
                    )
                }
                path == "/loopback-final" || path.startsWith(apiPath) -> {
                    writeResponse(
                        client,
                        status = "200 OK",
                        contentType = "application/json; charset=utf-8",
                        body = if (scenario == Scenario.DUPLICATE)
                            """{"success":true,"code":200,"result":{"username":"other","username":"loopback-user"}}"""
                            else SYNTHETIC_PROFILE_JSON,
                    )
                }
                path == PAGE_PATH -> {
                    writeResponse(
                        client,
                        status = "200 OK",
                        contentType = "text/html; charset=utf-8",
                        body = pageHtml(),
                    )
                }
                else -> writeResponse(client, "204 No Content", "text/plain", "")
            }
            if (path.startsWith(apiPath)) apiResponse.countDown()
        }

        private fun pageHtml(): String {
            val mode = when (scenario) {
                Scenario.SEQUENCE -> "sequence"
                Scenario.FAKE -> "fake"
                Scenario.BACKGROUND -> "background"
                Scenario.REDIRECT, Scenario.DUPLICATE, Scenario.NO_HELPER -> "fetch"
            }
            val backgroundFetch = if (scenario == Scenario.BACKGROUND) {
                "window.__backgroundFetch = fetch(${JSONObject.quote("http://127.0.0.1:$port$PROFILE_PATH")});"
            } else {
                ""
            }
            return """
                <!doctype html>
                <html><head><meta charset="utf-8"></head><body>
                <script>
                var mode = ${JSONObject.quote(mode)};
                var helperCalls = 0;
                var r = {b:function(options) {
                  var target = new URL('/login/wisdom-group-learning-bg' + options.url, location.href).href;
                  if (mode === 'fake' || mode === 'background') {
                    return Promise.resolve({success:true,code:200,result:{username:'loopback-user',syntheticExtra:'discard'}});
                  }
                  var transport = mode === 'sequence' ? (++helperCalls === 1 ? 'fetch' : 'xhr') : 'fetch';
                  if (transport === 'fetch') {
                    return fetch(target, {method:options.method}).then(function(response) { return response.json(); });
                  }
                  return new Promise(function(resolve, reject) {
                    var request = new XMLHttpRequest();
                    request.open('GET', target, true);
                    request.addEventListener('load', function() {
                      try { resolve(JSON.parse(request.responseText)); } catch (error) { reject(error); }
                    });
                    request.addEventListener('error', reject);
                    request.send();
                  });
                }};
                function l(e,t){return Object(r["b"])({url:e,method:"get",params:t,timeout:36e5})}
                ${if (scenario == Scenario.NO_HELPER) "" else "window.webpackJsonp = {push:function() { return {e:l}; }};"}
                $backgroundFetch
                </script>
                </body></html>
            """.trimIndent()
        }

        private fun writeResponse(
            client: Socket,
            status: String,
            contentType: String,
            body: String,
            extraHeaders: String = "",
        ) {
            val bytes = body.toByteArray(StandardCharsets.UTF_8)
            val headers = buildString {
                append("HTTP/1.1 ").append(status).append("\r\n")
                append("Content-Type: ").append(contentType).append("\r\n")
                append("Content-Length: ").append(bytes.size).append("\r\n")
                append("Connection: close\r\n")
                append("Cache-Control: no-store\r\n")
                append(extraHeaders)
                append("\r\n")
            }.toByteArray(StandardCharsets.US_ASCII)
            client.getOutputStream().apply {
                write(headers)
                write(bytes)
                flush()
            }
        }

        override fun close() {
            try {
                server.close()
            } finally {
                executor.shutdownNow()
                executor.awaitTermination(2, TimeUnit.SECONDS)
            }
        }

        companion object {
            private const val PAGE_PATH =
                "/login/sc-wisdom-group-learning/personalInformation/mySchedule"
            private const val PROFILE_PATH =
                "/login/wisdom-group-learning-bg/paramdesign/scMyInfo/info"
            private const val SYNTHETIC_PROFILE_JSON =
                "{\"success\":true,\"code\":200,\"result\":{\"username\":\"loopback-user\",\"displayName\":\"synthetic\",\"syntheticExtra\":\"discard\"}}"
        }
    }

    private companion object {
        const val OPERATION = 1L
        const val DOCUMENT = 1L
    }
}
