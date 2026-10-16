package cn.ustcassistant.mobile.files

import android.app.Activity
import android.content.Intent
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** QA-only host: captures picker requests without opening files or Flutter data. */
class FilesBridgeHostActivity : Activity() {
    data class StartedRequest(val intent: Intent, val requestCode: Int)

    private val requests = LinkedBlockingQueue<StartedRequest>()

    @Suppress("DEPRECATION")
    override fun startActivityForResult(intent: Intent, requestCode: Int) {
        requests.offer(StartedRequest(intent, requestCode))
    }

    fun hasPendingRequest(): Boolean = requests.isNotEmpty()

    fun nextRequest(): StartedRequest =
        requireNotNull(requests.poll(3, TimeUnit.SECONDS)) { "FilesChannel did not request the system picker" }
}
