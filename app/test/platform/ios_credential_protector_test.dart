import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/jw_credentials.dart';
import 'package:ustc_assistant_m0/platform/ios_credential_protector.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ustc_assistant/credentials_v1');
  const school = IOSJwCredentialProtector();
  const model = IOSModelCredentialProtector();
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
    'typed protectors use the fixed bounded channel and preserve inputs',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        final arguments = call.arguments as Map;
        expect(arguments.keys.toSet(), {'purpose', 'data'});
        return call.method == 'protect'
            ? envelope((arguments['data'] as Uint8List).length)
            : Uint8List.fromList([7, 8]);
      });

      for (final (protector, purpose) in [
        (school, schoolPurpose),
        (model, modelPurpose),
        (model, deepseekPurpose),
      ]) {
        final input = Uint8List.fromList([7, 8]);
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
        expect(cipher, hasLength(31));
        expect(cipher.first, 1);
      }

      expect(calls.map((call) => call.method), [
        'protect',
        'unprotect',
        'protect',
        'unprotect',
        'protect',
        'unprotect',
      ]);
      expect(calls.map((call) => (call.arguments as Map)['purpose']), [
        schoolPurpose,
        schoolPurpose,
        modelPurpose,
        modelPurpose,
        deepseekPurpose,
        deepseekPurpose,
      ]);
      expect(school.mechanism, 'ios-keychain-aes-gcm-v1');
      expect(model.mechanism, school.mechanism);
    },
  );

  test('wrong typed purpose is rejected before native delivery', () async {
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
  });

  test('plaintext, envelope size, and version bounds fail locally', () async {
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
  });

  test(
    'missing native method reports unavailable without exposing plaintext',
    () async {
      final bytes = Uint8List.fromList([7, 8]);
      await expectLater(
        school.protect(bytes, purpose: schoolPurpose),
        jwFailure(JwCredentialFailure.unavailable),
      );
      await expectLater(
        school.unprotect(envelope(2), purpose: schoolPurpose),
        jwFailure(JwCredentialFailure.unavailable),
      );
      await expectLater(
        model.protect(bytes, purpose: modelPurpose),
        modelFailure,
      );
      expect(bytes, [7, 8]);
    },
  );

  test('platform error details stay outside typed failure messages', () async {
    for (final (nativeCode, expected) in [
      ('unavailable', JwCredentialFailure.unavailable),
      ('keychain_locked', JwCredentialFailure.invalidCredential),
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(
          code: nativeCode,
          message: 'synthetic-private-detail',
          details: {'value': 'synthetic-private-detail'},
        );
      });
      try {
        await school.unprotect(envelope(2), purpose: schoolPurpose);
        fail('Mock native rejection was accepted');
      } on JwCredentialException catch (error) {
        expect(error.code, expected);
        expect(error.toString(), isNot(contains('synthetic-private-detail')));
      }
    }
  });

  test('malformed native results never become accepted credentials', () async {
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
