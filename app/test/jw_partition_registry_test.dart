import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/jw_work_contract.dart';
import 'package:ustc_assistant_m0/platform/demo_directory.dart';
import 'package:ustc_assistant_m0/platform/jw_partition_registry.dart';

const _ownerId = 'jw-owner-00000000000000000000000000000001';
const _otherOwner = 'jw-owner-00000000000000000000000000000002';
const _orphanId = 'jwp-00000000000000000000000000000001';

void main() {
  test(
    'new registries require reconciliation before allocating assets',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final registry = JwPartitionRegistry(h.owner);
      await expectLater(
        _create(registry),
        throwsA(_failure(FailureCode.cleanupPending)),
      );
      expect(await h.ledger.exists(), isFalse);
    },
  );

  test(
    'registration is durable and an uncommitted restart drains then deletes',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final registry = await h.ready();
      final ref = await _create(registry);
      final path = registry.profilePath(ref);
      final marker = h.marker(ref);
      final contents = jsonDecode(await marker.readAsString()) as Map;
      expect(contents['partition'], ref.metadata);
      expect(contents['state'], 'provisional');
      expect(await Directory(path).exists(), isTrue);
      expect(
        await File(
          '${marker.path.replaceFirst('.json', '')}.registering',
        ).exists(),
        isFalse,
      );

      var drains = 0;
      final restarted = JwPartitionRegistry(h.owner);
      final retained = await restarted.reconcile(
        [],
        ownerId: _ownerId,
        resetEpoch: 0,
        drain: (recovered) async {
          drains++;
          expect(p.windows.equals(recovered, path), isTrue);
          expect(
            (jsonDecode(await marker.readAsString()) as Map)['state'],
            'deletePending',
          );
          expect(await Directory(recovered).exists(), isTrue);
        },
      );
      expect(drains, 1);
      expect(retained, isEmpty);
      expect(await marker.exists(), isFalse);
      expect(await Directory(path).exists(), isFalse);
      await restarted.close();
      await restarted.close();
    },
  );

  test(
    'a specific committed permit recovers and preserves its claimed profile',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final initial = await h.ready();
      final ref = await _create(initial);
      final permit = JwClaimPermit(partition: ref, accountId: 1);
      final restarted = JwPartitionRegistry(h.owner);
      final retained = await restarted.reconcile(
        [permit],
        ownerId: _ownerId,
        resetEpoch: 0,
        drain: (_) async => fail('Claimed assets must be preserved.'),
      );
      expect(retained.single.sameAs(ref), isTrue);
      await restarted.claim(ref, permit); // Idempotent after crash recovery.
      final path = await restarted.openClaimed(
        permit,
        ownerId: _ownerId,
        resetEpoch: 0,
      );
      await restarted.close();
      expect(await Directory(path).exists(), isTrue);
      expect(await h.marker(ref).exists(), isTrue);
      await expectLater(
        restarted.openClaimed(permit, ownerId: _ownerId, resetEpoch: 0),
        throwsA(_failure(FailureCode.closed)),
      );
    },
  );

  for (final mismatch in [
    'missing',
    'owner',
    'attempt',
    'epoch',
    'partition',
    'account',
    'otherAccount',
  ]) {
    test('claimed restart rejects a $mismatch permit before reuse', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final initial = await h.ready();
      final ref = await _create(initial);
      await initial.claim(ref, JwClaimPermit(partition: ref, accountId: 1));
      final wrong = JwPartitionRef(
        id: mismatch == 'partition' ? _orphanId : ref.id,
        ownerId: mismatch == 'owner' ? _otherOwner : ref.ownerId,
        purpose: ref.purpose,
        attempt: mismatch == 'attempt' ? 'jw-2-1' : ref.attempt,
        resetEpoch: mismatch == 'epoch' ? 1 : ref.resetEpoch,
      );
      var drains = 0;
      final restarted = JwPartitionRegistry(h.owner);
      final result = await restarted.reconcile(
        mismatch == 'missing'
            ? []
            : [
                JwClaimPermit(
                  partition: wrong,
                  accountId: mismatch == 'account'
                      ? 0
                      : mismatch == 'otherAccount'
                      ? 2
                      : 1,
                ),
              ],
        ownerId: _ownerId,
        resetEpoch: 0,
        drain: (_) async {
          drains++;
          expect(
            (jsonDecode(await h.marker(ref).readAsString()) as Map)['state'],
            'deletePending',
          );
        },
      );
      expect(result, isEmpty);
      expect(drains, 1);
      expect(await h.marker(ref).exists(), isFalse);
    });
  }

  test(
    'current authority epoch and owner guard even an otherwise exact permit',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final registry = await h.ready();
      final ref = await _create(registry);
      final permit = JwClaimPermit(partition: ref, accountId: 1);
      await registry.claim(ref, permit);
      await expectLater(
        registry.openClaimed(permit, ownerId: _otherOwner, resetEpoch: 0),
        throwsA(_failure(FailureCode.staleResult)),
      );
      await expectLater(
        registry.openClaimed(permit, ownerId: _ownerId, resetEpoch: 1),
        throwsA(_failure(FailureCode.staleResult)),
      );
      final restarted = JwPartitionRegistry(h.owner);
      expect(
        await restarted.reconcile(
          [permit],
          ownerId: _ownerId,
          resetEpoch: 1,
          drain: (_) async {},
        ),
        isEmpty,
      );
      expect(await h.marker(ref).exists(), isFalse);
    },
  );

  test(
    'failed drain keeps deletion pending and blocks every reuse path',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final initial = await h.ready();
      final ref = await _create(initial);
      final permit = JwClaimPermit(partition: ref, accountId: 1);
      await initial.claim(ref, permit);
      final path = initial.profilePath(ref);
      await initial.markDeletePending(ref);
      final restarted = JwPartitionRegistry(h.owner);
      await expectLater(
        restarted.reconcile(
          [permit],
          ownerId: _ownerId,
          resetEpoch: 0,
          drain: (_) async =>
              throw const AppFailure(FailureCode.cleanupPending),
        ),
        throwsA(_failure(FailureCode.cleanupPending)),
      );
      expect(await Directory(path).exists(), isTrue);
      expect(await h.marker(ref).exists(), isTrue);
      await expectLater(
        _create(restarted),
        throwsA(_failure(FailureCode.cleanupPending)),
      );
      await expectLater(
        restarted.claim(ref, permit),
        throwsA(_failure(FailureCode.cleanupPending)),
      );
      await expectLater(
        restarted.openClaimed(permit, ownerId: _ownerId, resetEpoch: 0),
        throwsA(_failure(FailureCode.cleanupPending)),
      );
      await expectLater(
        restarted.close(),
        throwsA(_failure(FailureCode.cleanupPending)),
      );
      expect(
        await restarted.reconcile(
          [permit],
          ownerId: _ownerId,
          resetEpoch: 0,
          drain: (_) async {},
        ),
        isEmpty,
      );
      expect(await Directory(path).exists(), isFalse);
      final recovery = await _create(
        restarted,
        purpose: JwPartitionPurpose.recovery,
      );
      expect(recovery.id, isNot(ref.id));
      await restarted.clear(recovery, (_) async {});
      await restarted.close();
    },
  );

  test(
    'claim matches all five metadata fields and only one candidate is allocated',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final registry = await h.ready();
      final ref = await _create(registry);
      final wrong = JwPartitionRef(
        id: ref.id,
        ownerId: ref.ownerId,
        purpose: JwPartitionPurpose.recovery,
        attempt: ref.attempt,
        resetEpoch: ref.resetEpoch,
      );
      await expectLater(
        registry.claim(ref, JwClaimPermit(partition: wrong, accountId: 1)),
        throwsA(_failure(FailureCode.staleResult)),
      );
      await expectLater(_create(registry), throwsA(_failure(FailureCode.busy)));
      await expectLater(
        registry.close(),
        throwsA(_failure(FailureCode.cleanupPending)),
      );
      await registry.clear(ref, (_) async {});
      await registry.close();
    },
  );

  test(
    'complete staged deletion is replayed before a matching permit is considered',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final initial = await h.ready();
      final ref = await _create(initial);
      final permit = JwClaimPermit(partition: ref, accountId: 1);
      await initial.claim(ref, permit);
      final update = h.update(ref);
      final value =
          jsonDecode(await h.marker(ref).readAsString())
              as Map<String, dynamic>;
      value['state'] = 'deletePending';
      await update.writeAsString(jsonEncode(value), flush: true);
      var drains = 0;
      final restarted = JwPartitionRegistry(h.owner);
      expect(
        await restarted.reconcile(
          [permit],
          ownerId: _ownerId,
          resetEpoch: 0,
          drain: (_) async {
            drains++;
            expect(await update.exists(), isFalse);
            expect(
              (jsonDecode(await h.marker(ref).readAsString()) as Map)['state'],
              'deletePending',
            );
          },
        ),
        isEmpty,
      );
      expect(drains, 1);
    },
  );

  test(
    'complete staged claim is recovered using its committed permit',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final initial = await h.ready();
      final ref = await _create(initial);
      final permit = JwClaimPermit(partition: ref, accountId: 1);
      final value = jsonDecode(await h.marker(ref).readAsString()) as Map;
      value['state'] = 'claimed';
      await h.update(ref).writeAsString(jsonEncode(value), flush: true);
      final restarted = JwPartitionRegistry(h.owner);
      expect(
        (await restarted.reconcile(
          [permit],
          ownerId: _ownerId,
          resetEpoch: 0,
          drain: (_) async => fail('A committed claim must be kept.'),
        )).single.sameAs(ref),
        isTrue,
      );
      expect(await h.update(ref).exists(), isFalse);
      expect(
        (jsonDecode(await h.marker(ref).readAsString()) as Map)['state'],
        'claimed',
      );
      await restarted.close();
    },
  );

  for (final problem in [
    'incompleteUpdate',
    'wrongUpdate',
    'downgrade',
    'orphan',
    'unknown',
    'corrupt',
  ]) {
    test(
      '$problem rejects the entire ledger before any drain or deletion',
      () async {
        final h = await _Harness.create();
        addTearDown(h.dispose);
        final initial = await h.ready();
        final ref = await _create(initial);
        final path = initial.profilePath(ref);
        if (problem == 'incompleteUpdate') {
          await h.update(ref).writeAsString('{', flush: true);
        } else if (problem == 'wrongUpdate') {
          final value = jsonDecode(await h.marker(ref).readAsString()) as Map;
          (value['partition'] as Map)['attempt'] = 'jw-2-1';
          value['state'] = 'deletePending';
          await h.update(ref).writeAsString(jsonEncode(value), flush: true);
        } else if (problem == 'downgrade') {
          await initial.claim(ref, JwClaimPermit(partition: ref, accountId: 1));
          final value = jsonDecode(await h.marker(ref).readAsString()) as Map;
          value['state'] = 'provisional';
          await h.update(ref).writeAsString(jsonEncode(value), flush: true);
        } else if (problem == 'orphan') {
          await Directory(p.windows.join(h.ledger.path, _orphanId)).create();
        } else if (problem == 'unknown') {
          await Directory(p.windows.join(h.ledger.path, 'unknown')).create();
        } else {
          await h.marker(ref).writeAsString('{}', flush: true);
        }
        final restarted = JwPartitionRegistry(h.owner);
        await expectLater(
          restarted.reconcile(
            [],
            ownerId: _ownerId,
            resetEpoch: 0,
            drain: (_) async =>
                fail('Invalid ledger must be checked before draining.'),
          ),
          throwsA(_failure(FailureCode.unsafeDirectory)),
        );
        expect(await h.marker(ref).exists(), isTrue);
        expect(await Directory(path).exists(), isTrue);
      },
    );
  }

  test(
    'an interrupted registration with no profile can be discarded',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      await h.ledger.create(recursive: true);
      final staging = File(
        p.windows.join(h.ledger.path, '$_orphanId.registering'),
      );
      await staging.writeAsString('interrupted local metadata', flush: true);
      await h.ready();
      expect(await staging.exists(), isFalse);
    },
  );

  test(
    'registry operations serialize while native cleanup is draining',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final registry = await h.ready();
      final ref = await _create(registry);
      final entered = Completer<void>();
      final drained = Completer<void>();
      final clearing = registry.clear(ref, (_) async {
        entered.complete();
        await drained.future;
      });
      await entered.future;
      await expectLater(_create(registry), throwsA(_failure(FailureCode.busy)));
      drained.complete();
      await clearing;
      await registry.close();
    },
  );

  test(
    'released process ownership prevents access to the ledger and profile',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final registry = await h.ready();
      final ref = await _create(registry);
      await h.owner.release();
      await expectLater(
        registry.clear(ref, (_) async {}),
        throwsA(_failure(FailureCode.ownershipLost)),
      );
      expect(
        () => registry.profilePath(ref),
        throwsA(_failure(FailureCode.ownershipLost)),
      );
      expect(await h.marker(ref).exists(), isTrue);
    },
  );

  test(
    'static profile junctions are rejected before native recovery and deletion',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final registry = await h.ready();
      final ref = await _create(registry);
      final path = registry.profilePath(ref);
      final target = await Directory(
        p.windows.join(h.root.path, 'junction-target'),
      ).create();
      final sentinel = File(p.windows.join(target.path, 'synthetic.txt'));
      await sentinel.writeAsString('local test data', flush: true);
      final junction = p.windows.join(path, 'static-junction');
      String literal(String value) => "'${value.replaceAll("'", "''")}'";
      final created = await Process.run('powershell.exe', [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'New-Item -ItemType Junction -Path ${literal(junction)} '
            '-Target ${literal(target.path)} | Out-Null',
      ]);
      expect(
        created.exitCode,
        0,
        reason: 'Could not create the test junction.',
      );
      h.links.add(junction);
      await expectLater(
        registry.clear(
          ref,
          (_) async => fail('A junction must block recovery.'),
        ),
        throwsA(_failure(FailureCode.unsafeDirectory)),
      );
      expect(await sentinel.exists(), isTrue);
      expect(await h.marker(ref).exists(), isTrue);
      expect(
        (jsonDecode(await h.marker(ref).readAsString()) as Map)['state'],
        'deletePending',
      );
    },
  );

  for (final state in ['provisional', 'claimed']) {
    test(
      'a $state profile junction blocks claim, opening and startup reuse',
      () async {
        final h = await _Harness.create();
        addTearDown(h.dispose);
        final registry = await h.ready();
        final ref = await _create(registry);
        final permit = JwClaimPermit(partition: ref, accountId: 1);
        final path = registry.profilePath(ref);
        if (state == 'claimed') await registry.claim(ref, permit);
        final target = await Directory(
          p.windows.join(h.root.path, 'junction-target'),
        ).create();
        final sentinel = File(p.windows.join(target.path, 'synthetic.txt'));
        await sentinel.writeAsString('local test data', flush: true);
        final junction = p.windows.join(path, 'static-junction');
        String literal(String value) => "'${value.replaceAll("'", "''")}'";
        final created = await Process.run('powershell.exe', [
          '-NoLogo',
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          'New-Item -ItemType Junction -Path ${literal(junction)} '
              '-Target ${literal(target.path)} | Out-Null',
        ]);
        expect(
          created.exitCode,
          0,
          reason: 'Could not create the test junction.',
        );
        h.links.add(junction);
        await expectLater(
          registry.claim(ref, permit),
          throwsA(_failure(FailureCode.unsafeDirectory)),
        );
        if (state == 'claimed') {
          await expectLater(
            registry.openClaimed(permit, ownerId: _ownerId, resetEpoch: 0),
            throwsA(_failure(FailureCode.unsafeDirectory)),
          );
        }
        final restarted = JwPartitionRegistry(h.owner);
        await expectLater(
          restarted.reconcile(
            [permit],
            ownerId: _ownerId,
            resetEpoch: 0,
            drain: (_) async =>
                fail('A matching permit must not bypass metadata guards.'),
          ),
          throwsA(_failure(FailureCode.unsafeDirectory)),
        );
        await expectLater(
          _create(restarted),
          throwsA(_failure(FailureCode.cleanupPending)),
        );
        expect(await sentinel.exists(), isTrue);
        expect(
          (jsonDecode(await h.marker(ref).readAsString()) as Map)['state'],
          state,
        );
      },
    );
  }
}

Future<JwPartitionRef> _create(
  JwPartitionRegistry registry, {
  JwPartitionPurpose purpose = JwPartitionPurpose.initial,
}) => registry.createProvisional(
  ownerId: _ownerId,
  purpose: purpose,
  attempt: 'jw-1-1',
  resetEpoch: 0,
);

Matcher _failure(FailureCode code) =>
    isA<AppFailure>().having((value) => value.code, 'code', code);

final class _Harness {
  _Harness(this.root, this.owner);
  final Directory root;
  final DemoDirectory owner;
  final links = <String>[];
  Directory get ledger =>
      Directory(p.windows.join(owner.path, 'jw_partitions_v1'));
  File marker(JwPartitionRef ref) =>
      File(p.windows.join(ledger.path, '${ref.id}.json'));
  File update(JwPartitionRef ref) =>
      File(p.windows.join(ledger.path, '${ref.id}.updating'));

  static Future<_Harness> create() async {
    final root = await Directory.systemTemp.createTemp('ustc_jw_registry_');
    return _Harness(
      root,
      await DemoDirectory.acquire(p.windows.join(root.path, 'owner')),
    );
  }

  Future<JwPartitionRegistry> ready() async {
    final registry = JwPartitionRegistry(owner);
    await registry.reconcile(
      [],
      ownerId: _ownerId,
      resetEpoch: 0,
      drain: (_) async {},
    );
    return registry;
  }

  Future<void> dispose() async {
    for (final link in links) {
      final type = await FileSystemEntity.type(link, followLinks: false);
      if (type == FileSystemEntityType.link) {
        await Link(link).delete();
      } else if (type == FileSystemEntityType.directory) {
        await Directory(link).delete();
      }
    }
    await owner.release();
    final temp = p.windows.normalize(
      await Directory.systemTemp.resolveSymbolicLinks(),
    );
    final target = p.windows.normalize(await root.resolveSymbolicLinks());
    if (!p.windows.isWithin(temp, target)) {
      throw StateError('Test cleanup path escaped its temporary root.');
    }
    await Directory(target).delete(recursive: true);
  }
}
