package cn.ustcassistant.mobile.qa

import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.Message
import android.os.Messenger
import androidx.test.ext.junit.runners.AndroidJUnit4
import cn.ustcassistant.mobile.browser.BrowserProtocol
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** Bounds and ordering checks for the native-only, synthetic IPC codec. */
@RunWith(AndroidJUnit4::class)
class OrdinaryBrowserProtocolTest {
    @Test
    fun sendUsesBoundedOrderedChunksWithFixedMetadata() {
        val value = mapOf("payload" to ByteArray(BrowserProtocol.CHUNK_BYTES * 2 + 333) { (it % 251).toByte() })
        val encoded = BrowserProtocol.encode(value)
        val totalLength = encoded.size
        encoded.fill(0)
        val expectedParts = (totalLength + BrowserProtocol.CHUNK_BYTES - 1) / BrowserProtocol.CHUNK_BYTES
        val received = LinkedBlockingQueue<CapturedPacket>()
        val latch = CountDownLatch(expectedParts)
        val receiverThread = HandlerThread("ordinary-browser-protocol-test")
        receiverThread.start()
        try {
            val receiver = Messenger(Handler(receiverThread.looper) { message ->
                val data = message.data
                val payload = data.getByteArray("payload")
                received.offer(
                    CapturedPacket(
                        what = message.what,
                        instance = data.getString("instance"),
                        call = data.getLong("call", -1),
                        index = data.getInt("index", -1),
                        parts = data.getInt("parts", -1),
                        length = data.getInt("length", -1),
                        payloadSize = payload?.size ?: -1,
                        keys = data.keySet(),
                    ),
                )
                latch.countDown()
                true
            })
            BrowserProtocol.send(receiver, BrowserProtocol.EVENT, "qa-instance", 27L, value)

            assertTrue(latch.await(10, TimeUnit.SECONDS))
            val packets = (0 until expectedParts).map { received.poll(1, TimeUnit.SECONDS) }
            assertTrue(packets.all { it != null })
            val complete = packets.filterNotNull()
            assertEquals(expectedParts, complete.size)
            assertTrue(received.isEmpty())
            complete.forEachIndexed { index, packet ->
                assertEquals(BrowserProtocol.EVENT, packet.what)
                assertEquals("qa-instance", packet.instance)
                assertEquals(27L, packet.call)
                assertEquals(index, packet.index)
                assertEquals(expectedParts, packet.parts)
                assertEquals(totalLength, packet.length)
                assertTrue(packet.payloadSize in 1..BrowserProtocol.CHUNK_BYTES)
                assertEquals(
                    minOf(BrowserProtocol.CHUNK_BYTES, totalLength - index * BrowserProtocol.CHUNK_BYTES),
                    packet.payloadSize,
                )
                assertEquals(setOf("instance", "call", "index", "parts", "length", "payload"), packet.keys)
            }
        } finally {
            receiverThread.quitSafely()
            receiverThread.join(5_000)
            value["payload"]?.let { (it as ByteArray).fill(0) }
        }
    }

    @Test
    fun assemblyReturnsOnlyCompleteOrderedValues() {
        val syntheticSecret = "QA_ONLY_SYNTHETIC_PASSWORD_SENTINEL"
        val expectedPayload = ByteArray(BrowserProtocol.CHUNK_BYTES * 2 + 333) { ((it * 7) % 253).toByte() }
        val encoded = BrowserProtocol.encode(mapOf("password" to syntheticSecret, "payload" to expectedPayload))
        val assembler = BrowserProtocol.Assembly()
        try {
            val count = (encoded.size + BrowserProtocol.CHUNK_BYTES - 1) / BrowserProtocol.CHUNK_BYTES
            var result: Any? = BrowserProtocol.Incomplete
            for (index in 0 until count) {
                result = assembler.add(packet(encoded, index, count, encoded.size))
                if (index < count - 1) assertTrue(result === BrowserProtocol.Incomplete)
            }

            assertTrue(result is Map<*, *>)
            val decoded = result as Map<*, *>
            assertTrue(decoded["password"] is String && decoded["password"] == syntheticSecret)
            assertTrue((decoded["payload"] as? ByteArray)?.contentEquals(expectedPayload) == true)
            expectedPayload.fill(0)
        } finally {
            encoded.fill(0)
            expectedPayload.fill(0)
            assembler.clear()
        }
    }

    @Test
    fun assemblyRejectsOutOfOrderWrongTotalsAndOversize() {
        val encoded = BrowserProtocol.encode(ByteArray(BrowserProtocol.CHUNK_BYTES * 2 + 333) { 11 })
        try {
            val count = (encoded.size + BrowserProtocol.CHUNK_BYTES - 1) / BrowserProtocol.CHUNK_BYTES

            val outOfOrder = BrowserProtocol.Assembly()
            expectIllegalArgument { outOfOrder.add(packet(encoded, 1, count, encoded.size)) }
            outOfOrder.clear()

            val wrongCount = BrowserProtocol.Assembly()
            expectIllegalArgument { wrongCount.add(packet(encoded, 0, count + 1, encoded.size)) }
            wrongCount.clear()

            val wrongTotal = BrowserProtocol.Assembly()
            for (index in 0 until count - 1) {
                assertTrue(wrongTotal.add(packet(encoded, index, count, encoded.size - 1)) === BrowserProtocol.Incomplete)
            }
            expectIllegalArgument { wrongTotal.add(packet(encoded, count - 1, count, encoded.size - 1)) }
            wrongTotal.clear()

            val tooLarge = BrowserProtocol.Assembly()
            expectIllegalArgument {
                tooLarge.add(
                    Bundle().apply {
                        putInt("index", 0)
                        putInt("parts", (BrowserProtocol.MAX_BYTES + BrowserProtocol.CHUNK_BYTES) / BrowserProtocol.CHUNK_BYTES)
                        putInt("length", BrowserProtocol.MAX_BYTES + 1)
                        putByteArray("payload", byteArrayOf(1))
                    },
                )
            }
            tooLarge.clear()

            expectIllegalArgument { BrowserProtocol.decode(ByteArray(BrowserProtocol.MAX_BYTES + 1)) }
            expectIllegalArgument { BrowserProtocol.encode(ByteArray(BrowserProtocol.MAX_BYTES)) }
        } finally {
            encoded.fill(0)
        }
    }

    private fun packet(bytes: ByteArray, index: Int, parts: Int, length: Int): Bundle {
        val start = index * BrowserProtocol.CHUNK_BYTES
        val end = minOf(bytes.size, start + BrowserProtocol.CHUNK_BYTES)
        return Bundle().apply {
            putInt("index", index)
            putInt("parts", parts)
            putInt("length", length)
            putByteArray("payload", bytes.copyOfRange(start, end))
        }
    }

    private fun expectIllegalArgument(block: () -> Unit) {
        try {
            block()
        } catch (_: IllegalArgumentException) {
            return
        }
        throw AssertionError("Expected a malformed or oversized packet to be rejected")
    }

    private data class CapturedPacket(
        val what: Int,
        val instance: String?,
        val call: Long,
        val index: Int,
        val parts: Int,
        val length: Int,
        val payloadSize: Int,
        val keys: Set<String>,
    )
}
