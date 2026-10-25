package cn.ustcassistant.mobile.browser

import android.content.Context
import android.content.pm.ApplicationInfo
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.security.MessageDigest

/**
 * Durable, account-free mapping from approved C3 profile directories to AndroidX names.
 * This class records lifecycle metadata only; it never opens browser storage or C3 data.
 */
internal class ProfileLedger(context: Context) {
    internal data class Entry(
        val name: String,
        val ephemeral: Boolean,
        val revoked: Boolean,
    )

    private enum class State(val wireName: String) {
        RETAINED("retained"),
        CLEARED("cleared"),
        DELETED("deleted"),
    }

    private data class Record(
        val name: String,
        val source: String,
        val relativePath: String,
        val generation: Long,
        val ephemeral: Boolean,
        val revoked: Boolean,
        val state: State,
    ) {
        fun entry() = Entry(name = name, ephemeral = ephemeral, revoked = revoked)
    }

    private data class Candidate(
        val source: String,
        val relativePath: String,
        val ephemeral: Boolean,
    )

    private val qaBuild = context.packageName.endsWith(".qa") &&
        (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
    private val root: File
    private val ledgerRoot: File
    private val ledgerFile: AtomicFile
    private var records: List<Record>

    init {
        // Android itself exposes /data/user/0 through a platform-owned alias.
        // Resolve only this trusted Context root; caller paths stay exact/canonical.
        val noBackupRoot = context.noBackupFilesDir.canonicalFile
        ensureDirectoryChain(noBackupRoot, createMissing = false)
        root = File(noBackupRoot, "ustc_assistant_v1")
        ensureDirectoryChain(root, createMissing = true)
        ledgerRoot = File(root, "platform_webview_v1")
        ensureDirectoryChain(ledgerRoot, createMissing = true)
        val base = File(ledgerRoot, LEDGER_FILE_NAME)
        verifyLedgerNode(base)
        verifyLedgerNode(File(base.path + ".bak"))
        ledgerFile = AtomicFile(base)
        records = readLedger()
    }

    /**
     * Claims an already-created C3 path. Recovery persists revocation before opening
     * a known profile; an unknown but valid C3 path is registered as cleanup-only.
     */
    @Synchronized
    fun claim(
        profilePath: String,
        source: String,
        fixture: Boolean,
        recoveryOnly: Boolean,
    ): Entry {
        val candidate = validateProfilePath(profilePath, source, fixture)
        val matching = records
            .filter { it.source == candidate.source && it.relativePath == candidate.relativePath }
            .maxByOrNull { it.generation }

        if (matching == null) {
            // A C3-registered candidate can be recovered even if native never opened it.
            // Persist revocation before the root creates a constrained cleanup profile.
            val record = newRecord(candidate, generation = 1).copy(revoked = recoveryOnly)
            check(records.none { it.name == record.name }) { "Profile name collision" }
            persist(records + record)
            return record.entry()
        }

        when (matching.state) {
            State.CLEARED -> {
                check(recoveryOnly) { "Profile cleanup is pending cold deletion" }
                return matching.entry()
            }
            State.DELETED -> {
                if (recoveryOnly) return matching.entry()
                check(matching.generation < Long.MAX_VALUE) { "Profile generation is exhausted" }
                val generation = matching.generation + 1L
                val record = newRecord(candidate, generation)
                check(records.none { it.name == record.name }) { "Profile name collision" }
                persist(records + record)
                return record.entry()
            }
            State.RETAINED -> Unit
        }

        if (matching.revoked || recoveryOnly) {
            check(recoveryOnly) { "Revoked profile is available only during recovery" }
            // Persist even when already revoked so a recovery caller never receives
            // an Entry before durable evidence exists on this process path.
            val replacement = matching.copy(revoked = true)
            persist(records.map { if (it.name == matching.name) replacement else it })
            return replacement.entry()
        }

        return matching.entry()
    }

    /** Persist access revocation before the caller cancels work or touches WebView. */
    @Synchronized
    fun revoke(entry: Entry) {
        val record = requireKnown(entry)
        check(record.state != State.DELETED) { "Deleted profile cannot be revoked" }
        if (record.revoked) return
        persist(records.map {
            if (it.name == record.name) record.copy(revoked = true) else it
        })
    }

    /** Records the successful AndroidX browsing-data deletion callback. */
    @Synchronized
    fun cleared(entry: Entry) {
        val record = requireKnown(entry)
        check(record.revoked) { "Profile must be revoked before clearing" }
        when (record.state) {
            State.RETAINED -> persist(records.map {
                if (it.name == record.name) record.copy(state = State.CLEARED) else it
            })
            State.CLEARED -> Unit
            State.DELETED -> error("Deleted profile cannot be cleared again")
        }
    }

    /**
     * Durably confirms that a non-revoked profile remains in use. It cannot undo a
     * revocation or cancel a completed clear, so neither can re-enable old assets.
     */
    @Synchronized
    fun retained(entry: Entry) {
        val record = requireKnown(entry)
        check(record.state == State.RETAINED && !record.revoked) {
            "Revoked or cleared profile cannot be retained"
        }
        // The record was committed by claim; this explicit acknowledgement is safe
        // to repeat and leaves the same durable retained state in place.
        persist(records)
    }

    /** Only SDK-cleared, known mappings are eligible for a cold ProfileStore delete. */
    @Synchronized
    fun pendingColdDelete(): List<Entry> = records
        .filter { it.state == State.CLEARED }
        .sortedBy { it.name }
        .map { it.entry() }

    /** True once SDK browsing-data clearing was recorded, including completed deletion. */
    @Synchronized
    fun wasCleared(entry: Entry): Boolean = when (requireKnown(entry).state) {
        State.CLEARED, State.DELETED -> true
        State.RETAINED -> false
    }

    /** Called only after the root has successfully deleted this cold AndroidX profile. */
    @Synchronized
    fun deleted(entry: Entry) {
        val record = requireKnown(entry)
        when (record.state) {
            State.CLEARED -> persist(records.map {
                if (it.name == record.name) record.copy(state = State.DELETED) else it
            })
            State.DELETED -> Unit
            State.RETAINED -> error("Profile must be SDK-cleared before deletion")
        }
    }

    private fun requireKnown(entry: Entry): Record {
        val record = records.firstOrNull { it.name == entry.name }
            ?: error("Unknown profile entry")
        require(record.ephemeral == entry.ephemeral) { "Profile entry does not match ledger" }
        return record
    }

    private fun validateProfilePath(
        rawPath: String,
        source: String,
        fixture: Boolean,
    ): Candidate {
        require(source == "jw" || source == "young") { "Unsupported profile source" }
        require(rawPath.isNotEmpty() && rawPath[0] == File.separatorChar) {
            "Profile path must be absolute"
        }
        require(!rawPath.endsWith(File.separator) && !rawPath.contains("${File.separator}${File.separator}")) {
            "Profile path is not normalized"
        }
        require(rawPath.none { it == '\u0000' || it == '\\' }) { "Invalid profile path" }
        val parts = rawPath.split(File.separatorChar)
        require(parts.firstOrNull() == "" && parts.drop(1).all {
            it.isNotEmpty() && it != "." && it != ".."
        }) { "Profile path is not normalized" }

        val rootPath = root.absolutePath
        val prefix = rootPath + File.separator
        require(rawPath.startsWith(prefix)) { "Profile path is outside the private root" }
        val relative = rawPath.substring(prefix.length)
        val pathParts = relative.split(File.separatorChar)
        val candidate = parseRelativePath(pathParts, source, fixture)
        require(File(rawPath).absolutePath == rawPath) { "Profile path is not canonical" }
        require(File(rawPath).canonicalPath == rawPath) { "Profile path resolves through an alias" }
        ensureDirectoryChain(File(rawPath), createMissing = false)
        return candidate
    }

    private fun parseRelativePath(
        parts: List<String>,
        source: String,
        fixture: Boolean,
    ): Candidate {
        val fixtureRoot = parts.firstOrNull()?.takeIf { it.startsWith(FIXTURE_PREFIX) }
        val relativeParts = if (fixtureRoot != null) {
            require(qaBuild && fixture) { "Fixture paths require the isolated QA identity" }
            require(FIXTURE_ROOT.matches(fixtureRoot)) { "Invalid fixture root" }
            parts.drop(1)
        } else {
            require(!fixture) { "Fixture profiles require an isolated fixture root" }
            parts
        }

        require(relativeParts.size == 3) { "Unknown profile namespace" }
        val top = relativeParts[0]
        val namespace = relativeParts[1]
        val id = relativeParts[2]
        val namespaceSource = when {
            top == "demo_v1" && namespace == "observation_v1" -> "jw"
            top == "demo_v1" && namespace == "young_observation_v1" -> "young"
            top == "local_v1" && namespace == "jw_partitions_v1" -> "jw"
            top == "local_v1" && namespace == "young_partitions_v1" -> "young"
            else -> null
        }
        require(namespaceSource == source) { "Profile source does not match namespace" }
        val validId = when (namespace) {
            "observation_v1", "young_observation_v1" -> OBSERVATION_ID.matches(id)
            "jw_partitions_v1" -> JW_PARTITION_ID.matches(id)
            "young_partitions_v1" -> YOUNG_PARTITION_ID.matches(id)
            else -> false
        }
        require(validId) { "Invalid profile directory id" }

        return Candidate(
            source = source,
            relativePath = parts.joinToString(File.separator),
            ephemeral = top == "demo_v1",
        )
    }

    private fun newRecord(candidate: Candidate, generation: Long): Record {
        require(generation > 0L)
        return Record(
            name = profileName(candidate.source, candidate.relativePath, generation),
            source = candidate.source,
            relativePath = candidate.relativePath,
            generation = generation,
            ephemeral = candidate.ephemeral,
            revoked = false,
            state = State.RETAINED,
        )
    }

    private fun persist(next: List<Record>) {
        require(next.size <= MAX_RECORDS) { "Profile ledger is full" }
        val encoded = encodeLedger(next).toByteArray(StandardCharsets.UTF_8)
        require(encoded.size <= MAX_LEDGER_BYTES) { "Profile ledger is too large" }
        val stream = ledgerFile.startWrite()
        try {
            stream.write(encoded)
            stream.fd.sync()
            ledgerFile.finishWrite(stream)
            records = next
        } catch (failure: Throwable) {
            try {
                ledgerFile.failWrite(stream)
            } catch (_: Throwable) {
                // Preserve the original storage failure. AtomicFile retains its backup.
            }
            throw failure
        }
    }

    private fun encodeLedger(source: List<Record>): String {
        val rows = JSONArray()
        source.sortedWith(compareBy<Record>({ it.relativePath }, { it.generation })).forEach { record ->
            rows.put(JSONObject()
                .put("name", record.name)
                .put("source", record.source)
                .put("path", record.relativePath)
                .put("generation", record.generation)
                .put("ephemeral", record.ephemeral)
                .put("revoked", record.revoked)
                .put("state", record.state.wireName))
        }
        return JSONObject()
            .put("schema", SCHEMA_VERSION)
            .put("entries", rows)
            .toString()
    }

    private fun readLedger(): List<Record> {
        val base = ledgerFile.baseFile
        val backup = File(base.path + ".bak")
        verifyLedgerNode(base)
        verifyLedgerNode(backup)
        if (!base.exists() && !backup.exists()) return emptyList()

        try {
            val bytes = ByteArrayOutputStream()
            ledgerFile.openRead().use { input ->
                val chunk = ByteArray(4096)
                while (true) {
                    val count = input.read(chunk)
                    if (count < 0) break
                    if (bytes.size() + count > MAX_LEDGER_BYTES) {
                        throw IOException("Profile ledger is too large")
                    }
                    bytes.write(chunk, 0, count)
                }
            }
            return decodeLedger(String(bytes.toByteArray(), StandardCharsets.UTF_8))
        } catch (failure: Throwable) {
            throw IllegalStateException("Profile ledger is corrupt or unavailable", failure)
        }
    }

    private fun decodeLedger(raw: String): List<Record> {
        val data = JSONObject(raw)
        requireExactKeys(data, setOf("schema", "entries"))
        require(data.getInt("schema") == SCHEMA_VERSION) { "Unsupported profile ledger schema" }
        val rows = data.getJSONArray("entries")
        require(rows.length() <= MAX_RECORDS) { "Profile ledger is too large" }
        val result = ArrayList<Record>(rows.length())
        val names = HashSet<String>()
        val identities = HashSet<String>()
        for (index in 0 until rows.length()) {
            val row = rows.getJSONObject(index)
            requireExactKeys(
                row,
                setOf("name", "source", "path", "generation", "ephemeral", "revoked", "state"),
            )
            val source = row.getString("source")
            val relative = row.getString("path")
            val generation = row.getLong("generation")
            require(generation > 0L) { "Invalid profile generation" }
            val pathParts = relative.split(File.separatorChar)
            val fixture = pathParts.firstOrNull()?.startsWith(FIXTURE_PREFIX) == true
            val candidate = parseRelativePath(pathParts, source, fixture)
            require(candidate.relativePath == relative) { "Profile path is not normalized" }
            val ephemeral = row.getBoolean("ephemeral")
            require(ephemeral == candidate.ephemeral) { "Profile lifetime metadata is inconsistent" }
            val name = row.getString("name")
            require(name == profileName(source, relative, generation)) { "Profile name is invalid" }
            val revoked = row.getBoolean("revoked")
            val state = State.values().firstOrNull { it.wireName == row.getString("state") }
                ?: throw IllegalArgumentException("Invalid profile state")
            require(state == State.RETAINED || revoked) { "Unrevoked profile has a cleanup state" }
            require(names.add(name)) { "Duplicate profile name" }
            require(identities.add("$source\u0000$relative\u0000$generation")) {
                "Duplicate profile generation"
            }
            result.add(Record(name, source, relative, generation, ephemeral, revoked, state))
        }

        val groups = result.groupBy { it.source to it.relativePath }
        groups.values.forEach { group ->
            val ordered = group.sortedBy { it.generation }
            require(ordered.map { it.generation } == (1L..ordered.size.toLong()).toList()) {
                "Profile generations are incomplete"
            }
            require(ordered.dropLast(1).all { it.state == State.DELETED }) {
                "Older profile generation is still live"
            }
        }
        return result
    }

    private fun requireExactKeys(data: JSONObject, expected: Set<String>) {
        val actual = data.keys().asSequence().toSet()
        require(actual == expected) { "Unexpected profile ledger fields" }
    }

    private fun profileName(source: String, relativePath: String, generation: Long): String {
        // Generation one is SHA-256(source + canonical relative path). Later generations
        // use the same identity plus a domain-separated generation suffix after deletion.
        val input = if (generation == 1L) {
            source + relativePath
        } else {
            source + relativePath + "\u0000generation=$generation"
        }
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(input.toByteArray(StandardCharsets.UTF_8))
        return digest.joinToString(separator = "") { byte -> "%02x".format(byte.toInt() and 0xff) }
    }

    private fun verifyLedgerNode(file: File) {
        val stat = statOrNull(file) ?: return
        require((stat.st_mode and OsConstants.S_IFMT) == OsConstants.S_IFREG) {
            "Profile ledger contains a non-file node"
        }
    }

    private fun ensureDirectoryChain(path: File, createMissing: Boolean) {
        val absolute = path.absoluteFile.path
        require(absolute.startsWith(File.separator)) { "Directory path must be absolute" }
        val components = absolute.split(File.separatorChar).drop(1)
        require(components.all { it.isNotEmpty() && it != "." && it != ".." }) {
            "Directory path is not normalized"
        }
        var current = File(File.separator)
        for (component in components) {
            current = File(current, component)
            var stat = statOrNull(current)
            if (stat == null) {
                require(createMissing && current.mkdir()) { "Required directory is missing" }
                stat = statOrNull(current)
            }
            require(stat != null && (stat.st_mode and OsConstants.S_IFMT) == OsConstants.S_IFDIR) {
                "Directory path contains a link or non-directory"
            }
        }
    }

    private fun statOrNull(file: File): android.system.StructStat? = try {
        Os.lstat(file.absolutePath)
    } catch (failure: ErrnoException) {
        if (failure.errno == OsConstants.ENOENT) null else throw IOException("Filesystem check failed", failure)
    }

    private companion object {
        const val SCHEMA_VERSION = 1
        const val LEDGER_FILE_NAME = "profile-ledger.json"
        const val MAX_RECORDS = 4096
        const val MAX_LEDGER_BYTES = 1024 * 1024
        const val FIXTURE_PREFIX = "a2_fixture_"
        val FIXTURE_ROOT = Regex("^a2_fixture_[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
        val OBSERVATION_ID = Regex("^obs-[0-9a-f]{32}$")
        val JW_PARTITION_ID = Regex("^jwp-[0-9a-f]{32}$")
        val YOUNG_PARTITION_ID = Regex("^yp-[0-9a-f]{32}$")
    }
}
