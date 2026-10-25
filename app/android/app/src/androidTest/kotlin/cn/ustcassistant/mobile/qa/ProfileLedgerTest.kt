package cn.ustcassistant.mobile.qa

import android.content.Context
import android.content.ContextWrapper
import android.system.Os
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import cn.ustcassistant.mobile.browser.ProfileLedger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.UUID

/** Exercises only synthetic directories and a private, isolated ledger root. */
@RunWith(AndroidJUnit4::class)
class ProfileLedgerTest {
    @Test
    fun validatesNamespacesAndKeepsSyntheticFixtureNamesAccountFree() = withIsolatedContext { context, sandbox ->
        val root = File(sandbox, "ustc_assistant_v1")
        val jwObservation = createProfile(root, "demo_v1/observation_v1/obs-${"1".repeat(32)}")
        val youngObservation = createProfile(root, "demo_v1/young_observation_v1/obs-${"2".repeat(32)}")
        val jwPartition = createProfile(root, "local_v1/jw_partitions_v1/jwp-${"3".repeat(32)}")
        val youngPartition = createProfile(root, "local_v1/young_partitions_v1/yp-${"4".repeat(32)}")
        val fixturePartition = createProfile(
            root,
            "a2_fixture_${safeId()}/local_v1/young_partitions_v1/yp-${"5".repeat(32)}",
        )
        val fixtureObservation = createProfile(
            root,
            "a2_fixture_${safeId()}/demo_v1/observation_v1/obs-${"6".repeat(32)}",
        )
        val ledger = ProfileLedger(context)

        val jwDemo = ledger.claim(jwObservation.path, "jw", fixture = false, recoveryOnly = false)
        val youngDemo = ledger.claim(youngObservation.path, "young", fixture = false, recoveryOnly = false)
        val jwLocal = ledger.claim(jwPartition.path, "jw", fixture = false, recoveryOnly = false)
        val youngLocal = ledger.claim(youngPartition.path, "young", fixture = false, recoveryOnly = false)
        val qaFixture = ledger.claim(fixturePartition.path, "young", fixture = true, recoveryOnly = false)
        val qaObservation = ledger.claim(fixtureObservation.path, "jw", fixture = true, recoveryOnly = false)

        assertTrue(jwDemo.ephemeral)
        assertTrue(youngDemo.ephemeral)
        assertFalse(jwLocal.ephemeral)
        assertFalse(youngLocal.ephemeral)
        assertFalse(qaFixture.ephemeral)
        assertTrue(qaObservation.ephemeral)
        assertEquals(
            sha256("jw" + "demo_v1/observation_v1/obs-${"1".repeat(32)}"),
            jwDemo.name,
        )
        assertTrue(jwDemo.name.matches(Regex("^[0-9a-f]{64}$")))
        assertFalse(jwDemo.name.contains("account", ignoreCase = true))

        assertRejected {
            ledger.claim(jwObservation.path, "young", fixture = false, recoveryOnly = false)
        }
        assertRejected {
            ledger.claim(fixturePartition.path, "young", fixture = false, recoveryOnly = false)
        }
    }

    @Test
    fun revocationClearColdDeleteAndReclaimUseANewGeneration() = withIsolatedContext { context, sandbox ->
        val relative = "demo_v1/observation_v1/obs-${"a".repeat(32)}"
        val profile = createProfile(File(sandbox, "ustc_assistant_v1"), relative)
        val ledger = ProfileLedger(context)
        val initial = ledger.claim(profile.path, "jw", fixture = false, recoveryOnly = false)
        ledger.retained(initial)

        val reloaded = ProfileLedger(context)
        assertEquals(initial.name, reloaded.claim(profile.path, "jw", false, false).name)
        reloaded.revoke(initial)
        assertIllegalState {
            reloaded.claim(profile.path, "jw", fixture = false, recoveryOnly = false)
        }

        val recovery = ProfileLedger(context).claim(
            profile.path,
            "jw",
            fixture = false,
            recoveryOnly = true,
        )
        assertTrue(recovery.revoked)
        assertEquals(initial.name, recovery.name)
        assertIllegalState {
            ProfileLedger(context).claim(profile.path, "jw", fixture = false, recoveryOnly = false)
        }
        val cleanup = ProfileLedger(context)
        cleanup.cleared(recovery)
        assertEquals(listOf(recovery), cleanup.pendingColdDelete())
        val clearedRecovery = ProfileLedger(context).claim(profile.path, "jw", false, true)
        assertEquals(recovery.name, clearedRecovery.name)
        assertTrue(ProfileLedger(context).wasCleared(clearedRecovery))
        assertIllegalState { cleanup.claim(profile.path, "jw", false, false) }
        assertIllegalState { cleanup.retained(recovery) }

        cleanup.deleted(recovery)
        assertTrue(cleanup.pendingColdDelete().isEmpty())
        val deletedRecovery = ProfileLedger(context).claim(profile.path, "jw", false, true)
        assertEquals(recovery.name, deletedRecovery.name)
        assertTrue(ProfileLedger(context).wasCleared(deletedRecovery))
        val nextGeneration = ProfileLedger(context).claim(
            profile.path,
            "jw",
            fixture = false,
            recoveryOnly = false,
        )
        assertNotEquals(initial.name, nextGeneration.name)
        assertFalse(nextGeneration.revoked)

        val recoveryOnlyProfile = createProfile(
            File(sandbox, "ustc_assistant_v1"),
            "local_v1/jw_partitions_v1/jwp-${"f".repeat(32)}",
        )
        ProfileLedger(context).claim(
            recoveryOnlyProfile.path,
            "jw",
            fixture = false,
            recoveryOnly = false,
        )
        val recoveryOnlyEntry = ProfileLedger(context).claim(
            recoveryOnlyProfile.path,
            "jw",
            fixture = false,
            recoveryOnly = true,
        )
        assertTrue(recoveryOnlyEntry.revoked)
        assertIllegalState {
            ProfileLedger(context).claim(
                recoveryOnlyProfile.path,
                "jw",
                fixture = false,
                recoveryOnly = false,
            )
        }

        val recoveryCandidate = createProfile(
            File(sandbox, "ustc_assistant_v1"),
            "local_v1/young_partitions_v1/yp-${"9".repeat(32)}",
        )
        val unknownRecovery = ProfileLedger(context).claim(
            recoveryCandidate.path,
            "young",
            fixture = false,
            recoveryOnly = true,
        )
        assertTrue(unknownRecovery.revoked)
        assertFalse(ProfileLedger(context).wasCleared(unknownRecovery))
        assertIllegalState {
            ProfileLedger(context).claim(
                recoveryCandidate.path,
                "young",
                fixture = false,
                recoveryOnly = false,
            )
        }
    }

    @Test
    fun rejectsAliasesSymlinkAncestorsAndDoesNotAdoptUnknownProfiles() = withIsolatedContext { context, sandbox ->
        val root = File(sandbox, "ustc_assistant_v1")
        val profile = createProfile(root, "local_v1/jw_partitions_v1/jwp-${"b".repeat(32)}")
        val ledger = ProfileLedger(context)

        assertRejected {
            ledger.claim(
                File(profile.parentFile, "unused/../${profile.name}").path,
                "jw",
                fixture = false,
                recoveryOnly = false,
            )
        }
        assertRejected {
            ledger.claim(profile.path, "young", fixture = false, recoveryOnly = false)
        }

        val fixtureRoot = File(root, "a2_fixture_${safeId()}")
        assertTrue(fixtureRoot.mkdirs())
        val target = File(sandbox, "symlink-target")
        assertTrue(target.mkdir())
        val link = File(fixtureRoot, "demo_v1")
        Os.symlink(target.absolutePath, link.absolutePath)
        assertRejected {
            ledger.claim(
                File(link, "observation_v1/obs-${"c".repeat(32)}").path,
                "jw",
                fixture = true,
                recoveryOnly = false,
            )
        }

        val unknown = createProfile(root, "demo_v1/observation_v1/obs-${"d".repeat(32)}")
        assertTrue(ledger.pendingColdDelete().isEmpty())
        assertTrue(unknown.isDirectory)
    }

    @Test
    fun refusesToRebuildACorruptLedger() = withIsolatedContext { context, sandbox ->
        val profile = createProfile(
            File(sandbox, "ustc_assistant_v1"),
            "local_v1/young_partitions_v1/yp-${"e".repeat(32)}",
        )
        ProfileLedger(context).claim(profile.path, "young", fixture = false, recoveryOnly = false)
        val ledgerPath = File(
            File(sandbox, "ustc_assistant_v1/platform_webview_v1"),
            "profile-ledger.json",
        )
        ledgerPath.writeText("{broken", StandardCharsets.UTF_8)

        assertIllegalState { ProfileLedger(context) }
        assertTrue(profile.isDirectory)
        assertEquals("{broken", ledgerPath.readText(StandardCharsets.UTF_8))
    }

    private inline fun <T> withIsolatedContext(block: (Context, File) -> T): T {
        val target = InstrumentationRegistry.getInstrumentation().targetContext
        assertEquals("cn.ustcassistant.mobile.qa", target.packageName)
        val sandbox = File(target.noBackupFilesDir.canonicalFile, "profile-ledger-test-${safeId()}")
        assertTrue(sandbox.mkdir())
        val context = object : ContextWrapper(target) {
            override fun getNoBackupFilesDir(): File = sandbox
        }
        return try {
            block(context, sandbox)
        } finally {
            assertTrue("synthetic test tree cleanup failed", sandbox.deleteRecursively())
        }
    }

    private fun createProfile(root: File, relative: String): File {
        val profile = File(root, relative)
        assertTrue("could not create synthetic profile directory", profile.mkdirs())
        return profile
    }

    private fun safeId(): String = UUID.randomUUID().toString().replace("-", "")

    private fun sha256(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(StandardCharsets.UTF_8))
        .joinToString(separator = "") { byte -> "%02x".format(byte.toInt() and 0xff) }

    private fun assertRejected(block: () -> Unit) {
        try {
            block()
        } catch (_: IllegalArgumentException) {
            return
        }
        throw AssertionError("Expected the profile path to be rejected")
    }

    private fun assertIllegalState(block: () -> Unit) {
        try {
            block()
        } catch (_: IllegalStateException) {
            return
        }
        throw AssertionError("Expected the profile operation to fail closed")
    }
}
