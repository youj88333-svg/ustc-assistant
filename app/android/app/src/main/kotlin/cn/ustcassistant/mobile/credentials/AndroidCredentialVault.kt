package cn.ustcassistant.mobile.credentials

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.IOException
import java.security.Key
import java.security.KeyStore
import java.security.NoSuchAlgorithmException
import java.security.NoSuchProviderException
import java.security.ProviderException
import java.util.Arrays
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.NoSuchPaddingException
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal class VaultException(val code: String) : Exception()

/**
 * Android Keystore backed protection primitive for C3-owned credential ciphertext.
 * This class does not persist ciphertext and must not be exposed as a general channel API.
 */
internal class AndroidCredentialVault(
    private val keyNamespace: String = "ustc_assistant_credentials_v1",
) {
    internal fun protect(data: ByteArray, purpose: String): ByteArray {
        val family = parsePurpose(purpose) ?: throw VaultException(INVALID_REQUEST)
        if (data.size !in 1..MAX_PLAINTEXT_BYTES) throw VaultException(INVALID_REQUEST)

        val aad = purpose.toByteArray(Charsets.UTF_8)
        var nonce: ByteArray? = null
        var ciphertextAndTag: ByteArray? = null
        try {
            val key = getOrCreateKey(aliasFor(family))
            val cipher = newCipher()
            try {
                cipher.init(Cipher.ENCRYPT_MODE, key)
                nonce = cipher.iv ?: throw VaultException(PROTECTION_FAILED)
                if (nonce!!.size != GCM_NONCE_BYTES) throw VaultException(PROTECTION_FAILED)
                cipher.updateAAD(aad)
                ciphertextAndTag = cipher.doFinal(data)

                val encrypted = ciphertextAndTag!!
                if (encrypted.size < GCM_TAG_BYTES ||
                    ENVELOPE_HEADER_BYTES + encrypted.size > MAX_ENVELOPE_BYTES
                ) {
                    throw VaultException(PROTECTION_FAILED)
                }

                val envelope = ByteArray(ENVELOPE_HEADER_BYTES + encrypted.size)
                envelope[0] = ENVELOPE_VERSION
                System.arraycopy(nonce!!, 0, envelope, VERSION_BYTES, GCM_NONCE_BYTES)
                System.arraycopy(encrypted, 0, envelope, ENVELOPE_HEADER_BYTES, encrypted.size)
                return envelope
            } catch (error: VaultException) {
                throw error
            } catch (error: Exception) {
                if (isProviderUnavailable(error)) throw VaultException(UNAVAILABLE)
                throw VaultException(PROTECTION_FAILED)
            } catch (_: LinkageError) {
                throw VaultException(UNAVAILABLE)
            }
        } finally {
            wipe(aad)
            wipe(nonce)
            wipe(ciphertextAndTag)
        }
    }

    internal fun unprotect(data: ByteArray, purpose: String): ByteArray {
        val family = parsePurpose(purpose) ?: throw VaultException(INVALID_REQUEST)
        if (data.size !in MIN_ENVELOPE_BYTES..MAX_ENVELOPE_BYTES ||
            data[0] != ENVELOPE_VERSION
        ) {
            throw VaultException(INVALID_CREDENTIAL)
        }

        val nonce = data.copyOfRange(VERSION_BYTES, ENVELOPE_HEADER_BYTES)
        val ciphertextAndTag = data.copyOfRange(ENVELOPE_HEADER_BYTES, data.size)
        val aad = purpose.toByteArray(Charsets.UTF_8)
        var plaintext: ByteArray? = null
        try {
            val key = getExistingKey(aliasFor(family))
            val cipher = newCipher()
            try {
                cipher.init(
                    Cipher.DECRYPT_MODE,
                    key,
                    GCMParameterSpec(GCM_TAG_LENGTH_BITS, nonce),
                )
                cipher.updateAAD(aad)
                plaintext = cipher.doFinal(ciphertextAndTag)
            } catch (error: VaultException) {
                throw error
            } catch (error: Exception) {
                if (isProviderUnavailable(error)) throw VaultException(UNAVAILABLE)
                throw VaultException(INVALID_CREDENTIAL)
            } catch (_: LinkageError) {
                throw VaultException(UNAVAILABLE)
            }

            val recovered = plaintext!!
            if (recovered.size !in 1..MAX_PLAINTEXT_BYTES) {
                wipe(recovered)
                plaintext = null
                throw VaultException(INVALID_CREDENTIAL)
            }
            plaintext = null
            return recovered
        } finally {
            wipe(nonce)
            wipe(ciphertextAndTag)
            wipe(aad)
            wipe(plaintext)
        }
    }

    private fun parsePurpose(purpose: String): KeyFamily? {
        if (purpose.length !in 1..MAX_PURPOSE_CHARS) return null
        return when {
            SCHOOL_PURPOSE.matches(purpose) -> KeyFamily.SCHOOL
            MODEL_PURPOSE.matches(purpose) -> KeyFamily.MODEL
            else -> null
        }
    }

    private fun aliasFor(family: KeyFamily): String = when (family) {
        KeyFamily.SCHOOL -> "$keyNamespace.school"
        KeyFamily.MODEL -> "$keyNamespace.model"
    }

    private fun getOrCreateKey(alias: String): SecretKey = synchronized(KEY_CREATION_LOCK) {
        val keyStore = loadKeyStore()
        val exists = try {
            keyStore.containsAlias(alias)
        } catch (_: Exception) {
            throw VaultException(UNAVAILABLE)
        } catch (_: LinkageError) {
            throw VaultException(UNAVAILABLE)
        }

        if (exists) return@synchronized existingKeyForProtection(keyStore, alias)
        generateKey(alias)
    }

    private fun getExistingKey(alias: String): SecretKey {
        val keyStore = loadKeyStore()
        val exists = try {
            keyStore.containsAlias(alias)
        } catch (_: Exception) {
            throw VaultException(UNAVAILABLE)
        } catch (_: LinkageError) {
            throw VaultException(UNAVAILABLE)
        }
        if (!exists) throw VaultException(INVALID_CREDENTIAL)

        val key = try {
            keyStore.getKey(alias, null)
        } catch (_: java.security.UnrecoverableKeyException) {
            throw VaultException(INVALID_CREDENTIAL)
        } catch (_: Exception) {
            throw VaultException(UNAVAILABLE)
        } catch (_: LinkageError) {
            throw VaultException(UNAVAILABLE)
        }
        return key.asAesKeyOrNull() ?: throw VaultException(INVALID_CREDENTIAL)
    }

    private fun existingKeyForProtection(keyStore: KeyStore, alias: String): SecretKey {
        val key = try {
            keyStore.getKey(alias, null)
        } catch (_: java.security.UnrecoverableKeyException) {
            throw VaultException(PROTECTION_FAILED)
        } catch (error: Exception) {
            if (isProviderUnavailable(error)) throw VaultException(UNAVAILABLE)
            throw VaultException(PROTECTION_FAILED)
        } catch (_: LinkageError) {
            throw VaultException(UNAVAILABLE)
        }
        return key.asAesKeyOrNull() ?: throw VaultException(PROTECTION_FAILED)
    }

    private fun generateKey(alias: String): SecretKey {
        try {
            val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE_PROVIDER)
            generator.init(
                KeyGenParameterSpec.Builder(
                    alias,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setKeySize(AES_KEY_SIZE_BITS)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setRandomizedEncryptionRequired(true)
                    .setUserAuthenticationRequired(false)
                    .build(),
            )
            return generator.generateKey().asAesKeyOrNull()
                ?: throw VaultException(PROTECTION_FAILED)
        } catch (error: VaultException) {
            throw error
        } catch (error: Exception) {
            if (isProviderUnavailable(error)) throw VaultException(UNAVAILABLE)
            throw VaultException(PROTECTION_FAILED)
        } catch (_: LinkageError) {
            throw VaultException(UNAVAILABLE)
        }
    }

    private fun loadKeyStore(): KeyStore {
        try {
            return KeyStore.getInstance(KEYSTORE_PROVIDER).apply { load(null) }
        } catch (_: Exception) {
            throw VaultException(UNAVAILABLE)
        } catch (_: LinkageError) {
            throw VaultException(UNAVAILABLE)
        }
    }

    private fun newCipher(): Cipher {
        try {
            return Cipher.getInstance(CIPHER_TRANSFORMATION)
        } catch (_: Exception) {
            throw VaultException(UNAVAILABLE)
        } catch (_: LinkageError) {
            throw VaultException(UNAVAILABLE)
        }
    }

    private fun Key?.asAesKeyOrNull(): SecretKey? {
        val secretKey = this as? SecretKey ?: return null
        return secretKey.takeIf {
            it.algorithm.equals(KeyProperties.KEY_ALGORITHM_AES, ignoreCase = true)
        }
    }

    private fun wipe(bytes: ByteArray?) {
        if (bytes != null) Arrays.fill(bytes, 0.toByte())
    }

    private fun isProviderUnavailable(error: Exception): Boolean =
        error is NoSuchAlgorithmException ||
            error is NoSuchProviderException ||
            error is NoSuchPaddingException ||
            error is ProviderException ||
            error is IOException

    private enum class KeyFamily {
        SCHOOL,
        MODEL,
    }

    private companion object {
        private const val KEYSTORE_PROVIDER = "AndroidKeyStore"
        private const val CIPHER_TRANSFORMATION = "AES/GCM/NoPadding"
        private const val AES_KEY_SIZE_BITS = 256
        private const val GCM_TAG_LENGTH_BITS = 128
        private const val GCM_TAG_BYTES = GCM_TAG_LENGTH_BITS / 8
        private const val GCM_NONCE_BYTES = 12
        private const val VERSION_BYTES = 1
        private const val ENVELOPE_HEADER_BYTES = VERSION_BYTES + GCM_NONCE_BYTES
        private const val MIN_ENVELOPE_BYTES = ENVELOPE_HEADER_BYTES + GCM_TAG_BYTES
        private const val MAX_PLAINTEXT_BYTES = 16 * 1024
        private const val MAX_ENVELOPE_BYTES = 64 * 1024
        private const val MAX_PURPOSE_CHARS = 256
        private const val ENVELOPE_VERSION: Byte = 1

        private const val INVALID_REQUEST = "invalid_request"
        private const val UNAVAILABLE = "unavailable"
        private const val PROTECTION_FAILED = "protection_failed"
        private const val INVALID_CREDENTIAL = "invalid_credential"

        private val SCHOOL_PURPOSE = Regex(
            "^ustc-assistant/jw/login/v1:jw-owner-[0-9a-f]{32}:[0-9a-f]{64}$",
        )
        private val MODEL_PURPOSE = Regex("^ustc-model-key/v1/jw-owner-[0-9a-f]{32}$")
        private val KEY_CREATION_LOCK = Any()
    }
}
