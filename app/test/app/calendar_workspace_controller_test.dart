import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/app_shell_contract.dart';
import 'package:ustc_assistant_m0/app/calendar_workspace_contract.dart';
import 'package:ustc_assistant_m0/app/calendar_workspace_controller.dart';
import 'package:ustc_assistant_m0/core/agenda_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/jobs/jw_sync_port.dart';
import 'package:ustc_assistant_m0/jobs/young_sync_port.dart';

const _context = CalendarContext(
  owner: 'synthetic-calendar-owner',
  resetEpoch: 0,
  agendaEpoch: 0,
);
final _day = DateTime.utc(2026, 10, 12);
final _draft = PersonalEventDraft(
  title: '合成测试',
  start: DateTime.utc(2026, 10, 12, 1),
  end: DateTime.utc(2026, 10, 12, 2),
);

void main() {
  test(
    'constructor starts no query; explicit load works with no school binding',
    () async {
      final data = _Data();
      final shell = _Shell();
      final controller = _controller(data, shell);
      expect(data.queries, 0);
      expect(controller.view.canWrite, isFalse);
      await controller.load();
      expect(data.lastQuery!.firstDay, _day);
      expect(
        data.lastQuery!.endDayExclusive,
        _day.add(const Duration(days: 7)),
      );
      expect(controller.view.mode, CalendarViewMode.week);
      expect(controller.view.canWrite, isTrue);
      expect(shell.view.accountBound, isFalse);
    },
  );

  test(
    'late window and detail cannot overwrite a new date selection',
    () async {
      final data = _Data();
      final shell = _Shell();
      final controller = _controller(data, shell);
      final old = Completer<CalendarWindow>();
      final latest = Completer<CalendarWindow>();
      data.queryHandler = (query) =>
          query.firstDay == _day ? old.future : latest.future;
      final first = controller.load(day: _day, mode: CalendarViewMode.day);
      final nextDay = _day.add(const Duration(days: 1));
      final second = controller.load(day: nextDay, mode: CalendarViewMode.day);
      latest.complete(data.window(data.lastQuery!));
      await second;
      old.complete(
        data.window(CalendarQuery(firstDay: _day, endDayExclusive: nextDay)),
      );
      await first;
      expect(controller.view.window!.query.firstDay, nextDay);
      final detail = Completer<CalendarDetail>();
      data.detailHandler = (_) => detail.future;
      final selecting = controller.select(data.item.reference);
      data.queryHandler = null;
      await controller.load(day: _day);
      detail.complete(data.detailValue(data.item.reference));
      await selecting;
      expect(controller.view.detail, isNull);
      expect(controller.view.detailLoading, isFalse);
    },
  );

  test(
    'read context change drops selection and rejects an old creation form',
    () async {
      final data = _Data();
      final shell = _Shell();
      final controller = _controller(data, shell);
      await controller.load();
      await controller.select(data.item.reference);
      expect(controller.view.detail, isNotNull);
      final prior = data.context;
      data.context = const CalendarContext(
        owner: 'synthetic-calendar-owner',
        resetEpoch: 1,
        agendaEpoch: 1,
      );
      await controller.load();
      expect(controller.view.detail, isNull);
      await _failure(
        controller.execute(CreatePersonalEvent(_draft), expectedContext: prior),
        CalendarFailureCode.staleReference,
      );
      expect(data.prepares, 0);
      expect(data.commits, 0);
    },
  );

  test(
    'write mutex includes the detail refresh and shutdown waits for it',
    () async {
      final data = _Data();
      final shell = _Shell();
      final controller = _controller(data, shell);
      await controller.load();
      await controller.select(data.item.reference);
      final refreshDetail = Completer<CalendarDetail>();
      final entered = Completer<void>();
      data.detailHandler = (ref) {
        entered.complete();
        return refreshDetail.future;
      };
      data.commitHandler = (command) async {
        data.version++;
        return data.receipt(command);
      };
      final first = controller.execute(
        SetPersonalOccurrenceState(data.item.reference, completed: true),
        expectedContext: data.context,
      );
      await entered.future;
      expect(controller.view.loading, isFalse);
      expect(controller.view.detailLoading, isTrue);
      expect(controller.view.actionPending, isTrue);
      expect(controller.view.canWrite, isFalse);
      await _failure(
        controller.execute(
          CreatePersonalEvent(_draft),
          expectedContext: data.context,
        ),
        CalendarFailureCode.busy,
      );
      var shutdownFinished = false;
      final shutting = controller.shutdown().then(
        (_) => shutdownFinished = true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(shutdownFinished, isFalse);
      refreshDetail.complete(data.detailValue(data.item.reference));
      await first;
      await shutting;
      expect(data.prepares, 1);
      expect(data.commits, 1);
      expect(shutdownFinished, isTrue);
    },
  );

  test(
    'committed write stays successful when the following read fails',
    () async {
      final data = _Data();
      final shell = _Shell();
      final controller = _controller(data, shell);
      await controller.load();
      data.commitHandler = (command) async {
        data.queryHandler = (_) => Future.error(
          const CalendarFailure(CalendarFailureCode.limitExceeded),
        );
        return data.receipt(command);
      };
      final receipt = await controller.execute(
        CreatePersonalEvent(_draft),
        expectedContext: data.context,
      );
      expect(receipt.replayed, isFalse);
      expect(controller.view.failure, CalendarFailureCode.limitExceeded);
      expect(controller.view.canWrite, isFalse);
      expect(controller.view.actionPending, isFalse);
      data.queryHandler = null;
      await controller.load(mode: CalendarViewMode.day);
      expect(controller.view.canWrite, isTrue);
    },
  );

  test(
    'source busy blocks new writes; progress loss preserves read-only facts',
    () async {
      final data = _Data();
      final shell = _Shell();
      final controller = _controller(data, shell);
      await controller.load();
      final prior = controller.view.window;
      shell.busy = true;
      shell.notifyListeners();
      await _failure(
        controller.execute(
          CreatePersonalEvent(_draft),
          expectedContext: data.context,
        ),
        CalendarFailureCode.busy,
      );
      expect(data.prepares, 0);
      shell.busy = false;
      shell.notifyListeners();
      expect(controller.view.canWrite, isTrue);
      data.signals.addError(StateError('synthetic progress fault'));
      await Future<void>.delayed(Duration.zero);
      expect(controller.view.failure, CalendarFailureCode.storageFailed);
      expect(controller.view.window, same(prior));
      expect(controller.view.canWrite, isFalse);
    },
  );

  test(
    'disposal never cancels or closes an externally owned business port',
    () async {
      final data = _Data();
      final shell = _Shell();
      final controller = _controller(data, shell);
      await controller.load();
      final committing = Completer<CalendarWriteReceipt>();
      CalendarCommand? pending;
      data.commitHandler = (command) {
        pending = command;
        return committing.future;
      };
      final writing = controller.execute(
        CreatePersonalEvent(_draft),
        expectedContext: data.context,
      );
      await Future<void>.delayed(Duration.zero);
      controller.dispose();
      committing.complete(data.receipt(pending!));
      expect((await writing).replayed, isFalse);
      expect(data.commits, 1);
      expect(data.signals.isClosed, isFalse);
    },
  );
}

CalendarWorkspaceController _controller(_Data data, _Shell shell) {
  final controller = CalendarWorkspaceController(
    calendar: data,
    shell: shell,
    clock: FixedClock(DateTime.utc(2026, 10, 12, 1)),
  );
  addTearDown(() async {
    await controller.shutdown();
    controller.dispose();
    await data.signals.close();
    shell.dispose();
  });
  return controller;
}

Future<void> _failure(Future<Object?> future, CalendarFailureCode code) =>
    expectLater(
      future,
      throwsA(
        isA<CalendarFailure>().having((error) => error.code, 'code', code),
      ),
    );

final class _Data implements LocalCalendarPort {
  final signals = StreamController<int>.broadcast();
  CalendarContext context = _context;
  int version = 1, queries = 0, prepares = 0, commits = 0;
  CalendarQuery? lastQuery;
  Future<CalendarWindow> Function(CalendarQuery)? queryHandler;
  Future<CalendarDetail> Function(CalendarReference)? detailHandler;
  Future<CalendarWriteReceipt> Function(CalendarCommand)? commitHandler;
  CalendarOccurrence get item => CalendarOccurrence(
    reference: CalendarReference(
      context,
      const CalendarIdentity(CalendarKind.personal, 1),
      version,
    ),
    title: _draft.title,
    startsAtUtc: _draft.start,
    endsAtUtc: _draft.end,
  );
  CalendarWindow window(CalendarQuery query) => CalendarWindow(
    context: context,
    revision: version,
    query: query,
    items: [item],
    segments: [],
    conflicts: [],
    matched: 1,
    truncated: false,
    conflictsTruncated: false,
  );
  CalendarDetail detailValue(CalendarReference reference) =>
      CalendarDetail(occurrence: item, personalDraft: _draft, relations: []);
  CalendarWriteReceipt receipt(CalendarCommand command) => CalendarWriteReceipt(
    operationId: command.operationId,
    revision: version,
    replayed: false,
    target: item.reference,
  );
  @override
  Stream<int> get changes => signals.stream;
  @override
  Future<CalendarWindow> query(CalendarQuery query) {
    queries++;
    lastQuery = query;
    return queryHandler?.call(query) ?? Future.value(window(query));
  }

  @override
  Future<CalendarDetail> detail(CalendarReference reference) =>
      detailHandler?.call(reference) ?? Future.value(detailValue(reference));
  @override
  Future<CalendarCommand> prepare(
    CalendarContext context,
    CalendarIntent intent,
  ) async {
    prepares++;
    return CalendarCommand(
      'calendar-local-${prepares.toRadixString(16).padLeft(32, '0')}',
      context,
      intent,
    );
  }

  @override
  Future<CalendarWriteReceipt> commit(CalendarCommand command) {
    commits++;
    return commitHandler?.call(command) ?? Future.value(receipt(command));
  }
}

final class _Shell extends ChangeNotifier implements AppShellPort {
  bool busy = false;
  @override
  AppShellView get view => AppShellView(
    jw: JwSyncView(),
    young: YoungSyncView(),
    globallyBusy: busy,
  );
  @override
  DateTime get today => _day;
  @override
  JwSyncPort get jw => throw StateError('Unexpected legacy source access');
  @override
  YoungSyncPort get young =>
      throw StateError('Unexpected legacy source access');
  @override
  AgendaSlice readAgenda({
    required DateTime day,
    AgendaFilter filter = AgendaFilter.all,
    bool includeHidden = false,
  }) => throw StateError('Unexpected legacy projection');
  @override
  Future<void> setHidden(AgendaReference reference, {required bool hidden}) =>
      throw StateError('Unexpected legacy write');
}
