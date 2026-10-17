package cn.ustcassistant.mobile.browser

import android.os.Bundle
import android.os.Message
import android.os.Messenger
import io.flutter.plugin.common.StandardMessageCodec
import java.nio.ByteBuffer

/** Closed native operations. No Flutter engine or JavaScript-facing Java bridge lives in the host. */
internal interface BrowserResult {
    fun success(value: Any?)
    fun error(code: String, reason: String? = null)
}

internal object BrowserProtocol {
    const val CONNECT = 1
    const val CALL = 2
    const val RESULT = 3
    const val EVENT = 4
    const val SHUTDOWN = 5
    const val CONNECTED = 6
    const val CHUNK_BYTES = 48 * 1024
    const val MAX_BYTES = 4 * 1024 * 1024
    const val MAX_REQUEST_BYTES = 24 * 1024

    fun encode(value: Any?): ByteArray {
        val buffer = StandardMessageCodec.INSTANCE.encodeMessage(value) ?: return byteArrayOf(0)
        require(buffer.position() in 1..MAX_BYTES)
        return ByteArray(buffer.position()).also { buffer.flip(); buffer.get(it) }
    }

    fun decode(bytes: ByteArray): Any? {
        require(bytes.size in 1..MAX_BYTES)
        return StandardMessageCodec.INSTANCE.decodeMessage(ByteBuffer.wrap(bytes))
    }

    fun send(target: Messenger, what: Int, instance: String, call: Long, value: Any?, reply: Messenger? = null) {
        val bytes = encode(value)
        try {
            val parts = (bytes.size + CHUNK_BYTES - 1) / CHUNK_BYTES
            for (index in 0 until parts) {
                val payload = bytes.copyOfRange(index * CHUNK_BYTES, minOf(bytes.size, (index + 1) * CHUNK_BYTES))
                try {
                    val packet = Message.obtain(null, what).apply {
                        replyTo = reply
                        data = Bundle().apply {
                            putString("instance", instance); putLong("call", call)
                            putInt("index", index); putInt("parts", parts); putInt("length", bytes.size)
                            putByteArray("payload", payload)
                        }
                    }
                    target.send(packet)
                } finally { payload.fill(0) }
            }
        } finally { bytes.fill(0) }
    }

    /** One bounded, ordered response per call. No partial value is ever delivered. */
    class Assembly {
        private var bytes: ByteArray? = null
        private var expected = 0
        private var parts = 0
        fun add(packet: Bundle): Any? {
            val index = packet.getInt("index", -1)
            val count = packet.getInt("parts", -1)
            val length = packet.getInt("length", -1)
            val payload = packet.getByteArray("payload") ?: throw IllegalArgumentException()
            try {
                require(length in 1..MAX_BYTES && count == (length + CHUNK_BYTES - 1) / CHUNK_BYTES)
                require(index == expected && index in 0 until count)
                if (index == 0) { require(bytes == null); bytes = ByteArray(length); parts = count }
                val destination = bytes ?: throw IllegalArgumentException()
                require(destination.size == length && parts == count)
                require(payload.size == minOf(CHUNK_BYTES, length - index * CHUNK_BYTES))
                payload.copyInto(destination, index * CHUNK_BYTES); expected++
                if (expected != parts) return Incomplete
                return try { decode(destination) } finally { clear() }
            } catch (failure: Exception) { clear(); throw failure }
            finally { payload.fill(0) }
        }
        fun clear() { bytes?.fill(0); bytes = null; expected = 0; parts = 0 }
    }
    object Incomplete
}
