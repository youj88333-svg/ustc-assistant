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
    fun numericCacheBusterDoesNotChangeTheFixedProfileQuery() =
        withHarness(Scenario.CACHE_BUSTER) { harness ->
            prepareAndStart(harness)
            assertSuccess(harness.call(method = "dispatch", operation = OPERATION,
                step = 1, endpoint = "profile", pageNumber = 0, day = ""))
            assertProfileProjection(awaitPoll(harness, step = 1))
            assertEquals(1, harness.server.apiRequestCount.get())
        }

    @Test
    fun millisecondsCacheBusterWorksWithFetchAndNativeXhr() {
        for (scenario in listOf(Scenario.CACHE_MILLIS, Scenario.CACHE_XHR)) {
            withHarness(scenario) { harness ->
                prepareAndStart(harness)
                assertSuccess(harness.call(method = "dispatch", operation = OPERATION,
                    step = 1, endpoint = "profile", pageNumber = 0, day = ""))
                assertProfileProjection(awaitPoll(harness, step = 1))
                assertEquals(1, harness.server.apiRequestCount.get())
            }
        }
    }

    @Test
    fun cacheBustersCannotAuthorizeUnknownDuplicateOrIdentityParameters() {
        for (scenario in listOf(Scenario.CACHE_INVALID, Scenario.CACHE_DUPLICATE, Scenario.QUERY_SELECTOR)) {
            withHarness(scenario) { harness ->
                prepareAndStart(harness)
                val reply = harness.call(method = "dispatch", operation = OPERATION,
                    step = 1, endpoint = "profile", pageNumber = 0, day = "")
                assertClosedError(reply, "invalidSnapshot")
                assertEquals("requestTarget", reply.getJSONObject("error").getString("reason"))
                assertEquals(0, harness.server.apiRequestCount.get())
            }
        }
    }

    @Test
    fun statusAndMimeFailuresHaveDifferentValueFreeReasons() {
        for ((scenario, reason) in listOf(Scenario.HTTP_ERROR to "responseStatus", Scenario.WRONG_MIME to "responseMime")) {
            withHarness(scenario) { harness ->
                prepareAndStart(harness)
                assertSuccess(harness.call(method = "dispatch", operation = OPERATION,
                    step = 1, endpoint = "profile", pageNumber = 0, day = ""))
                val reply = awaitPoll(harness, step = 1)
                assertClosedError(reply, "invalidSnapshot")
                assertEquals(reason, reply.getJSONObject("error").getString("reason"))
                assertEquals(1, harness.server.apiRequestCount.get())
            }
        }
    }

    @Test
    fun aCacheBusterCannotChangeTheRequestedPageOrCalendarDay() {
        for (scenario in listOf(Scenario.QUERY_PAGE, Scenario.QUERY_DAY)) {
            withHarness(scenario) { harness ->
                prepareAndStart(harness)
                val reply = harness.call(method = "dispatch", operation = OPERATION,
                    step = 1, endpoint = "schedule", pageNumber = 1, day = "2026-10-19")
                assertClosedError(reply, "invalidSnapshot")
                assertEquals("requestTarget", reply.getJSONObject("error").getString("reason"))
                assertEquals(0, harness.server.apiRequestCount.get())
            }
        }
    }

    @Test
    fun xhrReadyStateHelperRejectionPreservesNativeFailureAndNeverDeliversSuccess() {
        val cases = listOf(
            Triple(Scenario.HTTP_ERROR_XHR, "invalidSnapshot", "responseStatus"),
            Triple(Scenario.INVALID_JSON_XHR, "invalidSnapshot", "responseFormat"),
            Triple(Scenario.HELPER_REJECT_XHR, "sourceFailed", "helperRejected"),
        )
        for ((scenario, code, reason) in cases) {
            withHarness(scenario) { harness ->
                prepareAndStart(harness)
                assertSuccess(harness.call(method = "dispatch", operation = OPERATION,
                    step = 1, endpoint = "profile", pageNumber = 0, day = ""))
                val reply = awaitPoll(harness, step = 1)
                assertClosedError(reply, code)
                assertEquals(reason, reply.getJSONObject("error").getString("reason"))
                assertEquals(1, harness.server.apiRequestCount.get())
            }
        }
    }

    @Test
    fun anArrayBeforeRuntimeInstallationDoesNotAccumulateProbeEntries() =
        withHarness(Scenario.NATIVE_ARRAY) { harness ->
            repeat(3) {
                assertEquals(false, assertSuccess(harness.call(method = "prepare", pageName = "calendar")).get("value"))
            }
            assertEquals(0, harness.chunkQueueLength())
            assertEquals(0, harness.server.apiRequestCount.get())
        }

    @Test
    fun webpackHarmonyGetterCanExposeTheRegisteredHelperWithoutGrantingResponseAuthority() =
        withHarness(Scenario.GETTER) { harness ->
            prepareAndStart(harness)
            assertEquals(0, harness.server.apiRequestCount.get())
            assertSuccess(harness.call(method = "dispatch", operation = OPERATION,
                step = 1, endpoint = "profile", pageNumber = 0, day = ""))
            assertProfileProjection(awaitPoll(harness, step = 1))
            assertEquals(1, harness.server.apiRequestCount.get())
        }

    @Test
    fun getterExportReturningAFakePromiseStillCannotSupplyBusinessFacts() =
        withHarness(Scenario.GETTER_FAKE) { harness ->
            prepareAndStart(harness)
            assertSuccess(harness.call(method = "dispatch", operation = OPERATION,
                step = 1, endpoint = "profile", pageNumber = 0, day = ""))
            assertClosedError(awaitPoll(harness, step = 1), "sourceFailed")
            assertEquals(0, harness.server.apiRequestCount.get())
        }

    @Test
    fun throwingModuleExportIsAClosedHelperFailureRatherThanASilentReadinessWait() =
        withHarness(Scenario.THROWING_GETTER) { harness ->
            val reply = harness.call(method = "prepare", pageName = "calendar")
            assertClosedError(reply, "sourceFailed")
            assertEquals("helperUnavailable", reply.getJSONObject("error").getString("reason"))
            assertEquals(0, harness.server.apiRequestCount.get())
        }

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
        assertTrue(error.getString("reason") in setOf("helperUnavailable", "sourceFailure",
            "requestTarget", "requestMethod", "transportAmbiguous", "responseTarget",
            "responseStatus", "responseMime", "responseTooLarge", "responseFormat",
            "transportFailed", "helperRejected", "xhrConfiguration"))
        assertNull(error.opt("raw"))
    }

    private enum class Scenario {
        CACHE_BUSTER,
        CACHE_MILLIS,
        CACHE_XHR,
        CACHE_INVALID,
        CACHE_DUPLICATE,
        QUERY_SELECTOR,
        QUERY_PAGE,
        QUERY_DAY,
        HTTP_ERROR,
        WRONG_MIME,
        HTTP_ERROR_XHR,
        INVALID_JSON_XHR,
        HELPER_REJECT_XHR,
        NATIVE_ARRAY,
        GETTER,
        GETTER_FAKE,
        THROWING_GETTER,
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

        fun chunkQueueLength(): Int {
            val done = CountDownLatch(1)
            var value = -1
            instrumentation.runOnMainSync {
                checkNotNull(webView).evaluateJavascript("window.webpackJsonp.length") { raw ->
                    value = raw.toIntOrNull() ?: -1
                    done.countDown()
                }
            }
            assertTrue(done.await(15, TimeUnit.SECONDS))
            return value
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
                        status = if (scenario == Scenario.HTTP_ERROR || scenario == Scenario.HTTP_ERROR_XHR) "503 Unavailable" else "200 OK",
                        contentType = if (scenario == Scenario.WRONG_MIME) "text/plain" else "application/json; charset=utf-8",
                        body = if (scenario == Scenario.INVALID_JSON_XHR) "synthetic-invalid-json"
                            else if (scenario == Scenario.DUPLICATE)
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
                Scenario.FAKE, Scenario.GETTER_FAKE -> "fake"
                Scenario.BACKGROUND -> "background"
                Scenario.CACHE_BUSTER -> "cacheBuster"
                Scenario.CACHE_MILLIS -> "cacheMillis"
                Scenario.CACHE_XHR -> "cacheXhr"
                Scenario.CACHE_INVALID -> "cacheInvalid"
                Scenario.CACHE_DUPLICATE -> "cacheDuplicate"
                Scenario.QUERY_SELECTOR -> "querySelector"
                Scenario.QUERY_PAGE -> "queryPage"
                Scenario.QUERY_DAY -> "queryDay"
                Scenario.HTTP_ERROR_XHR -> "httpErrorXhr"
                Scenario.INVALID_JSON_XHR -> "invalidJsonXhr"
                Scenario.HELPER_REJECT_XHR -> "helperRejectXhr"
                Scenario.REDIRECT, Scenario.DUPLICATE, Scenario.NO_HELPER,
                Scenario.GETTER, Scenario.THROWING_GETTER, Scenario.NATIVE_ARRAY,
                Scenario.HTTP_ERROR, Scenario.WRONG_MIME -> "fetch"
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
                  var parameters = new URLSearchParams(options.params);
                  if (mode === 'cacheBuster') parameters.append('_t','1792396800');
                  if (mode === 'cacheMillis' || mode === 'cacheXhr') parameters.append('_t','1792396800000');
                  if (mode === 'cacheInvalid') parameters.append('_t','other-account');
                  if (mode === 'cacheDuplicate') { parameters.append('_t','1792396800'); parameters.append('_t','1792396801'); }
                  if (mode === 'querySelector') { parameters.append('_t','1792396800'); parameters.append('username','other-account'); }
                  if (mode === 'queryPage' || mode === 'queryDay') {
                    parameters.append('_t','1792396800');
                    parameters.set(mode === 'queryPage' ? 'pageNo' : 'now', mode === 'queryPage' ? '2' : '2030-01-01');
                  }
                  if (parameters.toString()) target += '?' + parameters.toString();
                  if (mode === 'fake' || mode === 'background') {
                    return Promise.resolve({success:true,code:200,result:{username:'loopback-user',syntheticExtra:'discard'}});
                  }
                  var readyStateMode = mode === 'httpErrorXhr' || mode === 'invalidJsonXhr' || mode === 'helperRejectXhr';
                  var transport = readyStateMode || mode === 'cacheXhr' ? 'xhr' : mode === 'sequence' ? (++helperCalls === 1 ? 'fetch' : 'xhr') : 'fetch';
                  if (transport === 'fetch') {
                    return fetch(target, {method:options.method}).then(function(response) { return response.json(); });
                  }
                  return new Promise(function(resolve, reject) {
                    var request = new XMLHttpRequest();
                    request.open('GET', target, true);
                    if (readyStateMode) {
                      request.onreadystatechange = function() {
                        if (request.readyState !== 4) return;
                        if (request.status >= 400 || mode === 'helperRejectXhr') { reject(new Error('synthetic-helper-rejection')); return; }
                        try { resolve(JSON.parse(request.responseText)); } catch (error) { reject(error); }
                      };
                    } else request.addEventListener('load', function() {
                        try { resolve(JSON.parse(request.responseText)); } catch (error) { reject(error); }
                      });
                    request.addEventListener('error', reject);
                    request.send();
                  });
                }};
                function l(e,t){return Object(r["b"])({url:e,method:"get",params:t,timeout:36e5})}
                var factories=Object.create(null), moduleCache=Object.create(null);
                function fixtureRequire(id){
                  if(moduleCache[id])return moduleCache[id].exports;
                  var module=moduleCache[id]={exports:{}};
                  if(typeof factories[id]!=='function')throw new Error('synthetic-module-not-yet-registered');
                  factories[id](module,module.exports,fixtureRequire);return module.exports;
                }
                fixtureRequire.m=factories;
                window.webpackJsonp=[];
                window.webpackJsonp.push=function(data){
                  Object.keys(data[1]).forEach(function(id){factories[id]=data[1][id]});
                  var value;(data[2]||[]).forEach(function(entry){value=fixtureRequire(entry[0])});return value;
                };
                ${when (scenario) {
                    Scenario.NATIVE_ARRAY -> "window.webpackJsonp=[];"
                    Scenario.NO_HELPER -> ""
                    Scenario.GETTER, Scenario.GETTER_FAKE -> "factories['0fea']=function(module){Object.defineProperty(module.exports,'e',{enumerable:true,get:function(){return l}})};"
                    Scenario.THROWING_GETTER -> "factories['0fea']=function(module){Object.defineProperty(module.exports,'e',{get:function(){throw new Error('synthetic-private-detail')}})};"
                    else -> "factories['0fea']=function(module){module.exports={e:l}};"
                }}
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
