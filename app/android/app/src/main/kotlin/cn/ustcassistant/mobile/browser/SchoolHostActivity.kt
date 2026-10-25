package cn.ustcassistant.mobile.browser

import android.app.Activity
import android.os.Bundle
import android.os.Build
import android.view.KeyEvent
import android.view.WindowManager
import android.window.OnBackInvokedDispatcher

/** Native school surface only; the main Activity keeps the single Flutter engine. */
class SchoolHostActivity : Activity() {
    private var host: SchoolHostService? = null
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val service = SchoolHostService.current
        if (service == null || !service.accepts(intent.getStringExtra("instance"))) { finish(); return }
        host = service
        if (Build.VERSION.SDK_INT >= 33) {
            onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT) {
                leave()
            }
        }
        if (service.background()) window.addFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE)
        service.attach(this)
    }
    override fun onStart() { super.onStart(); host?.visibility(true) }
    override fun onStop() { host?.visibility(false); super.onStop() }
    override fun onDestroy() { host?.destroyed(this); host = null; super.onDestroy() }
    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        if (Build.VERSION.SDK_INT < 33 && keyCode == KeyEvent.KEYCODE_BACK) { leave(); return true }
        return super.onKeyUp(keyCode, event)
    }
    private fun leave() { host?.back(); finish() }
}
