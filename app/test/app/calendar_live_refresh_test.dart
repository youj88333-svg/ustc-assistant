import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/app_shell_contract.dart';
import 'package:ustc_assistant_m0/app/calendar_task_band.dart';
import 'package:ustc_assistant_m0/app/calendar_workspace_controller.dart';
import 'package:ustc_assistant_m0/app/task_workspace_contract.dart';
import 'package:ustc_assistant_m0/app/task_workspace_page.dart';
import 'package:ustc_assistant_m0/core/agenda_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/jobs/jw_sync_port.dart';
import 'package:ustc_assistant_m0/jobs/young_sync_port.dart';

const _context = CalendarContext(
  owner: 'synthetic-live-refresh-owner',
  resetEpoch: 0,
  agendaEpoch: 0,
);
final _start = DateTime.utc(2026, 10, 12, 1);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'queued Agent change drains after a pending local commit fails',
    () async {
      final clock = _MutableClock(_start);
      final calendar = _CalendarData();
      final shell = _Shell();
      final task = _taskRecord(id: 31, title: 'Agent 修改前');
      final tasks = _Tasks(records: [task]);
      final controller = CalendarWorkspaceController(
        calendar: calendar,
        shell: shell,
        tasks: tasks,
        clock: clock,
      );
      addTearDown(() async {
        await controller.shutdown();
        controller.dispose();
        await calendar.signals.close();
        shell.dispose();
      });

      await controller.load();
      await controller.select(calendar.item.reference);
      await controller.loadTasks();
      await controller.selectTask(task.reference);

      final gate = Completer<void>();
      calendar.commitGate = gate;
      calendar.commitEntered = Completer<void>();
      // A synchronous event queues the refresh microtask before execute sets
      // pending. The queued callback must retain the dirty bit when it runs.
      calendar.signalChange();
      final writing = controller.execute(
        CreatePersonalEvent(
          PersonalEventDraft(
            title: '本地写入',
            start: _start,
            end: _start.add(const Duration(hours: 1)),
          ),
        ),
        expectedContext: _context,
      );
      await calendar.commitEntered!.future;

      calendar.replace(title: 'Agent 修改后');
      tasks.records = [_taskRecord(id: 31, version: 2, title: 'Agent 修改后')];
      calendar.signalChange();
      gate.complete();

      await expectLater(
        writing,
        throwsA(
          isA<CalendarFailure>().having(
            (error) => error.code,
            'code',
            CalendarFailureCode.staleReference,
          ),
        ),
      );
      await _waitUntil(
        () =>
            calendar.queries >= 2 &&
            calendar.details >= 2 &&
            tasks.queries >= 3 &&
            tasks.details >= 2,
      );

      expect(controller.view.detail!.occurrence.title, 'Agent 修改后');
      expect(controller.taskView.detail!.task.draft.title, 'Agent 修改后');
      expect(controller.taskView.detail!.task.reference.version, 2);
      expect(controller.calendarTasks!.items.single.draft.title, 'Agent 修改后');
      expect(controller.taskView.actionPending, isFalse);
    },
  );

  testWidgets(
    'loaded deadline and planned block end notify without rereading',
    (tester) async {
      final clock = _MutableClock(_start);
      final calendar = _CalendarData();
      final shell = _Shell();
      final deadline = _start.add(const Duration(milliseconds: 160));
      final blockEnd = _start.add(const Duration(milliseconds: 320));
      final task = _taskRecord(id: 41, deadline: deadline);
      final block = _planBlock(task, endsAtUtc: blockEnd);
      final tasks = _Tasks(records: [task], blocks: [block]);
      final controller = CalendarWorkspaceController(
        calendar: calendar,
        shell: shell,
        tasks: tasks,
        clock: clock,
      );

      try {
        await controller.loadTasks();
        await controller.selectTask(task.reference);
        final taskReads = tasks.queries;
        final detailReads = tasks.details;
        final calendarReads = calendar.queries;
        var notifications = 0;
        controller.addListener(() => notifications++);

        clock.nowUtc = deadline;
        await tester.pump(const Duration(milliseconds: 160));
        expect(notifications, greaterThanOrEqualTo(1));

        clock.nowUtc = blockEnd;
        await tester.pump(const Duration(milliseconds: 160));
        expect(notifications, greaterThanOrEqualTo(2));
        expect(tasks.queries, taskReads);
        expect(tasks.details, detailReads);
        expect(calendar.queries, calendarReads);
        expect(controller.taskView.detail!.task.status, TaskStatus.active);
        expect(
          controller.taskView.detail!.blocks.single.status,
          PlanBlockStatus.planned,
        );
        expect(
          controller.taskView.detail!.blocks.single.awaitingReview(
            clock.nowUtc,
          ),
          isTrue,
        );
      } finally {
        await tester.runAsync(() async {
          await controller.shutdown();
          controller.dispose();
          await calendar.signals.close();
          shell.dispose();
        });
      }
    },
  );

  test(
    'shutdown cancels queued refresh and time timer without another read',
    () async {
      final clock = _MutableClock(_start);
      final calendar = _CalendarData();
      final shell = _Shell();
      final tasks = _Tasks(
        records: [
          _taskRecord(
            id: 51,
            deadline: _start.add(const Duration(milliseconds: 80)),
          ),
        ],
      );
      final controller = CalendarWorkspaceController(
        calendar: calendar,
        shell: shell,
        tasks: tasks,
        clock: clock,
      );
      var cleanedUp = false;
      Future<void> cleanup() async {
        if (cleanedUp) return;
        cleanedUp = true;
        await controller.shutdown();
        controller.dispose();
        await calendar.signals.close();
        shell.dispose();
      }

      addTearDown(cleanup);
      await controller.load();
      await controller.loadTasks();
      final taskReads = tasks.queries;
      final calendarReads = calendar.queries;

      final gate = Completer<void>();
      calendar.commitGate = gate;
      calendar.commitEntered = Completer<void>();
      // This event is queued while the write owns the controller. Shutdown
      // must discard it instead of restarting reads after closure.
      final writing = controller.execute(
        CreatePersonalEvent(
          PersonalEventDraft(
            title: '本地写入',
            start: _start,
            end: _start.add(const Duration(hours: 1)),
          ),
        ),
        expectedContext: _context,
      );
      await calendar.commitEntered!.future;
      calendar.signalChange();
      final shuttingDown = controller.shutdown();
      gate.complete();
      await expectLater(writing, throwsA(isA<CalendarFailure>()));
      await shuttingDown;
      final readsAtClose = (tasks.queries, calendar.queries);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(tasks.queries, readsAtClose.$1);
      expect(calendar.queries, readsAtClose.$2);
      expect(tasks.queries, taskReads);
      expect(calendar.queries, calendarReads);
      await cleanup();
    },
  );

  testWidgets(
    'Beijing midnight refreshes the date without rereading task data',
    (tester) async {
      final midnight = DateTime.utc(2026, 10, 12, 16);
      final clock = _MutableClock(
        midnight.subtract(const Duration(milliseconds: 160)),
      );
      final calendar = _CalendarData();
      final shell = _Shell();
      final tasks = _Tasks(records: [_taskRecord(id: 56)]);
      final controller = CalendarWorkspaceController(
        calendar: calendar,
        shell: shell,
        tasks: tasks,
        clock: clock,
      );

      try {
        await controller.loadTasks();
        final taskReads = tasks.queries;
        final calendarReads = calendar.queries;
        var notifications = 0;
        controller.addListener(() => notifications++);

        clock.nowUtc = midnight;
        await tester.pump(const Duration(milliseconds: 160));

        expect(notifications, greaterThanOrEqualTo(1));
        expect(controller.today, DateTime.utc(2026, 10, 13));
        expect(tasks.queries, taskReads);
        expect(calendar.queries, calendarReads);
      } finally {
        await tester.runAsync(() async {
          await controller.shutdown();
          controller.dispose();
          await calendar.signals.close();
          shell.dispose();
        });
      }
    },
  );

  testWidgets(
    'deadline equality uses the shared clock for task and block warnings',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final now = _start;
      final task = _taskRecord(id: 61, deadline: now);
      final block = _planBlock(task, endsAtUtc: now);
      final port = _PageTaskPort(
        nowUtc: now,
        task: task,
        block: block,
        detailNowUtc: now.subtract(const Duration(seconds: 1)),
      );
      addTearDown(port.dispose);

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Scaffold(body: TaskWorkspacePage(port: port)),
        ),
      );
      await tester.pump();

      expect(find.textContaining('已过截止'), findsOneWidget);
      expect(find.text('已到时间 · 待复核'), findsOneWidget);
      expect(
        calendarTaskDeadlineWarning(task, now),
        CalendarTaskDeadlineWarning.overdue,
      );
      expect(task.status, TaskStatus.active);
      expect(block.status, PlanBlockStatus.planned);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 30; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue, reason: 'live refresh did not finish');
}

TaskRecord _taskRecord({
  required int id,
  int version = 1,
  String title = '合成任务',
  DateTime? deadline,
}) => TaskRecord(
  reference: TaskReference(_context, id, version),
  draft: TaskDraft(title: title, deadlineAtUtc: deadline),
  status: TaskStatus.active,
  createdAtUtc: _start,
  updatedAtUtc: _start,
  blockCount: 1,
);

PlanBlockRecord _planBlock(TaskRecord task, {required DateTime endsAtUtc}) =>
    PlanBlockRecord(
      reference: CalendarReference(
        _context,
        const CalendarIdentity(CalendarKind.planBlock, 91),
        task.reference.version,
      ),
      task: task.reference,
      taskTitle: task.draft.title,
      taskStatus: task.status,
      draft: PlanBlockDraft(
        startsAtUtc: endsAtUtc.subtract(const Duration(hours: 1)),
        endsAtUtc: endsAtUtc,
      ),
      status: PlanBlockStatus.planned,
    );

final class _MutableClock implements AppClock {
  _MutableClock(this.nowUtc);
  @override
  DateTime nowUtc;
}

final class _CalendarData implements LocalCalendarPort {
  final StreamController<int> signals = StreamController<int>.broadcast(
    sync: true,
  );
  String title = '合成日程';
  int version = 1;
  int revision = 1;
  int queries = 0;
  int details = 0;
  int prepares = 0;
  Completer<void>? commitGate;
  Completer<void>? commitEntered;

  CalendarOccurrence get item => CalendarOccurrence(
    reference: CalendarReference(
      _context,
      const CalendarIdentity(CalendarKind.personal, 11),
      version,
    ),
    title: title,
    startsAtUtc: _start,
    endsAtUtc: _start.add(const Duration(hours: 1)),
  );

  void replace({required String title}) {
    this.title = title;
    version++;
    revision++;
  }

  void signalChange() => signals.add(revision);

  @override
  Stream<int> get changes => signals.stream;

  @override
  Future<CalendarWindow> query(CalendarQuery query) async {
    queries++;
    return CalendarWindow(
      context: _context,
      revision: revision,
      query: query,
      items: [item],
      segments: const [],
      conflicts: const [],
      matched: 1,
      truncated: false,
      conflictsTruncated: false,
    );
  }

  @override
  Future<CalendarDetail> detail(CalendarReference reference) async {
    details++;
    return CalendarDetail(
      occurrence: item,
      personalDraft: PersonalEventDraft(
        title: title,
        start: _start,
        end: _start.add(const Duration(hours: 1)),
      ),
      relations: const [],
    );
  }

  @override
  Future<CalendarCommand> prepare(
    CalendarContext context,
    CalendarIntent intent,
  ) async => CalendarCommand(
    'live-refresh-${(++prepares).toString().padLeft(32, '0')}',
    context,
    intent,
  );

  @override
  Future<CalendarWriteReceipt> commit(CalendarCommand command) async {
    commitEntered?.complete();
    await commitGate?.future;
    throw const CalendarFailure(CalendarFailureCode.staleReference);
  }
}

final class _Tasks implements LocalTaskPort {
  _Tasks({required this.records, this.blocks = const []});

  List<TaskRecord> records;
  List<PlanBlockRecord> blocks;
  int queries = 0;
  int details = 0;

  @override
  Future<TaskWindow> queryTasks(TaskQuery query) async {
    queries++;
    final items = records
        .where((task) {
          return switch (query.filter) {
            TaskFilter.open =>
              task.status == TaskStatus.active ||
                  task.status == TaskStatus.blocked,
            TaskFilter.active => task.status == TaskStatus.active,
            TaskFilter.blocked => task.status == TaskStatus.blocked,
            TaskFilter.completed => task.status == TaskStatus.completed,
            TaskFilter.cancelled => task.status == TaskStatus.cancelled,
            TaskFilter.all => true,
          };
        })
        .toList(growable: false);
    return TaskWindow(
      context: _context,
      revision: queries,
      query: query,
      items: items,
      matched: items.length,
      truncated: false,
    );
  }

  @override
  Future<TaskDetail> taskDetail(TaskReference reference) async {
    details++;
    final task = records.singleWhere(
      (candidate) => candidate.reference.localId == reference.localId,
    );
    return TaskDetail(task: task, blocks: blocks, nowUtc: _start);
  }

  @override
  Future<CalendarUndoView> queryUndo(CalendarContext context) async =>
      const CalendarUndoView();
}

final class _Shell extends ChangeNotifier implements AppShellPort {
  @override
  AppShellView get view => AppShellView(
    jw: JwSyncView(),
    young: YoungSyncView(),
    globallyBusy: false,
  );

  @override
  DateTime get today => _start;

  @override
  JwSyncPort get jw => throw StateError('unexpected legacy source access');

  @override
  YoungSyncPort get young =>
      throw StateError('unexpected legacy source access');

  @override
  AgendaSlice readAgenda({
    required DateTime day,
    AgendaFilter filter = AgendaFilter.all,
    bool includeHidden = false,
  }) => throw StateError('unexpected legacy projection');

  @override
  Future<void> setHidden(AgendaReference reference, {required bool hidden}) =>
      throw StateError('unexpected legacy write');
}

final class _PageTaskPort extends ChangeNotifier
    implements TaskWorkspacePort, CalendarTaskWorkspacePort {
  _PageTaskPort({
    required this.nowUtc,
    required TaskRecord task,
    required PlanBlockRecord block,
    required DateTime detailNowUtc,
  }) : _view = TaskWorkspaceView(
         window: TaskWindow(
           context: _context,
           revision: 1,
           query: const TaskQuery(),
           items: [task],
           matched: 1,
           truncated: false,
         ),
         detail: TaskDetail(task: task, blocks: [block], nowUtc: detailNowUtc),
       ),
       _calendarTasks = TaskWindow(
         context: _context,
         revision: 1,
         query: const TaskQuery(filter: TaskFilter.all, limit: 500),
         items: [task],
         matched: 1,
         truncated: false,
       );

  @override
  final DateTime nowUtc;
  final TaskWorkspaceView _view;
  final TaskWindow _calendarTasks;

  @override
  TaskWorkspaceView get taskView => _view;

  @override
  TaskWindow get calendarTasks => _calendarTasks;

  @override
  bool get calendarTasksLoading => false;

  @override
  CalendarFailureCode? get calendarTasksFailure => null;

  @override
  DateTime get today => beijingDay(nowUtc);

  @override
  Future<void> loadTasks({TaskQuery? query}) async {}

  @override
  Future<void> selectTask(TaskReference? reference) async {}

  @override
  Future<void> loadCalendarTasks() async {}

  @override
  Future<CalendarWriteReceipt> executeTask(
    CalendarIntent intent, {
    required CalendarContext expectedContext,
  }) => throw UnimplementedError();
}
