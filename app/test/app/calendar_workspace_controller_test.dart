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
    'task write keeps the shared mutex through both views, undo, and selected details',
    () async {
      final data = _Data();
      final shell = _Shell();
      final tasks = _Tasks(records: [_taskRecord(_context, 41, '阶段报告')]);
      final controller = _controller(data, shell, tasks: tasks);
      await controller.load();
      await controller.select(data.item.reference);
      await controller.loadTasks();
      await controller.selectTask(tasks.records.single.reference);

      final calendarWindow = Completer<CalendarWindow>();
      final calendarWindowEntered = Completer<void>();
      final calendarDetail = Completer<CalendarDetail>();
      final calendarDetailEntered = Completer<void>();
      data.queryHandler = (_) {
        calendarWindowEntered.complete();
        return calendarWindow.future;
      };
      data.detailHandler = (_) {
        calendarDetailEntered.complete();
        return calendarDetail.future;
      };

      final taskWindow = Completer<TaskWindow>();
      final taskWindowEntered = Completer<void>();
      final taskUndo = Completer<CalendarUndoView>();
      final taskUndoEntered = Completer<void>();
      final taskDetail = Completer<TaskDetail>();
      final taskDetailEntered = Completer<void>();
      tasks.queryHandler = (_) {
        taskWindowEntered.complete();
        return taskWindow.future;
      };
      tasks.undoHandler = (_) {
        taskUndoEntered.complete();
        return taskUndo.future;
      };
      tasks.detailHandler = (_) {
        taskDetailEntered.complete();
        return taskDetail.future;
      };
      data.commitHandler = (command) async {
        final prior = tasks.records.single;
        tasks.records = [
          _taskRecord(
            prior.reference.context,
            prior.reference.localId,
            prior.draft.title,
            version: prior.reference.version + 1,
            status: TaskStatus.completed,
          ),
        ];
        tasks.undoId = 'undo-after-write';
        return data.receipt(command);
      };

      final target = tasks.records.single.reference;
      final writing = controller.executeTask(
        SetTaskStatus(target, TaskStatus.completed),
        expectedContext: target.context,
      );
      await calendarWindowEntered.future;
      expect(controller.view.actionPending, isTrue);
      expect(controller.taskView.actionPending, isTrue);
      expect(controller.view.canWrite, isFalse);
      expect(controller.taskView.canWrite, isFalse);
      await _failure(
        controller.execute(
          CreatePersonalEvent(_draft),
          expectedContext: data.context,
        ),
        CalendarFailureCode.busy,
      );
      expect(data.prepares, 1);
      expect(data.commits, 1);

      calendarWindow.complete(data.window(data.lastQuery!));
      await calendarDetailEntered.future;
      expect(controller.view.detailLoading, isTrue);
      expect(controller.view.actionPending, isTrue);
      calendarDetail.complete(data.detailValue(data.item.reference));

      await taskWindowEntered.future;
      expect(controller.view.actionPending, isTrue);
      expect(controller.taskView.actionPending, isTrue);
      taskWindow.complete(tasks.window(tasks.lastQuery!));
      await taskUndoEntered.future;
      taskUndo.complete(
        CalendarUndoView(
          reference: CalendarUndoReference(tasks.context, tasks.undoId),
        ),
      );
      await taskDetailEntered.future;
      expect(controller.taskView.undo.reference?.undoId, 'undo-after-write');
      expect(controller.taskView.detailLoading, isTrue);
      expect(controller.view.actionPending, isTrue);
      await _failure(
        controller.execute(
          CreatePersonalEvent(_draft),
          expectedContext: data.context,
        ),
        CalendarFailureCode.busy,
      );

      taskDetail.complete(tasks.detailValue(tasks.records.single.reference));
      await writing;
      expect(controller.view.detail, isNotNull);
      expect(controller.taskView.detail!.task.status, TaskStatus.completed);
      expect(controller.taskView.detail!.task.reference.version, 2);
      expect(controller.view.actionPending, isFalse);
      expect(controller.taskView.actionPending, isFalse);
      expect(tasks.queries, 2);
      expect(tasks.undoQueries, 2);
    },
  );

  test(
    'late Task query and detail reads cannot replace a newer filter or selection',
    () async {
      final data = _Data();
      final shell = _Shell();
      final oldTask = _taskRecord(_context, 51, '旧筛选任务');
      final currentTask = _taskRecord(_context, 52, '新筛选任务');
      final tasks = _Tasks(records: [oldTask, currentTask]);
      final controller = _controller(data, shell, tasks: tasks);
      await controller.loadTasks();

      final lateWindow = Completer<TaskWindow>();
      tasks.queryHandler = (query) => query.keyword == '旧'
          ? lateWindow.future
          : Future.value(tasks.window(query, items: [currentTask]));
      final oldQuery = TaskQuery(filter: TaskFilter.all, keyword: '旧');
      final currentQuery = TaskQuery(filter: TaskFilter.all, keyword: '新');
      final oldLoad = controller.loadTasks(query: oldQuery);
      await controller.loadTasks(query: currentQuery);

      final lateDetail = Completer<TaskDetail>();
      tasks.detailHandler = (reference) =>
          reference.localId == oldTask.reference.localId
          ? lateDetail.future
          : Future.value(tasks.detailValue(reference));
      final oldSelection = controller.selectTask(oldTask.reference);
      await controller.selectTask(currentTask.reference);
      lateWindow.complete(
        tasks.window(oldQuery, items: [oldTask], revision: 90),
      );
      await oldLoad;
      lateDetail.complete(tasks.detailValue(oldTask.reference));
      await oldSelection;

      expect(controller.taskView.query.keyword, '新');
      expect(controller.taskView.window!.query.keyword, '新');
      expect(
        controller.taskView.window!.items.single.reference.localId,
        currentTask.reference.localId,
      );
      expect(
        controller.taskView.detail!.task.reference.localId,
        currentTask.reference.localId,
      );
    },
  );

  test(
    'same Task id after epoch change cannot rebind old selection or creation form',
    () async {
      final data = _Data();
      final shell = _Shell();
      final tasks = _Tasks(records: [_taskRecord(_context, 61, '任务')]);
      final controller = _controller(data, shell, tasks: tasks);
      await controller.loadTasks();
      final oldReference = tasks.records.single.reference;
      await controller.selectTask(oldReference);
      expect(controller.taskView.detail, isNotNull);

      final nextContext = CalendarContext(
        owner: _context.owner,
        resetEpoch: _context.resetEpoch + 1,
        agendaEpoch: _context.agendaEpoch,
      );
      data.context = nextContext;
      tasks.context = nextContext;
      tasks.records = [
        _taskRecord(
          nextContext,
          oldReference.localId,
          '新 epoch 的同 ID 任务',
          version: oldReference.version + 1,
        ),
      ];
      await controller.loadTasks();
      expect(controller.taskView.window!.context, nextContext);
      expect(controller.taskView.detail, isNull);
      expect(tasks.detailReferences.length, 1);

      await controller.selectTask(oldReference);
      expect(controller.taskView.detail, isNull);
      expect(controller.taskView.failure, CalendarFailureCode.staleReference);
      await _failure(
        controller.executeTask(
          CreateTask(const TaskDraft(title: '迟到的新建表单')),
          expectedContext: oldReference.context,
        ),
        CalendarFailureCode.staleReference,
      );
      expect(data.prepares, 0);
      expect(tasks.detailReferences.last.context, _context);
    },
  );

  test(
    'source busy and progress stream failure also block Task writes',
    () async {
      final data = _Data();
      final shell = _Shell();
      final tasks = _Tasks(records: [_taskRecord(_context, 71, '任务')]);
      final controller = _controller(data, shell, tasks: tasks);
      await controller.loadTasks();

      shell.busy = true;
      shell.notifyListeners();
      expect(controller.taskView.sourceBusy, isTrue);
      await _failure(
        controller.executeTask(
          CreateTask(const TaskDraft(title: '来源忙时新建')),
          expectedContext: tasks.context,
        ),
        CalendarFailureCode.busy,
      );
      expect(data.prepares, 0);

      shell.busy = false;
      shell.notifyListeners();
      data.signals.addError(StateError('synthetic progress fault'));
      await Future<void>.delayed(Duration.zero);
      expect(controller.taskView.failure, CalendarFailureCode.storageFailed);
      await _failure(
        controller.executeTask(
          CreateTask(const TaskDraft(title: '进度流失效时新建')),
          expectedContext: tasks.context,
        ),
        CalendarFailureCode.storageFailed,
      );
      expect(data.prepares, 0);
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

CalendarWorkspaceController _controller(
  _Data data,
  _Shell shell, {
  LocalTaskPort? tasks,
}) {
  final controller = CalendarWorkspaceController(
    calendar: data,
    shell: shell,
    tasks: tasks,
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

TaskRecord _taskRecord(
  CalendarContext context,
  int localId,
  String title, {
  int version = 1,
  TaskStatus status = TaskStatus.active,
}) => TaskRecord(
  reference: TaskReference(context, localId, version),
  draft: TaskDraft(title: title),
  status: status,
  createdAtUtc: DateTime.utc(2026, 10, 1),
  updatedAtUtc: DateTime.utc(2026, 10, 12),
  blockCount: 0,
);

final class _Tasks implements LocalTaskPort {
  _Tasks({required List<TaskRecord> records, CalendarContext? context})
    : records = List.of(records),
      context = context ?? _context;

  CalendarContext context;
  List<TaskRecord> records;
  int queries = 0;
  int undoQueries = 0;
  int revision = 1;
  TaskQuery? lastQuery;
  String undoId = 'undo-initial';
  final List<TaskReference> detailReferences = [];
  Future<TaskWindow> Function(TaskQuery)? queryHandler;
  Future<TaskDetail> Function(TaskReference)? detailHandler;
  Future<CalendarUndoView> Function(CalendarContext)? undoHandler;

  TaskWindow window(TaskQuery query, {List<TaskRecord>? items, int? revision}) {
    final result = items ?? records;
    return TaskWindow(
      context: context,
      revision: revision ?? this.revision,
      query: query,
      items: result,
      matched: result.length,
      truncated: false,
    );
  }

  TaskDetail detailValue(TaskReference reference) {
    TaskRecord? record;
    for (final candidate in records) {
      if (candidate.reference.context == reference.context &&
          candidate.reference.localId == reference.localId &&
          candidate.reference.version == reference.version) {
        record = candidate;
        break;
      }
    }
    if (record == null) {
      throw const CalendarFailure(CalendarFailureCode.staleReference);
    }
    return TaskDetail(
      task: record,
      blocks: const [],
      nowUtc: DateTime.utc(2026, 10, 12, 1),
    );
  }

  @override
  Future<TaskWindow> queryTasks(TaskQuery query) {
    queries++;
    lastQuery = query;
    return queryHandler?.call(query) ?? Future.value(window(query));
  }

  @override
  Future<TaskDetail> taskDetail(TaskReference reference) {
    detailReferences.add(reference);
    final handler = detailHandler;
    if (handler != null) return handler(reference);
    try {
      return Future.value(detailValue(reference));
    } catch (error) {
      return Future.error(error);
    }
  }

  @override
  Future<CalendarUndoView> queryUndo(CalendarContext context) {
    undoQueries++;
    final handler = undoHandler;
    if (handler != null) return handler(context);
    if (context != this.context) {
      return Future.error(
        const CalendarFailure(CalendarFailureCode.staleReference),
      );
    }
    return Future.value(
      CalendarUndoView(reference: CalendarUndoReference(context, undoId)),
    );
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
