package cn.ustcassistant.mobile

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import cn.ustcassistant.mobile.credentials.CredentialChannel
import cn.ustcassistant.mobile.browser.ObservationBridge
import android.content.Intent
import cn.ustcassistant.mobile.files.FilesChannel
import cn.ustcassistant.mobile.notifications.NotificationsChannel
import android.os.Bundle

class MainActivity : FlutterActivity() {
    private var credentials: CredentialChannel? = null
    private var platform: PlatformChannel? = null
    private var observation: ObservationBridge? = null
    private var files: FilesChannel? = null
    private var notifications: NotificationsChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        notifications?.onIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        notifications?.onIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        credentials = CredentialChannel(flutterEngine.dartExecutor.binaryMessenger)
        platform = PlatformChannel(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        observation = ObservationBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        files = FilesChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        notifications = NotificationsChannel(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        notifications?.dispose()
        notifications = null
        files?.dispose()
        files = null
        observation?.dispose()
        observation = null
        credentials?.dispose()
        credentials = null
        platform?.dispose()
        platform = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    @Deprecated("Platform callback retained for FlutterActivity result routing")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (files?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onStop() {
        files?.onHostStopped()
        observation?.onHostStopped()
        super.onStop()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (notifications?.onPermissionResult(requestCode) == true) return
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }
}
