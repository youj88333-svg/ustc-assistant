import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/jw_credentials.dart';
import 'package:ustc_assistant_m0/core/jw_work_contract.dart';
import 'package:ustc_assistant_m0/core/young_work_contract.dart';
import 'package:ustc_assistant_m0/data/jw_import_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/data/young_import_contract.dart';
import 'package:ustc_assistant_m0/source/jw_collection_contract.dart';
import 'package:ustc_assistant_m0/source/jw_probe_contract.dart';
import 'package:ustc_assistant_m0/source/young_business_contract.dart';
import 'package:ustc_assistant_m0/source/young_collection_contract.dart';

const _account = 'AB12345';
const _oldPassword = 'synthetic-shared-old';
const _newPassword = 'synthetic-shared-young-update';
final _day = DateTime.utc(2026, 6, 10);

int _jwPartitionSequence = 0;
int _youngPartitionSequence = 0;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('shared JW and Young school credential', () {
    test(
      'a JW-saved password is leased to the matching Young job once',
      () async {
        final protector = _SyntheticCredentialProtector();
        final store = await _openStore(credentialProtector: protector);
        await _saveJwCredential(store, _oldPassword);

        final ticket = await _beginYoungActivities(store);
        final lease = await store.leaseYoungCredentials(ticket);
        expect(lease, isNotNull);
        expect(_passwordFromLease(lease!), _oldPassword);
        expect(() => lease.take(), throwsA(isA<JwCredentialException>()));
        expect(await store.leaseYoungCredentials(ticket), isNull);
        expect(await _credentialRowCount(store), 1);
        expect((await store.readView()).credentialSaved, isTrue);
        expect((await store.readYoungView()).credentialSaved, isTrue);
        await store.failYoungJob(ticket);
      },
    );

    test(
      'a successful Young job does not save a password the user marked temporary',
      () async {
        final store = await _openStore(
          credentialProtector: _SyntheticCredentialProtector(),
        );
        await _saveJwCredential(store, _oldPassword);
        final beforeCiphertext = await _credentialCiphertext(store);
        final ticket = await _beginYoungActivities(store);
        final partition = await _stageYoungPartition(store, ticket);
        await store.stageYoungCredentials(ticket, _newPassword, save: false);
        final lease = (await store.leaseYoungCredentials(ticket))!;
        expect(_passwordFromLease(lease), _newPassword);
        await store.completeYoungQuery(
          ticket,
          _activitiesArtifact(ticket, partition),
        );

        expect(
          _sameBytes(await _credentialCiphertext(store), beforeCiphertext),
          isTrue,
        );
        expect(await _credentialRowCount(store), 1);
        final jwTicket = await store.beginJob();
        final jwLease = (await store.leaseCredentials(jwTicket))!;
        expect(_passwordFromLease(jwLease), _oldPassword);
        await store.failJob(jwTicket);
      },
    );

    test(
      'Young updates the shared password atomically and both sources reuse it after restart',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'young-shared-credential-',
        );
        addTearDown(() async {
          if (await directory.exists()) await directory.delete(recursive: true);
        });
        final file = File(
          '${directory.path}${Platform.pathSeparator}jw.sqlite',
        );
        final protector = _SyntheticCredentialProtector();

        final first = await _openFileStore(
          file,
          credentialProtector: protector,
        );
        await _saveJwCredential(first, _oldPassword);
        final jwEventsBefore = _jwEventFacts(await first.readView());
        await first.close();

        final second = await _openFileStore(
          file,
          credentialProtector: protector,
        );
        final oldCiphertext = await _credentialCiphertext(second);
        final ticket = await _beginYoungActivities(second);
        final partition = await _stageYoungPartition(second, ticket);
        await second.stageYoungCredentials(ticket, _newPassword, save: true);
        expect(
          _sameBytes(await _credentialCiphertext(second), oldCiphertext),
          isTrue,
        );

        final lease = (await second.leaseYoungCredentials(ticket))!;
        expect(_passwordFromLease(lease), _newPassword);
        final artifact = _activitiesArtifact(ticket, partition);
        await second.completeYoungQuery(ticket, artifact);
        final newCiphertext = await _credentialCiphertext(second);
        expect(_sameBytes(newCiphertext, oldCiphertext), isFalse);
        expect(await _credentialRowCount(second), 1);
        expect((await second.readView()).credentialSaved, isTrue);
        expect((await second.readYoungView()).credentialSaved, isTrue);
        expect(
          _jwEventFacts(await second.readView()),
          orderedEquals(jwEventsBefore),
        );
        await second.close();

        final reopened = await _openFileStore(
          file,
          credentialProtector: protector,
        );
        expect(await _credentialRowCount(reopened), 1);
        expect((await reopened.readView()).credentialSaved, isTrue);
        expect((await reopened.readYoungView()).credentialSaved, isTrue);
        expect(await reopened.readCommittedPermits(), hasLength(1));
        expect(await reopened.readYoungPermits(), hasLength(1));

        final jwTicket = await reopened.beginJob();
        final jwLease = (await reopened.leaseCredentials(jwTicket))!;
        expect(_passwordFromLease(jwLease), _newPassword);
        await reopened.failJob(jwTicket);

        final youngTicket = await _beginYoungActivities(reopened);
        final youngLease = (await reopened.leaseYoungCredentials(youngTicket))!;
        expect(_passwordFromLease(youngLease), _newPassword);
        await reopened.failYoungJob(youngTicket);
      },
    );

    for (final outcome in _YoungFailure.values) {
      test('$outcome cannot replace the old shared password', () async {
        var failBeforeCommit = true;
        final protector = _SyntheticCredentialProtector();
        final store = await _openStore(
          credentialProtector: protector,
          onYoungCheckpoint: (checkpoint) async {
            if (outcome == _YoungFailure.checkpoint &&
                checkpoint == YoungStoreCheckpoint.beforeCommit &&
                failBeforeCommit) {
              failBeforeCommit = false;
              throw const AppFailure(FailureCode.storageFailed);
            }
          },
        );
        await _saveJwCredential(store, _oldPassword);
        final beforeCiphertext = await _credentialCiphertext(store);
        final ticket = await _beginYoungActivities(store);

        Uint8List? stagedCiphertext;
        JwSecretLease? lease;
        if (outcome == _YoungFailure.protection) {
          protector.failProtect = true;
          await expectLater(
            store.stageYoungCredentials(ticket, _newPassword, save: true),
            throwsA(
              isA<JwCredentialException>().having(
                (error) => error.code,
                'credential failure',
                JwCredentialFailure.protectionFailed,
              ),
            ),
          );
          expect(
            protector.lastProtectInput!.every((byte) => byte == 0),
            isTrue,
          );
        } else {
          await store.stageYoungCredentials(ticket, _newPassword, save: true);
          stagedCiphertext = protector.lastProtectOutput;
          lease = (await store.leaseYoungCredentials(ticket))!;
        }

        switch (outcome) {
          case _YoungFailure.failed:
            await store.failYoungJob(ticket);
            break;
          case _YoungFailure.cancelled:
            expect(await store.cancelYoungJob(ticket), isTrue);
            break;
          case _YoungFailure.identityMismatch:
            final partition = await _stageYoungPartition(store, ticket);
            await _expectYoungIdentity(
              store.completeYoungQuery(
                ticket,
                _activitiesArtifact(ticket, partition, username: 'CD67890'),
              ),
              YoungIdentityFailure.accountMismatch,
            );
            await store.failYoungJob(ticket);
            break;
          case _YoungFailure.checkpoint:
            final partition = await _stageYoungPartition(store, ticket);
            await _expectAppFailure(
              store.completeYoungQuery(
                ticket,
                _activitiesArtifact(ticket, partition),
              ),
              FailureCode.storageFailed,
            );
            await store.failYoungJob(ticket);
            break;
          case _YoungFailure.protection:
            await store.failYoungJob(ticket);
            break;
        }

        if (lease != null) {
          expect(() => lease!.take(), throwsA(isA<JwCredentialException>()));
        }
        if (stagedCiphertext != null) {
          expect(stagedCiphertext.every((byte) => byte == 0), isTrue);
        }
        expect(
          _sameBytes(await _credentialCiphertext(store), beforeCiphertext),
          isTrue,
        );
        expect(await _credentialRowCount(store), 1);
        expect(await _credentialAuditCount(store, 'saved'), 1);

        final jwTicket = await store.beginJob();
        final jwLease = (await store.leaseCredentials(jwTicket))!;
        expect(_passwordFromLease(jwLease), _oldPassword);
        await store.failJob(jwTicket);
      });
    }

    test(
      'revoking Young permits leaves the shared password and JW permit intact',
      () async {
        final store = await _openStore(
          credentialProtector: _SyntheticCredentialProtector(),
        );
        await _saveJwCredential(store, _oldPassword);
        final youngTicket = await _beginYoungCalendar(store);
        final youngPartition = await _stageYoungPartition(store, youngTicket);
        await store.importYoungCalendar(
          youngTicket,
          _calendarArtifact(youngTicket, youngPartition),
        );
        final ciphertext = await _credentialCiphertext(store);
        final jwPermits = await store.readCommittedPermits();
        final jwFactsBefore = _jwNonCredentialFacts(await store.readView());
        final eventsBefore = _youngEventFacts(await store.readYoungView());

        await store.revokeYoungPermits();

        expect(await store.readYoungPermits(), isEmpty);
        expect(await store.readCommittedPermits(), hasLength(1));
        expect(
          (await store.readCommittedPermits()).single.partition.sameAs(
            jwPermits.single.partition,
          ),
          isTrue,
        );
        expect(
          _sameBytes(await _credentialCiphertext(store), ciphertext),
          isTrue,
        );
        expect((await store.readView()).credentialSaved, isTrue);
        expect(
          _jwNonCredentialFacts(await store.readView()),
          equals(jwFactsBefore),
        );
        final youngView = await store.readYoungView();
        expect(youngView.credentialSaved, isTrue);
        expect(_youngEventFacts(youngView), orderedEquals(eventsBefore));

        final jwTicket = await store.beginJob();
        final jwLease = (await store.leaseCredentials(jwTicket))!;
        expect(_passwordFromLease(jwLease), _oldPassword);
        await store.failJob(jwTicket);
      },
    );

    test(
      'shared deletion is busy for either source, then preserves both ledgers',
      () async {
        final store = await _openStore(
          credentialProtector: _SyntheticCredentialProtector(),
        );
        await _saveJwCredential(store, _oldPassword);
        final youngTicket = await _beginYoungCalendar(store);
        final youngPartition = await _stageYoungPartition(store, youngTicket);
        await store.importYoungCalendar(
          youngTicket,
          _calendarArtifact(youngTicket, youngPartition),
        );

        final activeJw = await store.beginJob();
        await _expectAppFailure(
          store.deleteSavedCredential(),
          FailureCode.busy,
        );
        await store.failJob(activeJw);
        final activeYoung = await _beginYoungActivities(store);
        await _expectAppFailure(
          store.deleteSavedCredential(),
          FailureCode.busy,
        );
        await store.failYoungJob(activeYoung);

        final jwBefore = await store.readView();
        final youngBefore = await store.readYoungView();
        final jwAuthority = await store.readAuthority();
        final youngAuthority = await store.readYoungAuthority();
        final jwPermits = await store.readCommittedPermits();
        final youngPermits = await store.readYoungPermits();
        expect(jwPermits, hasLength(1));
        expect(youngPermits, hasLength(1));

        await store.deleteSavedCredential();

        final jwAfter = await store.readView();
        final youngAfter = await store.readYoungView();
        expect(jwAfter.credentialSaved, isFalse);
        expect(youngAfter.credentialSaved, isFalse);
        expect(await _credentialRowCount(store), 0);
        expect(await _credentialAuditCount(store, 'saved'), 1);
        expect(await _credentialAuditCount(store, 'deleted'), 1);
        expect(
          _jwNonCredentialFacts(jwAfter),
          equals(_jwNonCredentialFacts(jwBefore)),
        );
        expect(
          _youngNonCredentialFacts(youngAfter),
          equals(_youngNonCredentialFacts(youngBefore)),
        );

        final jwAuthorityAfter = await store.readAuthority();
        final youngAuthorityAfter = await store.readYoungAuthority();
        expect(jwAuthorityAfter.ownerId, jwAuthority.ownerId);
        expect(jwAuthorityAfter.resetEpoch, jwAuthority.resetEpoch);
        expect(jwAuthorityAfter.accountBound, isTrue);
        expect(youngAuthorityAfter.ownerId, youngAuthority.ownerId);
        expect(youngAuthorityAfter.resetEpoch, youngAuthority.resetEpoch);
        expect(youngAuthorityAfter.accountBound, isTrue);
        final jwPermitsAfter = await store.readCommittedPermits();
        final youngPermitsAfter = await store.readYoungPermits();
        expect(jwPermitsAfter, hasLength(1));
        expect(
          jwPermitsAfter.single.partition.sameAs(jwPermits.single.partition),
          isTrue,
        );
        expect(youngPermitsAfter, hasLength(1));
        expect(
          youngPermitsAfter.single.partition.sameAs(
            youngPermits.single.partition,
          ),
          isTrue,
        );
      },
    );
  });
}

enum _YoungFailure {
  failed,
  cancelled,
  identityMismatch,
  checkpoint,
  protection,
}

Future<JwStore> _openStore({
  JwCredentialProtector? credentialProtector,
  Future<void> Function(YoungStoreCheckpoint)? onYoungCheckpoint,
}) => _openDatabase(
  NativeDatabase.memory(),
  credentialProtector: credentialProtector,
  onYoungCheckpoint: onYoungCheckpoint,
);

Future<JwStore> _openFileStore(
  File file, {
  JwCredentialProtector? credentialProtector,
}) => _openDatabase(
  NativeDatabase(file, logStatements: false),
  credentialProtector: credentialProtector,
);

Future<JwStore> _openDatabase(
  QueryExecutor executor, {
  JwCredentialProtector? credentialProtector,
  Future<void> Function(YoungStoreCheckpoint)? onYoungCheckpoint,
}) async {
  final store = JwStore(
    executor,
    ownership: _TestOwnership(),
    clock: FixedClock(DateTime.utc(2026, 10, 11, 12)),
    credentialProtector: credentialProtector,
    onYoungCheckpoint: onYoungCheckpoint,
  );
  await store.initialize();
  addTearDown(store.close);
  return store;
}

Future<void> _saveJwCredential(JwStore store, String password) async {
  final ticket = await store.beginJob(expectedAccountCode: _account);
  final partition = _jwPartition(ticket);
  await store.stagePartition(ticket, partition);
  await store.stageSemesterCatalog(ticket, const [
    JwSemesterOption(id: 202610, name: 'Synthetic 2026 autumn', selected: true),
  ]);
  await store.stageCredentials(ticket, password, save: true);
  await store.importSnapshot(ticket, _jwArtifact(ticket, partition));
}

Future<YoungJobTicket> _beginYoungActivities(JwStore store) =>
    store.beginYoungJob(
      kind: YoungJobKind.activities,
      expectedAccountCode: _account,
    );

Future<YoungJobTicket> _beginYoungCalendar(JwStore store) =>
    store.beginYoungJob(
      kind: YoungJobKind.calendar,
      expectedAccountCode: _account,
      firstDay: _day,
      lastDay: _day,
    );

JwPartitionRef _jwPartition(JwJobTicket ticket) {
  final sequence = ++_jwPartitionSequence;
  return JwPartitionRef(
    id: 'jwp-${sequence.toRadixString(16).padLeft(32, '0')}',
    ownerId: ticket.stamp.ownerId,
    purpose: ticket.stamp.accountId == null
        ? JwPartitionPurpose.initial
        : JwPartitionPurpose.recovery,
    attempt: ticket.stamp.jobId,
    resetEpoch: ticket.stamp.resetEpoch,
  );
}

Future<YoungPartitionRef> _stageYoungPartition(
  JwStore store,
  YoungJobTicket ticket,
) async {
  final sequence = ++_youngPartitionSequence;
  final ref = YoungPartitionRef(
    id: 'yp-${sequence.toRadixString(16).padLeft(32, '0')}',
    ownerId: ticket.stamp.ownerId,
    purpose: ticket.stamp.accountId == null
        ? YoungPartitionPurpose.initial
        : YoungPartitionPurpose.recovery,
    attempt: ticket.stamp.jobId,
    resetEpoch: ticket.stamp.resetEpoch,
  );
  await store.stageYoungPartition(ticket, ref);
  return ref;
}

// This test-only source bridge supplies closed synthetic evidence through the
// same decode/seal contracts used by C1; it never constructs a C3 grant.
JwCollectedArtifact _jwArtifact(JwJobTicket ticket, JwPartitionRef partition) {
  const semesterId = 202610;
  final courses = [
    {
      'lessonId': 101,
      'groupId': 1101,
      'date': '2026-06-10',
      'startMinute': 540,
      'endMinute': 600,
      'title': 'Synthetic JW course',
    },
  ];
  final exams = [
    {
      'courseCode': 'SYNTH-101',
      'examType': 'final',
      'date': '2026-12-20',
      'startMinute': 540,
      'endMinute': 600,
      'title': 'Synthetic JW exam',
    },
  ];
  final diagnostics = <String, Object>{
    'checks': {
      'identityBefore': 'ok',
      'course': 'ok',
      'index': 'ok',
      'datum': 'ok',
      'exams': 'ok',
      'identityAfter': 'ok',
    },
    'reason': 'none',
    'identityReads': 2,
    'lessonIds': 1,
    'lessons': 1,
    'groups': 1,
    'schedules': 1,
    'datedSchedules': 1,
    'timedSchedules': 1,
    'linkedSchedules': 1,
    'examRows': 1,
    'datedExams': 1,
    'semesterAccepted': true,
    'selfRouteBound': true,
    'identityStable': true,
    'emptyCourse': false,
    'emptyExams': false,
    'pagination': false,
    'types': {
      'lessonIds': 'array',
      'lessonList': 'array',
      'scheduleGroupList': 'array',
      'scheduleList': 'array',
      'date': 'string',
      'startTime': 'string',
      'endTime': 'string',
    },
  };
  final reply = JwCollectionReply.decode(
    jsonEncode({
      'operation': 31,
      'phase': 'done',
      'code': 'ok',
      'identity': {
        'candidateCount': 1,
        'method': 'table',
        'accountCode': _account,
      },
      'diagnostics': diagnostics,
      'snapshot': {
        'semesterId': semesterId,
        'courses': courses,
        'exams': exams,
      },
    }),
    operation: 31,
  );
  return JwCollectedArtifact.seal(
    reply: reply,
    stamp: ticket.stamp,
    partition: partition,
    session: 1,
    document: 2,
    semesterId: semesterId,
    collectedAtUtc: DateTime.utc(2026, 10, 11, 12),
  );
}

YoungCollectedArtifact _activitiesArtifact(
  YoungJobTicket ticket,
  YoungPartitionRef partition, {
  String username = _account,
}) {
  final activities = decodeYoungActivityPage({
    'success': true,
    'code': 200,
    'result': {
      'records': [
        {
          'id': 'synthetic-activity-19',
          'itemName': 'Synthetic Young activity',
          'st': '2026-06-10 09:00:00',
          'et': '2026-06-10 10:00:00',
          'applySt': '2026-06-01 08:00:00',
          'applyEt': '2026-06-09 20:00:00',
          'placeInfo': 'Synthetic room',
        },
      ],
      'total': 1,
    },
  }).records;
  return YoungCollectedArtifact.seal(
    profileBefore: _profile(username),
    profileAfter: _profile(username),
    stamp: ticket.stamp,
    partition: partition,
    session: 1,
    document: 2,
    operation: 3,
    collectedAtUtc: DateTime.utc(2026, 10, 11, 12),
    activities: activities,
    entries: const [],
    activityPages: 1,
    calendarPages: 0,
    calendarRows: 0,
    excludedSchedules: 0,
    days: 0,
    firstDay: null,
    lastDay: null,
  );
}

YoungCollectedArtifact _calendarArtifact(
  YoungJobTicket ticket,
  YoungPartitionRef partition,
) {
  final decoded = decodeYoungCalendarPage({
    'success': true,
    'code': 200,
    'result': {
      'records': [
        {
          'id': 'synthetic-young-calendar-id',
          'title': 'Synthetic Young event',
          'place': 'Synthetic campus',
          'startTime': '2026-06-10 09:00:00',
          'endTime': '2026-06-10 10:00:00',
          'itemId': 'synthetic-linked-activity',
        },
      ],
      'total': 1,
    },
  }).records;
  final linked = decoded.where((entry) => entry.itemId != null).toList();
  return YoungCollectedArtifact.seal(
    profileBefore: _profile(_account),
    profileAfter: _profile(_account),
    stamp: ticket.stamp,
    partition: partition,
    session: 1,
    document: 2,
    operation: 3,
    collectedAtUtc: DateTime.utc(2026, 10, 11, 12),
    activities: const [],
    entries: linked,
    activityPages: 0,
    calendarPages: 1,
    calendarRows: decoded.length,
    excludedSchedules: decoded.length - linked.length,
    days: 1,
    firstDay: _day,
    lastDay: _day,
  );
}

YoungProfileCandidate _profile(String username) => decodeYoungProfile({
  'success': true,
  'code': 200,
  'result': {'username': username},
});

String _passwordFromLease(JwSecretLease lease) {
  final bytes = lease.take();
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    final payload = decoded as Map<String, dynamic>;
    expect(payload['username'], _account);
    return payload['password'] as String;
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
}

Future<Uint8List?> _credentialCiphertext(JwStore store) async {
  final row = await store
      .customSelect(
        'SELECT ciphertext FROM jw_credentials WHERE account_id = 1',
      )
      .getSingleOrNull();
  final value = row?.read<Uint8List>('ciphertext');
  return value == null ? null : Uint8List.fromList(value);
}

Future<int> _credentialRowCount(JwStore store) async =>
    _count(store, 'jw_credentials');

Future<int> _credentialAuditCount(JwStore store, String action) async {
  final row = await store
      .customSelect(
        'SELECT COUNT(*) AS count FROM jw_credential_audit WHERE action = ?',
        variables: [Variable.withString(action)],
      )
      .getSingle();
  return row.read<int>('count');
}

Future<int> _count(JwStore store, String table) async {
  if (!RegExp(r'^[a-z_]+$').hasMatch(table)) {
    throw ArgumentError.value(table);
  }
  final row = await store
      .customSelect('SELECT COUNT(*) AS count FROM $table')
      .getSingle();
  return row.read<int>('count');
}

bool _sameBytes(Uint8List? left, Uint8List? right) {
  if (left == null || right == null) return left == null && right == null;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

List<Object?> _jwEventFacts(JwDataView view) => view.events
    .map((event) => (event.localId, event.version, event.kind, event.title))
    .toList();

List<Object?> _jwNonCredentialFacts(JwDataView view) => [
  view.accountBound,
  view.courseCount,
  view.examCount,
  view.importCount,
  view.auditCount,
  view.lastSemesterId,
  view.cachedSemesters
      .map((item) => (item.id, item.name, item.selected))
      .toList(),
  _jwEventFacts(view),
];

List<Object?> _youngEventFacts(YoungDataView view) => view.events
    .map((event) => (event.localId, event.version, event.title, event.hidden))
    .toList();

List<Object?> _youngNonCredentialFacts(YoungDataView view) => [
  view.accountBound,
  view.importCount,
  view.queryCount,
  view.auditCount,
  view.firstDay,
  view.lastDay,
  _youngEventFacts(view),
];

Future<void> _expectAppFailure(Future<dynamic> operation, FailureCode code) =>
    expectLater(
      operation,
      throwsA(
        isA<AppFailure>().having((error) => error.code, 'failure code', code),
      ),
    );

Future<void> _expectYoungIdentity(
  Future<dynamic> operation,
  YoungIdentityFailure code,
) => expectLater(
  operation,
  throwsA(
    isA<YoungIdentityException>().having(
      (error) => error.code,
      'identity failure',
      code,
    ),
  ),
);

final class _SyntheticCredentialProtector implements JwCredentialProtector {
  bool failProtect = false;
  Uint8List? lastProtectInput;
  Uint8List? lastProtectOutput;

  @override
  String get mechanism => 'synthetic-test-xor-v1';

  @override
  Future<Uint8List> protect(
    Uint8List plaintext, {
    required String purpose,
  }) async {
    lastProtectInput = plaintext;
    if (failProtect) {
      throw const JwCredentialException(JwCredentialFailure.protectionFailed);
    }
    final encrypted = _transform(plaintext, purpose);
    lastProtectOutput = encrypted;
    return encrypted;
  }

  @override
  Future<Uint8List> unprotect(
    Uint8List ciphertext, {
    required String purpose,
  }) async => _transform(ciphertext, purpose);

  Uint8List _transform(Uint8List bytes, String purpose) {
    var seed = 0x69;
    for (final byte in utf8.encode(purpose)) {
      seed = ((seed * 33) ^ byte) & 0xff;
    }
    return Uint8List.fromList(
      List<int>.generate(
        bytes.length,
        (index) => bytes[index] ^ ((seed + index * 29 + 0xA5) & 0xff),
      ),
    );
  }
}

final class _TestOwnership implements AssetOwnership {
  @override
  bool get isHeld => true;

  @override
  void ensureHeld() {}
}
