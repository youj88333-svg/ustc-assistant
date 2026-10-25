package cn.ustcassistant.mobile.speech

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadFactory
import java.util.concurrent.atomic.AtomicBoolean

/** Fixed local model preparation API. It retains application storage only, never an Activity. */
internal class SpeechModelChannel internal constructor(
    context: Context,
    messenger: BinaryMessenger,
    private val store: SpeechModelStore = SpeechModelStore(context.applicationContext),
) {
    private val main = Handler(Looper.getMainLooper())
    private val disposed = AtomicBoolean(false)
    private val lifecycleLock = Any()
    private val pendingReplies = linkedSetOf<PendingReply>()
    private val worker: ExecutorService = Executors.newSingleThreadExecutor(ThreadFactory { runnable ->
        Thread(runnable, "speech-model-store").apply { isDaemon = true }
    })
    private val channel = MethodChannel(messenger, CHANNEL_NAME)

    init {
        channel.setMethodCallHandler(::handle)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (disposed.get()) {
            result.error("closed", null, null)
            return
        }
        if (call.method != PREPARE_METHOD) {
            result.notImplemented()
            return
        }
        if (call.arguments != null) {
            result.error("invalid_request", null, null)
            return
        }

        val pending = synchronized(lifecycleLock) {
            if (disposed.get()) null else PendingReply(result).also(pendingReplies::add)
        }
        if (pending == null) {
            result.error("closed", null, null)
            return
        }

        try {
            worker.execute {
                try {
                    val directory = store.prepare { disposed.get() }
                    postReply(pending) {
                        result.success(mapOf("version" to store.version, "directory" to directory))
                    }
                } catch (_: Exception) {
                    postReply(pending) { result.error("model_unavailable", null, null) }
                }
            }
        } catch (_: RejectedExecutionException) {
            postReply(pending) { result.error("closed", null, null) }
        }
    }

    private fun postReply(pending: PendingReply, reply: () -> Unit) {
        main.post {
            synchronized(lifecycleLock) {
                if (!disposed.get() && !pending.completed.get()) {
                    pending.completed.set(true)
                    pendingReplies.remove(pending)
                    reply()
                }
            }
        }
    }

    /** Detaches the bridge and interrupts extraction; queued callbacks check this before replying. */
    fun dispose() {
        val toClose = synchronized(lifecycleLock) {
            if (!disposed.compareAndSet(false, true)) return
            pendingReplies.toList().also { pending ->
                pendingReplies.clear()
                pending.forEach { it.completed.set(true) }
            }
        }
        channel.setMethodCallHandler(null)
        worker.shutdownNow()
        for (pending in toClose) {
            main.post { pending.result.error("closed", null, null) }
        }
    }

    private class PendingReply(val result: MethodChannel.Result) {
        val completed = AtomicBoolean(false)
    }

    private companion object {
        const val CHANNEL_NAME = "ustc_assistant/android_speech_v1"
        const val PREPARE_METHOD = "prepareModel"
    }
}
