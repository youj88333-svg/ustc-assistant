package cn.ustcassistant.mobile.qa

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import org.json.JSONObject
import java.util.concurrent.Executors

/** Fixed synthetic operations only. This Activity is absent from production builds. */
class QaProbeActivity : Activity() {
    private val worker = Executors.newSingleThreadExecutor()
    private var webProbe: WebViewProbe? = null
    private lateinit var output: TextView
    private var busy = false
    private var activeOperation: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!packageName.endsWith(".qa")) { finish(); return }
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 32, 24, 24)
        }
        content.addView(TextView(this).apply {
            text = "USTC Assistant · A0 原生能力验证\n仅合成数据；尚非手机版业务应用。"
            textSize = 21f
        })
        listOf(
            "验证本机密钥" to "keystore",
            "验证浏览器隔离与清理" to "webview",
            "准备浏览器重启验证" to "webview_prepare",
            "检查重启后的浏览器资料" to "webview_verify",
            "完成已撤销浏览器分区清理" to "webview_cleanup",
            "通知能力" to "notification_report",
            "15秒合成提醒" to "notification_schedule",
            "取消合成提醒" to "notification_cancel",
            "清理合成提醒" to "notification_clear",
        ).forEach { (label, command) ->
            content.addView(Button(this).apply {
                text = label
                setOnClickListener { execute(command) }
            })
        }
        output = TextView(this).apply { textSize = 13f; setTextIsSelectable(true) }
        content.addView(output)
        setContentView(ScrollView(this).apply { addView(content) })
        acceptIntent(intent)
    }

    private fun execute(command: String, operation: String? = null) {
        if (busy) return
        activeOperation = operation
        busy = true
        output.text = "正在验证…"
        when (command) {
            "keystore" -> worker.execute {
                val result = KeystoreProbe.run(applicationContext)
                runOnUiThread { complete(result) }
            }
            "webview", "webview_prepare", "webview_verify", "webview_cleanup" -> {
                webProbe?.cancel()
                webProbe = WebViewProbe(this)
                webProbe!!.run(command, ::complete)
            }
            "notification_schedule" -> complete(NotificationProbe.schedule(this))
            "notification_cancel" -> complete(NotificationProbe.cancel(this))
            "notification_clear" -> complete(NotificationProbe.clear(this))
            "notification_report" -> complete(NotificationProbe.report(this))
            else -> complete(JSONObject().put("kind", "android-qa-command-v1")
                .put("success", false).put("failure", "unknown_command"))
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        acceptIntent(intent)
    }

    private fun acceptIntent(intent: Intent) {
        val command = intent.getStringExtra("qa_command") ?: return
        val operation = intent.getStringExtra("qa_operation") ?: return
        val sequence = intent.getLongExtra("qa_sequence", 0)
        if (!Regex("^[0-9a-f]{32}$").matches(operation) || sequence <= 0 || busy) return
        val ledger = getSharedPreferences("a0_command_lifecycle", MODE_PRIVATE)
        // Android may restore the task's original Intent after process death,
        // even after later onNewIntent calls. Reject every older sequence.
        if (sequence <= ledger.getLong("last_sequence", 0)) return
        if (!ledger.edit().putLong("last_sequence", sequence).commit()) return
        execute(command, operation)
    }

    private fun complete(result: JSONObject) {
        if (isFinishing || isDestroyed) return
        result.put("operation", activeOperation ?: JSONObject.NULL)
        // A fixed private QA file containing only allowlisted safe probe projections.
        try {
            val target = java.io.File(filesDir, "qa-probe-report.json")
            val pending = java.io.File(filesDir, "qa-probe-report.pending")
            pending.writeText(result.toString(), Charsets.UTF_8)
            if (!pending.renameTo(target)) {
                pending.delete()
                output.text = "验证摘要写入失败。"
                busy = false
                return
            }
        } catch (_: Exception) {
            output.text = "验证摘要写入失败。"
            busy = false
            return
        }
        output.text = result.toString(2)
        busy = false
    }

    override fun onDestroy() {
        webProbe?.cancel()
        worker.shutdown()
        super.onDestroy()
    }
}
