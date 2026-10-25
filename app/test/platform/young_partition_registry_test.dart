import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/young_work_contract.dart';
import 'package:ustc_assistant_m0/platform/demo_directory.dart';
import 'package:ustc_assistant_m0/platform/young_partition_registry.dart';

const String _ownerId = 'jw-owner-00000000000000000000000000000001';
const String _otherOwner = 'jw-owner-00000000000000000000000000000002';

void main() {
  test(
    'Young registry requires reconciliation and touches only its root',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);

      final jwRoot = Directory(
        p.windows.join(harness.owner.path, 'jw_partitions_v1'),
      );
      await jwRoot.create(recursive: true);
      final jwSentinel = File(
        p.windows.join(jwRoot.path, 'synthetic-jw-sentinel'),
      );
      await jwSentinel.writeAsString('SYNTHETIC_JW_SENTINEL', flush: true);
      final observationRoot = Directory(
        p.windows.join(harness.owner.path, 'young_observation_v1'),
      );
      await observationRoot.create(recursive: true);
      final observationSentinel = File(
        p.windows.join(observationRoot.path, 'synthetic-observation-sentinel'),
      );
      await observationSentinel.writeAsString(
        'SYNTHETIC_OBSERVATION_SENTINEL',
        flush: true,
      );

      final registry = YoungPartitionRegistry(harness.owner);
      await expectLater(
        _create(registry),
        throwsA(_failure(FailureCode.cleanupPending)),
      );
      expect(await harness.ledger.exists(), isFalse);
      await registry.reconcile(
        const <YoungClaimPermit>[],
        ownerId: _ownerId,
        resetEpoch: 0,
        drain: (_) async {},
      );
      expect(await jwSentinel.readAsString(), 'SYNTHETIC_JW_SENTINEL');
      expect(
        await observationSentinel.readAsString(),
        'SYNTHETIC_OBSERVATION_SENTINEL',
      );
      expect(await harness.ledger.exists(), isTrue);
      await registry.close();
    },
  );

  test(
    'a provisional partition without a permit is drained and removed',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final registry = await harness.ready();
      final ref = await _create(registry);
      final path = registry.profilePath(ref);
      final marker = harness.marker(ref);
      expect(ref.id, matches(RegExp(r'^yp-[0-9a-f]{32}$')));
      expect(ref.attempt, 'young-1-1');
      expect(await Directory(path).exists(), isTrue);
      final metadata = jsonDecode(await marker.readAsString()) as Map;
      expect(metadata['purpose'], 'young-partition-ledger');
      expect((metadata['partition'] as Map)['ownerId'], _ownerId);

      var drains = 0;
      final restarted = YoungPartitionRegistry(harness.owner);
      final retained = await restarted.reconcile(
        const <YoungClaimPermit>[],
        ownerId: _ownerId,
        resetEpoch: 0,
        drain: (profilePath) async {
          drains++;
          expect(p.windows.equals(profilePath, path), isTrue);
          expect(
            (jsonDecode(await marker.readAsString()) as Map)['state'],
            'deletePending',
          );
          expect(await Directory(profilePath).exists(), isTrue);
        },
      );
      expect(drains, 1);
      expect(retained, isEmpty);
      expect(await marker.exists(), isFalse);
      expect(await Directory(path).exists(), isFalse);
      await restarted.close();
    },
  );

  test(
    'an exact committed Young permit recovers and opens only its profile',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final initial = await harness.ready();
      final ref = await _create(initial);
      final permit = YoungClaimPermit(partition: ref, accountId: 1);
      await expectLater(
        initial.claim(ref, YoungClaimPermit(partition: ref, accountId: 2)),
        throwsA(_failure(FailureCode.staleResult)),
      );
      final restarted = YoungPartitionRegistry(harness.owner);
      final retained = await restarted.reconcile(
        <YoungClaimPermit>[permit],
        ownerId: _ownerId,
        resetEpoch: 0,
        drain: (_) async =>
            fail('A committed Young profile must be preserved.'),
      );
      expect(retained.single.sameAs(ref), isTrue);
      await restarted.claim(ref, permit);
      final path = await restarted.openClaimed(
        permit,
        ownerId: _ownerId,
        resetEpoch: 0,
      );
      expect(await Directory(path).exists(), isTrue);
      await restarted.close();
      await expectLater(
        restarted.openClaimed(permit, ownerId: _ownerId, resetEpoch: 0),
        throwsA(_failure(FailureCode.closed)),
      );
    },
  );

  test(
    'a permit with a wrong owner cannot preserve another owner profile',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final initial = await harness.ready();
      final ref = await _create(initial);
      final permit = YoungClaimPermit(partition: ref, accountId: 1);
      final path = initial.profilePath(ref);
      var drains = 0;
      final restarted = YoungPartitionRegistry(harness.owner);
      final result = await restarted.reconcile(
        <YoungClaimPermit>[permit],
        ownerId: _otherOwner,
        resetEpoch: 0,
        drain: (profilePath) async {
          drains++;
          expect(p.windows.equals(profilePath, path), isTrue);
        },
      );
      expect(result, isEmpty);
      expect(drains, 1);
      expect(await Directory(path).exists(), isFalse);
      expect(await harness.marker(ref).exists(), isFalse);
    },
  );

  test('account 2 permit cannot preserve a Young profile', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final initial = await harness.ready();
    final ref = await _create(initial);
    final path = initial.profilePath(ref);
    var drains = 0;
    final restarted = YoungPartitionRegistry(harness.owner);
    final result = await restarted.reconcile(
      <YoungClaimPermit>[YoungClaimPermit(partition: ref, accountId: 2)],
      ownerId: _ownerId,
      resetEpoch: 0,
      drain: (profilePath) async {
        drains++;
        expect(p.windows.equals(profilePath, path), isTrue);
      },
    );
    expect(result, isEmpty);
    expect(drains, 1);
    expect(await Directory(path).exists(), isFalse);
    expect(await harness.marker(ref).exists(), isFalse);
  });

  test(
    'failed drain stays pending and a later reconciliation can finish cleanup',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final initial = await harness.ready();
      final ref = await _create(initial);
      final permit = YoungClaimPermit(partition: ref, accountId: 1);
      final path = initial.profilePath(ref);
      await initial.claim(ref, permit);
      await initial.markDeletePending(ref);

      final restarted = YoungPartitionRegistry(harness.owner);
      await expectLater(
        restarted.reconcile(
          <YoungClaimPermit>[permit],
          ownerId: _ownerId,
          resetEpoch: 0,
          drain: (_) async =>
              throw const AppFailure(FailureCode.cleanupPending),
        ),
        throwsA(_failure(FailureCode.cleanupPending)),
      );
      expect(await Directory(path).exists(), isTrue);
      expect(await harness.marker(ref).exists(), isTrue);
      expect(
        (jsonDecode(await harness.marker(ref).readAsString()) as Map)['state'],
        'deletePending',
      );
      await expectLater(
        _create(restarted),
        throwsA(_failure(FailureCode.cleanupPending)),
      );

      expect(
        await restarted.reconcile(
          <YoungClaimPermit>[permit],
          ownerId: _ownerId,
          resetEpoch: 0,
          drain: (_) async {},
        ),
        isEmpty,
      );
      expect(await Directory(path).exists(), isFalse);
      expect(await harness.marker(ref).exists(), isFalse);
      final recovery = await _create(
        restarted,
        purpose: YoungPartitionPurpose.recovery,
      );
      expect(recovery.id, isNot(ref.id));
      await restarted.clear(recovery, (_) async {});
      await restarted.close();
    },
  );

  test(
    'clear drains before deletion and serializes competing allocation',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final registry = await harness.ready();
      final ref = await _create(registry);
      final path = registry.profilePath(ref);
      var observedPending = false;
      await registry.clear(ref, (profilePath) async {
        observedPending = true;
        expect(p.windows.equals(profilePath, path), isTrue);
        expect(
          (jsonDecode(await harness.marker(ref).readAsString())
              as Map)['state'],
          'deletePending',
        );
        await expectLater(
          _create(registry),
          throwsA(_failure(FailureCode.busy)),
        );
      });
      expect(observedPending, isTrue);
      expect(await Directory(path).exists(), isFalse);
      await registry.close();
    },
  );
}

Future<YoungPartitionRef> _create(
  YoungPartitionRegistry registry, {
  YoungPartitionPurpose purpose = YoungPartitionPurpose.initial,
}) => registry.createProvisional(
  ownerId: _ownerId,
  purpose: purpose,
  attempt: 'young-1-1',
  resetEpoch: 0,
);

Matcher _failure(FailureCode code) =>
    isA<AppFailure>().having((value) => value.code, 'code', code);

final class _Harness {
  _Harness(this.root, this.owner);

  final Directory root;
  final DemoDirectory owner;

  Directory get ledger =>
      Directory(p.windows.join(owner.path, 'young_partitions_v1'));

  File marker(YoungPartitionRef ref) =>
      File(p.windows.join(ledger.path, '${ref.id}.json'));

  static Future<_Harness> create() async {
    final root = await Directory.systemTemp.createTemp('ustc_young_registry_');
    return _Harness(
      root,
      await DemoDirectory.acquire(p.windows.join(root.path, 'owner')),
    );
  }

  Future<YoungPartitionRegistry> ready() async {
    final registry = YoungPartitionRegistry(owner);
    await registry.reconcile(
      const <YoungClaimPermit>[],
      ownerId: _ownerId,
      resetEpoch: 0,
      drain: (_) async {},
    );
    return registry;
  }

  Future<void> dispose() async {
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
