import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/security/windows_dpapi_protector.dart';
import 'package:ustc_assistant_app/core/security/credential_protector.dart';

void main() {
  test('DPAPI round trip does not persist plaintext', () async {
    if (!Platform.isWindows) return;
    final protector = WindowsDpapiProtector();
    final protected = await protector.protect(
      Uint8List.fromList(utf8.encode('PB00000000')),
    );
    expect(protected.scheme, 'windows-dpapi-current-user');
    expect(protected.version, 1);
    expect(
      utf8.decode(protected.bytes, allowMalformed: true),
      isNot(contains('PB00000000')),
    );
    expect(utf8.decode(await protector.unprotect(protected)), 'PB00000000');
  });

  test('unsupported protection metadata is rejected safely', () async {
    if (!Platform.isWindows) return;
    final protector = WindowsDpapiProtector();
    expect(
      protector.unprotect(
        ProtectedSecret(
          bytes: Uint8List.fromList([1]),
          scheme: 'unknown',
          version: 9,
        ),
      ),
      throwsA(isA<CredentialProtectionException>()),
    );
  });
}
