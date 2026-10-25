package cn.ustcassistant.mobile.browser

import android.content.Context
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.security.SecureRandom

/** Lifecycle metadata only. Never opens a browser database, cookie, storage value or C3 database. */
internal class SchoolPartitionLedger(private val context: Context,
    private val availableBytes: () -> Long = { context.dataDir.usableSpace }) {
    class CapacityExceeded : IllegalStateException()
    data class Entry(val key: String, val suffix: String, val ephemeral: Boolean)
    private data class Record(
        val key: String, val suffix: String, val source: String, val ephemeral: Boolean,
        val state: String, val started: Boolean, val layout: Boolean,
        val providerName: String? = null, val providerVersion: String? = null,
    ) { fun entry() = Entry(key, suffix, ephemeral) }
    private val root = SchoolHostSlot.root(context)
    private val file = AtomicFile(File(root, "partitions.json"))
    private val appData = context.dataDir.canonicalFile
    private val appCache = context.cacheDir.canonicalFile
    private var legacyPending = false
    private var legacyRetired = false
    private var records = emptyList<Record>()
    private var orphans = emptySet<String>()

    init {
        for (node in listOf(file.baseFile, File(file.baseFile.path + ".bak"))) checkRegularOrMissing(node)
        if (file.baseFile.exists() || File(file.baseFile.path + ".bak").exists()) {
            val bytes = file.openRead().use { input -> input.readBytesBounded(1024 * 1024) }
            val value = JSONObject(String(bytes, Charsets.UTF_8))
            val fields = value.keys().asSequence().toSet()
            require(fields == setOf("schema", "legacyRetired", "legacyPending", "entries") ||
                fields == setOf("schema", "legacyRetired", "legacyPending", "entries", "orphans"))
            require(value.getInt("schema") == 1)
            legacyRetired = value.getBoolean("legacyRetired")
            legacyPending = value.getBoolean("legacyPending")
            require(!legacyPending || legacyRetired)
            val entries = value.getJSONArray("entries")
            require(entries.length() <= 2048)
            val keys = hashSetOf<String>()
            records = (0 until entries.length()).map { index ->
                val row = entries.getJSONObject(index)
                val rowFields = row.keys().asSequence().toSet()
                val baseFields = setOf("key", "suffix", "source", "ephemeral", "state", "started", "layout")
                require(rowFields == baseFields || rowFields == baseFields + setOf("providerName", "providerVersion"))
                val record = Record(row.getString("key"), row.getString("suffix"), row.getString("source"),
                    row.getBoolean("ephemeral"), row.getString("state"), row.getBoolean("started"), row.getBoolean("layout"),
                    if (row.isNull("providerName")) null else row.getString("providerName"),
                    if (row.isNull("providerVersion")) null else row.getString("providerVersion"))
                require(KEY.matches(record.key) && SUFFIX.matches(record.suffix) && keys.add(record.suffix))
                require(record.source in setOf("jw", "young") && record.state in STATES)
                require(!record.layout || record.started)
                validateProvider(record.providerName, record.providerVersion)
                record
            }
            require(records.groupBy { it.key }.values.all { group ->
                group.count { it.state == "retained" } <= 1 &&
                    group.map { it.source to it.ephemeral }.distinct().size == 1
            })
            val lost = value.optJSONArray("orphans") ?: JSONArray()
            require(lost.length() <= 2048)
            orphans = (0 until lost.length()).map { lost.getString(it).also { suffix -> require(SUFFIX.matches(suffix)) } }.toSet()
            require(orphans.size == lost.length())
            require(records.size + orphans.size <= 2048)
        }
        if (!legacyRetired) {
            // This backend can never open the old default WebView store. Its tombstone
            // survives even when the old native ledger is missing or corrupt.
            val pending = File(appData, "app_webview").exists() ||
                File(appCache, "WebView").exists() ||
                File(context.noBackupFilesDir, "ustc_assistant_v1/platform_webview_v1").exists()
            persist(records, true, pending)
        }
        // Recover names only, never browser contents. Losing the lifecycle file
        // must not make existing suffix stores disappear from cleanup status.
        val known = records.filter { it.state != "deleted" }.map { it.suffix }.toSet()
        val discovered = linkedSetOf<String>()
        for ((parent, prefix) in listOf(appData to "app_webview_", appCache to "webview_")) {
            val names = parent.list() ?: throw IllegalStateException("Cannot inspect browser directory ownership")
            for (name in names) {
                if (name.startsWith(prefix)) {
                    val suffix = name.removePrefix(prefix)
                    if (SUFFIX.matches(suffix) && suffix !in known) discovered.add(suffix)
                }
            }
        }
        val missing = orphans + discovered
        if (missing != orphans) persist(records, orphaned = missing)
    }

    @Synchronized fun claim(path: String, source: String, fixture: Boolean, recovery: Boolean): Entry {
        val relative = validatePath(path, source, fixture)
        val key = MessageDigest.getInstance("SHA-256").digest((source + "\u0000" + relative).toByteArray())
            .joinToString("") { "%02x".format(it.toInt() and 255) }
        val existing = records.lastOrNull { it.key == key }
        if (existing != null && existing.state == "retained") {
            if (recovery) revoke(existing.entry())
            return existing.entry()
        }
        if (recovery && existing != null) return existing.entry()
        if (!recovery) ensureCreationBudget()
        if (records.size + orphans.size >= 2048) throw CapacityExceeded()
        val suffix = "ustc_" + ByteArray(16).also { SecureRandom().nextBytes(it) }
            .joinToString("") { "%02x".format(it.toInt() and 255) }
        check(records.none { it.suffix == suffix })
        val row = Record(key, suffix, source, relative.contains("/demo_v1/") || relative.startsWith("demo_v1/") ||
            relative.contains("/observation_v1/") || relative.contains("/young_observation_v1/"),
            if (recovery) "revoked" else "retained", false, false)
        persist(records + row)
        return row.entry()
    }

    @Synchronized fun started(entry: Entry) = update(entry) { row ->
        check(row.state == "retained"); row.copy(started = true)
    }
    @Synchronized fun ensureCreationBudget() {
        if (records.count { it.state == "quarantined" || it.state == "revoked" } + orphans.size >= 16 ||
            records.size + orphans.size >= 2048 || availableBytes() < 256L * 1024 * 1024) throw CapacityExceeded()
    }
    @Synchronized fun layoutObserved(entry: Entry, expectedDirectoryExists: Boolean,
        providerName: String? = null, providerVersion: String? = null) = update(entry) { row ->
        validateProvider(providerName, providerVersion)
        // Supported platform/Chromium layout is independently covered by the QA
        // canary tests. An unexpected layout remains an explicit physical-cleanup pending.
        row.copy(layout = row.layout || (expectedDirectoryExists && dataPath(entry).isDirectory),
            providerName = providerName ?: row.providerName, providerVersion = providerVersion ?: row.providerVersion)
    }
    @Synchronized fun retained(entry: Entry) = update(entry) { row -> check(row.state == "retained"); row }
    @Synchronized fun revoke(entry: Entry) = update(entry) { row ->
        if (row.state == "deleted") row else row.copy(state = "revoked")
    }
    @Synchronized fun quarantine(entry: Entry) = update(entry) { row ->
        check(row.state != "retained"); if (row.state == "deleted") row else row.copy(state = "quarantined")
    }

    /** Caller has already confirmed the host slot and old browser execution are stopped. */
    @Synchronized fun cleanup(entry: Entry): Boolean {
        val row = requireEntry(entry)
        if (row.state == "deleted") return true
        check(row.state == "revoked" || row.state == "quarantined")
        if (row.started && !row.layout) { quarantine(entry); return false }
        return try {
            val data = dataPath(entry)
            val cache = cachePath(entry)
            deleteOwnedTree(data, appData)
            deleteOwnedTree(cache, appCache)
            check(!data.exists() && !cache.exists())
            update(entry) { it.copy(state = "deleted") }
            true
        } catch (_: Exception) { quarantine(entry); false }
    }

    @Synchronized fun cleanupRetired(): Map<String, Any> {
        check(SchoolHostSlot.available(context))
        records.filter { it.state == "revoked" || it.state == "quarantined" }.map { it.entry() }.forEach { cleanup(it) }
        for (suffix in orphans.toList()) {
            try {
                // An orphan's named application-owned trees are known, but no
                // C3 placeholder/permit is recreated to gain access to them.
                deleteOwnedTree(File(appData, "app_webview_$suffix"), appData)
                deleteOwnedTree(File(appCache, "webview_$suffix"), appCache)
                persist(records, orphaned = orphans - suffix)
            } catch (_: Exception) { /* Persisted orphan remains visible. */ }
        }
        // Legacy Profile metadata did not record a provider/layout proof. Two
        // absent guessed paths are not proof that all its assets were cleared.
        // Keep this retired backend pending until a separately verified legacy
        // cleanup can cover it; it never blocks an independently isolated suffix.
        return status()
    }

    @Synchronized fun status(): Map<String, Any> {
        val pending = records.count { it.state == "revoked" || it.state == "quarantined" } +
            orphans.size + if (legacyPending) 1 else 0
        return mapOf("backend" to "system-directory-v1", "pending" to (pending != 0), "count" to pending)
    }

    @Synchronized fun isCurrentBackend(path: String, source: String, fixture: Boolean): Boolean {
        val relative = validatePath(path, source, fixture, requireExists = false)
        val key = MessageDigest.getInstance("SHA-256").digest((source + "\u0000" + relative).toByteArray())
            .joinToString("") { "%02x".format(it.toInt() and 255) }
        return records.lastOrNull { it.key == key }?.state == "retained"
    }

    fun dataPath(entry: Entry) = File(appData, "app_webview_${entry.suffix}")
    private fun cachePath(entry: Entry) = File(appCache, "webview_${entry.suffix}")

    private fun requireEntry(entry: Entry): Record = records.single { it.suffix == entry.suffix }.also {
        require(it.key == entry.key && it.ephemeral == entry.ephemeral)
    }
    private fun update(entry: Entry, change: (Record) -> Record) {
        val current = requireEntry(entry)
        val replacement = change(current)
        persist(records.map { if (it.suffix == current.suffix) replacement else it })
    }
    private fun persist(next: List<Record>, retired: Boolean = legacyRetired, pending: Boolean = legacyPending,
        orphaned: Set<String> = orphans) {
        check(next.size + orphaned.size <= 2048)
        val entries = JSONArray()
        for (row in next) entries.put(JSONObject().put("key", row.key).put("suffix", row.suffix)
            .put("source", row.source).put("ephemeral", row.ephemeral).put("state", row.state)
            .put("started", row.started).put("layout", row.layout)
            .put("providerName", row.providerName ?: JSONObject.NULL)
            .put("providerVersion", row.providerVersion ?: JSONObject.NULL))
        val bytes = JSONObject().put("schema", 1).put("legacyRetired", retired)
            .put("legacyPending", pending).put("entries", entries).put("orphans", JSONArray(orphaned.sorted()))
            .toString().toByteArray(Charsets.UTF_8)
        check(bytes.size <= 1024 * 1024)
        val stream = file.startWrite()
        try {
            stream.write(bytes); stream.fd.sync(); file.finishWrite(stream)
            records = next; legacyRetired = retired; legacyPending = pending; orphans = orphaned
        }
        catch (failure: Exception) { file.failWrite(stream); throw failure }
    }

    private fun validateProvider(name: String?, version: String?) {
        require((name == null) == (version == null))
        if (name != null && version != null) {
            require(name.length in 1..160 && Regex("[A-Za-z0-9_.]+").matches(name))
            require(version.length in 1..128 && Regex("[A-Za-z0-9_.+\\-]+").matches(version))
        }
    }

    private fun validatePath(raw: String, source: String, fixture: Boolean, requireExists: Boolean = true): String {
        require(source == "jw" || source == "young")
        val base = File(context.noBackupFilesDir.canonicalFile, "ustc_assistant_v1")
        require(raw.startsWith(base.path + "/") && raw == File(raw).absolutePath && raw == File(raw).canonicalPath)
        require(raw.none { it == '\u0000' || it == '\\' })
        val relative = raw.substring(base.path.length + 1)
        val parts = relative.split('/')
        require(parts.all { it.isNotEmpty() && it != "." && it != ".." })
        val qa = context.packageName == "cn.ustcassistant.mobile.qa" &&
            (context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
        val offset = if (parts.first().startsWith("a2_fixture_")) {
            require(qa && fixture && Regex("^a2_fixture_[A-Za-z0-9][A-Za-z0-9_-]{0,63}$").matches(parts.first())); 1
        } else { require(!fixture); 0 }
        require(parts.size - offset == 3)
        val namespace = parts[offset + 1]
        val id = parts[offset + 2]
        when (parts[offset] to namespace) {
            "demo_v1" to "observation_v1" -> require(source == "jw" && Regex("obs-[0-9a-f]{32}").matches(id))
            "demo_v1" to "young_observation_v1" -> require(source == "young" && Regex("obs-[0-9a-f]{32}").matches(id))
            "local_v1" to "jw_partitions_v1" -> require(source == "jw" && Regex("jwp-[0-9a-f]{32}").matches(id))
            "local_v1" to "young_partitions_v1" -> require(source == "young" && Regex("yp-[0-9a-f]{32}").matches(id))
            else -> throw IllegalArgumentException("Unknown browser namespace")
        }
        var current = base
        for (part in parts) {
            current = File(current, part)
            try { require((Os.lstat(current.path).st_mode and OsConstants.S_IFMT) == OsConstants.S_IFDIR) }
            catch (failure: ErrnoException) {
                if (!requireExists && failure.errno == OsConstants.ENOENT) return relative
                throw failure
            }
        }
        return relative
    }

    private fun deleteOwnedTree(path: File, parent: File) {
        require(path.parentFile == parent && path != parent)
        require(path.name == "app_webview" || path.name == "WebView" ||
            Regex("(?:app_)?webview_ustc_[0-9a-f]{32}").matches(path.name))
        fun remove(node: File) {
            val stat = try { Os.lstat(node.path) } catch (failure: ErrnoException) {
                if (failure.errno == OsConstants.ENOENT) return else throw failure
            }
            when (stat.st_mode and OsConstants.S_IFMT) {
                OsConstants.S_IFDIR -> {
                    require(node.canonicalFile == node.absoluteFile)
                    val children = node.listFiles() ?: throw IllegalStateException("Cannot enumerate owned browser directory")
                    for (child in children) { require(child.parentFile == node); remove(child) }
                    check(node.delete())
                }
                OsConstants.S_IFREG -> check(node.delete())
                else -> throw IllegalStateException("Unexpected browser filesystem node")
            }
        }
        remove(path)
    }
    private fun checkRegularOrMissing(node: File) {
        try { require((Os.lstat(node.path).st_mode and OsConstants.S_IFMT) == OsConstants.S_IFREG) }
        catch (failure: ErrnoException) { if (failure.errno != OsConstants.ENOENT) throw failure }
    }
    private fun java.io.InputStream.readBytesBounded(limit: Int): ByteArray {
        val output = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            val count = read(buffer); if (count < 0) break
            require(output.size() + count <= limit); output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }
    companion object {
        private val KEY = Regex("[0-9a-f]{64}")
        private val SUFFIX = Regex("ustc_[0-9a-f]{32}")
        private val STATES = setOf("retained", "revoked", "quarantined", "deleted")
    }
}
