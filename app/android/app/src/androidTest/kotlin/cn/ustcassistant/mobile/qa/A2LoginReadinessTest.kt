package cn.ustcassistant.mobile.qa

import android.webkit.WebView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import cn.ustcassistant.mobile.browser.SchoolPolicy
import cn.ustcassistant.mobile.browser.ScriptCatalog
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Synthetic CAS DOM fixtures only; these tests never connect to a school. */
@RunWith(AndroidJUnit4::class)
class A2LoginReadinessTest {
    @Test fun partialFormCanCompleteWithinReadinessGrace() {
        val fixture = open("""<html><body>
            <form id="normalLoginForm"><input name="username" type="text"></form>
            <button id="help" type="button">Help</button>
            </body></html>""")
        try {
            assertEquals("waiting", fixture.advance())
            fixture.evaluate("""document.querySelector('form').insertAdjacentHTML('beforeend',
                '<input type="password"><button id="submitBtn" type="submit">Login</button>')""")
            assertEquals("formReady", fixture.advance())
        } finally {
            fixture.close()
        }
    }

    @Test fun completeFormAllowsAnUnrelatedButton() {
        val fixture = open("""<html><body>
            <form id="normalLoginForm">
                <input name="username" type="text"><input type="password">
                <button id="showPassword" type="button">Show password</button>
                <button id="submitBtn" type="submit">Login</button>
            </form>
            </body></html>""")
        try {
            assertEquals("formReady", fixture.advance())
        } finally {
            fixture.close()
        }
    }

    @Test fun partialFormThatStaysIncompleteExpiresToClosedFailure() {
        val fixture = open("""<html><body>
            <form id="normalLoginForm"><input name="username" type="text"></form>
            </body></html>""")
        try {
            assertEquals("waiting", fixture.advance())
            Thread.sleep(1_700)
            assertEquals("pageStructureChanged", fixture.advance())
        } finally {
            fixture.close()
        }
    }

    @Test fun emptyPageContinuesWaitingForTheAuthenticationBudget() {
        val fixture = open("<html><body></body></html>")
        try {
            assertEquals("waiting", fixture.advance())
            Thread.sleep(1_700)
            assertEquals("waiting", fixture.advance())
        } finally {
            fixture.close()
        }
    }

    @Test fun emptyFormContainerUsesThePartialFormGrace() {
        val fixture = open("""<html><body>
            <form id="normalLoginForm"></form>
            </body></html>""")
        try {
            assertEquals("waiting", fixture.advance())
            Thread.sleep(900)
            fixture.evaluate("""document.querySelector('form').innerHTML =
                '<input name="username" type="text">'""")
            assertEquals("waiting", fixture.advance())
            Thread.sleep(800)
            assertEquals("pageStructureChanged", fixture.advance())
        } finally {
            fixture.close()
        }
    }

    @Test fun emptyFormCanCompleteWithinThePartialFormGrace() {
        val fixture = open("""<html><body>
            <form id="normalLoginForm"></form>
            </body></html>""")
        try {
            assertEquals("waiting", fixture.advance())
            fixture.evaluate("""document.querySelector('form').innerHTML =
                '<input name="username" type="text"><input type="password">' +
                '<button id="submitBtn" type="submit">Login</button>'""")
            assertEquals("formReady", fixture.advance())
        } finally {
            fixture.close()
        }
    }

    @Test fun changingPartialFormDoesNotRestartTheGrace() {
        val fixture = open("""<html><body>
            <form id="normalLoginForm"><input name="username" type="text"></form>
            </body></html>""")
        try {
            assertEquals("waiting", fixture.advance())
            Thread.sleep(500)
            fixture.evaluate("""document.querySelector('form').insertAdjacentHTML('beforeend',
                '<input type="password">')""")
            assertEquals("waiting", fixture.advance())
            Thread.sleep(1_200)
            assertEquals("pageStructureChanged", fixture.advance())
        } finally {
            fixture.close()
        }
    }

    @Test fun firstPartialDeadlineSurvivesAFormReadyPass() {
        val fixture = open("""<html><body>
            <form id="normalLoginForm"><input name="username" type="text"></form>
            </body></html>""")
        try {
            assertEquals("waiting", fixture.advance())
            Thread.sleep(500)
            fixture.evaluate("""document.querySelector('form').insertAdjacentHTML('beforeend',
                '<input type="password"><button id="submitBtn" type="submit">Login</button>')""")
            assertEquals("formReady", fixture.advance())
            Thread.sleep(1_200)
            fixture.evaluate("document.querySelector('#submitBtn').remove()")
            assertEquals("pageStructureChanged", fixture.advance())
        } finally {
            fixture.close()
        }
    }

    @Test fun ambiguousOrUnsupportedControlsFailImmediately() {
        val fixtures = listOf(
            """<form><input name="username" type="text"><input name="username" type="text">
                <input type="password"><button id="submitBtn" type="submit">Login</button></form>""",
            """<form><input name="username" type="text"></form>
                <form><input type="password"><button id="submitBtn" type="submit">Login</button></form>""",
            """<form><input name="username" type="text"><input type="password">
                <button id="submitBtn" type="reset">Reset</button></form>""",
            """<form><input name="username" type="text"><input type="password">
                <button type="submit">Unrecognized submit action</button></form>""",
        )
        for (html in fixtures) {
            val fixture = open("<html><body>$html</body></html>")
            try {
                assertEquals("pageStructureChanged", fixture.advance())
            } finally {
                fixture.close()
            }
        }
    }

    private fun open(html: String): LoginFixture {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assertTrue(context.packageName == "cn.ustcassistant.mobile.qa")
        val origin = "http://127.0.0.1:43128"
        val initialUrl = "$origin/cas/login"
        val policy = SchoolPolicy.fromArguments(
            mapOf("source" to "jw", "testMode" to true,
                "initialUrl" to initialUrl, "allowedOrigins" to listOf(origin)), true,
        )
        val scripts = ScriptCatalog(context)
        val ready = CountDownLatch(1)
        var bootstrapResult: String? = null
        var browser: WebView? = null
        instrumentation.runOnMainSync {
            browser = WebView(context).also { view ->
                view.settings.javaScriptEnabled = true
                view.measure(
                    android.view.View.MeasureSpec.makeMeasureSpec(
                        1080, android.view.View.MeasureSpec.EXACTLY,
                    ),
                    android.view.View.MeasureSpec.makeMeasureSpec(
                        1600, android.view.View.MeasureSpec.EXACTLY,
                    ),
                )
                view.layout(0, 0, 1080, 1600)
                view.webViewClient = object : android.webkit.WebViewClient() {
                    override fun onPageFinished(v: WebView, url: String) {
                        if (url != initialUrl) return
                        v.evaluateJavascript(scripts.bootstrap(policy, url, 1L)) {
                            bootstrapResult = it
                            ready.countDown()
                        }
                    }
                }
                // A synthetic base URL gives the fixed script its expected CAS origin;
                // loadDataWithBaseURL does not fetch this address.
                view.loadDataWithBaseURL(initialUrl, html, "text/html", "UTF-8", null)
            }
        }
        assertTrue("Synthetic WebView did not become ready", ready.await(15, TimeUnit.SECONDS))
        assertEquals("true", bootstrapResult)
        return LoginFixture(instrumentation, browser!!, scripts)
    }

    private class LoginFixture(
        private val instrumentation: android.app.Instrumentation,
        private val browser: WebView,
        private val scripts: ScriptCatalog,
    ) {
        fun advance(): String = call("advance")

        fun evaluate(source: String) {
            val done = CountDownLatch(1)
            instrumentation.runOnMainSync {
                browser.evaluateJavascript(source) { done.countDown() }
            }
            assertTrue("Synthetic DOM update did not finish", done.await(5, TimeUnit.SECONDS))
        }

        private fun call(method: String): String {
            val done = CountDownLatch(1)
            var value: String? = null
            val source = scripts.apiCall(
                JSONObject().put("method", method).put("operation", 1L).put("document", 1L),
            )
            instrumentation.runOnMainSync {
                browser.evaluateJavascript(source) { raw ->
                    try {
                        value = scripts.unwrap(raw).getString("value")
                    } finally {
                        done.countDown()
                    }
                }
            }
            assertTrue("Synthetic login check did not finish", done.await(5, TimeUnit.SECONDS))
            return value ?: throw AssertionError("Synthetic login check returned no state")
        }

        fun close() {
            instrumentation.runOnMainSync { browser.destroy() }
        }
    }
}
