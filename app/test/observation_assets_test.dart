import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/platform/demo_directory.dart';
import 'package:ustc_assistant_m0/platform/observation_assets.dart';

const _markerSuffix = '.pending';
const _testProfileId = 'obs-00000000000000000000000000000001';
const _syntheticContent = 'synthetic observation asset';

void main() {
  test(
    'inactive observer can close while the other source owns a profile',
    () async {
      for (final youngIsActive in [false, true]) {
        final harness = await _Harness.create();
        addTearDown(harness.dispose);
        final jw = ObservationAssets(harness.owner);
        final young = ObservationAssets.young(harness.owner);
        final active = youngIsActive ? young : jw;
        final idle = youngIsActive ? jw : young;
        final profile = await active.register();
        await idle.recoverPending(
          (_) async => fail('foreign profile was recovered'),
        );
        await idle.close();
        expect(await Directory(profile).exists(), true);
        await active.cleanup();
        await active.close();
      }
    },
  );

  test(
    'register retains its marker and restart drains before deletion',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final assets = ObservationAssets(harness.owner);
      final ledger = Directory(
        p.windows.join(harness.owner.path, 'observation_v1'),
      );
      await ledger.create(recursive: true);

      final profilePath = await assets.register();
      final id = p.windows.basename(profilePath);
      final marker = File(p.windows.join(ledger.path, '$id$_markerSuffix'));
      final staging = File(p.windows.join(ledger.path, '$id.registering'));
      final profileFile = File(p.windows.join(profilePath, 'synthetic.txt'));
      await profileFile.writeAsString(_syntheticContent, flush: true);

      expect(await marker.exists(), isTrue);
      expect(await staging.exists(), isFalse);
      expect(await Directory(profilePath).exists(), isTrue);

      var drainCalls = 0;
      final restartedAssets = ObservationAssets(harness.owner);
      await restartedAssets.recoverPending((recoveredPath) async {
        drainCalls++;
        expect(p.windows.equals(recoveredPath, profilePath), isTrue);
        expect(await marker.exists(), isTrue);
        expect(await Directory(recoveredPath).exists(), isTrue);
        expect(await profileFile.readAsString(), _syntheticContent);
      });

      expect(drainCalls, 1);
      expect(await marker.exists(), isFalse);
      expect(await Directory(profilePath).exists(), isFalse);
      await restartedAssets.close();
    },
  );

  test(
    'removes an interrupted registering file only when no profile exists',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final ledger = Directory(
        p.windows.join(harness.owner.path, 'observation_v1'),
      );
      await ledger.create(recursive: true);
      final staging = File(
        p.windows.join(ledger.path, '$_testProfileId.registering'),
      );
      await staging.writeAsString(
        'partial synthetic registration',
        flush: true,
      );
      var drainCalls = 0;

      await ObservationAssets(harness.owner).recoverPending((_) async {
        drainCalls++;
      });

      expect(drainCalls, 0);
      expect(await staging.exists(), isFalse);
    },
  );

  test('preserves a registering file if a profile exists for its ID', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final ledger = Directory(
      p.windows.join(harness.owner.path, 'observation_v1'),
    );
    final profile = Directory(p.windows.join(ledger.path, _testProfileId));
    await profile.create(recursive: true);
    final sentinel = File(p.windows.join(profile.path, 'keep.txt'));
    await sentinel.writeAsString(_syntheticContent, flush: true);
    final staging = File(
      p.windows.join(ledger.path, '$_testProfileId.registering'),
    );
    await staging.writeAsString('partial synthetic registration', flush: true);

    await expectLater(
      ObservationAssets(harness.owner).recoverPending((_) async {}),
      throwsA(_failure(FailureCode.unsafeDirectory)),
    );
    expect(await staging.exists(), isTrue);
    expect(await sentinel.readAsString(), _syntheticContent);
  });

  test(
    'preserves a registering file if a pending marker exists for its ID',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final ledger = Directory(
        p.windows.join(harness.owner.path, 'observation_v1'),
      );
      await ledger.create(recursive: true);
      final staging = File(
        p.windows.join(ledger.path, '$_testProfileId.registering'),
      );
      await staging.writeAsString(
        'partial synthetic registration',
        flush: true,
      );
      final marker = File(
        p.windows.join(ledger.path, '$_testProfileId$_markerSuffix'),
      );
      await _writeValidMarker(marker, _testProfileId);

      await expectLater(
        ObservationAssets(harness.owner).recoverPending((_) async {}),
        throwsA(_failure(FailureCode.unsafeDirectory)),
      );
      expect(await staging.exists(), isTrue);
      expect(await marker.exists(), isTrue);
    },
  );

  test(
    'drain failure retains marker, profile, and synthetic contents',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final assets = ObservationAssets(harness.owner);
      final profilePath = await assets.register();
      final id = p.windows.basename(profilePath);
      final marker = File(
        p.windows.join(
          harness.owner.path,
          'observation_v1',
          '$id$_markerSuffix',
        ),
      );
      final profileFile = File(p.windows.join(profilePath, 'synthetic.txt'));
      await profileFile.writeAsString(_syntheticContent, flush: true);

      final recoveringAssets = ObservationAssets(harness.owner);
      await expectLater(
        recoveringAssets.recoverPending((_) async {
          throw const AppFailure(FailureCode.cleanupPending);
        }),
        throwsA(_failure(FailureCode.cleanupPending)),
      );

      expect(await marker.exists(), isTrue);
      expect(await Directory(profilePath).exists(), isTrue);
      expect(await profileFile.readAsString(), _syntheticContent);
    },
  );

  test(
    'rejects unknown ledger directories without deleting their contents',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final ledger = Directory(
        p.windows.join(harness.owner.path, 'observation_v1'),
      );
      final unknown = Directory(p.windows.join(ledger.path, 'unregistered'));
      await unknown.create(recursive: true);
      final sentinel = File(p.windows.join(unknown.path, 'keep.txt'));
      await sentinel.writeAsString(_syntheticContent, flush: true);

      await expectLater(
        ObservationAssets(harness.owner).recoverPending((_) async {}),
        throwsA(_failure(FailureCode.unsafeDirectory)),
      );
      expect(await sentinel.readAsString(), _syntheticContent);
    },
  );

  test(
    'rejects an orphan profile without deleting it or draining it',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final ledger = Directory(
        p.windows.join(harness.owner.path, 'observation_v1'),
      );
      final profile = Directory(p.windows.join(ledger.path, _testProfileId));
      await profile.create(recursive: true);
      final sentinel = File(p.windows.join(profile.path, 'keep.txt'));
      await sentinel.writeAsString(_syntheticContent, flush: true);
      var drainCalls = 0;

      await expectLater(
        ObservationAssets(harness.owner).recoverPending((_) async {
          drainCalls++;
        }),
        throwsA(_failure(FailureCode.unsafeDirectory)),
      );
      expect(drainCalls, 0);
      expect(await sentinel.readAsString(), _syntheticContent);
    },
  );

  test(
    'rejects a corrupt marker before deleting its registered profile',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final ledger = Directory(
        p.windows.join(harness.owner.path, 'observation_v1'),
      );
      final profile = Directory(p.windows.join(ledger.path, _testProfileId));
      await profile.create(recursive: true);
      final sentinel = File(p.windows.join(profile.path, 'keep.txt'));
      await sentinel.writeAsString(_syntheticContent, flush: true);
      final marker = File(
        p.windows.join(ledger.path, '$_testProfileId$_markerSuffix'),
      );
      await marker.writeAsString('{broken marker', flush: true);
      var drainCalls = 0;

      await expectLater(
        ObservationAssets(harness.owner).recoverPending((_) async {
          drainCalls++;
        }),
        throwsA(_failure(FailureCode.unsafeDirectory)),
      );
      expect(drainCalls, 0);
      expect(await marker.readAsString(), '{broken marker');
      expect(await sentinel.readAsString(), _syntheticContent);
    },
  );

  test(
    'rejects a static junction before deleting the profile or its target',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final ledger = Directory(
        p.windows.join(harness.owner.path, 'observation_v1'),
      );
      final profilePath = p.windows.join(ledger.path, _testProfileId);
      final profile = Directory(profilePath);
      await profile.create(recursive: true);
      final target = Directory(
        p.windows.join(harness.root.path, 'junction-target'),
      );
      await target.create();
      final targetFile = File(p.windows.join(target.path, 'keep.txt'));
      await targetFile.writeAsString(_syntheticContent, flush: true);
      final junctionPath = p.windows.join(profilePath, 'static-junction');
      await _createJunction(junctionPath, target.path);
      harness.trackLink(junctionPath);
      final marker = File(
        p.windows.join(ledger.path, '$_testProfileId$_markerSuffix'),
      );
      await _writeValidMarker(marker, _testProfileId);
      final profileFile = File(p.windows.join(profilePath, 'keep.txt'));
      await profileFile.writeAsString(_syntheticContent, flush: true);

      await expectLater(
        ObservationAssets(harness.owner).recoverPending((_) async {}),
        throwsA(_failure(FailureCode.unsafeDirectory)),
      );
      expect(await marker.exists(), isTrue);
      expect(await profileFile.readAsString(), _syntheticContent);
      expect(await targetFile.readAsString(), _syntheticContent);
    },
  );

  test(
    'assets.close refuses to delete an active profile without a drain',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final assets = ObservationAssets(harness.owner);
      final profilePath = await assets.register();
      final id = p.windows.basename(profilePath);
      final marker = File(
        p.windows.join(
          harness.owner.path,
          'observation_v1',
          '$id$_markerSuffix',
        ),
      );
      final sentinel = File(p.windows.join(profilePath, 'synthetic.txt'));
      await sentinel.writeAsString(_syntheticContent, flush: true);

      await expectLater(
        assets.close(),
        throwsA(_failure(FailureCode.cleanupPending)),
      );
      expect(await marker.exists(), isTrue);
      expect(await Directory(profilePath).exists(), isTrue);
      expect(await sentinel.readAsString(), _syntheticContent);
    },
  );

  test(
    'rejects operations after DemoDirectory ownership is released',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      await harness.owner.release();
      final assets = ObservationAssets(harness.owner);

      await expectLater(
        assets.register(),
        throwsA(_failure(FailureCode.ownershipLost)),
      );
      expect(
        await Directory(
          p.windows.join(harness.owner.path, 'observation_v1'),
        ).exists(),
        isFalse,
      );
    },
  );
}

Matcher _failure(FailureCode code) =>
    isA<AppFailure>().having((failure) => failure.code, 'code', code);

Future<void> _writeValidMarker(File marker, String id) async {
  await marker.writeAsString(
    jsonEncode({
      'version': 1,
      'purpose': 'observation-delete-pending',
      'id': id,
    }),
    flush: true,
  );
}

Future<void> _createJunction(String junctionPath, String targetPath) async {
  String literal(String value) => "'${value.replaceAll("'", "''")}'";
  final result = await Process.run('powershell.exe', [
    '-NoLogo',
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    'New-Item -ItemType Junction -Path ${literal(junctionPath)} '
        '-Target ${literal(targetPath)} | Out-Null',
  ]);
  expect(
    result.exitCode,
    0,
    reason: 'Unable to create a test-only junction: ${result.stderr}',
  );
}

final class _Harness {
  _Harness(this.root, this.owner);

  final Directory root;
  final DemoDirectory owner;
  final List<String> _links = [];

  static Future<_Harness> create() async {
    final root = await Directory.systemTemp.createTemp('ustc_m1_observation_');
    final ownerPath = p.windows.join(root.path, 'owner');
    final owner = await DemoDirectory.acquire(ownerPath);
    return _Harness(root, owner);
  }

  void trackLink(String path) => _links.add(path);

  Future<void> dispose() async {
    for (final path in _links) {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        await Link(path).delete();
      } else if (type == FileSystemEntityType.directory) {
        await Directory(path).delete();
      }
    }
    await owner.release();

    final tempRoot = p.windows.normalize(
      await Directory.systemTemp.resolveSymbolicLinks(),
    );
    final resolvedRoot = p.windows.normalize(await root.resolveSymbolicLinks());
    if (p.windows.equals(tempRoot, resolvedRoot) ||
        !p.windows.isWithin(tempRoot, resolvedRoot)) {
      throw StateError(
        'Refusing to delete a path outside the test temp scope.',
      );
    }
    await Directory(resolvedRoot).delete(recursive: true);
  }
}
