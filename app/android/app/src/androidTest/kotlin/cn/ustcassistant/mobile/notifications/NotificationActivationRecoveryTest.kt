package cn.ustcassistant.mobile.notifications

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicLong

@RunWith(AndroidJUnit4::class)
class NotificationActivationRecoveryTest {
    private lateinit var temporaryDirectory: File
    private val now = AtomicLong(BASE_NOW)

    @Before
    fun createTemporaryLedgerDirectory() {
        val cache = InstrumentationRegistry.getInstrumentation().targetContext.cacheDir.canonicalFile
        temporaryDirectory = File(cache, "notification-activation-${UUID.randomUUID()}")
        assertTrue(temporaryDirectory.mkdirs() || temporaryDirectory.isDirectory)
    }

    @After
    fun deleteOnlyThisTestsTemporaryDirectory() {
        if (!::temporaryDirectory.isInitialized) return
        val cache = InstrumentationRegistry.getInstrumentation().targetContext.cacheDir.canonicalFile
        val candidate = temporaryDirectory.canonicalFile
        if (candidate.parentFile == cache && candidate.name.startsWith("notification-activation-")) {
            assertTrue(!candidate.exists() || candidate.deleteRecursively())
        }
    }

    @Test
    fun clickSurvivesManagerReconstructionAndIsConsumedOnce() {
        val activated = clickDeliveredReminder("cold-click", caseDirectory("cold-click"))
        val persisted = activated.ledger.read().entries.getValue("cold-click")
        assertTrue(persisted.clicked)
        assertTrue(persisted.activationPending)

        // A fresh core represents process death after click persistence but before
        // the Dart side drains the handoff.
        val firstColdManager = manager(activated.directory)
        val handoff = firstColdManager.takeActivations()
        assertEquals(1, handoff.size)
        assertEquals(mapOf(
            "id" to "cold-click",
            "digest" to DIGEST,
            "token" to TOKEN,
        ), handoff.single())
        assertEquals(setOf("id", "digest", "token"), handoff.single().keys)
        assertFalse(activated.ledger.read().entries.getValue("cold-click").activationPending)
        assertTrue(firstColdManager.takeActivations().isEmpty())

        // The durable consumption also prevents a second manager from replaying it.
        assertTrue(manager(activated.directory).takeActivations().isEmpty())
    }

    @Test
    fun blockedClickCannotBeRecoveredAfterManagerReconstruction() {
        val activated = clickDeliveredReminder("blocked-click", caseDirectory("blocked-click"))

        activated.manager.block()

        assertTrue(activated.ledger.read().blocked)
        val restarted = manager(activated.directory)
        assertTrue(restarted.takeActivations().isEmpty())
        val clickedRequest = activated.ledger.read().entries.getValue("blocked-click").request.identity
        restarted.bind(authority(), listOf(clickedRequest))
        assertTrue(restarted.takeActivations().isEmpty())
    }

    @Test
    fun cancelledClickCannotBeRecoveredAfterManagerReconstruction() {
        val activated = clickDeliveredReminder("cancelled-click", caseDirectory("cancelled-click"))

        activated.manager.cancel("cancelled-click")

        assertFalse(activated.ledger.read().entries.containsKey("cancelled-click"))
        assertTrue(manager(activated.directory).takeActivations().isEmpty())
    }

    @Test
    fun clickFromPreviousAuthorityEpochCannotBeRecovered() {
        val activated = clickDeliveredReminder("old-epoch-click", caseDirectory("old-epoch-click"))

        activated.manager.bind(
            authority(owner = "next-synthetic-owner", reset = 2, agenda = 1),
            emptyList(),
        )

        assertTrue(manager(activated.directory).takeActivations().isEmpty())
    }

    @Test
    fun expiredClickCannotBeRecoveredAfterManagerReconstruction() {
        val activated = clickDeliveredReminder("expired-click", caseDirectory("expired-click"))
        now.addAndGet(31 * DAY)

        assertTrue(manager(activated.directory).takeActivations().isEmpty())
        assertFalse(activated.ledger.read().entries.getValue("expired-click").activationPending)
    }

    @Test
    fun legacyClickedEntryIsParsedAsConsumedAndIsNotReplayed() {
        val directory = caseDirectory("legacy-entry")
        val request = request("legacy-click")
        val legacyEntry = NativeEntry(
            request = request,
            nonce = NONCE,
            generation = LEGACY_GENERATION,
            state = DeliveryState.delivered,
            clicked = true,
        )
        val mirror = NotificationMirror(
            generation = LEGACY_GENERATION,
            blocked = false,
            authority = authority(),
            allowed = mapOf(request.identity.id to request.identity),
            entries = mapOf(request.identity.id to legacyEntry),
        )
        val legacyJson = mirror.json()
        legacyJson.getJSONArray("entries").getJSONObject(0).remove("activationPending")
        File(directory, "reminders.json").writeText(legacyJson.toString())

        val loaded = NotificationLedger(directory).read().entries.getValue("legacy-click")
        assertTrue(loaded.clicked)
        assertFalse(loaded.activationPending)
        assertTrue(manager(directory).takeActivations().isEmpty())
    }

    @Test
    fun rejectsMalformedActivationPendingShapesAndUnknownFields() {
        val notClicked = mirrorJson("not-clicked").also { json ->
            val entry = json.getJSONArray("entries").getJSONObject(0)
            entry.put("clicked", false)
            entry.put("activationPending", true)
        }
        assertMirrorRejected(notClicked)

        val notDelivered = mirrorJson("not-delivered").also { json ->
            val entry = json.getJSONArray("entries").getJSONObject(0)
            entry.put("state", DeliveryState.pending.name)
            entry.put("activationPending", true)
        }
        assertMirrorRejected(notDelivered)

        val malformedBoolean = mirrorJson("bad-boolean").also { json ->
            json.getJSONArray("entries").getJSONObject(0).put("activationPending", "true")
        }
        assertMirrorRejected(malformedBoolean)

        val unknownField = mirrorJson("unknown-field").also { json ->
            json.getJSONArray("entries").getJSONObject(0).put("unexpected", false)
        }
        assertMirrorRejected(unknownField)
    }

    private fun clickDeliveredReminder(id: String, directory: File): ActivatedReminder {
        val ledger = NotificationLedger(directory)
        val core = manager(ledger)
        val request = request(id)
        core.bind(authority(), listOf(request.identity))
        core.schedule(request)

        val scheduled = ledger.read().entries.getValue(id)
        now.set(request.identity.due)
        core.deliver(id, scheduled.nonce, scheduled.generation)
        val delivered = ledger.read().entries.getValue(id)
        assertEquals(DeliveryState.delivered, delivered.state)
        assertTrue(core.click(id, delivered.nonce, delivered.generation))

        return ActivatedReminder(directory, ledger, core)
    }

    private fun mirrorJson(id: String): JSONObject {
        val request = request(id)
        val entry = NativeEntry(
            request = request,
            nonce = NONCE,
            generation = LEGACY_GENERATION,
            state = DeliveryState.delivered,
            clicked = true,
        )
        return NotificationMirror(
            generation = LEGACY_GENERATION,
            blocked = false,
            authority = authority(),
            allowed = mapOf(id to request.identity),
            entries = mapOf(id to entry),
        ).json()
    }

    private fun assertMirrorRejected(raw: JSONObject) {
        try {
            NotificationMirror.parse(raw)
            throw AssertionError("Expected invalid activation mirror to be rejected")
        } catch (_: NotificationFailure) {
            // Invalid persisted state must fail closed at the mirror boundary.
        }
    }

    private fun manager(directory: File) = manager(NotificationLedger(directory))

    private fun manager(ledger: NotificationLedger) = NotificationManagerCore(ledger, FakeNotificationDriver()) {
        now.get()
    }

    private fun request(id: String): NativeRequest {
        val identity = RequestIdentity(id, now.get() + 500, DIGEST, TOKEN)
        return NativeRequest(identity, "Synthetic reminder", "Synthetic detail", "Synthetic location")
    }

    private fun authority(owner: String = "synthetic-owner", reset: Long = 1, agenda: Long = 1) =
        PublicationAuthority(owner = owner, reset = reset, agenda = agenda, revision = 1, enabled = true)

    private fun caseDirectory(name: String): File = File(temporaryDirectory, name).apply {
        assertTrue(mkdirs() || isDirectory)
    }

    private data class ActivatedReminder(
        val directory: File,
        val ledger: NotificationLedger,
        val manager: NotificationManagerCore,
    )

    private class FakeNotificationDriver : NotificationDriver {
        val scheduled = CopyOnWriteArrayList<NativeEntry>()
        val cancelled = CopyOnWriteArrayList<String>()

        override fun ensureChannel() = Unit
        override fun notificationsAllowed() = true
        override fun exactAllowed() = true
        override fun schedule(entry: NativeEntry, exact: Boolean) { scheduled += entry }
        override fun cancel(entry: NativeEntry) { cancelled += entry.request.identity.id }
        override fun cancelDisplayed(id: String) = Unit
        override fun show(entry: NativeEntry) = Unit
        override fun clearDisplayed() = Unit
        override fun displayedAreClear() = true
    }

    companion object {
        private const val BASE_NOW = 1_800_000_000_000L
        private const val DAY = 86_400_000L
        private const val LEGACY_GENERATION = 7L
        private val DIGEST = "d".repeat(64)
        private val TOKEN = "t".repeat(16)
        private val NONCE = "n".repeat(32)
    }
}
