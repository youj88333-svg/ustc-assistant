package cn.ustcassistant.mobile.qa

import android.content.Context
import android.content.ContextWrapper
import android.system.Os
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import cn.ustcassistant.mobile.browser.SchoolHostSlot
import cn.ustcassistant.mobile.browser.SchoolPartitionLedger
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.nio.charset.StandardCharsets
import java.util.UUID

/** Synthetic lifecycle checks with a per-test Context and browser-data root. */
@RunWith(AndroidJUnit4::class)
class OrdinaryPartitionLedgerTest {
    @Test
    fun lowSpaceAndPendingBudgetRejectNewStoresButStillPermitRecovery() = withIsolatedContext { context, _ ->
        var free = 1024L * 1024 * 1024
        val ledger = SchoolPartitionLedger(context) { free }
        val firstPath = createFixture(context, safeId(), "jw", "a")
        val first = ledger.claim(firstPath.path, "jw", true, false)
        free = 128L * 1024 * 1024
        try { ledger.ensureCreationBudget(); throw AssertionError("Low-space preflight should reject") }
        catch (_: SchoolPartitionLedger.CapacityExceeded) { }
        assertEquals(first, ledger.claim(firstPath.path, "jw", true, false))
        val unknownPath = createFixture(context, safeId(), "young", "b")
        try { ledger.claim(unknownPath.path, "young", true, false); throw AssertionError("New store should reject") }
        catch (_: SchoolPartitionLedger.CapacityExceeded) { }
        val recovery = ledger.claim(unknownPath.path, "young", true, true)
        assertTrue(ledger.cleanup(recovery))
        assertEquals("retained", stateFor(context, first.suffix))
        free = 1024L * 1024 * 1024
        ledger.revoke(first)
        repeat(15) {
            val path = createFixture(context, safeId(), "jw", "c")
            ledger.revoke(ledger.claim(path.path, "jw", true, false))
        }
        assertEquals(16, ledger.status()["count"])
        try { ledger.ensureCreationBudget(); throw AssertionError("Pending budget should reject") }
        catch (_: SchoolPartitionLedger.CapacityExceeded) { }
        assertEquals(0, ledger.cleanupRetired()["count"])
        ledger.ensureCreationBudget()
        assertEquals(false, ledger.status()["pending"])
    }

    @Test
    fun privateFixtureClaimsUseDistinctRandomSourceSuffixes() = withIsolatedContext { context, _ ->
        val fixtureId = safeId()
        val jwPath = createFixture(context, fixtureId, "jw", "1")
        val youngPath = createFixture(context, fixtureId, "young", "2")
        val ledger = SchoolPartitionLedger(context)

        val jw = ledger.claim(jwPath.path, "jw", fixture = true, recovery = false)
        val young = ledger.claim(youngPath.path, "young", fixture = true, recovery = false)

        assertTrue(jw.suffix.matches(Regex("ustc_[0-9a-f]{32}")))
        assertTrue(young.suffix.matches(Regex("ustc_[0-9a-f]{32}")))
        assertNotEquals(jw.suffix, young.suffix)
        assertFalse(ledger.dataPath(jw).exists())
        assertFalse(ledger.dataPath(young).exists())
        assertEquals(jw.suffix, SchoolPartitionLedger(context)
            .claim(jwPath.path, "jw", fixture = true, recovery = false).suffix)

        val persisted = ledgerFile(context).readText(StandardCharsets.UTF_8)
        assertFalse(persisted.contains(fixtureId))
        assertFalse(persisted.contains(jwPath.path))
        assertFalse(persisted.contains(youngPath.path))
    }

    @Test
    fun recoveryRevokesOldSuffixAndLeavesItPendingWhileNewClaimGetsNewSuffix() =
        withIsolatedContext { context, _ ->
            val path = createFixture(context, safeId(), "young", "3")
            val firstLedger = SchoolPartitionLedger(context)
            val old = firstLedger.claim(path.path, "young", fixture = true, recovery = false)

            val recoveryLedger = SchoolPartitionLedger(context)
            val recovery = recoveryLedger.claim(path.path, "young", fixture = true, recovery = true)
            assertEquals(old.suffix, recovery.suffix)
            assertEquals("revoked", stateFor(context, old.suffix))
            assertTrue(recoveryLedger.status()["pending"] == true)

            val nextLedger = SchoolPartitionLedger(context)
            val next = nextLedger.claim(path.path, "young", fixture = true, recovery = false)
            assertNotEquals(old.suffix, next.suffix)
            assertEquals("revoked", stateFor(context, old.suffix))
            assertEquals("retained", stateFor(context, next.suffix))
            assertTrue(nextLedger.status()["pending"] == true)
        }

    @Test
    fun unstartedPartitionWithoutFilesCanBeReclaimed() = withIsolatedContext { context, _ ->
        val path = createFixture(context, safeId(), "jw", "4")
        val ledger = SchoolPartitionLedger(context)
        val entry = ledger.claim(path.path, "jw", fixture = true, recovery = false)
        ledger.revoke(entry)

        assertFalse(ledger.dataPath(entry).exists())
        assertFalse(cachePath(context, entry).exists())
        assertTrue(ledger.cleanup(entry))
        assertEquals("deleted", stateFor(context, entry.suffix))
        assertEquals(false, ledger.status()["pending"])
    }

    @Test
    fun startedPartitionWithUnknownLayoutIsQuarantinedWithoutDeletingData() =
        withIsolatedContext { context, _ ->
            val path = createFixture(context, safeId(), "young", "5")
            val ledger = SchoolPartitionLedger(context)
            val entry = ledger.claim(path.path, "young", fixture = true, recovery = false)
            ledger.started(entry)
            val data = ledger.dataPath(entry)
            assertTrue(data.mkdirs())
            val marker = File(data, "synthetic-layout-marker.bin")
            val markerBytes = byteArrayOf(9, 3, 1, 7)
            marker.writeBytes(markerBytes)
            ledger.layoutObserved(entry, expectedDirectoryExists = false)
            ledger.revoke(entry)

            assertFalse(ledger.cleanup(entry))
            assertEquals("quarantined", stateFor(context, entry.suffix))
            assertTrue(ledger.status()["pending"] == true)
            assertTrue(data.isDirectory)
            assertArrayEquals(markerBytes, marker.readBytes())
        }

    @Test
    fun knownLayoutCleanupIsScopedAndPreservesOtherSourceAndSyntheticC3Sentinels() =
        withIsolatedContext { context, _ ->
            val fixtureId = safeId()
            val ledger = SchoolPartitionLedger(context)
            val jw = ledger.claim(
                createFixture(context, fixtureId, "jw", "6").path,
                "jw", fixture = true, recovery = false,
            )
            val young = ledger.claim(
                createFixture(context, fixtureId, "young", "7").path,
                "young", fixture = true, recovery = false,
            )
            ledger.started(jw)
            ledger.started(young)

            val jwData = ledger.dataPath(jw)
            val jwCache = cachePath(context, jw)
            val youngData = ledger.dataPath(young)
            val youngCache = cachePath(context, young)
            assertTrue(jwData.mkdirs())
            assertTrue(jwCache.mkdirs())
            assertTrue(youngData.mkdirs())
            assertTrue(youngCache.mkdirs())
            File(jwData, "synthetic-browser-marker.bin").writeBytes(byteArrayOf(1, 2, 3))
            val otherSourceMarker = File(youngData, "synthetic-browser-marker.bin")
            otherSourceMarker.writeBytes(byteArrayOf(4, 5, 6))

            val c3Root = File(context.dataDir, "synthetic_c3").apply { assertTrue(mkdirs()) }
            val c3Sentinel = File(c3Root, "synthetic-password-sentinel.bin")
            val syntheticPasswordSentinel = "QA_ONLY_SYNTHETIC_PASSWORD_SENTINEL".toByteArray(StandardCharsets.UTF_8)
            c3Sentinel.writeBytes(syntheticPasswordSentinel)
            val c3DatabaseSentinel = File(c3Root, "synthetic-c3-database-marker.bin")
            c3DatabaseSentinel.writeBytes(byteArrayOf(8, 8, 2))

            ledger.layoutObserved(jw, expectedDirectoryExists = true)
            ledger.revoke(jw)
            assertTrue(ledger.cleanup(jw))

            assertFalse(jwData.exists())
            assertFalse(jwCache.exists())
            assertTrue(youngData.isDirectory)
            assertTrue(youngCache.isDirectory)
            assertArrayEquals(byteArrayOf(4, 5, 6), otherSourceMarker.readBytes())
            assertArrayEquals(syntheticPasswordSentinel, c3Sentinel.readBytes())
            assertArrayEquals(byteArrayOf(8, 8, 2), c3DatabaseSentinel.readBytes())
            assertEquals("retained", stateFor(context, young.suffix))
            assertFalse(ledgerFile(context).readText(StandardCharsets.UTF_8)
                .contains(String(syntheticPasswordSentinel, StandardCharsets.UTF_8)))
        }

    @Test
    fun rejectsTraversalSymlinkOutsideRootAndCorruptLedger() = withIsolatedContext { context, sandbox ->
        val fixtureId = safeId()
        val valid = createFixture(context, fixtureId, "jw", "8")
        val ledger = SchoolPartitionLedger(context)
        ledger.claim(valid.path, "jw", fixture = true, recovery = false)

        expectRejected {
            ledger.claim(File(valid.parentFile, "../" + valid.name).path, "jw", true, false)
        }
        val outside = File(sandbox, "outside-root/local_v1/jw_partitions_v1/jwp-${safeId()}")
        assertTrue(outside.mkdirs())
        expectRejected { ledger.claim(outside.path, "jw", fixture = true, recovery = false) }

        val base = File(context.noBackupFilesDir, "ustc_assistant_v1")
        val linkRoot = File(base, "a2_fixture_${safeId()}")
        assertTrue(linkRoot.mkdirs())
        val linkTarget = File(sandbox, "symlink-target").apply { assertTrue(mkdirs()) }
        val link = File(linkRoot, "local_v1")
        Os.symlink(linkTarget.absolutePath, link.absolutePath)
        val symlinkPath = File(link, "jw_partitions_v1/jwp-${safeId()}")
        expectRejected { ledger.claim(symlinkPath.path, "jw", fixture = true, recovery = false) }

        val metadata = ledgerFile(context)
        val corrupt = "{not-json".toByteArray(StandardCharsets.UTF_8)
        metadata.writeBytes(corrupt)
        var rejected = false
        try {
            SchoolPartitionLedger(context)
        } catch (_: Exception) {
            rejected = true
        }
        assertTrue("A corrupt ledger must fail closed.", rejected)
        assertArrayEquals(corrupt, metadata.readBytes())
        assertTrue(valid.isDirectory)
    }

    @Test
    fun lostLedgerRetainsOrphanCleanupUntilTheActualStoreIsRemoved() = withIsolatedContext { context, _ ->
        val path = createFixture(context, safeId(), "jw", "9")
        val ledger = SchoolPartitionLedger(context)
        val old = ledger.claim(path.path, "jw", fixture = true, recovery = false)
        ledger.started(old)
        val oldData = ledger.dataPath(old).apply { assertTrue(mkdirs()) }
        val marker = File(oldData, "synthetic-orphan-marker").apply { writeText("QA_ONLY") }
        assertTrue(ledgerFile(context).delete())
        File(ledgerFile(context).path + ".bak").delete()

        val recovered = SchoolPartitionLedger(context)
        assertTrue(recovered.status()["pending"] == true)
        assertFalse(recovered.isCurrentBackend(path.path, "jw", fixture = true))
        val handoff = recovered.claim(path.path, "jw", fixture = true, recovery = true)
        recovered.quarantine(handoff)
        assertTrue(recovered.cleanup(handoff))
        assertTrue("An empty placeholder cannot erase the lost physical store's pending status",
            recovered.status()["pending"] == true)
        assertTrue(marker.isFile)
        assertFalse(recovered.cleanupRetired()["pending"] == true)
        assertFalse(oldData.exists())
    }

    @Test
    fun unknownLegacyLayoutCannotBeClearedByMissingGuessedPaths() = withIsolatedContext { context, _ ->
        val oldMetadata = File(context.noBackupFilesDir, "ustc_assistant_v1/platform_webview_v1")
        assertTrue(oldMetadata.mkdirs())
        val marker = File(oldMetadata, "synthetic-legacy-lifecycle").apply { writeText("QA_ONLY") }
        val ledger = SchoolPartitionLedger(context)
        assertTrue(ledger.status()["pending"] == true)
        assertTrue(ledger.cleanupRetired()["pending"] == true)
        assertTrue(marker.isFile)
    }

    private inline fun <T> withIsolatedContext(block: (Context, File) -> T): T {
        val target = InstrumentationRegistry.getInstrumentation().targetContext
        assertEquals("cn.ustcassistant.mobile.qa", target.packageName)
        assertTrue(target.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0)
        val sandbox = File(target.noBackupFilesDir.canonicalFile, "ordinary-webview-test-" + safeId())
        assertTrue(sandbox.mkdir())
        val noBackup = File(sandbox, "no-backup").apply { assertTrue(mkdirs()) }
        val data = File(sandbox, "data").apply { assertTrue(mkdirs()) }
        val cache = File(sandbox, "cache").apply { assertTrue(mkdirs()) }
        val context = object : ContextWrapper(target) {
            override fun getNoBackupFilesDir(): File = noBackup
            override fun getDataDir(): File = data
            override fun getCacheDir(): File = cache
        }
        return try {
            block(context, sandbox)
        } finally {
            assertTrue("isolated synthetic test root cleanup failed", sandbox.deleteRecursively())
        }
    }

    private fun createFixture(context: Context, fixtureId: String, source: String, idSuffix: String): File {
        val namespace: String
        val idPrefix: String
        if (source == "jw") {
            namespace = "jw_partitions_v1"
            idPrefix = "jwp-"
        } else {
            namespace = "young_partitions_v1"
            idPrefix = "yp-"
        }
        val path = File(
            File(context.noBackupFilesDir, "ustc_assistant_v1"),
            "a2_fixture_" + fixtureId + "/local_v1/" + namespace + "/" + idPrefix + idSuffix.repeat(32),
        )
        assertTrue("could not create the private QA fixture placeholder", path.mkdirs())
        return path
    }

    private fun ledgerFile(context: Context): File =
        File(SchoolHostSlot.root(context), "partitions.json")

    private fun cachePath(context: Context, entry: SchoolPartitionLedger.Entry): File =
        File(context.cacheDir, "webview_" + entry.suffix)

    private fun stateFor(context: Context, suffix: String): String {
        val entries = JSONObject(ledgerFile(context).readText(StandardCharsets.UTF_8))
            .getJSONArray("entries")
        return (0 until entries.length())
            .map { entries.getJSONObject(it) }
            .single { it.getString("suffix") == suffix }
            .getString("state")
    }

    private fun safeId(): String = UUID.randomUUID().toString().replace("-", "")

    private fun expectRejected(block: () -> Unit) {
        try {
            block()
        } catch (_: IllegalArgumentException) {
            return
        }
        throw AssertionError("Expected the partition path to be rejected")
    }
}
