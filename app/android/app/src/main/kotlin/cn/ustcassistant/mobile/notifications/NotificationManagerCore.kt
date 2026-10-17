package cn.ustcassistant.mobile.notifications

import java.util.UUID
import java.util.concurrent.Executors

internal object NotificationSerialization {
    val monitor = Any()
    val worker = Executors.newSingleThreadExecutor()
}

internal interface NotificationDriver {
    fun ensureChannel()
    fun notificationsAllowed(): Boolean
    fun exactAllowed(): Boolean
    fun schedule(entry: NativeEntry, exact: Boolean)
    fun cancel(entry: NativeEntry)
    fun cancelDisplayed(id: String)
    fun show(entry: NativeEntry)
    fun clearDisplayed()
    fun displayedAreClear(): Boolean
}

/** Serializes mirror persistence and the final OS call, including Receiver use.
 * It never opens the business database and never decides business eligibility.
 */
internal class NotificationManagerCore(private val ledger: NotificationLedger, private val driver: NotificationDriver,
    private val now: () -> Long = System::currentTimeMillis) {
    companion object { const val MAX_PENDING = 480; private const val DAY = 86_400_000L }
    private var restoredAccess: Pair<Boolean, Boolean>? = null

    fun initialize(): Map<String, Any> = synchronized(NotificationSerialization.monitor) {
        driver.ensureChannel()
        val access = driver.notificationsAllowed() to driver.exactAllowed()
        if (restoredAccess != access) {
            restoreLocked()
            restoredAccess = access
        }
        capabilityLocked()
    }

    fun capability(): Map<String, Any> = synchronized(NotificationSerialization.monitor) { capabilityLocked() }

    private fun capabilityLocked(): Map<String, Any> = mapOf(
        "available" to true, "enabledBySystem" to driver.notificationsAllowed(),
        "schedulesAfterExit" to true, "activationAvailable" to true,
        "exactScheduling" to driver.exactAllowed(), "queueEvidence" to "localRegistration",
        "maximumPending" to MAX_PENDING, "deliveryFailures" to ledger.read().deliveryFailures)

    fun bind(authority: PublicationAuthority, allowed: List<RequestIdentity>) = synchronized(NotificationSerialization.monitor) {
        if (allowed.size > NotificationMirror.MAX_ENTRIES || allowed.distinctBy { it.id }.size != allowed.size ||
            (!authority.enabled && allowed.isNotEmpty())) throw NotificationFailure("invalid_input")
        var state = ledger.read()
        val previous = state.authority
        if (previous != null && previous.sameContext(authority) && authority.revision < previous.revision) {
            throw NotificationFailure("stale")
        }
        val generation = state.generation + if (previous != null && !previous.sameContext(authority)) 1 else 0
        state = state.copy(generation = generation, blocked = false, authority = authority, allowed = allowed.associateBy { it.id })
        state = state.copy(entries = state.entries.mapValues { (_, entry) ->
            if (!state.allows(entry) || entry.request.identity.due < now() - 30 * DAY ||
                (entry.state == DeliveryState.pending && entry.request.identity.due < now() - DAY)) entry.copy(state = DeliveryState.revoked, registered = false, activationPending = false)
            else entry
        })
        // An old intent loses authority durably before any OS cancellation.
        ledger.write(state)
        cleanupRevoked(state)
    }

    fun block() = synchronized(NotificationSerialization.monitor) {
        val state = ledger.read()
        ledger.write(state.copy(blocked = true, generation = state.generation + 1))
    }

    fun schedule(request: NativeRequest) = synchronized(NotificationSerialization.monitor) {
        var state = cleanupRevoked(ledger.read())
        val id = request.identity.id
        if (state.blocked || state.authority?.enabled != true) throw NotificationFailure("maintenance")
        if (id != "m6-check" && state.allowed[id] != request.identity) throw NotificationFailure("stale")
        if (request.identity.due <= now() || request.identity.due > now() + 181 * DAY) throw NotificationFailure("invalid_input")
        if (!driver.notificationsAllowed()) throw NotificationFailure("disabled_by_system")
        val old = state.entries[id]
        // A wall-clock rollback must not turn a consumed request into a new
        // alarm. Keep the durable consumption evidence until C3 replaces it.
        if (old != null && old.request == request && old.generation == state.generation && old.state == DeliveryState.delivered) {
            throw NotificationFailure("stale")
        }
        if (old != null && (old.request != request || old.generation != state.generation || old.state != DeliveryState.pending)) {
            state = revoke(state, id)
            state = cleanupRevoked(state)
        }
        val existing = state.entries[id]
        if (existing == null && state.entries.values.count { it.state == DeliveryState.pending } >= MAX_PENDING) {
            throw NotificationFailure("publish_failed")
        }
        if (existing == null && state.entries.size >= NotificationMirror.MAX_ENTRIES) throw NotificationFailure("publish_failed")
        val entry = existing ?: NativeEntry(request, UUID.randomUUID().toString().replace("-", ""), state.generation)
        val exact = driver.exactAllowed()
        val pending = entry.copy(registered = false, exact = exact)
        state = state.copy(entries = state.entries + (id to pending))
        ledger.write(state)
        try {
            driver.schedule(pending, exact)
            ledger.write(state.copy(entries = state.entries + (id to pending.copy(registered = true))))
        } catch (error: Exception) {
            if (error is NotificationFailure) throw error
            throw NotificationFailure("publish_failed")
        }
    }

    fun pending(): List<Map<String, Any>> = synchronized(NotificationSerialization.monitor) {
        val state = cleanupRevoked(ledger.read())
        if (!driver.notificationsAllowed()) return@synchronized emptyList()
        state.entries.values.filter { state.allows(it) && it.state == DeliveryState.pending && it.registered && it.request.identity.due > now() }
            .map { it.request.wire() }
    }

    fun cancel(id: String) = synchronized(NotificationSerialization.monitor) {
        var state = ledger.read()
        if (state.entries.containsKey(id)) state = revoke(state, id)
        cleanupRevoked(state)
        try { driver.cancelDisplayed(id) } catch (_: Exception) { throw NotificationFailure("cancel_failed") }
    }

    private fun revoke(state: NotificationMirror, id: String): NotificationMirror {
        val entry = state.entries[id] ?: return state
        val revoked = state.copy(entries = state.entries + (id to entry.copy(state = DeliveryState.revoked, registered = false, activationPending = false)))
        ledger.write(revoked)
        return revoked
    }

    private fun cleanupRevoked(original: NotificationMirror): NotificationMirror {
        var state = original
        var failed = false
        for (entry in original.entries.values.filter { it.state == DeliveryState.revoked }) {
            try {
                driver.cancel(entry)
                state = state.copy(entries = state.entries - entry.request.identity.id)
            } catch (_: Exception) { failed = true }
        }
        if (state != original) ledger.write(state)
        if (failed) throw NotificationFailure("cancel_failed")
        return state
    }

    fun clear() = synchronized(NotificationSerialization.monitor) {
        var state = ledger.read()
        state = state.copy(blocked = true, generation = state.generation + 1,
            deliveryFailures = 0, allowed = emptyMap(), entries = state.entries.mapValues { (_, entry) -> entry.copy(state = DeliveryState.revoked, registered = false, activationPending = false) })
        ledger.write(state)
        try {
            cleanupRevoked(state)
            driver.clearDisplayed()
            if (!driver.displayedAreClear()) throw NotificationFailure("cleanup_pending")
        } catch (_: Exception) { throw NotificationFailure("cleanup_pending") }
    }

    fun restore() = synchronized(NotificationSerialization.monitor) {
        driver.ensureChannel(); restoreLocked()
        restoredAccess = driver.notificationsAllowed() to driver.exactAllowed()
    }

    private fun restoreLocked() {
        var state = cleanupRevoked(ledger.read())
        if (state.blocked) return
        val enabled = driver.notificationsAllowed()
        val exact = driver.exactAllowed()
        state = state.copy(entries = state.entries.mapValues { (_, entry) ->
            if (entry.state != DeliveryState.pending) entry
            else if (!state.allows(entry) || entry.request.identity.due <= now()) entry.copy(state = DeliveryState.revoked, registered = false, activationPending = false)
            else entry.copy(registered = false, exact = exact)
        })
        // One durable revocation batch before OS work, one acknowledgement
        // batch after. Avoid hundreds of full-mirror fsyncs on boot/resume.
        ledger.write(state)
        state = cleanupRevoked(state)
        var failed = false
        for (next in state.entries.values.filter { it.state == DeliveryState.pending }) {
            try {
                if (enabled) {
                    driver.schedule(next, next.exact)
                    state = state.copy(entries = state.entries + (next.request.identity.id to next.copy(registered = true)))
                } else driver.cancel(next)
            } catch (_: Exception) { failed = true }
        }
        ledger.write(state)
        if (failed) throw NotificationFailure("publish_failed")
    }

    fun deliver(id: String, nonce: String, generation: Long) = synchronized(NotificationSerialization.monitor) {
        var state = ledger.read()
        val entry = state.entries[id] ?: return@synchronized
        val due = entry.request.identity.due
        if (!state.allows(entry) || !entry.registered || entry.state != DeliveryState.pending ||
            nonce != entry.nonce || generation != entry.generation || due > now() + 1000 || due < now() - DAY) return@synchronized
        // Consume before notify. A crash here can miss an alert; it cannot replay
        // it. This is deliberately not an exactly-once delivery claim.
        state = state.copy(entries = state.entries + (id to entry.copy(state = DeliveryState.delivered, registered = false)))
        ledger.write(state)
        try {
            if (!driver.notificationsAllowed()) throw NotificationFailure("disabled_by_system")
            driver.show(entry)
        } catch (_: Exception) {
            ledger.write(state.copy(deliveryFailures = minOf(state.deliveryFailures + 1, 1_000_000)))
        }
    }

    fun click(id: String, nonce: String, generation: Long): Boolean = synchronized(NotificationSerialization.monitor) {
        val state = ledger.read()
        val entry = state.entries[id] ?: return@synchronized false
        if (!state.allows(entry) || entry.state != DeliveryState.delivered || entry.clicked ||
            entry.nonce != nonce || entry.generation != generation || entry.request.identity.due < now() - 30 * DAY) return@synchronized false
        val pending = state.entries.values.filter { it.activationPending }
        val entries = state.entries.toMutableMap()
        if (pending.size >= 32) {
            // Keep the bounded handoff queue in the existing minimal mirror.
            val oldest = pending.minBy { it.request.identity.due }
            entries[oldest.request.identity.id] = oldest.copy(activationPending = false)
        }
        entries[id] = entry.copy(clicked = true, activationPending = true)
        ledger.write(state.copy(entries = entries))
        true
    }

    fun takeActivations(): List<Map<String, String>> = synchronized(NotificationSerialization.monitor) {
        val state = ledger.read()
        val pending = state.entries.values.filter { it.activationPending }
        if (pending.isEmpty()) return@synchronized emptyList()
        val current = pending.filter { state.allows(it) && it.state == DeliveryState.delivered &&
            it.request.identity.due >= now() - 30 * DAY }.take(32)
        // Crash before this durable handoff can retry after a cold restart.
        // After handing to Dart, routing is best effort and revalidated by C3;
        // this deliberately does not claim exactly-once UI navigation.
        ledger.write(state.copy(entries = state.entries.mapValues { (_, entry) ->
            if (entry.activationPending) entry.copy(activationPending = false) else entry
        }))
        current.map { mapOf("id" to it.request.identity.id,
            "digest" to it.request.identity.digest, "token" to it.request.identity.token) }
    }
}
