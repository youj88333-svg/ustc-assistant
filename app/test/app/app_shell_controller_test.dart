import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/app_shell_controller.dart';
import 'package:ustc_assistant_m0/core/agenda_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/data/jw_import_contract.dart';
import 'package:ustc_assistant_m0/data/young_import_contract.dart';
import 'package:ustc_assistant_m0/jobs/jw_sync_port.dart';
import 'package:ustc_assistant_m0/jobs/young_sync_port.dart';

void main() {
  test('subscribes to source state without starting any source', () async {
    final jw = _Jw();
    final young = _Young();
    var globalBusy = false;
    final extra = StreamController<Object?>.broadcast();
    final shell = AppShellController(
      jw: jw,
      young: young,
      clock: FixedClock(DateTime.utc(2026, 10, 11, 16)),
      isGloballyBusy: () => globalBusy,
      extraChanges: [extra.stream],
    );
    var changes = 0;
    shell.addListener(() => changes++);
    expect(shell.today, DateTime.utc(2026, 10, 12));
    expect(shell.view.accountBound, isTrue);
    expect(shell.readAgenda(day: shell.today).items, hasLength(2));
    globalBusy = true;
    extra.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(shell.view.globallyBusy, isTrue);
    expect(changes, 1);
    expect(jw.unexpectedCalls, 0);
    expect(young.unexpectedCalls, 0);
    shell.dispose();
    extra.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(changes, 1);
    expect(jw.unexpectedCalls, 0);
    await Future.wait([
      jw.changes.close(),
      young.changes.close(),
      extra.close(),
    ]);
  });

  test(
    'source-bound references route to the correct versioned local write',
    () async {
      final jw = _Jw();
      final young = _Young();
      final shell = AppShellController(jw: jw, young: young);
      final rows = shell.readAgenda(day: DateTime.utc(2026, 10, 12)).items;
      await shell.setHidden(rows.last.reference, hidden: true);
      expect(young.hiddenCalls, [(1, 4, true)]);
      expect(jw.hiddenCalls, isEmpty);
      await shell.setHidden(rows.first.reference, hidden: false);
      expect(jw.hiddenCalls, [(1, 2, false)]);
      expect(young.hiddenCalls, [(1, 4, true)]);
      await expectLater(
        shell.setHidden(
          const AgendaReference(
            source: AgendaSource.exam,
            localId: 1,
            version: 2,
          ),
          hidden: true,
        ),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.code,
            'code',
            FailureCode.staleResult,
          ),
        ),
      );
      expect(jw.hiddenCalls, hasLength(1));
      shell.dispose();
      await Future.wait([jw.changes.close(), young.changes.close()]);
    },
  );

  test(
    'busy and pending writes reject re-entry; raw failures are projected',
    () async {
      final jw = _Jw();
      final young = _Young();
      final gate = Completer<void>();
      jw.pending = gate.future;
      var busy = true;
      final shell = AppShellController(
        jw: jw,
        young: young,
        isGloballyBusy: () => busy,
      );
      final ref = shell
          .readAgenda(day: DateTime.utc(2026, 10, 12))
          .items
          .first
          .reference;
      await expectLater(
        shell.setHidden(ref, hidden: true),
        throwsA(
          isA<AppFailure>().having((e) => e.code, 'code', FailureCode.busy),
        ),
      );
      busy = false;
      final first = shell.setHidden(ref, hidden: true);
      expect(shell.view.actionPending, isTrue);
      await expectLater(
        shell.setHidden(ref, hidden: true),
        throwsA(
          isA<AppFailure>().having((e) => e.code, 'code', FailureCode.busy),
        ),
      );
      gate.complete();
      await first;
      jw.pending = null;
      jw.failure = StateError('synthetic private detail');
      await expectLater(
        shell.setHidden(ref, hidden: true),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.code,
            'code',
            FailureCode.storageFailed,
          ),
        ),
      );
      expect(shell.view.actionFailure, FailureCode.storageFailed);
      expect(shell.view.actionPending, isFalse);
      shell.dispose();
      await Future.wait([jw.changes.close(), young.changes.close()]);
    },
  );

  test('progress failure keeps old records but rejects new writes', () async {
    final jw = _Jw();
    final young = _Young();
    final shell = AppShellController(jw: jw, young: young);
    jw.changes.addError(StateError('synthetic source detail'));
    await Future<void>.delayed(Duration.zero);
    expect(shell.view.progressUnavailable, isTrue);
    final ref = shell
        .readAgenda(day: DateTime.utc(2026, 10, 12))
        .items
        .first
        .reference;
    await expectLater(
      shell.setHidden(ref, hidden: true),
      throwsA(isA<AppFailure>()),
    );
    expect(jw.hiddenCalls, isEmpty);
    shell.dispose();
    await expectLater(
      shell.setHidden(ref, hidden: true),
      throwsA(
        isA<AppFailure>().having((e) => e.code, 'code', FailureCode.closed),
      ),
    );
    await Future.wait([jw.changes.close(), young.changes.close()]);
  });
}

final class _Jw extends Fake implements JwSyncPort {
  final changes = StreamController<JwSyncView>.broadcast();
  final hiddenCalls = <(int, int, bool)>[];
  int unexpectedCalls = 0;
  Future<void>? pending;
  Object? failure;
  @override
  final syncView = JwSyncView(
    accountBound: true,
    data: JwDataView(
      accountBound: true,
      courseCount: 1,
      examCount: 0,
      importCount: 1,
      auditCount: 1,
      events: [
        JwStoredEvent(
          localId: 1,
          version: 2,
          kind: JwEventKind.course,
          title: '合成课程',
          startsAtUtc: DateTime.utc(2026, 10, 12, 1),
          endsAtUtc: DateTime.utc(2026, 10, 12, 2),
          presence: JwPresence.missingWithinScope,
          hidden: false,
        ),
      ],
    ),
  );
  @override
  Stream<JwSyncView> get syncChanges => changes.stream;
  @override
  Future<void> setHidden({
    required int localId,
    required int expectedVersion,
    required bool hidden,
  }) async {
    hiddenCalls.add((localId, expectedVersion, hidden));
    if (pending != null) await pending;
    if (failure != null) throw failure!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    unexpectedCalls++;
    return super.noSuchMethod(invocation);
  }
}

final class _Young extends Fake implements YoungSyncPort {
  final changes = StreamController<YoungSyncView>.broadcast();
  final hiddenCalls = <(int, int, bool)>[];
  int unexpectedCalls = 0;
  @override
  final syncView = YoungSyncView(
    accountBound: true,
    data: YoungDataView(
      accountBound: true,
      importCount: 1,
      queryCount: 0,
      auditCount: 1,
      events: [
        YoungStoredEvent(
          localId: 1,
          version: 4,
          title: '合成二课',
          place: '合成地点',
          startsAtUtc: DateTime.utc(2026, 10, 12, 2),
          endsAtUtc: DateTime.utc(2026, 10, 12, 3),
          presence: YoungPresence.observed,
          hidden: false,
        ),
      ],
    ),
  );
  @override
  Stream<YoungSyncView> get syncChanges => changes.stream;
  @override
  Future<void> setHidden({
    required int localId,
    required int expectedVersion,
    required bool hidden,
  }) async => hiddenCalls.add((localId, expectedVersion, hidden));
  @override
  dynamic noSuchMethod(Invocation invocation) {
    unexpectedCalls++;
    return super.noSuchMethod(invocation);
  }
}
