import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/platform/windows_model_credential_protector.dart';

void main() {
  test(
    'DPAPI model purposes preserve both providers and reject cross-provider decryption',
    () async {
      const protector = WindowsModelCredentialProtector();
      final owner = 'jw-owner-${'a' * 32}';
      final schoolPurpose = ModelProvider.school.keyPurpose(owner);
      final officialPurpose = ModelProvider.deepseek.keyPurpose(owner);
      final plaintext = Uint8List.fromList('synthetic-dpapi-key'.codeUnits);
      final school = await protector.protect(plaintext, purpose: schoolPurpose);
      final official = await protector.protect(
        plaintext,
        purpose: officialPurpose,
      );
      final schoolBytes = await protector.unprotect(
        school,
        purpose: schoolPurpose,
      );
      final officialBytes = await protector.unprotect(
        official,
        purpose: officialPurpose,
      );
      expect(schoolBytes, plaintext);
      expect(officialBytes, plaintext);
      for (final (cipher, wrongPurpose) in [
        (school, officialPurpose),
        (official, schoolPurpose),
      ]) {
        await expectLater(
          protector.unprotect(cipher, purpose: wrongPurpose),
          throwsA(isA<AgentFailure>()),
        );
      }
      for (final purpose in [
        '$officialPurpose\n',
        '$officialPurpose/extra',
        'other-model-key/v1/$owner',
      ]) {
        await expectLater(
          protector.protect(plaintext, purpose: purpose),
          throwsA(isA<AgentFailure>()),
        );
      }
      for (final bytes in [plaintext, schoolBytes, officialBytes]) {
        bytes.fillRange(0, bytes.length, 0);
      }
    },
    skip: !Platform.isWindows ? 'Windows DPAPI only' : false,
  );
}
