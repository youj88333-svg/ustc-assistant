package cn.ustcassistant.mobile.credentials

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec

/** Private app RPC only. No webpage bridge, credential persistence, or arbitrary aliases. */
internal class CredentialChannel(messenger: BinaryMessenger) {
    private val vault = AndroidCredentialVault()
    private val channel = MethodChannel(
        messenger,
        "ustc_assistant/credentials_v1",
        StandardMethodCodec.INSTANCE,
        messenger.makeBackgroundTaskQueue(BinaryMessenger.TaskQueueOptions().setIsSerial(true)),
    )

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "protect" && call.method != "unprotect") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val arguments = call.arguments as? Map<*, *>
            val purpose = arguments?.get("purpose") as? String
            val data = arguments?.get("data") as? ByteArray
            if (arguments?.keys != setOf("purpose", "data") || purpose == null || data == null) {
                data?.fill(0)
                result.error("invalid_request", null, null)
                return@setMethodCallHandler
            }
            try {
                val output = if (call.method == "protect") vault.protect(data, purpose)
                    else vault.unprotect(data, purpose)
                try {
                    // StandardMethodCodec copies bytes into its reply before this call returns.
                    result.success(output)
                } finally { output.fill(0) }
            } catch (error: VaultException) {
                result.error(error.code, null, null)
            } catch (_: Exception) {
                result.error(if (call.method == "protect") "protection_failed" else "invalid_credential", null, null)
            } finally {
                // This is the decoded channel copy, never a browser or persisted value.
                data.fill(0)
            }
        }
    }

    fun dispose() { channel.setMethodCallHandler(null) }
}
