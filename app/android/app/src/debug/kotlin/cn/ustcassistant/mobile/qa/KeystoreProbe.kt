package cn.ustcassistant.mobile.qa

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import org.json.JSONObject
import java.security.GeneralSecurityException
import java.security.KeyStore
import java.security.SecureRandom
import java.util.Arrays
import javax.crypto.BadPaddingException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec

/**
 * A temporary, synthetic Android Keystore capability probe for the isolated QA application.
 * This is not the application's credential protector.
 */
object KeystoreProbe {
    private const val RESULT_KIND = "android-keystore-probe-v1"
    private const val KEYSTORE_PROVIDER = "AndroidKeyStore"
    private const val KEY_ALIAS_PREFIX = "a0-keystore-probe-"
    private const val GCM_TAG_LENGTH_BITS = 128
    private const val EXPECTED_GCM_NONCE_LENGTH_BYTES = 12

    private const val FAILURE_NONE = "none"
    private const val FAILURE_NOT_QA_PACKAGE = "not_qa_package"
    private const val FAILURE_KEYSTORE_UNAVAILABLE = "keystore_unavailable"
    private const val FAILURE_KEY_GENERATION_FAILED = "key_generation_failed"
    private const val FAILURE_PROBE_FAILED = "probe_failed"
    private const val FAILURE_CLEANUP_FAILED = "cleanup_failed"

    private val random = SecureRandom()

    /** Runs synchronously; callers should invoke this from a background thread. */
    @Synchronized
    fun run(context: Context): JSONObject {
        val checks = JSONObject()
            .put("roundTrip", false)
            .put("wrongPurposeRejected", false)
            .put("nonceUnique", false)
            .put("missingKeyRejected", false)

        var success = false
        var failure = FAILURE_NONE
        var stageFailure = FAILURE_KEYSTORE_UNAVAILABLE
        var probeAttempted = false
        var operationFailed = false
        var hardwareBacked: Any = JSONObject.NULL
        var keyStore: KeyStore? = null
        var keyAlias: String? = null
        var ownsKeyAlias = false
        var cleanupFailed = false
        var ownedKeyWasDeleted = false

        var plaintext: ByteArray? = null
        var purpose: ByteArray? = null
        var wrongPurpose: ByteArray? = null
        var firstNonce: ByteArray? = null
        var secondNonce: ByteArray? = null
        var firstCiphertext: ByteArray? = null
        var secondCiphertext: ByteArray? = null
        var recoveredPlaintext: ByteArray? = null
        var wrongPurposePlaintext: ByteArray? = null

        try {
            if (!context.packageName.endsWith(".qa")) {
                failure = FAILURE_NOT_QA_PACKAGE
            } else {
                probeAttempted = true
                val loadedKeyStore = KeyStore.getInstance(KEYSTORE_PROVIDER).apply { load(null) }
                keyStore = loadedKeyStore
                stageFailure = FAILURE_KEY_GENERATION_FAILED
                val ownedAlias = allocateAlias(loadedKeyStore)
                keyAlias = ownedAlias
                ownsKeyAlias = true

                val key = generateKey(ownedAlias)
                hardwareBacked = queryHardwareBacked(key) ?: JSONObject.NULL

                stageFailure = FAILURE_PROBE_FAILED
                val payload = byteArrayOf(
                    0x41, 0x30, 0x2d, 0x53, 0x59, 0x4e, 0x54, 0x48,
                    0x45, 0x54, 0x49, 0x43, 0x2d, 0x50, 0x41, 0x59,
                    0x4c, 0x4f, 0x41, 0x44, 0x2d, 0x56, 0x31,
                )
                plaintext = payload
                val purposeBytes = byteArrayOf(
                    0x61, 0x30, 0x2d, 0x6b, 0x65, 0x79, 0x73, 0x74,
                    0x6f, 0x72, 0x65, 0x2d, 0x70, 0x72, 0x6f, 0x62,
                    0x65, 0x2d, 0x70, 0x75, 0x72, 0x70, 0x6f, 0x73,
                    0x65, 0x2d, 0x76, 0x31,
                )
                purpose = purposeBytes
                val wrongPurposeBytes = byteArrayOf(
                    0x61, 0x30, 0x2d, 0x6b, 0x65, 0x79, 0x73, 0x74,
                    0x6f, 0x72, 0x65, 0x2d, 0x77, 0x72, 0x6f, 0x6e,
                    0x67, 0x2d, 0x70, 0x75, 0x72, 0x70, 0x6f, 0x73,
                    0x65, 0x2d, 0x76, 0x31,
                )
                wrongPurpose = wrongPurposeBytes

                val encryptCipher = Cipher.getInstance("AES/GCM/NoPadding")
                encryptCipher.init(Cipher.ENCRYPT_MODE, key)
                val firstNonceBytes = encryptCipher.iv ?: throw GeneralSecurityException()
                firstNonce = firstNonceBytes
                encryptCipher.updateAAD(purposeBytes)
                val firstCiphertextBytes = encryptCipher.doFinal(payload)
                firstCiphertext = firstCiphertextBytes

                val decryptCipher = Cipher.getInstance("AES/GCM/NoPadding")
                decryptCipher.init(
                    Cipher.DECRYPT_MODE,
                    key,
                    GCMParameterSpec(GCM_TAG_LENGTH_BITS, firstNonceBytes),
                )
                decryptCipher.updateAAD(purposeBytes)
                val recovered = decryptCipher.doFinal(firstCiphertextBytes)
                recoveredPlaintext = recovered
                checks.put("roundTrip", recovered.contentEquals(payload))

                val wrongPurposeCipher = Cipher.getInstance("AES/GCM/NoPadding")
                wrongPurposeCipher.init(
                    Cipher.DECRYPT_MODE,
                    key,
                    GCMParameterSpec(GCM_TAG_LENGTH_BITS, firstNonceBytes),
                )
                wrongPurposeCipher.updateAAD(wrongPurposeBytes)
                var wrongPurposeRejected = false
                try {
                    wrongPurposePlaintext = wrongPurposeCipher.doFinal(firstCiphertextBytes)
                } catch (_: BadPaddingException) {
                    wrongPurposeRejected = true
                } finally {
                    wipe(wrongPurposePlaintext)
                    wrongPurposePlaintext = null
                }
                checks.put("wrongPurposeRejected", wrongPurposeRejected)

                val secondEncryptCipher = Cipher.getInstance("AES/GCM/NoPadding")
                secondEncryptCipher.init(Cipher.ENCRYPT_MODE, key)
                val secondNonceBytes = secondEncryptCipher.iv ?: throw GeneralSecurityException()
                secondNonce = secondNonceBytes
                secondEncryptCipher.updateAAD(purposeBytes)
                secondCiphertext = secondEncryptCipher.doFinal(payload)
                checks.put(
                    "nonceUnique",
                    firstNonceBytes.size == EXPECTED_GCM_NONCE_LENGTH_BYTES &&
                        secondNonceBytes.size == EXPECTED_GCM_NONCE_LENGTH_BYTES &&
                        !firstNonceBytes.contentEquals(secondNonceBytes),
                )

                success = checks.allChecksPassed()
                failure = if (success) FAILURE_NONE else FAILURE_PROBE_FAILED
            }
        } catch (_: Exception) {
            operationFailed = true
            success = false
            failure = stageFailure
        } catch (_: LinkageError) {
            operationFailed = true
            success = false
            failure = stageFailure
        } finally {
            wipe(plaintext)
            wipe(purpose)
            wipe(wrongPurpose)
            wipe(firstNonce)
            wipe(secondNonce)
            wipe(firstCiphertext)
            wipe(secondCiphertext)
            wipe(recoveredPlaintext)
            wipe(wrongPurposePlaintext)

            val cleanupKeyStore = keyStore
            val cleanupAlias = keyAlias
            if (ownsKeyAlias && cleanupKeyStore != null && cleanupAlias != null) {
                var keyAbsent = false
                repeat(2) {
                    if (!keyAbsent) {
                        try {
                            cleanupKeyStore.deleteEntry(cleanupAlias)
                            keyAbsent = !cleanupKeyStore.containsAlias(cleanupAlias)
                        } catch (_: Exception) {
                            keyAbsent = try {
                                !cleanupKeyStore.containsAlias(cleanupAlias)
                            } catch (_: Exception) {
                                false
                            } catch (_: LinkageError) {
                                false
                            }
                        } catch (_: LinkageError) {
                            keyAbsent = false
                        }
                    }
                }
                if (keyAbsent) {
                    ownedKeyWasDeleted = true
                } else {
                    cleanupFailed = true
                }
            }
        }

        val deletedKeyStore = keyStore
        val deletedKeyAlias = keyAlias
        if (probeAttempted && ownedKeyWasDeleted && deletedKeyStore != null && deletedKeyAlias != null) {
            checks.put("missingKeyRejected", keyIsRejectedAfterDeletion(deletedKeyStore, deletedKeyAlias))
        }

        if (cleanupFailed) {
            success = false
            failure = FAILURE_CLEANUP_FAILED
        } else if (probeAttempted && !operationFailed) {
            success = checks.allChecksPassed()
            failure = if (success) FAILURE_NONE else FAILURE_PROBE_FAILED
        }

        return JSONObject()
            .put("kind", RESULT_KIND)
            .put("success", success)
            .put("checks", checks)
            .put("hardwareBacked", hardwareBacked)
            .put("failure", failure)
    }

    private fun allocateAlias(keyStore: KeyStore): String {
        repeat(8) {
            val randomBytes = ByteArray(16)
            val suffix = try {
                random.nextBytes(randomBytes)
                buildString(randomBytes.size * 2) {
                    for (byte in randomBytes) {
                        val value = byte.toInt() and 0xff
                        append(HEX[value ushr 4])
                        append(HEX[value and 0x0f])
                    }
                }
            } finally {
                wipe(randomBytes)
            }

            val candidate = KEY_ALIAS_PREFIX + suffix
            if (!keyStore.containsAlias(candidate)) return candidate
        }
        throw GeneralSecurityException()
    }

    private fun generateKey(alias: String): SecretKey {
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE_PROVIDER)
        generator.init(
            KeyGenParameterSpec.Builder(
                alias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setKeySize(256)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build(),
        )
        return generator.generateKey()
    }

    private fun queryHardwareBacked(key: SecretKey): Boolean? {
        return try {
            val keyInfo = SecretKeyFactory
                .getInstance(key.algorithm, KEYSTORE_PROVIDER)
                .getKeySpec(key, KeyInfo::class.java) as KeyInfo
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                when (keyInfo.securityLevel) {
                    KeyProperties.SECURITY_LEVEL_SOFTWARE -> false
                    KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT,
                    KeyProperties.SECURITY_LEVEL_STRONGBOX,
                    KeyProperties.SECURITY_LEVEL_UNKNOWN_SECURE -> true
                    else -> null
                }
            } else {
                @Suppress("DEPRECATION")
                keyInfo.isInsideSecureHardware
            }
        } catch (_: Exception) {
            null
        } catch (_: LinkageError) {
            null
        }
    }

    private fun keyIsRejectedAfterDeletion(keyStore: KeyStore, alias: String): Boolean {
        val aliasIsPresent = try {
            keyStore.containsAlias(alias)
        } catch (_: Exception) {
            return false
        } catch (_: LinkageError) {
            return false
        }
        if (aliasIsPresent) return false

        return try {
            val key = keyStore.getKey(alias, null)
            key == null
        } catch (_: Exception) {
            true
        } catch (_: LinkageError) {
            true
        }
    }

    private fun JSONObject.allChecksPassed(): Boolean {
        return optBoolean("roundTrip") &&
            optBoolean("wrongPurposeRejected") &&
            optBoolean("nonceUnique") &&
            optBoolean("missingKeyRejected")
    }

    private fun wipe(bytes: ByteArray?) {
        if (bytes != null) Arrays.fill(bytes, 0.toByte())
    }

    private const val HEX = "0123456789abcdef"
}
