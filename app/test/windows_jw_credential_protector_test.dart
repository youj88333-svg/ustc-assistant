import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/jw_credentials.dart';
import 'package:ustc_assistant_m0/platform/windows_jw_credential_protector.dart';

void main() {
  const protector = WindowsJwCredentialProtector();

  test('reports unavailable outside Windows', () async {
    await expectLater(
      protector.protect(Uint8List.fromList([1]), purpose: 'test'),
      throwsA(
        isA<JwCredentialException>()
            .having(
              (error) => error.code,
              'code',
              JwCredentialFailure.unavailable,
            )
            .having(
              (error) => error.toString(),
              'message',
              'JwCredentialException(unavailable)',
            ),
      ),
    );
    await expectLater(
      protector.unprotect(Uint8List.fromList([1]), purpose: 'test'),
      throwsA(
        isA<JwCredentialException>()
            .having(
              (error) => error.code,
              'code',
              JwCredentialFailure.unavailable,
            )
            .having(
              (error) => error.toString(),
              'message',
              'JwCredentialException(unavailable)',
            ),
      ),
    );
  }, skip: Platform.isWindows);

  group('Windows DPAPI', () {
    test(
      'round trips random bytes with the current-user mechanism',
      () async {
        final random = Random.secure();
        final input = Uint8List.fromList(
          List<int>.generate(512, (_) => random.nextInt(256)),
        );
        final protectorBytes = Uint8List.fromList(input);

        expect(protector.mechanism, 'dpapi-current-user-v1');
        final ciphertext = await protector.protect(
          protectorBytes,
          purpose: 'test:round-trip',
        );
        expect(protectorBytes, orderedEquals(input));
        expect(ciphertext, isNot(equals(protectorBytes)));
        final plaintext = await protector.unprotect(
          ciphertext,
          purpose: 'test:round-trip',
        );

        expect(plaintext, orderedEquals(input));
        expect(identical(plaintext, protectorBytes), isFalse);
        expect(identical(ciphertext, protectorBytes), isFalse);
      },
      skip: !Platform.isWindows,
    );

    test('rejects a wrong purpose and modified ciphertext', () async {
      final ciphertext = await protector.protect(
        Uint8List.fromList([17, 39, 91, 142, 203]),
        purpose: 'test:bound-purpose',
      );

      await expectLater(
        protector.unprotect(ciphertext, purpose: 'test:other-purpose'),
        throwsA(
          isA<JwCredentialException>()
              .having(
                (error) => error.code,
                'code',
                JwCredentialFailure.invalidCredential,
              )
              .having(
                (error) => error.toString(),
                'message',
                'JwCredentialException(invalidCredential)',
              ),
        ),
      );

      final changed = Uint8List.fromList(ciphertext);
      changed[changed.length ~/ 2] ^= 0x80;
      await expectLater(
        protector.unprotect(changed, purpose: 'test:bound-purpose'),
        throwsA(
          isA<JwCredentialException>()
              .having(
                (error) => error.code,
                'code',
                JwCredentialFailure.invalidCredential,
              )
              .having(
                (error) => error.toString(),
                'message',
                'JwCredentialException(invalidCredential)',
              ),
        ),
      );
    }, skip: !Platform.isWindows);

    test('accepts the plaintext and purpose limits', () async {
      final input = Uint8List.fromList(
        List<int>.generate(16 * 1024, (index) => index % 256),
      );
      final purpose = List.filled(256, 'x').join();
      final ciphertext = await protector.protect(input, purpose: purpose);
      final plaintext = await protector.unprotect(ciphertext, purpose: purpose);

      expect(plaintext, orderedEquals(input));
    }, skip: !Platform.isWindows);

    test(
      'rejects empty and oversized inputs with fixed safe errors',
      () async {
        final secretMarker = 'credential-marker-must-not-appear';
        final oversizedPlaintext = Uint8List.fromList(
          List<int>.filled(16 * 1024 + 1, secretMarker.codeUnitAt(0)),
        );
        final oversizedCiphertext = Uint8List(64 * 1024 + 1);

        Future<void> expectFixedError(
          Future<Uint8List> Function() operation,
          JwCredentialFailure expectedCode,
        ) async {
          try {
            await operation();
            fail('Expected a fixed credential error.');
          } on JwCredentialException catch (error) {
            expect(error.code, expectedCode);
            expect(error.toString(), isNot(contains(secretMarker)));
            expect(
              error.toString(),
              matches(RegExp(r'^JwCredentialException\([a-zA-Z]+\)$')),
            );
          }
        }

        await expectFixedError(
          () => protector.protect(Uint8List(0), purpose: 'safe'),
          JwCredentialFailure.protectionFailed,
        );
        await expectFixedError(
          () => protector.protect(oversizedPlaintext, purpose: 'safe'),
          JwCredentialFailure.protectionFailed,
        );
        await expectFixedError(
          () => protector.protect(
            Uint8List.fromList([1]),
            purpose: secretMarker + List.filled(257, 'p').join(),
          ),
          JwCredentialFailure.protectionFailed,
        );
        await expectFixedError(
          () => protector.protect(Uint8List.fromList([1]), purpose: ''),
          JwCredentialFailure.protectionFailed,
        );
        await expectFixedError(
          () => protector.unprotect(Uint8List(0), purpose: 'safe'),
          JwCredentialFailure.invalidCredential,
        );
        await expectFixedError(
          () => protector.unprotect(oversizedCiphertext, purpose: 'safe'),
          JwCredentialFailure.invalidCredential,
        );
        await expectFixedError(
          () => protector.unprotect(Uint8List.fromList([1]), purpose: ''),
          JwCredentialFailure.invalidCredential,
        );
        await expectFixedError(
          () => protector.unprotect(
            Uint8List.fromList([1]),
            purpose: List.filled(257, 'p').join(),
          ),
          JwCredentialFailure.invalidCredential,
        );
      },
      skip: !Platform.isWindows,
    );
  });
}
