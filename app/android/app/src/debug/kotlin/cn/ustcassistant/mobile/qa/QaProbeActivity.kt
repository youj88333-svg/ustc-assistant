package cn.ustcassistant.mobile.qa

import android.app.Activity
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
        val command = intent.getStringExtra("qa_command")
        if (command != null) execute(command)
    }

    private fun execute(command: String) {
        if (busy) return
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

    private fun complete(result: JSONObject) {
        if (isFinishing || isDestroyed) return
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
