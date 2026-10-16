package cn.ustcassistant.mobile

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import cn.ustcassistant.mobile.credentials.CredentialChannel

class MainActivity : FlutterActivity() {
    private var credentials: CredentialChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        credentials = CredentialChannel(flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        credentials?.dispose()
        credentials = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
