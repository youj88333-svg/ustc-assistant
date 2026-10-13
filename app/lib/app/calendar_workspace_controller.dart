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
    implements CalendarWorkspacePort, TaskWorkspacePort {
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
    ++_queryGeneration;
    ++_detailGeneration;
    ++_taskQueryGeneration;
    ++_taskDetailGeneration;
    _selected = null;
    _detail = null;
    _selectedTask = null;
    _taskDetail = null;
    _window = null;
    _taskWindow = null;
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
    if (view.failure != null ||
        view.window == null ||
        taskView.failure != null ||
        taskView.window == null) {
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
    _notify();
  }

  void _scheduleRefresh() {
    if (_refreshQueued || _closing || _disposed || _pending) return;
    _refreshQueued = true;
    scheduleMicrotask(() {
      _refreshQueued = false;
      if (!_closing && !_disposed && !_pending) unawaited(_refreshAll());
    });
  }

  Future<void> _refreshAll() async {
    await load();
    if (tasks != null && !_closing && !_disposed) await loadTasks();
  }

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
      _notify();
    } catch (error) {
      if (!_taskCurrent(queryGeneration) ||
          generation != _taskDetailGeneration) {
        return;
      }
      _taskDetailLoading = false;
      _taskFailure = _code(error);
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
    );
    try {
      final result = await calendar.query(query);
      if (!_current(generation)) return;
      _window = result;
      _loading = false;
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
          _notify();
        } else {
          await select(latest.first.reference);
        }
      }
    } catch (error) {
      if (!_current(generation)) return;
      _loading = false;
      _failure = _code(error);
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
    _notify();
    if (reference == null) return;
    try {
      final detail = await calendar.detail(reference);
      if (!_current(queryGeneration) || generation != _detailGeneration) return;
      _detail = detail;
      _detailLoading = false;
      _failure = null;
      _notify();
    } catch (error) {
      if (!_current(queryGeneration) || generation != _detailGeneration) return;
      _detailLoading = false;
      _failure = _code(error);
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
        if (!_closing && !_disposed) {
          await _refreshAll();
        }
        // A query failure cannot turn an already committed command into a
        // reported write failure; the separate view failure exposes the read.
        result.complete(receipt);
      } catch (error) {
        final code = _code(error);
        if (!_closing && !_disposed) {
          _failure = code;
          _taskFailure = code;
        }
        result.completeError(CalendarFailure(code));
      } finally {
        _pending = false;
        _notify();
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
    ++_queryGeneration;
    ++_detailGeneration;
    ++_taskQueryGeneration;
    ++_taskDetailGeneration;
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
    ++_queryGeneration;
    ++_detailGeneration;
    ++_taskQueryGeneration;
    ++_taskDetailGeneration;
    shell.removeListener(_sourceChanged);
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
