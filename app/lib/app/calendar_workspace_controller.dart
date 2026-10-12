import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/agenda_contract.dart';
import '../core/calendar_contract.dart';
import '../core/contracts.dart';
import 'app_shell_contract.dart';
import 'calendar_workspace_contract.dart';

/// C5 selection and notification adapter only. Every effective occurrence,
/// overlap and write result comes from C3, including sources loaded during sync.
final class CalendarWorkspaceController extends ChangeNotifier
    implements CalendarWorkspacePort {
  CalendarWorkspaceController({
    required this.calendar,
    required this.shell,
    this.clock = const SystemClock(),
  }) : _day = beijingDay(clock.nowUtc) {
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
      if (!_closing && !_disposed && !_pending) unawaited(load());
    });
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
  }) {
    if (_closing || _disposed) {
      return Future.error(const CalendarFailure(CalendarFailureCode.closed));
    }
    if (!view.canWrite) {
      return Future.error(
        CalendarFailure(
          view.sourceBusy || _pending || _loading
              ? CalendarFailureCode.busy
              : view.failure ?? CalendarFailureCode.storageFailed,
        ),
      );
    }
    if (expectedContext != _window!.context) {
      return Future.error(
        const CalendarFailure(CalendarFailureCode.staleReference),
      );
    }
    final result = Completer<CalendarWriteReceipt>();
    _pending = true;
    _failure = null;
    final context = expectedContext;
    _notify();
    _activeAction = () async {
      try {
        final command = await calendar.prepare(context, intent);
        final receipt = await calendar.commit(command);
        if (!_closing && !_disposed) {
          await load();
        }
        // A query failure cannot turn an already committed command into a
        // reported write failure; the separate view failure exposes the read.
        result.complete(receipt);
      } catch (error) {
        final code = _code(error);
        if (!_closing && !_disposed) _failure = code;
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
    shell.removeListener(_sourceChanged);
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
