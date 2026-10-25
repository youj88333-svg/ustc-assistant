import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/observation_assets.dart';
import 'package:ustc_assistant_m0/core/work_lease.dart';
import 'package:ustc_assistant_m0/jobs/observation_coordinator.dart';
import 'package:ustc_assistant_m0/jobs/observation_port.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';
import 'package:ustc_assistant_m0/source/young_read_only_contract.dart';

Matcher _failure(FailureCode code) =>
    throwsA(isA<AppFailure>().having((error) => error.code, 'code', code));

Map<String, Object?> _snapshot({
  required int session,
  required int document,
  required int operation,
  bool listening = true,
  int accepted = 0,
}) {
  final profile = accepted == 0
      ? <String, Object?>{
          'observations': 0,
          'success': 'unobserved',
          'code': 'absent',
          'result': 'absent',
          'loginCode': 'absent',
          'username': 'absent',
        }
      : <String, Object?>{
          'observations': accepted,
          'success': 'true',
          'code': 'number',
          'result': 'object',
          'loginCode': 'string',
          'username': 'string',
        };
  const unobservedList = <String, Object?>{
    'observations': 0,
    'success': 'unobserved',
    'code': 'absent',
    'result': 'absent',
    'records': 'absent',
    'count': 0,
    'total': 'absent',
    'id': 'absent',
    'title': 'absent',
    'date': 'absent',
    'startTime': 'absent',
    'endTime': 'absent',
  };
  return <String, Object?>{
    'session': session,
    'document': document,
    'operation': operation,
    'listening': listening,
    'accepted': accepted,
    'rejected': 0,
    'lastRejection': 'none',
    'profile': profile,
    'schedule': unobservedList,
    'activities': unobservedList,
  };
}

YoungReadOnlyInspection _inspection(
  int session,
  int document,
  int operation, {
  bool listening = true,
  int accepted = 0,
}) => YoungReadOnlyInspection.decode(
  _snapshot(
    session: session,
    document: document,
    operation: operation,
    listening: listening,
    accepted: accepted,
  ),
  session: session,
  document: document,
  operation: operation,
);

void main() {
  test(
    'start, refresh, stop preserve the closed summary and restart binds anew',
    () async {
      final browser = _Browser(readAccepted: 2);
      final assets = _Assets();
      final coordinator = _coordinator(browser, assets, WorkLeasePool());
      final changes = <YoungReadOnlyInspection?>[];
      final subscription = coordinator.readOnlyChanges.listen(changes.add);
      try {
        await coordinator.open();
        await coordinator.startReadOnlyInspection();
        final firstOperation = browser.readOnlyCalls.single.operation;
        await coordinator.refreshReadOnlyInspection();
        await coordinator.stopReadOnlyInspection();

        expect(browser.readOnlyCalls.map((call) => call.method), [
          'startYoungReadOnly',
          'readYoungReadOnly',
          'readYoungReadOnly',
          'stopYoungReadOnly',
        ]);
        expect(browser.readOnlyCalls.map((call) => call.operation).toList(), [
          firstOperation,
          firstOperation,
          firstOperation,
          firstOperation,
        ]);
        final stopped = coordinator.readOnlyInspection!;
        expect(stopped.listening, isFalse);
        expect(stopped.accepted, 2);
        expect(stopped.safeSummary()['listening'], isFalse);
        expect(stopped.safeSummary()['accepted'], 2);

        await coordinator.startReadOnlyInspection();
        final restarted = browser.readOnlyCalls.last;
        expect(restarted.method, 'startYoungReadOnly');
        expect(restarted.operation, isNot(firstOperation));
        expect(coordinator.readOnlyInspection!.listening, isTrue);

        await Future<void>.delayed(Duration.zero);
        expect(changes.whereType<YoungReadOnlyInspection>(), isNotEmpty);
        expect(
          changes
              .whereType<YoungReadOnlyInspection>()
              .last
              .safeSummary()['kind'],
          'young-readonly-observation-v1',
        );
      } finally {
        await subscription.cancel();
        await coordinator.shutdown();
        await browser.dispose();
      }
    },
  );

  test('non-Young targets reject before invoking the Young port', () async {
    final browser = _Browser();
    final coordinator = _coordinator(
      browser,
      _Assets(),
      WorkLeasePool(),
      target: ObservationTarget.jw(),
    );
    try {
      await coordinator.open();
      await expectLater(
        coordinator.startReadOnlyInspection(),
        _failure(FailureCode.invalidSnapshot),
      );
      expect(browser.readOnlyCalls, isEmpty);
    } finally {
      await coordinator.shutdown();
      await browser.dispose();
    }
  });

  test(
    'unready documents and overlapping read-only calls return busy',
    () async {
      final unreadyBrowser = _Browser(readyOnOpen: false);
      final unready = _coordinator(unreadyBrowser, _Assets(), WorkLeasePool());
      try {
        await unready.open();
        expect(unready.view.ready, isFalse);
        await expectLater(
          unready.startReadOnlyInspection(),
          _failure(FailureCode.busy),
        );
        expect(unreadyBrowser.readOnlyCalls, isEmpty);
      } finally {
        await unready.shutdown();
        await unreadyBrowser.dispose();
      }

      final browser = _Browser();
      final coordinator = _coordinator(browser, _Assets(), WorkLeasePool());
      final gate = Completer<YoungReadOnlyInspection>();
      browser.startGate = gate;
      try {
        await coordinator.open();
        final start = coordinator.startReadOnlyInspection();
        await expectLater(
          coordinator.refreshReadOnlyInspection(),
          _failure(FailureCode.busy),
        );
        expect(browser.readOnlyCalls, hasLength(1));
        final call = browser.readOnlyCalls.single;
        gate.complete(_inspection(call.session, call.document, call.operation));
        browser.startGate = null;
        await start;
        expect(coordinator.readOnlyInspection!.listening, isTrue);
      } finally {
        if (!gate.isCompleted && browser.readOnlyCalls.isNotEmpty) {
          final call = browser.readOnlyCalls.single;
          gate.complete(
            _inspection(call.session, call.document, call.operation),
          );
        }
        await coordinator.shutdown();
        await browser.dispose();
      }
    },
  );

  test(
    'document change clears state, then resumes after the old request settles',
    () async {
      final browser = _Browser();
      final coordinator = _coordinator(browser, _Assets(), WorkLeasePool());
      final changes = <YoungReadOnlyInspection?>[];
      final subscription = coordinator.readOnlyChanges.listen(changes.add);
      final gate = Completer<YoungReadOnlyInspection>();
      browser.startGate = gate;
      try {
        await coordinator.open();
        final start = coordinator.startReadOnlyInspection();
        final oldCall = browser.readOnlyCalls.single;
        browser.startGate = null;
        final oldResult = expectLater(start, _failure(FailureCode.staleResult));

        // Revoke the old document before letting its native request answer.
        browser.navigate();
        expect(coordinator.view.ready, isTrue);
        expect(coordinator.readOnlyInspection, isNull);
        await Future<void>.delayed(Duration.zero);
        expect(changes.last, isNull);

        // Navigation revokes the old result immediately, while single-flight
        // remains held until its native Future settles.
        await expectLater(
          coordinator.startReadOnlyInspection(),
          _failure(FailureCode.busy),
        );
        expect(browser.readOnlyCalls, hasLength(1));

        gate.complete(
          _inspection(oldCall.session, oldCall.document, oldCall.operation),
        );
        await oldResult;
        await Future<void>.delayed(Duration.zero);

        expect(coordinator.readOnlyInspection, isNull);
        expect(changes.whereType<YoungReadOnlyInspection>(), isEmpty);

        await coordinator.startReadOnlyInspection();
        final newCall = browser.readOnlyCalls.last;
        expect(newCall.method, 'startYoungReadOnly');
        expect(newCall.document, isNot(oldCall.document));
        expect(newCall.operation, isNot(oldCall.operation));
        expect(coordinator.readOnlyInspection?.operation, newCall.operation);
        await Future<void>.delayed(Duration.zero);
        expect(
          changes.whereType<YoungReadOnlyInspection>().map(
            (value) => value.operation,
          ),
          [newCall.operation],
        );
      } finally {
        if (!gate.isCompleted && browser.readOnlyCalls.isNotEmpty) {
          final call = browser.readOnlyCalls.single;
          gate.complete(
            _inspection(call.session, call.document, call.operation),
          );
        }
        await subscription.cancel();
        await coordinator.shutdown();
        await browser.dispose();
      }
    },
  );

  test(
    'close clears the stream state and a late native result cannot republish',
    () async {
      final browser = _Browser();
      final coordinator = _coordinator(browser, _Assets(), WorkLeasePool());
      final changes = <YoungReadOnlyInspection?>[];
      final subscription = coordinator.readOnlyChanges.listen(changes.add);
      final gate = Completer<YoungReadOnlyInspection>();
      browser.startGate = gate;
      try {
        await coordinator.open();
        final start = coordinator.startReadOnlyInspection();
        final call = browser.readOnlyCalls.single;
        final stale = expectLater(start, _failure(FailureCode.staleResult));

        await coordinator.closeSession();
        expect(coordinator.readOnlyInspection, isNull);
        await Future<void>.delayed(Duration.zero);
        expect(changes.last, isNull);
        browser.startGate = null;
        gate.complete(_inspection(call.session, call.document, call.operation));
        await stale;
        await Future<void>.delayed(Duration.zero);

        expect(coordinator.readOnlyInspection, isNull);
        expect(changes.whereType<YoungReadOnlyInspection>(), isEmpty);
        expect(coordinator.view.phase, ObservationPhase.idle);
      } finally {
        if (!gate.isCompleted && browser.readOnlyCalls.isNotEmpty) {
          final call = browser.readOnlyCalls.single;
          gate.complete(
            _inspection(call.session, call.document, call.operation),
          );
        }
        await subscription.cancel();
        await coordinator.shutdown();
        await browser.dispose();
      }
    },
  );

  test(
    'shutdown closes the read stream before a late result can publish',
    () async {
      final browser = _Browser();
      final coordinator = _coordinator(browser, _Assets(), WorkLeasePool());
      final changes = <YoungReadOnlyInspection?>[];
      var streamDone = false;
      final subscription = coordinator.readOnlyChanges.listen(
        changes.add,
        onDone: () => streamDone = true,
      );
      final gate = Completer<YoungReadOnlyInspection>();
      browser.startGate = gate;
      try {
        await coordinator.open();
        final start = coordinator.startReadOnlyInspection();
        final call = browser.readOnlyCalls.single;
        final stale = expectLater(start, _failure(FailureCode.staleResult));

        await coordinator.shutdown();
        expect(coordinator.readOnlyInspection, isNull);
        expect(streamDone, isTrue);
        expect(changes.last, isNull);
        final eventCount = changes.length;
        browser.startGate = null;
        gate.complete(_inspection(call.session, call.document, call.operation));
        await stale;
        await Future<void>.delayed(Duration.zero);

        expect(coordinator.readOnlyInspection, isNull);
        expect(changes, hasLength(eventCount));
      } finally {
        if (!gate.isCompleted && browser.readOnlyCalls.isNotEmpty) {
          final call = browser.readOnlyCalls.single;
          gate.complete(
            _inspection(call.session, call.document, call.operation),
          );
        }
        await subscription.cancel();
        await coordinator.shutdown();
        await browser.dispose();
      }
    },
  );
}

ObservationCoordinator _coordinator(
  _Browser browser,
  _Assets assets,
  WorkLeasePool leases, {
  ObservationTarget? target,
}) => ObservationCoordinator(
  browser: browser,
  assets: assets,
  leases: leases,
  target: target ?? ObservationTarget.young(),
  drainTimeout: const Duration(milliseconds: 100),
  pollInterval: const Duration(milliseconds: 1),
);

final class _Assets implements ObservationAssetsPort {
  int registrations = 0;
  int deletions = 0;

  @override
  Future<void> recoverPending(Future<void> Function(String) drain) async {}

  @override
  Future<String> register() async {
    registrations++;
    return r'C:\synthetic-young-profile';
  }

  @override
  Future<void> cleanup() async {
    deletions++;
  }

  @override
  Future<void> close() async {}
}

final class _ReadOnlyCall {
  const _ReadOnlyCall(this.method, this.session, this.document, this.operation);

  final String method;
  final int session;
  final int document;
  final int operation;
}

final class _Browser
    implements ObservationBrowserPort, YoungReadOnlyBrowserPort {
  _Browser({this.readyOnOpen = true, this.readAccepted = 0});

  final _events = StreamController<BrowserEvent>.broadcast(sync: true);
  final List<_ReadOnlyCall> readOnlyCalls = <_ReadOnlyCall>[];
  final bool readyOnOpen;
  final int readAccepted;
  int _session = 0;
  int _document = 0;
  ObservationTarget? _target;
  Completer<YoungReadOnlyInspection>? startGate;
  Completer<YoungReadOnlyInspection>? readGate;

  @override
  Stream<BrowserEvent> get events => _events.stream;

  @override
  Future<void> open({
    required int session,
    required String profilePath,
    required ObservationTarget target,
    bool recoveryOnly = false,
  }) async {
    _session = session;
    _document = 1;
    _target = target;
    if (readyOnOpen) _ready();
  }

  void _ready() => _events.add(
    BrowserEvent(
      session: _session,
      document: _document,
      kind: BrowserEventKind.ready,
      origin: _target?.initialUri.origin,
    ),
  );

  void navigate() {
    _document++;
    _events.add(
      BrowserEvent(
        session: _session,
        document: _document,
        kind: BrowserEventKind.navigating,
        origin: _target?.initialUri.origin,
      ),
    );
    _ready();
  }

  YoungReadOnlyInspection _reply(
    String method,
    int session,
    int document,
    int operation,
  ) => _inspection(
    session,
    document,
    operation,
    accepted: method == 'readYoungReadOnly' ? readAccepted : 0,
  );

  Future<YoungReadOnlyInspection> _record(
    String method, {
    required int session,
    required int document,
    required int operation,
  }) {
    readOnlyCalls.add(_ReadOnlyCall(method, session, document, operation));
    final gate = switch (method) {
      'startYoungReadOnly' => startGate,
      'readYoungReadOnly' => readGate,
      _ => null,
    };
    if (gate != null) return gate.future;
    return Future<YoungReadOnlyInspection>.value(
      _reply(method, session, document, operation),
    );
  }

  @override
  Future<YoungReadOnlyInspection> startYoungReadOnly({
    required int session,
    required int document,
    required int operation,
  }) => _record(
    'startYoungReadOnly',
    session: session,
    document: document,
    operation: operation,
  );

  @override
  Future<YoungReadOnlyInspection> readYoungReadOnly({
    required int session,
    required int document,
    required int operation,
  }) => _record(
    'readYoungReadOnly',
    session: session,
    document: document,
    operation: operation,
  );

  @override
  Future<void> stopYoungReadOnly({
    required int session,
    required int document,
    required int operation,
  }) async {
    readOnlyCalls.add(
      _ReadOnlyCall('stopYoungReadOnly', session, document, operation),
    );
  }

  @override
  Future<BrowserInspection> inspect({
    required int session,
    required int document,
  }) async => BrowserInspection(
    session: session,
    document: document,
    ready: true,
    origin: _target?.initialUri.origin,
  );

  @override
  Future<void> navigateInitial(int session) async => navigate();

  @override
  Future<void> navigateJwPage({
    required int session,
    required int document,
    required JwObservationPage page,
  }) async {}

  @override
  Future<void> close(int session) async {}

  @override
  Future<bool> drained(int session) async => true;

  Future<void> dispose() => _events.close();
}
