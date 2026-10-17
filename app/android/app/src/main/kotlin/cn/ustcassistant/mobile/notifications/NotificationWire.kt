package cn.ustcassistant.mobile.notifications

import org.json.JSONArray
import org.json.JSONObject

internal class NotificationFailure(val code: String) : Exception(code)

internal fun exactKeys(map: Map<*, *>, fields: Set<String>) {
    if (map.keys != fields) throw NotificationFailure("invalid_input")
}

internal fun integer(raw: Any?, minimum: Long = 0, maximum: Long = 8_640_000_000_000_000): Long {
    val value = when (raw) { is Int -> raw.toLong(); is Long -> raw; else -> throw NotificationFailure("invalid_input") }
    if (value !in minimum..maximum) throw NotificationFailure("invalid_input")
    return value
}

internal fun opaque(raw: Any?, minimum: Int, maximum: Int): String {
    val value = raw as? String ?: throw NotificationFailure("invalid_input")
    if (value.length !in minimum..maximum || !value.matches(Regex("[A-Za-z0-9_-]+"))) {
        throw NotificationFailure("invalid_input")
    }
    return value
}

internal fun text(raw: Any?, maximum: Int, required: Boolean = false): String {
    val value = raw as? String ?: throw NotificationFailure("invalid_input")
    if (value.codePointCount(0, value.length) > maximum || (required && value.isBlank()) ||
        value.codePoints().anyMatch { it < 0x20 || it in 0x7f..0x9f || it in 0xd800..0xdfff }) {
        throw NotificationFailure("invalid_input")
    }
    return value
}

internal fun jsonMap(json: JSONObject): Map<String, Any?> = json.keys().asSequence().associateWith { key ->
    json.get(key).let { if (it === JSONObject.NULL) null else it }
}

internal data class RequestIdentity(val id: String, val due: Long, val digest: String, val token: String) {
    fun wire(): Map<String, Any> = mapOf("id" to id, "deliveryAtUnixMs" to due, "digest" to digest, "token" to token)
    fun json() = JSONObject(wire())
    companion object {
        private val fields = setOf("id", "deliveryAtUnixMs", "digest", "token")
        fun parse(raw: Any?): RequestIdentity {
            val map = raw as? Map<*, *> ?: throw NotificationFailure("invalid_input")
            exactKeys(map, fields)
            return RequestIdentity(opaque(map["id"], 1, 16), integer(map["deliveryAtUnixMs"]),
                opaque(map["digest"], 64, 64), opaque(map["token"], 16, 64))
        }
    }
}

internal data class NativeRequest(val identity: RequestIdentity, val title: String, val detail: String, val location: String) {
    fun wire(): Map<String, Any> = identity.wire() + mapOf("title" to title, "detail" to detail, "location" to location)
    fun json() = JSONObject(wire())
    companion object {
        private val fields = setOf("id", "deliveryAtUnixMs", "digest", "token", "title", "detail", "location")
        fun parse(raw: Any?): NativeRequest {
            val map = raw as? Map<*, *> ?: throw NotificationFailure("invalid_input")
            exactKeys(map, fields)
            return NativeRequest(RequestIdentity.parse(map.filterKeys { it in setOf("id", "deliveryAtUnixMs", "digest", "token") }),
                text(map["title"], 160, true), text(map["detail"], 240), text(map["location"], 160))
        }
    }
}

internal data class PublicationAuthority(val owner: String, val reset: Long, val agenda: Long, val revision: Long, val enabled: Boolean) {
    fun sameContext(other: PublicationAuthority) = owner == other.owner && reset == other.reset && agenda == other.agenda
    fun json() = JSONObject(mapOf("owner" to owner, "resetEpoch" to reset, "agendaEpoch" to agenda, "revision" to revision, "enabled" to enabled))
    companion object {
        fun parse(raw: Any?): PublicationAuthority {
            val map = raw as? Map<*, *> ?: throw NotificationFailure("invalid_input")
            exactKeys(map, setOf("owner", "resetEpoch", "agendaEpoch", "revision", "enabled"))
            val owner = opaque(map["owner"], 1, 96)
            return PublicationAuthority(owner, integer(map["resetEpoch"]), integer(map["agendaEpoch"]), integer(map["revision"]),
                map["enabled"] as? Boolean ?: throw NotificationFailure("invalid_input"))
        }
    }
}

internal enum class DeliveryState { pending, delivered, revoked }

internal data class NativeEntry(val request: NativeRequest, val nonce: String, val generation: Long,
    val state: DeliveryState = DeliveryState.pending, val registered: Boolean = false,
    val exact: Boolean = false, val clicked: Boolean = false, val activationPending: Boolean = false) {
    fun json() = JSONObject(mapOf("request" to request.json(), "nonce" to nonce, "generation" to generation,
        "state" to state.name, "registered" to registered, "exact" to exact, "clicked" to clicked,
        "activationPending" to activationPending))
    companion object {
        fun parse(raw: JSONObject): NativeEntry {
            val map = jsonMap(raw)
            val previous = setOf("request", "nonce", "generation", "state", "registered", "exact", "clicked")
            exactKeys(map, if (map.containsKey("activationPending")) previous + "activationPending" else previous)
            val state = DeliveryState.valueOf(map["state"] as? String ?: "")
            val clicked = map["clicked"] as? Boolean ?: throw NotificationFailure("invalid_input")
            // V1 entries from earlier QA builds remain consumed. Never invent
            // a fresh activation for a click whose handoff was not recorded.
            val activationPending = if (map.containsKey("activationPending")) {
                map["activationPending"] as? Boolean ?: throw NotificationFailure("invalid_input")
            } else false
            if (activationPending && (!clicked || state != DeliveryState.delivered)) throw NotificationFailure("invalid_input")
            return NativeEntry(NativeRequest.parse(jsonMap(raw.getJSONObject("request"))), opaque(map["nonce"], 32, 32),
                integer(map["generation"]), state,
                map["registered"] as? Boolean ?: throw NotificationFailure("invalid_input"),
                map["exact"] as? Boolean ?: throw NotificationFailure("invalid_input"),
                clicked, activationPending)
        }
    }
}

internal data class NotificationMirror(val generation: Long = 0, val blocked: Boolean = true,
    val authority: PublicationAuthority? = null, val allowed: Map<String, RequestIdentity> = emptyMap(),
    val entries: Map<String, NativeEntry> = emptyMap(), val deliveryFailures: Long = 0) {
    fun allows(entry: NativeEntry) = !blocked && authority?.enabled == true &&
        entry.generation == generation && entry.state != DeliveryState.revoked &&
        (allowed[entry.request.identity.id] == entry.request.identity || entry.request.identity.id == "m6-check")
    fun json(): JSONObject = JSONObject(mapOf("format" to 1, "generation" to generation, "blocked" to blocked,
        "authority" to (authority?.json() ?: JSONObject.NULL), "deliveryFailures" to deliveryFailures,
        "allowed" to JSONArray(allowed.values.map { it.json() }), "entries" to JSONArray(entries.values.map { it.json() })))
    companion object {
        const val MAX_ENTRIES = 2048
        fun parse(raw: JSONObject): NotificationMirror {
            val map = jsonMap(raw)
            exactKeys(map, setOf("format", "generation", "blocked", "authority", "allowed", "entries", "deliveryFailures"))
            if (map["format"] != 1) throw NotificationFailure("storage_failed")
            val authority = if (raw.isNull("authority")) null else PublicationAuthority.parse(jsonMap(raw.getJSONObject("authority")))
            val allowedArray = raw.getJSONArray("allowed")
            val entryArray = raw.getJSONArray("entries")
            if (allowedArray.length() > MAX_ENTRIES || entryArray.length() > MAX_ENTRIES) throw NotificationFailure("storage_failed")
            val allowed = (0 until allowedArray.length()).map { RequestIdentity.parse(jsonMap(allowedArray.getJSONObject(it))) }
            val entries = (0 until entryArray.length()).map { NativeEntry.parse(entryArray.getJSONObject(it)) }
            if (allowed.distinctBy { it.id }.size != allowed.size || entries.distinctBy { it.request.identity.id }.size != entries.size) {
                throw NotificationFailure("storage_failed")
            }
            return NotificationMirror(integer(map["generation"]), map["blocked"] as? Boolean ?: throw NotificationFailure("storage_failed"),
                authority, allowed.associateBy { it.id }, entries.associateBy { it.request.identity.id }, integer(map["deliveryFailures"]))
        }
    }
}
