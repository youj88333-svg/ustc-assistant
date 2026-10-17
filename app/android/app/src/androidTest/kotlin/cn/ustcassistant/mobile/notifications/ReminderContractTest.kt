package cn.ustcassistant.mobile.notifications

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.Before
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class ReminderContractTest {
    private lateinit var temporaryDirectory: File
    private val now = AtomicLong(BASE_NOW)

    @Before
    fun createTemporaryLedgerDirectory() {
        val cache = InstrumentationRegistry.getInstrumentation().targetContext.cacheDir.canonicalFile
        temporaryDirectory = File(cache, "reminder-contract-${UUID.randomUUID()}")
        assertTrue(temporaryDirectory.mkdirs() || temporaryDirectory.isDirectory)
    }

    @After
    fun deleteOnlyThisTestsTemporaryDirectory() {
        if (!::temporaryDirectory.isInitialized) return
        val cache = InstrumentationRegistry.getInstrumentation().targetContext.cacheDir.canonicalFile
        val candidate = temporaryDirectory.canonicalFile
        if (candidate.parentFile == cache && candidate.name.startsWith("reminder-contract-")) {
            assertTrue(!candidate.exists() || candidate.deleteRecursively())
        }
    }

    @Test
    fun bindsSchedulesAndReadsBackRegisteredSyntheticReminder() {
        val ledger = NotificationLedger(temporaryDirectory)
        val driver = FakeNotificationDriver()
        val manager = manager(ledger, driver)
        val request = install(manager, listOf("reminder-one")).single()

        val saved = ledger.read().entries.getValue(request.identity.id)
        assertEquals(DeliveryState.pending, saved.state)
        assertTrue(saved.registered)
        assertTrue(saved.exact)
        assertEquals(request.wire(), manager.pending().single())
        assertEquals(listOf("reminder-one"), driver.scheduled.map { it.entry.request.identity.id })
        assertTrue(driver.scheduled.single().exact)
    }

    @Test
    fun rejectsBadNonceAndOldGenerationForDeliveryAndClick() {
        val ledger = NotificationLedger(temporaryDirectory)
        val driver = FakeNotificationDriver()
        val manager = manager(ledger, driver)
        val requests = install(manager, listOf("click-reminder", "broadcast-rem"))
        val clickRequest = requests.first { it.identity.id == "click-reminder" }
        val broadcastRequest = requests.first { it.identity.id == "broadcast-rem" }
        val clickEntry = ledger.read().entries.getValue(clickRequest.identity.id)
        val broadcastEntry = ledger.read().entries.getValue(broadcastRequest.identity.id)

        manager.deliver(clickRequest.identity.id, clickEntry.nonce, clickEntry.generation)
        assertFalse(manager.click(clickRequest.identity.id, "wrong${clickEntry.nonce}", clickEntry.generation))

        manager.deliver(broadcastRequest.identity.id, "wrong${broadcastEntry.nonce}", broadcastEntry.generation)
        assertEquals(1, driver.showCalls.size)

        // A block advances the durable generation. The already delivered click and
        // the pending broadcast both carry the old generation and must be rejected.
        manager.block()
        assertEquals(clickEntry.generation + 1, ledger.read().generation)
        manager.deliver(broadcastRequest.identity.id, broadcastEntry.nonce, broadcastEntry.generation)
        assertFalse(manager.click(clickRequest.identity.id, clickEntry.nonce, clickEntry.generation))
        assertTrue(manager.takeActivations().isEmpty())
        assertEquals(1, driver.showCalls.size)
    }

    @Test
    fun clearBlocksDurablyBeforeCancellationFailureAndRejectsOldDelivery() {
        val ledger = NotificationLedger(temporaryDirectory)
        val driver = FakeNotificationDriver()
        val manager = manager(ledger, driver)
        val request = install(manager, listOf("clear-reminder")).single()
        val entry = ledger.read().entries.getValue(request.identity.id)
        var stateAtCancellation: NotificationMirror? = null
        driver.beforeCancel = { stateAtCancellation = ledger.read() }
        driver.cancelError = IllegalStateException("synthetic cancellation failure")

        expectFailure("cleanup_pending") { manager.clear() }

        val persistedAtCancellation = stateAtCancellation
        assertNotNull(persistedAtCancellation)
        assertTrue(persistedAtCancellation!!.blocked)
        assertEquals(entry.generation + 1, persistedAtCancellation.generation)
        assertEquals(DeliveryState.revoked, persistedAtCancellation.entries.getValue(request.identity.id).state)
        manager.deliver(request.identity.id, entry.nonce, entry.generation)
        assertTrue(driver.showCalls.isEmpty())
        assertTrue(ledger.read().blocked)
        assertEquals(emptyList<String>(), driver.cancelDisplayedCalls)
    }

    @Test
    fun reconstructedManagerRestoresOnlyUnblockedFutureEntries() {
        val firstLedger = NotificationLedger(temporaryDirectory)
        val firstDriver = FakeNotificationDriver()
        val firstManager = manager(firstLedger, firstDriver)
        val dueSoon = now.get() + 60_000
        val dueLater = now.get() + 120_000
        val requests = listOf(
            request("expired-old", dueSoon),
            request("still-in-future", dueLater),
        )
        firstManager.bind(authority(), requests.map { it.identity })
        requests.forEach(firstManager::schedule)

        now.addAndGet(90_000)
        val secondLedger = NotificationLedger(temporaryDirectory)
        val secondDriver = FakeNotificationDriver()
        val secondManager = manager(secondLedger, secondDriver)
        secondManager.restore()

        assertEquals(listOf("still-in-future"), secondDriver.scheduled.map { it.entry.request.identity.id })
        assertEquals(listOf("expired-old"), secondDriver.cancelledIds)
        assertEquals(setOf("still-in-future"), secondLedger.read().entries.keys)
        assertEquals(listOf(requests.last().wire()), secondManager.pending())

        secondManager.block()
        val thirdLedger = NotificationLedger(temporaryDirectory)
        val thirdDriver = FakeNotificationDriver()
        manager(thirdLedger, thirdDriver).restore()
        assertTrue(thirdLedger.read().blocked)
        assertTrue(thirdDriver.scheduled.isEmpty())
    }

    @Test
    fun corruptMirrorFailsClosedWithoutScheduling() {
        File(temporaryDirectory, "reminders.json").writeText("{corrupt synthetic mirror")
        val driver = FakeNotificationDriver()
        val manager = manager(NotificationLedger(temporaryDirectory), driver)

        expectFailure("storage_failed") { manager.restore() }

        assertTrue(driver.scheduled.isEmpty())
        assertTrue(driver.showCalls.isEmpty())
    }

    @Test
    fun showAndBlockAreSerializedByTheSameProcessMonitor() {
        val ledger = NotificationLedger(temporaryDirectory)
        val driver = FakeNotificationDriver()
        val manager = manager(ledger, driver)
        val request = install(manager, listOf("ordered-rem")).single()
        val entry = ledger.read().entries.getValue(request.identity.id)
        val showEntered = CountDownLatch(1)
        val releaseShow = CountDownLatch(1)
        val blockAttempted = CountDownLatch(1)
        val blockFinished = CountDownLatch(1)
        val blockThread = AtomicReference<Thread>()
        driver.showHook = {
            driver.events += "show-enter"
            showEntered.countDown()
            check(releaseShow.await(5, TimeUnit.SECONDS))
            driver.events += "show-exit"
        }
        val executor = Executors.newFixedThreadPool(2)

        try {
            val delivery = executor.submit {
                manager.deliver(request.identity.id, entry.nonce, entry.generation)
            }
            assertTrue(showEntered.await(5, TimeUnit.SECONDS))
            val block = executor.submit {
                blockThread.set(Thread.currentThread())
                blockAttempted.countDown()
                manager.block()
                blockFinished.countDown()
            }
            assertTrue(blockAttempted.await(5, TimeUnit.SECONDS))

            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            while (blockThread.get()?.state != Thread.State.BLOCKED && System.nanoTime() < deadline) {
                Thread.yield()
            }
            assertEquals(Thread.State.BLOCKED, blockThread.get().state)
            assertFalse(blockFinished.await(100, TimeUnit.MILLISECONDS))
            assertEquals(DeliveryState.delivered, ledger.read().entries.getValue(request.identity.id).state)

            releaseShow.countDown()
            delivery.get(5, TimeUnit.SECONDS)
            block.get(5, TimeUnit.SECONDS)
            assertTrue(blockFinished.await(5, TimeUnit.SECONDS))
            assertTrue(ledger.read().blocked)
            assertEquals(listOf("show-enter", "show-exit"), driver.events)
        } finally {
            releaseShow.countDown()
            executor.shutdownNow()
            executor.awaitTermination(5, TimeUnit.SECONDS)
        }
    }

    @Test
    fun persistedConsumptionAndShowFailureOnlyIncrementDeliveryFailures() {
        val ledger = NotificationLedger(temporaryDirectory)
        val driver = FakeNotificationDriver()
        driver.showError = IllegalStateException("synthetic notify failure")
        val manager = manager(ledger, driver)
        val request = install(manager, listOf("notify-fails")).single()
        val entry = ledger.read().entries.getValue(request.identity.id)

        manager.deliver(request.identity.id, entry.nonce, entry.generation)
        val afterFirstDelivery = ledger.read()
        assertEquals(DeliveryState.delivered, afterFirstDelivery.entries.getValue(request.identity.id).state)
        assertFalse(afterFirstDelivery.entries.getValue(request.identity.id).registered)
        assertEquals(1L, afterFirstDelivery.deliveryFailures)

        manager.deliver(request.identity.id, entry.nonce, entry.generation)
        val afterReplay = ledger.read()
        assertEquals(1, driver.showCalls.size)
        assertEquals(1L, afterReplay.deliveryFailures)
        assertEquals(DeliveryState.delivered, afterReplay.entries.getValue(request.identity.id).state)
    }

    @Test
    fun reportsNotificationAndExactPermissionEvidenceWithoutOverclaimingQueue() {
        val ledger = NotificationLedger(temporaryDirectory)
        val driver = FakeNotificationDriver().apply {
            notificationsEnabled = false
            exactSchedulingAllowed = false
        }
        val manager = manager(ledger, driver)
        val initial = manager.initialize()
        assertEquals(false, initial["enabledBySystem"])
        assertEquals(false, initial["exactScheduling"])
        assertEquals("localRegistration", initial["queueEvidence"])
        assertEquals(480, initial["maximumPending"])

        val request = request("inexact-rem")
        manager.bind(authority(), listOf(request.identity))
        expectFailure("disabled_by_system") { manager.schedule(request) }
        assertFalse(ledger.read().entries.containsKey(request.identity.id))

        driver.notificationsEnabled = true
        manager.schedule(request)
        assertFalse(driver.scheduled.single().exact)
        assertFalse(ledger.read().entries.getValue(request.identity.id).exact)
        assertEquals(false, manager.capability()["exactScheduling"])
    }

    @Test
    fun clockRollbackCannotRearmAnAlreadyDeliveredIdentity() {
        val ledger = NotificationLedger(temporaryDirectory)
        val driver = FakeNotificationDriver()
        val manager = manager(ledger, driver)
        val request = install(manager, listOf("clock-rollback")).single()
        val original = ledger.read().entries.getValue(request.identity.id)
        now.set(request.identity.due)
        manager.deliver(request.identity.id, original.nonce, original.generation)
        now.addAndGet(-60_000)
        expectFailure("stale") { manager.schedule(request) }
        assertEquals(original.nonce, ledger.read().entries.getValue(request.identity.id).nonce)
        assertEquals(DeliveryState.delivered, ledger.read().entries.getValue(request.identity.id).state)
        assertEquals(1, driver.scheduled.size)
        assertEquals(1, driver.showCalls.size)
    }

    @Test
    fun boundedRestoreBatches480EntriesAndRepeatedInitializeDoesNotReschedule() {
        val ledger = NotificationLedger(temporaryDirectory)
        val driver = FakeNotificationDriver()
        val requests = (0 until 480).map { request("limit-$it", now.get() + 60_000) }
        val entries = requests.associate { it.identity.id to NativeEntry(it, UUID.randomUUID().toString().replace("-", ""), 0) }
        ledger.write(NotificationMirror(blocked = false, authority = authority(), allowed = requests.associateBy { it.identity.id }.mapValues { it.value.identity }, entries = entries))
        val manager = manager(ledger, driver)
        val start = android.os.SystemClock.elapsedRealtime()
        manager.initialize()
        val elapsed = android.os.SystemClock.elapsedRealtime() - start
        assertEquals(480, manager.pending().size)
        assertTrue("bounded mirror restore exceeded bridge timeout: $elapsed ms", elapsed < 7000)
        manager.initialize()
        assertEquals(480, driver.scheduled.size)
        println("A5 synthetic 480-entry restore ms=$elapsed")
    }

    private fun manager(
        ledger: NotificationLedger,
        driver: FakeNotificationDriver,
    ) = NotificationManagerCore(ledger, driver) { now.get() }

    private fun install(manager: NotificationManagerCore, ids: List<String>): List<NativeRequest> {
        val requests = ids.map { request(it) }
        manager.bind(authority(), requests.map { it.identity })
        requests.forEach(manager::schedule)
        return requests
    }

    private fun request(id: String, due: Long = now.get() + 500): NativeRequest {
        val identity = RequestIdentity(id, due, "d".repeat(64), "t".repeat(16))
        return NativeRequest(identity, "Synthetic reminder", "Synthetic detail", "Synthetic location")
    }

    private fun authority() = PublicationAuthority(
        owner = "synthetic-owner",
        reset = 1,
        agenda = 1,
        revision = 1,
        enabled = true,
    )

    private fun expectFailure(expectedCode: String, action: () -> Unit) {
        try {
            action()
            throw AssertionError("Expected NotificationFailure($expectedCode)")
        } catch (failure: NotificationFailure) {
            assertEquals(expectedCode, failure.code)
        }
    }

    private data class ScheduleCall(val entry: NativeEntry, val exact: Boolean)

    private class FakeNotificationDriver : NotificationDriver {
        val scheduled = CopyOnWriteArrayList<ScheduleCall>()
        val cancelledIds = CopyOnWriteArrayList<String>()
        val cancelDisplayedCalls = CopyOnWriteArrayList<String>()
        val showCalls = CopyOnWriteArrayList<String>()
        val events = CopyOnWriteArrayList<String>()
        @Volatile var notificationsEnabled = true
        @Volatile var exactSchedulingAllowed = true
        @Volatile var cancelError: Exception? = null
        @Volatile var showError: Exception? = null
        @Volatile var beforeCancel: (() -> Unit)? = null
        @Volatile var showHook: (() -> Unit)? = null
        @Volatile var displayedClear = true

        override fun ensureChannel() = Unit
        override fun notificationsAllowed() = notificationsEnabled
        override fun exactAllowed() = exactSchedulingAllowed
        override fun schedule(entry: NativeEntry, exact: Boolean) {
            scheduled += ScheduleCall(entry, exact)
        }
        override fun cancel(entry: NativeEntry) {
            cancelledIds += entry.request.identity.id
            beforeCancel?.invoke()
            cancelError?.let { throw it }
        }
        override fun cancelDisplayed(id: String) {
            cancelDisplayedCalls += id
        }
        override fun show(entry: NativeEntry) {
            showCalls += entry.request.identity.id
            showHook?.invoke()
            showError?.let { throw it }
        }
        override fun clearDisplayed() {
            displayedClear = true
        }
        override fun displayedAreClear() = displayedClear
    }

    companion object {
        private const val BASE_NOW = 1_800_000_000_000L
    }
}
