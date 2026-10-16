import 'package:flutter/services.dart';

import '../core/agent_contract.dart';
import '../core/jw_credentials.dart';

const _credentialChannel = MethodChannel('ustc_assistant/credentials_v1');
const _mechanism = 'android-keystore-aes-gcm-v1';
const _maxPlaintext = 16 * 1024;
const _maxEnvelope = 64 * 1024;
const _envelopeOverhead = 1 + 12 + 16;
final _schoolPurpose = RegExp(
  r'^ustc-assistant/jw/login/v1:jw-owner-[0-9a-f]{32}:[0-9a-f]{64}$',
);
final _modelPurpose = RegExp(r'^ustc-model-key/v1/jw-owner-[0-9a-f]{32}$');

/// Keystore holds the non-exportable key; C3 remains the ciphertext owner.
final class AndroidJwCredentialProtector implements JwCredentialProtector {
  const AndroidJwCredentialProtector();

  @override
  String get mechanism => _mechanism;

  @override
  Future<Uint8List> protect(Uint8List plaintext, {required String purpose}) =>
      _transform(
        _credentialChannel,
        plaintext,
        purpose,
        _schoolPurpose,
        protect: true,
      );

  @override
  Future<Uint8List> unprotect(
    Uint8List ciphertext, {
    required String purpose,
  }) => _transform(
    _credentialChannel,
    ciphertext,
    purpose,
    _schoolPurpose,
    protect: false,
  );
}

/// A separate typed outlet cannot consume a school-credential purpose.
final class AndroidModelCredentialProtector
    implements ModelCredentialProtector {
  const AndroidModelCredentialProtector();

  @override
  String get mechanism => _mechanism;

  @override
  Future<Uint8List> protect(Uint8List plaintext, {required String purpose}) =>
      _modelTransform(plaintext, purpose, protect: true);

  @override
  Future<Uint8List> unprotect(
    Uint8List ciphertext, {
    required String purpose,
  }) => _modelTransform(ciphertext, purpose, protect: false);

  Future<Uint8List> _modelTransform(
    Uint8List bytes,
    String purpose, {
    required bool protect,
  }) async {
    try {
      return await _transform(
        _credentialChannel,
        bytes,
        purpose,
        _modelPurpose,
        protect: protect,
      );
    } on JwCredentialException {
      throw const AgentFailure(AgentFailureCode.protectionFailed);
    }
  }
}

Future<Uint8List> _transform(
  MethodChannel channel,
  Uint8List bytes,
  String purpose,
  RegExp purposePattern, {
  required bool protect,
}) async {
  final failure = protect
      ? JwCredentialFailure.protectionFailed
      : JwCredentialFailure.invalidCredential;
  if (purpose.length > 256 ||
      purposePattern.firstMatch(purpose)?.end != purpose.length ||
      (protect
          ? bytes.isEmpty || bytes.length > _maxPlaintext
          : bytes.length <= _envelopeOverhead ||
                bytes.length > _maxEnvelope ||
                bytes.first != 1)) {
    throw JwCredentialException(failure);
  }
  final input = Uint8List.fromList(bytes);
  Uint8List? output;
  try {
    final result = await channel.invokeMethod<Object?>(
      protect ? 'protect' : 'unprotect',
      <String, Object>{'purpose': purpose, 'data': input},
    );
    if (result is! Uint8List) throw JwCredentialException(failure);
    output = result;
    if (protect
        ? result.length != bytes.length + _envelopeOverhead || result.first != 1
        : result.isEmpty ||
              result.length > _maxPlaintext ||
              result.length != bytes.length - _envelopeOverhead) {
      throw JwCredentialException(failure);
    }
    return Uint8List.fromList(result);
  } on MissingPluginException {
    throw const JwCredentialException(JwCredentialFailure.unavailable);
  } on PlatformException catch (error) {
    // Never retain platform messages/details, which are outside this contract.
    throw JwCredentialException(
      error.code == 'unavailable' ? JwCredentialFailure.unavailable : failure,
    );
  } on JwCredentialException {
    rethrow;
  } catch (_) {
    throw JwCredentialException(failure);
  } finally {
    input.fillRange(0, input.length, 0);
    output?.fillRange(0, output.length, 0);
  }
}
