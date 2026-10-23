import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/jw_credentials.dart';
import 'package:ustc_assistant_m0/platform/android_credential_protector.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ustc_assistant/credentials_v1');
  const school = AndroidJwCredentialProtector();
  const model = AndroidModelCredentialProtector();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final owner = 'jw-owner-${'a' * 32}';
  final schoolPurpose = 'ustc-assistant/jw/login/v1:$owner:${'b' * 64}';
  final modelPurpose = ModelProvider.school.keyPurpose(owner);
  final deepseekPurpose = ModelProvider.deepseek.keyPurpose(owner);
  Matcher jwFailure(JwCredentialFailure code) => throwsA(
    isA<JwCredentialException>().having((error) => error.code, 'code', code),
  );
  final modelFailure = throwsA(
    isA<AgentFailure>().having(
      (error) => error.code,
      'code',
      AgentFailureCode.protectionFailed,
    ),
  );

  Uint8List envelope(int plaintextSize) =>
      Uint8List(plaintextSize + 29)..[0] = 1;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'typed outlets share only the bounded fixed RPC, retaining caller bytes',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        final arguments = call.arguments as Map;
        expect(arguments.keys.toSet(), {'purpose', 'data'});
        expect(
          arguments['purpose'],
          anyOf(schoolPurpose, modelPurpose, deepseekPurpose),
        );
        final data = arguments['data'] as Uint8List;
        calls.add(call.method);
        return call.method == 'protect'
            ? envelope(data.length)
            : Uint8List.fromList([7, 8]);
      });
      for (final (protector, purpose) in [
        (school, schoolPurpose),
        (model, modelPurpose),
        (model, deepseekPurpose),
      ]) {
        final input = Uint8List.fromList([7, 8]);
        // The two interfaces are deliberately distinct; use their shared behavior here only.
        final cipher = protector is JwCredentialProtector
            ? await protector.protect(input, purpose: purpose)
            : await (protector as ModelCredentialProtector).protect(
                input,
                purpose: purpose,
              );
        final plain = protector is JwCredentialProtector
            ? await protector.unprotect(cipher, purpose: purpose)
            : await (protector as ModelCredentialProtector).unprotect(
                cipher,
                purpose: purpose,
              );
        expect(input, [7, 8]);
        expect(plain, [7, 8]);
        expect(cipher.length, 31);
        expect(cipher.first, 1);
      }
      expect(calls, [
        'protect',
        'unprotect',
        'protect',
        'unprotect',
        'protect',
        'unprotect',
      ]);
      expect(school.mechanism, 'android-keystore-aes-gcm-v1');
      expect(model.mechanism, school.mechanism);
    },
  );

  test(
    'family and exact purpose checks reject before native delivery',
    () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        calls++;
        return null;
      });
      final bytes = Uint8List.fromList([7]);
      for (final purpose in [
        modelPurpose,
        deepseekPurpose,
        '$schoolPurpose\n',
        '$schoolPurpose/extra',
        'x' * 257,
      ]) {
        await expectLater(
          school.protect(bytes, purpose: purpose),
          jwFailure(JwCredentialFailure.protectionFailed),
        );
      }
      await expectLater(
        model.protect(bytes, purpose: schoolPurpose),
        modelFailure,
      );
      await expectLater(
        model.unprotect(envelope(1), purpose: schoolPurpose),
        modelFailure,
      );
      for (final purpose in [
        'other-model-key/v1/$owner',
        '$deepseekPurpose\n',
        '${deepseekPurpose}suffix',
      ]) {
        await expectLater(model.protect(bytes, purpose: purpose), modelFailure);
      }
      expect(calls, 0);
      expect(bytes, [7]);
    },
  );

  test(
    'input limits and envelope version are enforced without invoking native',
    () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        calls++;
        return null;
      });
      for (final bytes in [Uint8List(0), Uint8List(16 * 1024 + 1)]) {
        await expectLater(
          school.protect(bytes, purpose: schoolPurpose),
          jwFailure(JwCredentialFailure.protectionFailed),
        );
      }
      for (final bytes in [
        Uint8List(0),
        Uint8List(29)..[0] = 1,
        Uint8List(30),
        Uint8List(64 * 1024 + 1)..[0] = 1,
      ]) {
        await expectLater(
          school.unprotect(bytes, purpose: schoolPurpose),
          jwFailure(JwCredentialFailure.invalidCredential),
        );
      }
      expect(calls, 0);
    },
  );

  test('missing host is unavailable and model failures stay typed', () async {
    final bytes = Uint8List.fromList([7]);
    await expectLater(
      school.protect(bytes, purpose: schoolPurpose),
      jwFailure(JwCredentialFailure.unavailable),
    );
    await expectLater(
      school.unprotect(envelope(1), purpose: schoolPurpose),
      jwFailure(JwCredentialFailure.unavailable),
    );
    await expectLater(
      model.protect(bytes, purpose: modelPurpose),
      modelFailure,
    );
  });

  test(
    'native failure details cannot escape the fixed error boundary',
    () async {
      for (final code in [
        'invalid_request',
        'invalid_credential',
        'unavailable',
        'unexpected_provider_error',
      ]) {
        messenger.setMockMethodCallHandler(channel, (_) async {
          throw PlatformException(
            code: code,
            message: 'synthetic-private-detail',
            details: {'value': 'synthetic-private-detail'},
          );
        });
        final expected = code == 'unavailable'
            ? JwCredentialFailure.unavailable
            : JwCredentialFailure.invalidCredential;
        try {
          await school.unprotect(envelope(1), purpose: schoolPurpose);
          fail('Native rejection was accepted');
        } on JwCredentialException catch (error) {
          expect(error.code, expected);
          expect(error.toString(), isNot(contains('synthetic-private-detail')));
        }
      }
    },
  );

  test('invalid native output never becomes an accepted credential', () async {
    for (final output in <Object?>[
      null,
      'synthetic',
      Uint8List(30),
      envelope(2),
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => output);
      await expectLater(
        school.protect(Uint8List.fromList([7]), purpose: schoolPurpose),
        jwFailure(JwCredentialFailure.protectionFailed),
      );
    }
    for (final output in <Object?>[
      null,
      'synthetic',
      Uint8List(0),
      Uint8List(2),
      Uint8List(16 * 1024 + 1),
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => output);
      await expectLater(
        school.unprotect(envelope(1), purpose: schoolPurpose),
        jwFailure(JwCredentialFailure.invalidCredential),
      );
    }
  });
}
