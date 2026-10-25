package cn.ustcassistant.mobile.speech

import android.content.Context
import android.content.res.AssetManager
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.InterruptedIOException
import java.security.MessageDigest

internal fun interface SpeechAssetSource {
    @Throws(IOException::class)
    fun open(assetPath: String): InputStream
}

internal data class SpeechModelAsset(
    val assetPath: String,
    val fileName: String,
    val size: Long,
    val sha256: String,
)

/** Extracts only the fixed, versioned model assets into app-private no-backup storage. */
internal class SpeechModelStore internal constructor(
    noBackupFilesDir: File,
    private val assets: SpeechAssetSource,
    manifest: List<SpeechModelAsset> = FIXED_MANIFEST,
) {
    private val noBackupRoot = noBackupFilesDir
    private val modelAssets = manifest.toList().also(::validateManifest)
    val version: String get() = MODEL_VERSION

    constructor(context: Context) : this(
        // Resolve only the framework-owned sandbox root: Android may expose
        // a legitimate /data/user/0 alias. Caller/test roots and all descendants
        // still undergo the explicit no-link checks below.
        context.applicationContext.noBackupFilesDir.canonicalFile,
        assetSource(context.applicationContext.assets),
        FIXED_MANIFEST,
    )

    /** Returns the absolute cache directory only after every fixed asset is verified. */
    fun prepare(isCancelled: () -> Boolean = { false }): String = synchronized(CACHE_LOCK) {
        checkCancelled(isCancelled)
        val trustedRoot = validateNoBackupRoot(noBackupRoot)
        val speechRoot = ensureChildDirectory(trustedRoot, SPEECH_DIRECTORY)
        val versionDirectory = ensureChildDirectory(speechRoot, MODEL_VERSION)

        for (asset in modelAssets) {
            checkCancelled(isCancelled)
            val target = childFile(versionDirectory, asset.fileName)
            if (isVerified(target, asset, isCancelled)) continue
            extractAtomically(versionDirectory, target, asset, isCancelled)
        }
        checkCancelled(isCancelled)
        versionDirectory.canonicalPath
    }

    private fun extractAtomically(
        directory: File,
        target: File,
        asset: SpeechModelAsset,
        isCancelled: () -> Boolean,
    ) {
        val temporary = childFile(directory, "${asset.fileName}.tmp")
        var promoted = false
        try {
            validateRegularOrMissing(temporary)
            validateRegularOrMissing(target)
            assets.open(asset.assetPath).use { input ->
                val descriptor = Os.open(
                    temporary.absolutePath,
                    OsConstants.O_WRONLY or OsConstants.O_CREAT or OsConstants.O_TRUNC or NO_FOLLOW,
                    PRIVATE_FILE_MODE,
                )
                FileOutputStream(descriptor).use { output ->
                    val digest = MessageDigest.getInstance("SHA-256")
                    val buffer = ByteArray(COPY_BUFFER_BYTES)
                    var copied = 0L
                    try {
                        while (true) {
                            checkCancelled(isCancelled)
                            val count = input.read(buffer)
                            if (count < 0) break
                            if (count == 0) throw IOException("Speech model asset made no progress")
                            copied += count.toLong()
                            if (copied > asset.size) throw IOException("Speech model asset exceeds its fixed size")
                            digest.update(buffer, 0, count)
                            output.write(buffer, 0, count)
                        }
                        if (copied != asset.size || !digest.digest().hexDigestEquals(asset.sha256)) {
                            throw IOException("Speech model asset failed integrity verification")
                        }
                        checkCancelled(isCancelled)
                        output.fd.sync()
                    } finally {
                        buffer.fill(0)
                    }
                }
            }

            checkCancelled(isCancelled)
            validateRegularOrMissing(target)
            Os.rename(temporary.absolutePath, target.absolutePath)
            promoted = true
        } finally {
            if (!promoted) removeTemporaryIfRegular(temporary)
        }
    }

    private fun isVerified(
        file: File,
        asset: SpeechModelAsset,
        isCancelled: () -> Boolean,
    ): Boolean {
        val stat = statOrNull(file) ?: return false
        if ((stat.st_mode and OsConstants.S_IFMT) != OsConstants.S_IFREG) {
            throw IOException("Speech model path contains a link or non-file")
        }
        if (stat.st_size != asset.size) return false
        val descriptor = Os.open(file.absolutePath, OsConstants.O_RDONLY or NO_FOLLOW, 0)
        FileInputStream(descriptor).use { input ->
            val digest = MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(COPY_BUFFER_BYTES)
            var readTotal = 0L
            try {
                while (true) {
                    checkCancelled(isCancelled)
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (count == 0) throw IOException("Speech model file made no progress")
                    readTotal += count.toLong()
                    if (readTotal > asset.size) return false
                    digest.update(buffer, 0, count)
                }
                return readTotal == asset.size && digest.digest().hexDigestEquals(asset.sha256)
            } finally {
                buffer.fill(0)
            }
        }
    }

    private fun ensureChildDirectory(parent: File, name: String): File {
        requireSafeComponent(name)
        val child = File(parent, name)
        val stat = statOrNull(child)
        if (stat == null) {
            if (!child.mkdir()) throw IOException("Speech model directory could not be created")
        } else if ((stat.st_mode and OsConstants.S_IFMT) != OsConstants.S_IFDIR) {
            throw IOException("Speech model directory contains a link or non-directory")
        }
        verifyCanonicalChild(parent, child)
        return child
    }

    private fun childFile(parent: File, name: String): File {
        requireSafeComponent(name)
        val child = File(parent, name)
        verifyCanonicalChild(parent, child)
        return child
    }

    private fun validateRegularOrMissing(file: File) {
        val stat = statOrNull(file) ?: return
        if ((stat.st_mode and OsConstants.S_IFMT) != OsConstants.S_IFREG) {
            throw IOException("Speech model path contains a link or non-file")
        }
    }

    private fun verifyCanonicalChild(parent: File, child: File) {
        if (child.parentFile?.absoluteFile?.path != parent.absoluteFile.path ||
            child.canonicalFile.path != child.absoluteFile.path
        ) {
            throw IOException("Speech model path escaped its private directory")
        }
    }

    private fun ensureDirectoryChain(path: File, createMissing: Boolean) {
        val absolute = path.absoluteFile.path
        if (!path.isAbsolute || !absolute.startsWith(File.separator)) {
            throw IOException("Speech model root must be absolute")
        }
        val components = absolute.split(File.separatorChar).drop(1)
        if (components.any { it.isEmpty() || it == "." || it == ".." }) {
            throw IOException("Speech model root is not normalized")
        }
        var current = File(File.separator)
        for (component in components) {
            current = File(current, component)
            var stat = statOrNull(current)
            if (stat == null) {
                if (!createMissing || !current.mkdir()) {
                    throw IOException("Speech model root is unavailable")
                }
                stat = statOrNull(current)
            }
            if (stat == null || (stat.st_mode and OsConstants.S_IFMT) != OsConstants.S_IFDIR) {
                throw IOException("Speech model root contains a link or non-directory")
            }
        }
        if (path.canonicalFile.path != absolute) {
            throw IOException("Speech model root is not canonical")
        }
    }

    private fun statOrNull(file: File): android.system.StructStat? = try {
        Os.lstat(file.absolutePath)
    } catch (failure: ErrnoException) {
        if (failure.errno == OsConstants.ENOENT) null else throw IOException("Speech model filesystem check failed", failure)
    }

    private fun validateNoBackupRoot(root: File): File {
        if (!root.isAbsolute) throw IOException("Speech model root must be absolute")
        val absolute = root.absoluteFile
        if (root.canonicalFile.path != absolute.path) {
            throw IOException("Speech model root must not contain links")
        }
        ensureDirectoryChain(absolute, createMissing = false)
        return absolute
    }

    private fun removeTemporaryIfRegular(file: File) {
        try {
            val stat = statOrNull(file) ?: return
            if ((stat.st_mode and OsConstants.S_IFMT) == OsConstants.S_IFREG) {
                file.delete()
            }
        } catch (_: Exception) {
            // A leftover fixed temporary name is safe: the next attempt truncates it before use.
        }
    }

    private fun checkCancelled(isCancelled: () -> Boolean) {
        if (isCancelled() || Thread.currentThread().isInterrupted) {
            throw InterruptedIOException("Speech model preparation was cancelled")
        }
    }

    private fun requireSafeComponent(value: String) {
        if (!COMPONENT_PATTERN.matches(value)) throw IOException("Speech model path component is invalid")
    }

    private fun ByteArray.hexDigestEquals(expected: String): Boolean =
        joinToString(separator = "") { byte -> "%02x".format(byte.toInt() and 0xff) } == expected

    internal companion object {
        const val MODEL_VERSION = "sensevoice-int8-2024-07-17"
        const val SPEECH_DIRECTORY = "speech_v1"
        const val ASSET_ROOT = "speech/sensevoice/"
        const val COPY_BUFFER_BYTES = 32 * 1024
        const val MAX_ASSET_SIZE = 512L * 1024L * 1024L
        const val PRIVATE_FILE_MODE = 0x180 // 0600
        val NO_FOLLOW = OsConstants.O_NOFOLLOW
        val COMPONENT_PATTERN = Regex("^[A-Za-z0-9._-]+$")
        val SHA256_PATTERN = Regex("^[0-9a-f]{64}$")
        val CACHE_LOCK = Any()
        val REQUIRED_FILES = listOf("model.int8.onnx", "tokens.txt", "LICENSE")
        val FIXED_MANIFEST = listOf(
            SpeechModelAsset(
                "${ASSET_ROOT}model.int8.onnx",
                "model.int8.onnx",
                239_233_841L,
                "c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51",
            ),
            SpeechModelAsset(
                "${ASSET_ROOT}tokens.txt",
                "tokens.txt",
                315_894L,
                "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc",
            ),
            SpeechModelAsset(
                "${ASSET_ROOT}LICENSE",
                "LICENSE",
                71L,
                "221c6df10b0931a5629adad671ea48fb7747e034c414b6d2bfa275bc3dd4ea17",
            ),
        )

        fun assetSource(assetManager: AssetManager): SpeechAssetSource =
            SpeechAssetSource { path -> assetManager.open(path, AssetManager.ACCESS_STREAMING) }
    }

    private fun validateManifest(manifest: List<SpeechModelAsset>) {
        if (manifest.map { it.fileName }.toSet() != REQUIRED_FILES.toSet() || manifest.size != REQUIRED_FILES.size) {
            throw IllegalArgumentException("Speech model manifest must contain the fixed file set")
        }
        for (asset in manifest) {
            if (asset.assetPath != "$ASSET_ROOT${asset.fileName}" ||
                asset.size <= 0L || asset.size > MAX_ASSET_SIZE ||
                !SHA256_PATTERN.matches(asset.sha256)
            ) {
                throw IllegalArgumentException("Speech model manifest is invalid")
            }
        }
    }
}
