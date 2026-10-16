package cn.ustcassistant.mobile.qa

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.ProfileStore
import androidx.webkit.WebStorageCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import org.json.JSONObject
import java.util.UUID

/** Tests profiles against an inline, reserved synthetic origin. It performs no HTTP requests. */
class WebViewProbe(private val activity: Activity) {
    private val handler = Handler(Looper.getMainLooper())
    private val preferences = activity.getSharedPreferences("a0_webview_probe", 0)
    private val views = mutableListOf<WebView>()
    private var active = false
    private var callback: ((JSONObject) -> Unit)? = null
    private var result = JSONObject()
    private val checks = JSONObject()
    private val timeout = Runnable { finish(false, "timeout") }

    fun run(command: String, done: (JSONObject) -> Unit) {
        check(Looper.myLooper() == Looper.getMainLooper())
        callback = done
        active = true
        result = JSONObject().put("kind", "android-webview-probe-v1")
            .put("multiProfile", false).put("deleteBrowsingData", false)
            .put("checks", checks).put("restartPrepared", false)
            .put("profileDeletionDeferred", false)
        if (!activity.packageName.endsWith(".qa")) { finish(false, "wrong_package"); return }
        try {
            val multi = WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)
            val deletion = WebViewFeature.isFeatureSupported(WebViewFeature.DELETE_BROWSING_DATA)
            result.put("multiProfile", multi).put("deleteBrowsingData", deletion)
            result.put("providerVersion", WebViewCompat.getCurrentWebViewPackage(activity)?.versionName
                ?: JSONObject.NULL)
            if (!multi || !deletion) { finish(false, "provider_unsupported"); return }
            handler.postDelayed(timeout, 45_000)
            if (command == "webview_cleanup") {
                finish(cleanupUnloadedProfiles(), "cleanup_failed")
                return
            }
            if (command == "webview_verify") { verifyRestart(); return }
            if (!cleanupUnloadedProfiles()) { finish(false, "cleanup_pending"); return }
            val names = setOf("a0_" + UUID.randomUUID(), "a0_" + UUID.randomUUID()).toList()
            if (!preferences.edit().putString("first", names[0]).putString("second", names[1])
                    .putBoolean("prepared", false).commit()) {
                finish(false, "registry_failed"); return
            }
            withPage(names[0]) { first ->
                setAndCheck(first, "a") { firstOk ->
                    checks.put("firstStorage", firstOk)
                    withPage(names[1]) { second ->
                        setAndCheck(second, "b") { secondOk ->
                            checks.put("secondStorage", secondOk)
                            inspect(first, "a") { isolated ->
                                checks.put("profileIsolation", isolated && firstOk && secondOk)
                                if (!isolated || !firstOk || !secondOk) {
                                    finish(false, "isolation_failed")
                                } else if (command == "webview_prepare") {
                                    prepareRestart(names)
                                } else {
                                    clearAndVerify(names)
                                }
                            }
                        }
                    }
                }
            }
        } catch (_: Exception) { finish(false, "provider_failed") }
    }

    private fun prepareRestart(names: List<String>) {
        names.forEach { ProfileStore.getInstance().getOrCreateProfile(it).cookieManager.flush() }
        if (!preferences.edit().putBoolean("prepared", true).commit()) {
            finish(false, "registry_failed"); return
        }
        result.put("restartPrepared", true)
        finish(true, "none")
    }

    private fun verifyRestart() {
        val names = registeredNames()
        if (!preferences.getBoolean("prepared", false) || names.size != 2) {
            finish(false, "restart_not_prepared"); return
        }
        withPage(names[0]) { first ->
            inspect(first, "a") { firstOk ->
                withPage(names[1]) { second ->
                    inspect(second, "b") { secondOk ->
                        checks.put("restartStorageRecovered", firstOk && secondOk)
                        if (!firstOk || !secondOk) finish(false, "restart_storage_failed")
                        else clearAndVerify(names)
                    }
                }
            }
        }
    }

    private fun clearAndVerify(names: List<String>) {
        destroyViews()
        val firstProfile = ProfileStore.getInstance().getOrCreateProfile(names[0])
        WebStorageCompat.deleteBrowsingData(firstProfile.webStorage) {
            if (!active) return@deleteBrowsingData
            checks.put("clearCallback", true)
            withPage(names[0]) { first ->
                evaluate(first, "localStorage.getItem('probe') === null && document.cookie === ''") { clear ->
                    checks.put("firstCleared", clear)
                    withPage(names[1]) { second ->
                        inspect(second, "b") { retained ->
                            checks.put("otherProfileRetained", retained)
                            destroyViews()
                            val secondProfile = ProfileStore.getInstance().getOrCreateProfile(names[1])
                            WebStorageCompat.deleteBrowsingData(secondProfile.webStorage) {
                                if (!active) return@deleteBrowsingData
                                checks.put("secondClearCallback", true)
                                preferences.edit().putBoolean("prepared", false).commit()
                                // ProfileStore cannot remove a profile already loaded in this process.
                                // Leave the owned names registered for deletion on a cold QA start.
                                result.put("profileDeletionDeferred", true)
                                finish(clear && retained, "clear_verification_failed")
                            }
                        }
                    }
                }
            }
        }
    }

    private fun registeredNames(): List<String> = listOfNotNull(
        preferences.getString("first", null), preferences.getString("second", null),
    ).filter { it.startsWith("a0_") && it.length == 39 }

    private fun cleanupUnloadedProfiles(): Boolean {
        val names = registeredNames()
        return try {
            val store = ProfileStore.getInstance()
            names.forEach { name ->
                if (store.allProfileNames.contains(name)) store.deleteProfile(name)
            }
            val removed = names.none { store.allProfileNames.contains(it) }
            checks.put("registeredProfilesDeleted", removed).put("deletedProfileCount", names.size)
            if (removed) preferences.edit().clear().commit() else false
        } catch (_: IllegalStateException) {
            // A process with an already loaded profile must not claim deletion succeeded.
            result.put("profileDeletionDeferred", true)
            false
        }
    }

    @Suppress("SetJavaScriptEnabled")
    private fun withPage(profile: String, ready: (WebView) -> Unit) {
        if (!active) return
        try {
            val view = WebView(activity)
            views.add(view)
            WebViewCompat.setProfile(view, profile)
            view.settings.javaScriptEnabled = true
            view.settings.domStorageEnabled = true
            view.settings.allowFileAccess = false
            view.settings.allowContentAccess = false
            var delivered = false
            view.webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) = true
                override fun onPageFinished(view: WebView, url: String?) {
                    if (active && !delivered) { delivered = true; ready(view) }
                }
            }
            view.loadDataWithBaseURL(ORIGIN, "<!doctype html><title>A0 synthetic profile</title>",
                "text/html", "utf-8", null)
        } catch (_: Exception) { finish(false, "page_failed") }
    }

    private fun setAndCheck(view: WebView, value: String, done: (Boolean) -> Unit) {
        // Both values are fixed synthetic literals; no caller input is interpolated into script.
        val script = if (value == "a")
            "localStorage.setItem('probe','a'); document.cookie='qa_probe=a; SameSite=Lax; path=/'; true"
        else "localStorage.setItem('probe','b'); document.cookie='qa_probe=b; SameSite=Lax; path=/'; true"
        evaluate(view, script) { ok -> if (ok) inspect(view, value, done) else done(false) }
    }

    private fun inspect(view: WebView, value: String, done: (Boolean) -> Unit) {
        val script = if (value == "a")
            "localStorage.getItem('probe') === 'a' && document.cookie.includes('qa_probe=a') && !document.cookie.includes('qa_probe=b')"
        else "localStorage.getItem('probe') === 'b' && document.cookie.includes('qa_probe=b') && !document.cookie.includes('qa_probe=a')"
        evaluate(view, script, done)
    }

    private fun evaluate(view: WebView, script: String, done: (Boolean) -> Unit) {
        if (!active) return
        try {
            view.evaluateJavascript(script) { value ->
                if (active && views.contains(view)) done(value == "true")
            }
        } catch (_: Exception) { finish(false, "script_failed") }
    }

    private fun finish(success: Boolean, failure: String) {
        if (!active) return
        active = false
        handler.removeCallbacks(timeout)
        destroyViews()
        result.put("success", success).put("failure", if (success) "none" else failure)
        callback?.invoke(result)
        callback = null
    }

    fun cancel() {
        active = false
        callback = null
        handler.removeCallbacks(timeout)
        destroyViews()
    }

    private fun destroyViews() {
        views.forEach { it.stopLoading(); it.destroy() }
        views.clear()
    }

    companion object { private const val ORIGIN = "https://a0.ustcassistant.invalid/" }
}
