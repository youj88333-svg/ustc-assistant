package cn.ustcassistant.mobile.qa

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class KeystoreProbeTest {
    @Test
    fun reportsSyntheticKeystoreBehaviorsWithoutSecretMaterial() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        assertTrue("The Keystore probe requires the isolated QA application ID.", context.packageName.endsWith(".qa"))

        val report = KeystoreProbe.run(context)

        assertEquals("android-keystore-probe-v1", report.getString("kind"))
        assertTrue(report.getBoolean("success"))
        assertEquals(
            setOf("kind", "success", "checks", "hardwareBacked", "failure"),
            report.keys().asSequence().toSet(),
        )

        val checks = report.getJSONObject("checks")
        assertEquals(
            setOf("roundTrip", "wrongPurposeRejected", "nonceUnique", "missingKeyRejected"),
            checks.keys().asSequence().toSet(),
        )
        assertTrue(checks.getBoolean("roundTrip"))
        assertTrue(checks.getBoolean("wrongPurposeRejected"))
        assertTrue(checks.getBoolean("nonceUnique"))
        assertTrue(checks.getBoolean("missingKeyRejected"))

        val hardwareBacked = report.get("hardwareBacked")
        assertTrue(hardwareBacked === JSONObject.NULL || hardwareBacked is Boolean)
        assertEquals("none", report.getString("failure"))

        val serialized = report.toString()
        assertFalse(serialized.contains("a0-keystore-probe-"))
        assertFalse(serialized.contains("A0-SYNTHETIC-PAYLOAD-V1"))
    }
}
