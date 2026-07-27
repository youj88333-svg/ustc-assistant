import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/security/credential_protector.dart';
import 'package:ustc_assistant_app/features/accounts/application/account_service.dart';
import 'package:ustc_assistant_app/features/import/data/source_bundle_decoder.dart';
import 'package:ustc_assistant_app/features/import/domain/import_result.dart';
import 'package:ustc_assistant_app/features/import/presentation/file_import_action.dart';

class FakeProtector implements CredentialProtector {
  @override
  Future<ProtectedSecret> protect(Uint8List plaintext) async => ProtectedSecret(
    bytes: Uint8List.fromList(plaintext),
    scheme: 'fake',
    version: 1,
  );

  @override
  Future<Uint8List> unprotect(ProtectedSecret protected) async =>
      Uint8List.fromList(protected.bytes);
}

class FakePicker implements ImportFilePicker {
  FakePicker(this.candidate);

  final ImportFileCandidate? candidate;

  @override
  Future<ImportFileCandidate?> pickJson() async => candidate;
}

void main() {
  late AppDatabase database;
  late AccountService accounts;
  late String accountId;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    accounts = AccountService(database: database, protector: FakeProtector());
    accountId = await accounts.persistVerifiedAccount(username: 'PB00000000');
  });
  tearDown(() => database.close());

  test(
    'active account is preselected but requires explicit confirmation',
    () async {
      var confirmations = 0;
      String? preselected;
      final action = FileImportAction(
        accounts: accounts,
        picker: FakePicker(
          ImportFileCandidate(
            name: 'bundle.json',
            length: 2,
            readBytes: () async => Uint8List.fromList([123, 125]),
          ),
        ),
        confirmTarget: (choices, initial) async {
          confirmations++;
          preselected = initial;
          return accountId;
        },
        importBundle: (bytes, {required accountId, required origin}) async {
          expect(origin, ImportOrigin.file);
          return const ImportResult(
            status: ImportStatus.imported,
            bundleId: 'bundle',
            source: 'ustc_jw',
            importedEntityCount: 1,
          );
        },
      );

      expect(await action.run(), isA<FileImportCompleted>());
      expect(confirmations, 1);
      expect(preselected, accountId);
    },
  );

  test('oversized file is rejected before reading or confirmation', () async {
    var read = false;
    var confirmed = false;
    final action = FileImportAction(
      accounts: accounts,
      picker: FakePicker(
        ImportFileCandidate(
          name: 'large.json',
          length: SourceBundleDecoder.maxBundleBytes + 1,
          readBytes: () async {
            read = true;
            return Uint8List(0);
          },
        ),
      ),
      confirmTarget: (_, _) async {
        confirmed = true;
        return accountId;
      },
      importBundle: (bytes, {required accountId, required origin}) async =>
          throw StateError('must not import'),
    );

    final outcome = await action.run();
    expect(outcome, isA<FileImportRejected>());
    expect((outcome as FileImportRejected).code, 'limit_exceeded');
    expect(read, isFalse);
    expect(confirmed, isFalse);
  });

  test('cancelled target selection never reads or imports', () async {
    var read = false;
    final action = FileImportAction(
      accounts: accounts,
      picker: FakePicker(
        ImportFileCandidate(
          name: 'bundle.json',
          length: 2,
          readBytes: () async {
            read = true;
            return Uint8List(2);
          },
        ),
      ),
      confirmTarget: (_, _) async => null,
      importBundle: (bytes, {required accountId, required origin}) async =>
          throw StateError('must not import'),
    );

    expect(await action.run(), isA<FileImportCancelled>());
    expect(read, isFalse);
  });
}
