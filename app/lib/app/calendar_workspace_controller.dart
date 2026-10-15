import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/agenda_contract.dart';
import '../core/calendar_contract.dart';
import '../core/contracts.dart';
import '../core/settings_contract.dart';
import 'app_shell_contract.dart';
import 'calendar_workspace_contract.dart';
import 'task_workspace_contract.dart';

/// C5 selection and notification adapter only. Every effective occurrence,
/// overlap and write result comes from C3, including sources loaded during sync.
final class CalendarWorkspaceController extends ChangeNotifier
    implements
        CalendarWorkspacePort,
        TaskWorkspacePort,
        CalendarTaskWorkspacePort {
  CalendarWorkspaceController({
    required this.calendar,
    required this.shell,
    LocalTaskPort? tasks,
    this.clock = const SystemClock(),
  }) : tasks =
           tasks ??
           (calendar is LocalTaskPort ? calendar as LocalTaskPort : null),
       _day = beijingDay(clock.nowUtc) {
    _lastJwData = shell.view.jw.data;
    _lastYoungData = shell.view.young.data;
    shell.addListener(_sourceChanged);
    _subscription = calendar.changes.listen(
      (_) => _scheduleRefresh(),
      onError: (Object _, StackTrace _) => _progressFailed(),
      onDone: _progressFailed,
    );
  }

  final LocalCalendarPort calendar;
  final LocalTaskPort? tasks;
  final AppShellPort shell;
  final AppClock clock;
  late final StreamSubscription<int> _subscription;
  DateTime _day;
  CalendarViewMode _mode = CalendarViewMode.week;
  CalendarFilter _filter = CalendarFilter.all;
  bool _includeInactive = false;
  CalendarWindow? _window;
  CalendarDetail? _detail;
  CalendarReference? _selected;
  CalendarFailureCode? _failure;
  bool _loading = false;
  bool _detailLoading = false;
  bool _pending = false;
  bool _progressUnavailable = false;
  bool _closing = false;
  bool _disposed = false;
  bool _refreshQueued = false;
  bool _refreshDirty = false;
  int? _refreshingEpoch;
  int _refreshEpoch = 0;
  int _queryGeneration = 0;
  int _detailGeneration = 0;
  Object? _lastJwData;
  Object? _lastYoungData;
  Future<void>? _activeAction;
  TaskQuery _taskQuery = const TaskQuery();
  TaskWindow? _taskWindow;
  TaskDetail? _taskDetail;
  TaskReference? _selectedTask;
  CalendarUndoView _undo = const CalendarUndoView();
  CalendarFailureCode? _taskFailure;
  bool _tasksLoading = false;
  bool _taskDetailLoading = false;
  int _taskQueryGeneration = 0;
  int _taskDetailGeneration = 0;
  TaskWindow? _calendarTasks;
  bool _calendarTasksLoading = false;
  CalendarFailureCode? _calendarTasksFailure;
  int _calendarTasksGeneration = 0;
  Timer? _timeRefreshTimer;
  int _timeRefreshGeneration = 0;
  bool _timeRefreshEnabled = false;

  static const _timeRefreshPollInterval = Duration(minutes: 1);

  @override
  TaskWorkspaceView get taskView => TaskWorkspaceView(
    window: _taskWindow,
    detail: _taskDetail,
    query: _taskQuery,
    undo: _undo,
    loading: _tasksLoading,
    detailLoading: _taskDetailLoading,
    actionPending: _pending,
    sourceBusy: shell.view.globallyBusy || shell.view.progressUnavailable,
    failure: _closing
        ? CalendarFailureCode.closed
        : _progressUnavailable
        ? CalendarFailureCode.storageFailed
        : _taskFailure,
  );

  @override
  DateTime get today => beijingDay(clock.nowUtc);

  @override
  DateTime get nowUtc => clock.nowUtc.toUtc();

  @override
  TaskWindow? get calendarTasks => _calendarTasks;

  @override
  bool get calendarTasksLoading => _calendarTasksLoading;

  @override
  CalendarFailureCode? get calendarTasksFailure => _calendarTasksFailure;

  @override
  CalendarWorkspaceView get view => CalendarWorkspaceView(
    day: _day,
    mode: _mode,
    filter: _filter,
    includeInactive: _includeInactive,
    window: _window,
    detail: _detail,
    loading: _loading,
    detailLoading: _detailLoading,
    actionPending: _pending,
    sourceBusy: shell.view.globallyBusy || shell.view.progressUnavailable,
    failure: _closing
        ? CalendarFailureCode.closed
        : _progressUnavailable
        ? CalendarFailureCode.storageFailed
        : _failure,
  );

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> resetAfterMaintenance(
    DisplayPreferences preferences, {
    required bool resetDay,
  }) async {
    ++_refreshEpoch;
    _refreshDirty = false;
    _timeRefreshEnabled = false;
    _cancelTimeRefresh();
    ++_queryGeneration;
    ++_detailGeneration;
    ++_taskQueryGeneration;
    ++_taskDetailGeneration;
    ++_calendarTasksGeneration;
    _selected = null;
    _detail = null;
    _selectedTask = null;
    _taskDetail = null;
    _window = null;
    _taskWindow = null;
    _calendarTasks = null;
    _calendarTasksLoading = false;
    _calendarTasksFailure = null;
    _undo = const CalendarUndoView();
    _taskQuery = const TaskQuery();
    if (resetDay) {
      _day = today;
      _filter = CalendarFilter.all;
    }
    await load(
      mode: preferences.calendarView == DefaultCalendarView.week
          ? CalendarViewMode.week
          : CalendarViewMode.day,
      includeInactive: preferences.includeInactive,
    );
    await loadTasks();
    await loadCalendarTasks();
    if (view.failure != null ||
        view.window == null ||
        taskView.failure != null ||
        taskView.window == null ||
        calendarTasksFailure != null ||
        calendarTasks == null) {
      throw const SettingsFailure(SettingsFailureCode.storageFailed);
    }
  }

  void _progressFailed() {
    if (_closing || _disposed) return;
    _progressUnavailable = true;
    _notify();
  }

  void _sourceChanged() {
    if (_closing || _disposed) return;
    final jw = shell.view.jw.data;
    final young = shell.view.young.data;
    if (!identical(jw, _lastJwData) || !identical(young, _lastYoungData)) {
      _lastJwData = jw;
      _lastYoungData = young;
      _scheduleRefresh();
    }
    _queueRefreshDrain();
    _notify();
  }

  void _scheduleRefresh() {
    if (_closing || _disposed) return;
    _refreshDirty = true;
    _queueRefreshDrain();
  }

  void _queueRefreshDrain() {
    if (_refreshQueued ||
        !_refreshDirty ||
        _closing ||
        _disposed ||
        _pending ||
        shell.view.globallyBusy) {
      return;
    }
    _refreshQueued = true;
    scheduleMicrotask(() {
      _refreshQueued = false;
      if (_closing || _disposed) {
        _refreshDirty = false;
        return;
      }
      if (!_refreshDirty ||
          _pending ||
          shell.view.globallyBusy ||
          _refreshingEpoch == _refreshEpoch) {
        return;
      }
      _refreshDirty = false;
      final epoch = _refreshEpoch;
      _refreshingEpoch = epoch;
      unawaited(_drainRefresh(epoch));
    });
  }

  Future<void> _drainRefresh(int epoch) async {
    try {
      await _refreshAll(refreshEpoch: epoch);
    } finally {
      if (_refreshingEpoch == epoch) _refreshingEpoch = null;
      _queueRefreshDrain();
    }
  }

  Future<void> _refreshAll({int? refreshEpoch}) async {
    final epoch = refreshEpoch ?? _refreshEpoch;
    if (!_refreshCurrent(epoch)) return;
    await load();
    if (_refreshCurrent(epoch) && tasks != null) {
      await loadTasks();
      if (_refreshCurrent(epoch)) await loadCalendarTasks();
    }
  }

  bool _refreshCurrent(int epoch) =>
      !_closing && !_disposed && epoch == _refreshEpoch;

  void _cancelTimeRefresh() {
    ++_timeRefreshGeneration;
    _timeRefreshTimer?.cancel();
    _timeRefreshTimer = null;
  }

  void _rescheduleTimeRefresh() {
    _cancelTimeRefresh();
    if (!_timeRefreshEnabled || _closing || _disposed) return;

    final now = clock.nowUtc.toUtc();
    DateTime? nextBoundary;
    void consider(DateTime? boundary) {
      if (boundary == null) return;
      final instant = boundary.toUtc();
      if (instant.isAfter(now) &&
          (nextBoundary == null || instant.isBefore(nextBoundary!))) {
        nextBoundary = instant;
      }
    }

    void considerTask(TaskRecord task) {
      if (task.status == TaskStatus.completed ||
          task.status == TaskStatus.cancelled) {
        return;
      }
      consider(task.draft.deadlineAtUtc);
    }

    for (final task in _taskWindow?.items ?? const <TaskRecord>[]) {
      considerTask(task);
    }
    for (final task in _calendarTasks?.items ?? const <TaskRecord>[]) {
      considerTask(task);
    }
    final selectedTask = _taskDetail?.task;
    if (selectedTask != null) considerTask(selectedTask);

    void considerBlock(PlanBlockRecord? block) {
      if (block?.status == PlanBlockStatus.planned) {
        consider(block!.draft.endsAtUtc);
      }
    }

    for (final block in _taskDetail?.blocks ?? const <PlanBlockRecord>[]) {
      considerBlock(block);
    }
    considerBlock(_detail?.planBlock);
    for (final occurrence in _window?.items ?? const <CalendarOccurrence>[]) {
      if (occurrence.reference.identity.kind == CalendarKind.planBlock &&
          occurrence.planBlockStatus == PlanBlockStatus.planned) {
        consider(occurrence.endsAtUtc);
      }
    }

    final beijingTomorrow = beijingDay(now).add(const Duration(days: 1));
    consider(beijingTomorrow.subtract(const Duration(hours: 8)));
    final untilBoundary = nextBoundary?.difference(now);
    final delay =
        untilBoundary == null || untilBoundary > _timeRefreshPollInterval
        ? _timeRefreshPollInterval
        : untilBoundary;
    final generation = _timeRefreshGeneration;
    _timeRefreshTimer = Timer(delay, () {
      if (generation != _timeRefreshGeneration ||
          _closing ||
          _disposed ||
          !_timeRefreshEnabled) {
        return;
      }
      _timeRefreshTimer = null;
      _notify();
      _rescheduleTimeRefresh();
    });
  }

  @override
  Future<void> loadCalendarTasks() async {
    if (_closing || _disposed) return;
    final generation = ++_calendarTasksGeneration;
    if (tasks == null) {
      _calendarTasks = null;
      _calendarTasksLoading = false;
      _calendarTasksFailure = CalendarFailureCode.storageFailed;
      _rescheduleTimeRefresh();
      _notify();
      return;
    }
    _calendarTasksLoading = true;
    _calendarTasksFailure = null;
    _notify();
    try {
      final result = await tasks!.queryTasks(
        const TaskQuery(filter: TaskFilter.all, limit: 500),
      );
      if (!_calendarTasksCurrent(generation)) return;
      _calendarTasks = result;
      _calendarTasksLoading = false;
      _calendarTasksFailure = null;
      _timeRefreshEnabled = true;
      _rescheduleTimeRefresh();
      _notify();
    } catch (error) {
      if (!_calendarTasksCurrent(generation)) return;
      _calendarTasks = null;
      _calendarTasksLoading = false;
      _calendarTasksFailure = _code(error);
      _rescheduleTimeRefresh();
      _notify();
    }
  }

  bool _calendarTasksCurrent(int generation) =>
      !_closing && !_disposed && generation == _calendarTasksGeneration;

  bool _taskCurrent(int generation) =>
      !_closing && !_disposed && generation == _taskQueryGeneration;

  @override
  Future<void> loadTasks({TaskQuery? query}) async {
    if (_closing || _disposed || tasks == null) return;
    if (query != null) {
      _taskQuery = query;
      _taskWindow = null;
      _selectedTask = null;
      _taskDetail = null;
      ++_taskDetailGeneration;
      _taskDetailLoading = false;
      _rescheduleTimeRefresh();
    }
    final generation = ++_taskQueryGeneration;
    _tasksLoading = true;
    _taskFailure = null;
    _notify();
    try {
      final result = await tasks!.queryTasks(_taskQuery);
      final undo = await tasks!.queryUndo(result.context);
      if (!_taskCurrent(generation)) return;
      _taskWindow = result;
      _undo = undo;
      _tasksLoading = false;
      _timeRefreshEnabled = true;
      _rescheduleTimeRefresh();
      _notify();
      final selected = _selectedTask;
      if (selected != null) {
        final latest = result.items.where(
          (t) => t.reference.localId == selected.localId,
        );
        if (selected.context != result.context || latest.isEmpty) {
          _selectedTask = null;
          _taskDetail = null;
          ++_taskDetailGeneration;
          _taskDetailLoading = false;
          _rescheduleTimeRefresh();
          _notify();
        } else {
          await selectTask(latest.first.reference);
        }
      }
    } catch (error) {
      if (!_taskCurrent(generation)) return;
      _tasksLoading = false;
      _taskFailure = _code(error);
      _undo = const CalendarUndoView();
      _rescheduleTimeRefresh();
      _notify();
    }
  }

  @override
  Future<void> selectTask(TaskReference? reference) async {
    if (_closing || _disposed || tasks == null) return;
    final generation = ++_taskDetailGeneration;
    final queryGeneration = _taskQueryGeneration;
    _selectedTask = reference;
    _taskDetail = null;
    _taskDetailLoading = reference != null;
    _rescheduleTimeRefresh();
    _notify();
    if (reference == null) return;
    try {
      final detail = await tasks!.taskDetail(reference);
      if (!_taskCurrent(queryGeneration) ||
          generation != _taskDetailGeneration) {
        return;
      }
      _taskDetail = detail;
      _taskDetailLoading = false;
      _taskFailure = null;
      _timeRefreshEnabled = true;
      _rescheduleTimeRefresh();
      _notify();
    } catch (error) {
      if (!_taskCurrent(queryGeneration) ||
          generation != _taskDetailGeneration) {
        return;
      }
      _taskDetailLoading = false;
      _taskFailure = _code(error);
      _rescheduleTimeRefresh();
      _notify();
    }
  }

  @override
  Future<void> load({
    DateTime? day,
    CalendarViewMode? mode,
    CalendarFilter? filter,
    bool? includeInactive,
  }) async {
    if (_closing || _disposed) return;
    final changing =
        day != null ||
        mode != null ||
        filter != null ||
        includeInactive != null;
    if (day != null) _day = calendarDay(day);
    if (mode != null) _mode = mode;
    if (filter != null) _filter = filter;
    if (includeInactive != null) _includeInactive = includeInactive;
    if (changing) {
      _selected = null;
      _detail = null;
      ++_detailGeneration;
      _detailLoading = false;
      _window = null;
      _rescheduleTimeRefresh();
    }
    final generation = ++_queryGeneration;
    _loading = true;
    _failure = null;
    _notify();
    final first = _mode == CalendarViewMode.day
        ? _day
        : _day.subtract(Duration(days: _day.weekday - 1));
    final query = CalendarQuery(
      firstDay: first,
      endDayExclusive: first.add(
        Duration(days: _mode == CalendarViewMode.day ? 1 : 7),
      ),
      filter: _filter,
      includeHidden: _includeInactive,
      includeSkipped: _includeInactive,
      includeRetired: _includeInactive,
    );
    try {
      final result = await calendar.query(query);
      if (!_current(generation)) return;
      _window = result;
      _loading = false;
      _timeRefreshEnabled = true;
      _rescheduleTimeRefresh();
      _notify();
      final selected = _selected;
      if (selected != null) {
        final latest = result.items.where(
          (item) => item.reference.identity == selected.identity,
        );
        if (selected.context != result.context || latest.isEmpty) {
          _selected = null;
          _detail = null;
          ++_detailGeneration;
          _detailLoading = false;
          _rescheduleTimeRefresh();
          _notify();
        } else {
          await select(latest.first.reference);
        }
      }
    } catch (error) {
      if (!_current(generation)) return;
      _loading = false;
      _failure = _code(error);
      _rescheduleTimeRefresh();
      _notify();
    }
  }

  bool _current(int generation) =>
      !_closing && !_disposed && generation == _queryGeneration;

  @override
  Future<void> select(CalendarReference? reference) async {
    if (_closing || _disposed) return;
    final generation = ++_detailGeneration;
    final queryGeneration = _queryGeneration;
    _selected = reference;
    _detail = null;
    _detailLoading = reference != null;
    _rescheduleTimeRefresh();
    _notify();
    if (reference == null) return;
    try {
      final detail = await calendar.detail(reference);
      if (!_current(queryGeneration) || generation != _detailGeneration) return;
      _detail = detail;
      _detailLoading = false;
      _failure = null;
      _timeRefreshEnabled = true;
      _rescheduleTimeRefresh();
      _notify();
    } catch (error) {
      if (!_current(queryGeneration) || generation != _detailGeneration) return;
      _detailLoading = false;
      _failure = _code(error);
      _rescheduleTimeRefresh();
      _notify();
    }
  }

  CalendarFailureCode _code(Object error) =>
      error is CalendarFailure ? error.code : CalendarFailureCode.storageFailed;

  @override
  Future<CalendarWriteReceipt> execute(
    CalendarIntent intent, {
    required CalendarContext expectedContext,
  }) => _execute(intent, expectedContext: expectedContext, fromTasks: false);

  @override
  Future<CalendarWriteReceipt> executeTask(
    CalendarIntent intent, {
    required CalendarContext expectedContext,
  }) => _execute(intent, expectedContext: expectedContext, fromTasks: true);

  Future<CalendarWriteReceipt> _execute(
    CalendarIntent intent, {
    required CalendarContext expectedContext,
    required bool fromTasks,
  }) {
    if (_closing || _disposed) {
      return Future.error(const CalendarFailure(CalendarFailureCode.closed));
    }
    final canWrite = fromTasks ? taskView.canWrite : view.canWrite;
    final failure = fromTasks ? taskView.failure : view.failure;
    if (!canWrite) {
      return Future.error(
        CalendarFailure(
          view.sourceBusy || _pending || (fromTasks ? _tasksLoading : _loading)
              ? CalendarFailureCode.busy
              : failure ?? CalendarFailureCode.storageFailed,
        ),
      );
    }
    if (expectedContext !=
        (fromTasks ? _taskWindow!.context : _window!.context)) {
      return Future.error(
        const CalendarFailure(CalendarFailureCode.staleReference),
      );
    }
    final actionRefreshEpoch = _refreshEpoch;
    final result = Completer<CalendarWriteReceipt>();
    _pending = true;
    _failure = null;
    _taskFailure = null;
    final context = expectedContext;
    _notify();
    _activeAction = () async {
      try {
        final command = await calendar.prepare(context, intent);
        final receipt = await calendar.commit(command);
        if (_refreshCurrent(actionRefreshEpoch)) {
          // The post-commit read satisfies changes observed while this write
          // was pending. Keep them dirty if maintenance or a source job blocks
          // the read; new signals during the read set the bit again.
          if (shell.view.globallyBusy) {
            _refreshDirty = true;
          } else {
            _refreshDirty = false;
            await _refreshAll(refreshEpoch: actionRefreshEpoch);
          }
        }
        // A query failure cannot turn an already committed command into a
        // reported write failure; the separate view failure exposes the read.
        result.complete(receipt);
      } catch (error) {
        final code = _code(error);
        if (_refreshCurrent(actionRefreshEpoch)) {
          _failure = code;
          _taskFailure = code;
        }
        result.completeError(CalendarFailure(code));
      } finally {
        _pending = false;
        _notify();
        _queueRefreshDrain();
      }
    }();
    return result.future;
  }

  Future<void> shutdown() async {
    if (_closing) {
      await _activeAction;
      return;
    }
    _closing = true;
    ++_refreshEpoch;
    _refreshDirty = false;
    _timeRefreshEnabled = false;
    _cancelTimeRefresh();
    ++_queryGeneration;
    ++_detailGeneration;
    ++_taskQueryGeneration;
    ++_taskDetailGeneration;
    ++_calendarTasksGeneration;
    shell.removeListener(_sourceChanged);
    await _subscription.cancel();
    await _activeAction;
    _notify();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _closing = true;
    ++_refreshEpoch;
    _refreshDirty = false;
    _timeRefreshEnabled = false;
    _cancelTimeRefresh();
    ++_queryGeneration;
    ++_detailGeneration;
    ++_taskQueryGeneration;
    ++_taskDetailGeneration;
    ++_calendarTasksGeneration;
    shell.removeListener(_sourceChanged);
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
