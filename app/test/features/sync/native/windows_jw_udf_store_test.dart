import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/features/sync/native/windows_jw_udf_store.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ustc-jw-udf-store-');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('reference uses an opaque jw digest and never account text', () {
    final store = WindowsJwUdfStore(privateRoot: root);
    final ref = store.referenceFor('private-account');

    expect(ref.opaqueToken, matches(RegExp(r'^jw_[0-9a-f]{24}$')));
    expect(ref.opaqueToken, isNot(contains('private-account')));
    expect(ref.toString(), isNot(contains('private-account')));
  });

  test('ensure creates only the contained token partition', () async {
    final store = WindowsJwUdfStore(privateRoot: root);
    final ref = store.referenceFor('private-account');

    final partition = await store.ensurePartition(ref);

    expect(await partition.exists(), isTrue);
    expect(partition.path, contains(store.udfRoot.path));
    expect(partition.path, isNot(contains('private-account')));
  });

  test('root deletion is refused', () async {
    final store = WindowsJwUdfStore(privateRoot: root);

    await expectLater(
      store.deleteResolved(store.udfRoot),
      throwsA(isA<JwUdfPrivacyError>()),
    );
  });

  test('nested and non-token children are refused', () async {
    final store = WindowsJwUdfStore(privateRoot: root);
    final ref = store.referenceFor('private-account');
    final partition = await store.ensurePartition(ref);

    await expectLater(
      store.deleteResolved(
        Directory('${partition.path}${Platform.pathSeparator}nested'),
      ),
      throwsA(isA<JwUdfPrivacyError>()),
    );
    await expectLater(
      store.deleteResolved(
        Directory('${store.udfRoot.path}${Platform.pathSeparator}foreign'),
      ),
      throwsA(isA<JwUdfPrivacyError>()),
    );
  });

  test('invalid refs fail closed without echoing account or paths', () async {
    final store = WindowsJwUdfStore(privateRoot: root);
    const accountText = 'private-account';
    const invalid = JwSessionPartitionRef(accountText);

    Object? error;
    try {
      await store.ensurePartition(invalid);
    } on Object catch (caught) {
      error = caught;
    }

    expect(error, isA<JwUdfPrivacyError>());
    expect(error.toString(), isNot(contains(accountText)));
    expect(error.toString(), isNot(contains(root.path)));
  });

  test(
    'rejects a direct symlink partition without touching its target',
    () async {
      final store = WindowsJwUdfStore(privateRoot: root);
      final ref = store.referenceFor('private-account');
      final outside = await Directory.systemTemp.createTemp('ustc-jw-outside-');
      addTearDown(() async {
        if (await outside.exists()) {
          await outside.delete(recursive: true);
        }
      });
      await store.udfRoot.create(recursive: true);
      final link = Link(
        '${store.udfRoot.path}${Platform.pathSeparator}${ref.opaqueToken}',
      );
      await link.create(outside.path);

      await expectLater(
        store.clearPartition(ref),
        throwsA(isA<JwUdfPrivacyError>()),
      );
      expect(await outside.exists(), isTrue);
    },
    skip: !Platform.isWindows,
  );

  test(
    'transient Win32 5 and 32 errors retry within the configured bound',
    () async {
      final failures = <int>[32, 5];
      var attempts = 0;
      var delays = 0;
      final store = WindowsJwUdfStore(
        privateRoot: root,
        releaseAttempts: 3,
        releaseRetryDelay: Duration.zero,
        releaseDelay: (_) async {
          delays++;
        },
        deleteDirectory: (directory) async {
          attempts++;
          if (failures.isNotEmpty) {
            final code = failures.removeAt(0);
            throw FileSystemException(
              'transient release failure',
              directory.path,
              OSError('transient release failure', code),
            );
          }
          await directory.delete(recursive: true);
        },
      );
      final ref = store.referenceFor('private-account');
      await store.ensurePartition(ref);
      await store.markQuarantined(ref, 'collection_failed');

      await store.clearPartition(ref);

      expect(attempts, 3);
      expect(delays, 2);
      expect(await store.isQuarantined(ref), isFalse);
    },
  );

  test('unknown deletion errors are single-shot and safe', () async {
    var attempts = 0;
    final store = WindowsJwUdfStore(
      privateRoot: root,
      releaseAttempts: 20,
      releaseDelay: (_) async {},
      deleteDirectory: (directory) async {
        attempts++;
        throw FileSystemException(
          'unknown failure',
          directory.path,
          OSError('unknown failure', 1234),
        );
      },
    );
    final ref = store.referenceFor('private-account');
    await store.ensurePartition(ref);
    await store.markQuarantined(ref, 'collection_failed');

    Object? error;
    try {
      await store.clearPartition(ref);
    } on Object catch (caught) {
      error = caught;
    }

    expect(attempts, 1);
    expect(error, isA<JwUdfClearError>());
    expect((error! as JwUdfError).code, 'browser_cleanup_incomplete');
    expect(error.toString(), isNot(contains(root.path)));
    expect(error.toString(), isNot(contains('private-account')));
    expect(await store.isQuarantined(ref), isTrue);
  });

  test('quarantine marker is persistent and removed only after clear', () async {
    final first = WindowsJwUdfStore(privateRoot: root);
    final ref = first.referenceFor('private-account');
    await first.ensurePartition(ref);
    await first.markQuarantined(ref, 'collection_failed');

    final marker = File(
      '${first.quarantineRoot.path}${Platform.pathSeparator}${ref.opaqueToken}.json',
    );
    expect(await marker.exists(), isTrue);
    final markerText = await marker.readAsString();
    expect(jsonDecode(markerText), <String, Object?>{
      'version': 1,
      'partition': ref.opaqueToken,
      'reasonCode': 'collection_failed',
    });

    final restarted = WindowsJwUdfStore(privateRoot: root);
    expect(await restarted.isQuarantined(ref), isTrue);
    expect(
      restarted.quarantineRoot.listSync().where(
        (entry) => entry.path.endsWith('.tmp'),
      ),
      isEmpty,
    );

    await restarted.clearPartition(ref);
    expect(await restarted.isQuarantined(ref), isFalse);
    await restarted.clearPartition(ref);
  });

  test('failed clear retains the marker and a later clear can retry', () async {
    var shouldFail = true;
    final first = WindowsJwUdfStore(
      privateRoot: root,
      releaseAttempts: 1,
      deleteDirectory: (directory) async {
        if (shouldFail) {
          throw const FileSystemException('locked');
        }
        await directory.delete(recursive: true);
      },
    );
    final ref = first.referenceFor('private-account');
    await first.ensurePartition(ref);
    await first.markQuarantined(ref, 'collection_failed');

    await expectLater(
      first.clearPartition(ref),
      throwsA(isA<JwUdfClearError>()),
    );
    expect(await first.isQuarantined(ref), isTrue);

    shouldFail = false;
    await first.clearPartition(ref);
    expect(await first.isQuarantined(ref), isFalse);
  });

  test(
    'unknown direct entries fail clear-all before deleting owned entries',
    () async {
      final attempted = <String>[];
      final store = WindowsJwUdfStore(
        privateRoot: root,
        releaseAttempts: 1,
        deleteDirectory: (directory) async {
          attempted.add(directory.path);
          await directory.delete(recursive: true);
        },
      );
      final ref = store.referenceFor('private-account');
      await store.ensurePartition(ref);
      await File(
        '${store.udfRoot.path}${Platform.pathSeparator}not-owned',
      ).writeAsString('keep');

      await expectLater(
        store.clearAllPartitions(),
        throwsA(isA<JwUdfPrivacyError>()),
      );
      expect(attempted, isEmpty);
      expect(await store.resolveForTest(ref).exists(), isTrue);
    },
  );

  test('clear all removes new and recognized legacy partitions', () async {
    final store = WindowsJwUdfStore(privateRoot: root);
    final newRef = store.referenceFor('new-account');
    final newPartition = await store.ensurePartition(newRef);
    const legacyId = '550e8400-e29b-41d4-a716-446655440000';
    final legacy = Directory(
      '${root.path}${Platform.pathSeparator}webview'
      '${Platform.pathSeparator}$legacyId',
    );
    await legacy.create(recursive: true);

    await store.clearAllPartitions();

    expect(await newPartition.exists(), isFalse);
    expect(await legacy.exists(), isFalse);
  });

  test('unknown legacy entries fail clear-all before deleting owned entries', () async {
    final attempted = <String>[];
    final store = WindowsJwUdfStore(
      privateRoot: root,
      releaseAttempts: 1,
      deleteDirectory: (directory) async {
        attempted.add(directory.path);
        await directory.delete(recursive: true);
      },
    );
    final ref = store.referenceFor('new-account');
    await store.ensurePartition(ref);
    final legacyRoot = Directory(
      '${root.path}${Platform.pathSeparator}webview',
    );
    await legacyRoot.create(recursive: true);
    final unknown = Directory(
      '${legacyRoot.path}${Platform.pathSeparator}foreign-name',
    );
    await unknown.create();

    await expectLater(
      store.clearAllPartitions(),
      throwsA(isA<JwUdfPrivacyError>()),
    );
    expect(attempted, isEmpty);
    expect(await store.resolveForTest(ref).exists(), isTrue);
    expect(await unknown.exists(), isTrue);
  });

  test(
    'locked legacy first child still attempts later owned items and retries',
    () async {
      final attempted = <String>[];
      var shouldFail = true;
      final store = WindowsJwUdfStore(
        privateRoot: root,
        releaseAttempts: 1,
        releaseDelay: (_) async {},
        deleteDirectory: (directory) async {
          attempted.add(directory.path);
          if (shouldFail && attempted.length == 1) {
            throw const FileSystemException('locked');
          }
          await directory.delete(recursive: true);
        },
      );
      final newRef = store.referenceFor('new-account');
      final newPartition = await store.ensurePartition(newRef);
      const firstLegacyId = '550e8400-e29b-41d4-a716-446655440000';
      const secondLegacyId = '6ba7b810-9dad-41d1-80b4-00c04fd430c8';
      final legacyRoot = Directory(
        '${root.path}${Platform.pathSeparator}webview',
      );
      final firstLegacy = Directory(
        '${legacyRoot.path}${Platform.pathSeparator}$firstLegacyId',
      );
      final secondLegacy = Directory(
        '${legacyRoot.path}${Platform.pathSeparator}$secondLegacyId',
      );
      await firstLegacy.create(recursive: true);
      await secondLegacy.create(recursive: true);

      await expectLater(
        store.clearAllPartitions(),
        throwsA(isA<JwUdfClearError>()),
      );
      expect(attempted, hasLength(3));
      expect(attempted, contains(firstLegacy.path.toLowerCase()));
      expect(attempted, contains(secondLegacy.path.toLowerCase()));
      expect(attempted, contains(newPartition.path.toLowerCase()));

      shouldFail = false;
      await store.clearAllPartitions();
      expect(await firstLegacy.exists(), isFalse);
      expect(await secondLegacy.exists(), isFalse);
      expect(await newPartition.exists(), isFalse);
    },
  );

  test(
    'rejects a legacy direct symlink without touching its target',
    () async {
      final attempted = <String>[];
      final store = WindowsJwUdfStore(
        privateRoot: root,
        deleteDirectory: (directory) async {
          attempted.add(directory.path);
          await directory.delete(recursive: true);
        },
      );
      final outside = await Directory.systemTemp.createTemp(
        'ustc-jw-legacy-outside-',
      );
      addTearDown(() async {
        if (await outside.exists()) await outside.delete(recursive: true);
      });
      const legacyId = '550e8400-e29b-41d4-a716-446655440000';
      final legacyRoot = Directory(
        '${root.path}${Platform.pathSeparator}webview',
      );
      await legacyRoot.create(recursive: true);
      final link = Link(
        '${legacyRoot.path}${Platform.pathSeparator}$legacyId',
      );
      await link.create(outside.path);

      await expectLater(
        store.clearAllPartitions(),
        throwsA(isA<JwUdfPrivacyError>()),
      );
      expect(attempted, isEmpty);
      expect(await outside.exists(), isTrue);
    },
    skip: !Platform.isWindows,
  );

  test(
    'clear all attempts later partitions after the first deletion fails',
    () async {
      final attempted = <String>[];
      final store = WindowsJwUdfStore(
        privateRoot: root,
        deleteDirectory: (directory) async {
          attempted.add(directory.path);
          if (attempted.length == 1) {
            throw const FileSystemException('locked');
          }
          await directory.delete(recursive: true);
        },
        releaseDelay: (_) async {},
        releaseAttempts: 1,
      );
      await store.ensurePartition(store.referenceFor('private-account-a'));
      await store.ensurePartition(store.referenceFor('private-account-b'));

      await expectLater(
        store.clearAllPartitions(),
        throwsA(isA<JwUdfClearError>()),
      );
      expect(attempted, hasLength(2));
    },
  );

  test(
    'unknown quarantine reason is rejected without writing a marker',
    () async {
      final store = WindowsJwUdfStore(privateRoot: root);
      final ref = store.referenceFor('private-account');

      await expectLater(
        store.markQuarantined(ref, 'account=private-account'),
        throwsA(isA<JwUdfPrivacyError>()),
      );
      expect(await store.isQuarantined(ref), isFalse);
    },
  );

  test('clear all removes an orphan quarantine marker', () async {
    final store = WindowsJwUdfStore(privateRoot: root);
    final ref = store.referenceFor('orphan-account');
    final partition = await store.ensurePartition(ref);
    await store.markQuarantined(ref, 'collection_failed');
    await partition.delete(recursive: true);

    expect(await store.isQuarantined(ref), isTrue);
    await store.clearAllPartitions();

    expect(await store.isQuarantined(ref), isFalse);
  });

  test('unknown quarantine entries block every clear-all deletion', () async {
    final attempted = <String>[];
    final store = WindowsJwUdfStore(
      privateRoot: root,
      releaseAttempts: 1,
      deleteDirectory: (directory) async {
        attempted.add(directory.path);
        await directory.delete(recursive: true);
      },
    );
    final ref = store.referenceFor('quarantine-entry-account');
    await store.ensurePartition(ref);
    await store.quarantineRoot.create(recursive: true);
    await File(
      '${store.quarantineRoot.path}${Platform.pathSeparator}foreign-entry',
    ).writeAsString('keep');

    await expectLater(
      store.clearAllPartitions(),
      throwsA(isA<JwUdfPrivacyError>()),
    );
    expect(attempted, isEmpty);
    expect(await store.resolveForTest(ref).exists(), isTrue);
  });

  test('clear-all retries after a partial marker cleanup', () async {
    final store = WindowsJwUdfStore(privateRoot: root);
    final ref = store.referenceFor('partial-marker-account');
    final partition = await store.ensurePartition(ref);
    await store.markQuarantined(ref, 'collection_failed');
    final marker = File(
      '${store.quarantineRoot.path}${Platform.pathSeparator}${ref.opaqueToken}.json',
    );
    await marker.delete();
    final markerBlocker = Directory(marker.path);
    await markerBlocker.create();

    await expectLater(
      store.clearPartition(ref),
      throwsA(isA<JwUdfPrivacyError>()),
    );
    expect(await partition.exists(), isFalse);
    expect(await markerBlocker.exists(), isTrue);

    await markerBlocker.delete();
    await File(marker.path).writeAsString('{}');
    await store.clearAllPartitions();

    expect(await marker.exists(), isFalse);
  });
}
