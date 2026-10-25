package cn.ustcassistant.mobile.qa.credentials

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import cn.ustcassistant.mobile.credentials.AndroidCredentialVault
import cn.ustcassistant.mobile.credentials.VaultException
import java.security.KeyStore
import java.security.SecureRandom
import java.util.UUID
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidCredentialVaultTest {
    private var testNamespace: String? = null
    private var vault: AndroidCredentialVault? = null

    @Before
    fun setUp() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        assertTrue(
            "Credential vault tests require the isolated QA application ID.",
            context.packageName.endsWith(".qa"),
        )
        val suffix = UUID.randomUUID().toString().replace("-", "")
        testNamespace = "ustc_assistant_credentials_qa_$suffix"
        vault = AndroidCredentialVault(testNamespace!!)
    }

    @After
    fun deleteOnlyTestAliases() {
        val namespace = testNamespace ?: return
        try {
            val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            listOf("$namespace.school", "$namespace.model").forEach { alias ->
                if (keyStore.containsAlias(alias)) keyStore.deleteEntry(alias)
            }
            assertFalse(keyStore.containsAlias("$namespace.school"))
            assertFalse(keyStore.containsAlias("$namespace.model"))
        } finally {
            vault = null
            testNamespace = null
        }
    }

    @Test
    fun roundTripsBothCredentialFamiliesAndRejectsDifferentPurposes() {
        val data = syntheticBytes(73)
        val originalData = data.copyOf()
        val schoolPurpose = schoolPurpose()
        val otherSchoolPurpose = schoolPurpose(owner = "1" + "0".repeat(31))
        val modelPurpose = modelPurpose()
        val otherModelPurpose = modelPurpose(owner = "1" + "0".repeat(31))
        val deepseekPurpose = modelPurpose(provider = "deepseek")

        val schoolEnvelope = vault().protect(data, schoolPurpose)
        val modelEnvelope = vault().protect(data, modelPurpose)
        val deepseekEnvelope = vault().protect(data, deepseekPurpose)
        val originalSchoolEnvelope = schoolEnvelope.copyOf()
        val originalModelEnvelope = modelEnvelope.copyOf()

        assertArrayEquals(originalData, data)
        assertArrayEquals(data, vault().unprotect(schoolEnvelope, schoolPurpose))
        assertArrayEquals(data, vault().unprotect(modelEnvelope, modelPurpose))
        assertArrayEquals(data, vault().unprotect(deepseekEnvelope, deepseekPurpose))
        assertArrayEquals(originalSchoolEnvelope, schoolEnvelope)
        assertArrayEquals(originalModelEnvelope, modelEnvelope)
        assertEquals(ENVELOPE_VERSION, schoolEnvelope[0].toInt())
        assertEquals(ENVELOPE_VERSION, modelEnvelope[0].toInt())
        assertVaultCode(INVALID_CREDENTIAL) {
            vault().unprotect(schoolEnvelope, otherSchoolPurpose)
        }
        assertVaultCode(INVALID_CREDENTIAL) {
            vault().unprotect(modelEnvelope, otherModelPurpose)
        }
        assertVaultCode(INVALID_CREDENTIAL) {
            vault().unprotect(modelEnvelope, deepseekPurpose)
        }
        assertVaultCode(INVALID_CREDENTIAL) {
            vault().unprotect(deepseekEnvelope, modelPurpose)
        }
    }

    @Test
    fun usesDifferentKeystoreGeneratedNoncesForRepeatedProtection() {
        val data = syntheticBytes(48)
        val purpose = schoolPurpose()

        val first = vault().protect(data, purpose)
        val second = vault().protect(data, purpose)

        assertEquals(ENVELOPE_HEADER_BYTES + data.size + GCM_TAG_BYTES, first.size)
        assertEquals(ENVELOPE_HEADER_BYTES + data.size + GCM_TAG_BYTES, second.size)
        assertNotEquals(
            first.sliceArray(1 until ENVELOPE_HEADER_BYTES).toList(),
            second.sliceArray(1 until ENVELOPE_HEADER_BYTES).toList(),
        )
    }

    @Test
    fun rejectsCrossFamilyEnvelopes() {
        val data = syntheticBytes(32)
        val schoolEnvelope = vault().protect(data, schoolPurpose())
        val modelEnvelope = vault().protect(data, modelPurpose())

        assertVaultCode(INVALID_CREDENTIAL) {
            vault().unprotect(schoolEnvelope, modelPurpose())
        }
        assertVaultCode(INVALID_CREDENTIAL) {
            vault().unprotect(modelEnvelope, schoolPurpose())
        }
    }

    @Test
    fun rejectsBadVersionTagShortAndOversizedEnvelopes() {
        val valid = vault().protect(syntheticBytes(32), schoolPurpose())

        val badVersion = valid.copyOf().apply { this[0] = 2 }
        assertVaultCode(INVALID_CREDENTIAL) { vault().unprotect(badVersion, schoolPurpose()) }

        val badTag = valid.copyOf().apply { this[lastIndex] = (this[lastIndex].toInt() xor 1).toByte() }
        assertVaultCode(INVALID_CREDENTIAL) { vault().unprotect(badTag, schoolPurpose()) }

        assertVaultCode(INVALID_CREDENTIAL) {
            vault().unprotect(ByteArray(MIN_ENVELOPE_BYTES - 1), schoolPurpose())
        }
        assertVaultCode(INVALID_CREDENTIAL) {
            vault().unprotect(ByteArray(MAX_ENVELOPE_BYTES + 1), schoolPurpose())
        }
    }

    @Test
    fun validatesPurposeAndPlaintextBounds() {
        assertVaultCode(INVALID_REQUEST) { vault().protect(ByteArray(0), schoolPurpose()) }
        assertVaultCode(INVALID_REQUEST) {
            vault().protect(ByteArray(MAX_PLAINTEXT_BYTES + 1), schoolPurpose())
        }
        assertVaultCode(INVALID_REQUEST) {
            vault().protect(syntheticBytes(1), "not-a-credential-purpose")
        }
        assertVaultCode(INVALID_REQUEST) {
            vault().protect(
                syntheticBytes(1),
                "other-model-key/v1/jw-owner-${"c".repeat(32)}",
            )
        }
        assertVaultCode(INVALID_REQUEST) {
            vault().protect(syntheticBytes(1), modelPurpose(provider = "deepseek") + "\n")
        }
        assertVaultCode(INVALID_REQUEST) {
            vault().protect(syntheticBytes(1), schoolPurpose() + "\n")
        }
        assertVaultCode(INVALID_REQUEST) {
            vault().unprotect(ByteArray(MIN_ENVELOPE_BYTES), "not-a-credential-purpose")
        }

        val boundaryPlaintext = syntheticBytes(MAX_PLAINTEXT_BYTES)
        val envelope = vault().protect(boundaryPlaintext, schoolPurpose())
        assertArrayEquals(boundaryPlaintext, vault().unprotect(envelope, schoolPurpose()))
    }

    @Test
    fun missingKeyIsNotRecreatedByUnprotectAndOldEnvelopeStaysInvalidAfterProtect() {
        val namespace = testNamespace!!
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val data = syntheticBytes(64)

        listOf(
            "$namespace.school" to listOf(schoolPurpose()),
            "$namespace.model" to listOf(
                modelPurpose(),
                modelPurpose(provider = "deepseek"),
            ),
        ).forEach { (alias, purposes) ->
            val oldEnvelope = vault().protect(data, purposes.first())
            assertTrue(keyStore.containsAlias(alias))
            assertNull(keyStore.getKey(alias, null)?.encoded)
            keyStore.deleteEntry(alias)

            assertVaultCode(INVALID_CREDENTIAL) {
                vault().unprotect(oldEnvelope, purposes.first())
            }
            assertFalse(keyStore.containsAlias(alias))
            assertNull(keyStore.getKey(alias, null))

            val newEnvelope = vault().protect(data, purposes.last())
            assertTrue(keyStore.containsAlias(alias))
            assertArrayEquals(data, vault().unprotect(newEnvelope, purposes.last()))
            assertVaultCode(INVALID_CREDENTIAL) {
                vault().unprotect(oldEnvelope, purposes.first())
            }
        }
    }

    private fun vault(): AndroidCredentialVault = checkNotNull(vault)

    private fun schoolPurpose(owner: String = "a".repeat(32)): String =
        "ustc-assistant/jw/login/v1:jw-owner-$owner:${"b".repeat(64)}"

    private fun modelPurpose(
        owner: String = "c".repeat(32),
        provider: String = "ustc",
    ): String = "$provider-model-key/v1/jw-owner-$owner"

    private fun syntheticBytes(size: Int): ByteArray = ByteArray(size).also(SecureRandom()::nextBytes)

    private fun assertVaultCode(expectedCode: String, action: () -> Unit) {
        try {
            action()
            fail("Expected VaultException with code $expectedCode")
        } catch (error: VaultException) {
            assertEquals(expectedCode, error.code)
            assertNull("VaultException must not expose a platform cause.", error.cause)
        }
    }

    private companion object {
        private const val INVALID_REQUEST = "invalid_request"
        private const val INVALID_CREDENTIAL = "invalid_credential"
        private const val MAX_PLAINTEXT_BYTES = 16 * 1024
        private const val MAX_ENVELOPE_BYTES = 64 * 1024
        private const val GCM_TAG_BYTES = 16
        private const val ENVELOPE_HEADER_BYTES = 13
        private const val MIN_ENVELOPE_BYTES = ENVELOPE_HEADER_BYTES + GCM_TAG_BYTES
        private const val ENVELOPE_VERSION = 1
    }
}
