import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/contracts.dart';
import '../jobs/observation_port.dart';
import '../jobs/young_read_only_port.dart';
import '../source/young_observation_contract.dart';
import '../source/young_read_only_contract.dart';

/// A user-driven view of bounded Young response-shape observations.
///
/// The panel never displays response field values and never treats these
/// observations as identity evidence, a complete snapshot, or import approval.
class YoungReadOnlyPanel extends StatefulWidget {
  const YoungReadOnlyPanel({super.key, required this.observation});

  final YoungReadOnlyObservationPort observation;

  @override
  State<YoungReadOnlyPanel> createState() => _YoungReadOnlyPanelState();
}

class _YoungReadOnlyPanelState extends State<YoungReadOnlyPanel> {
  late ObservationView _view;
  YoungReadOnlyInspection? _inspection;
  StreamSubscription<ObservationView>? _viewSubscription;
  StreamSubscription<YoungReadOnlyInspection?>? _readOnlySubscription;

  int _controllerEpoch = 0;
  int _contextEpoch = 0;
  int? _lastOperation;
  int _nextActionToken = 0;
  int? _activeActionToken;
  _ReadOnlyAction? _activeAction;
  int _copyGeneration = 0;
  String? _actionMessage;
  String? _copyStatus;

  @override
  void initState() {
    super.initState();
    _listenToObservation();
  }

  @override
  void didUpdateWidget(covariant YoungReadOnlyPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.observation != widget.observation) {
      _controllerEpoch++;
      _contextEpoch++;
      _copyGeneration++;
      unawaited(_viewSubscription?.cancel());
      unawaited(_readOnlySubscription?.cancel());
      _activeActionToken = null;
      _activeAction = null;
      _actionMessage = null;
      _copyStatus = null;
      _listenToObservation();
    }
  }

  void _listenToObservation() {
    final epoch = _controllerEpoch;
    _view = widget.observation.view;
    _inspection = widget.observation.readOnlyInspection;
    _lastOperation = _inspection?.operation;
    _viewSubscription = widget.observation.changes.listen((view) {
      if (!_isCurrentController(epoch) ||
          !identical(widget.observation.view, view)) {
        return;
      }
      final previous = _view;
      final changedPage = !_samePage(
        previous.youngInspection,
        view.youngInspection,
      );
      final viewUnavailable =
          view.phase != ObservationPhase.open || !view.ready;
      if (changedPage || viewUnavailable) {
        _invalidateContext();
        _lastOperation = null;
      }
      setState(() {
        _view = view;
        if (!_matchesCurrentPage(_inspection, view)) {
          _inspection = null;
        }
      });
    });
    _readOnlySubscription = widget.observation.readOnlyChanges.listen((
      inspection,
    ) {
      if (!_isCurrentController(epoch) ||
          !identical(widget.observation.readOnlyInspection, inspection)) {
        return;
      }
      final operation = inspection?.operation;
      if (_lastOperation != operation) {
        _lastOperation = operation;
        _invalidateContext();
        setState(() => _inspection = null);
        return;
      }
      if (!_matchesCurrentPage(inspection, widget.observation.view)) {
        _invalidateCopy();
        setState(() => _inspection = null);
        return;
      }
      if (!identical(_inspection, inspection)) _invalidateCopy();
      setState(() {
        _inspection = inspection;
      });
    });
  }

  @override
  void dispose() {
    _controllerEpoch++;
    _contextEpoch++;
    _copyGeneration++;
    unawaited(_viewSubscription?.cancel());
    unawaited(_readOnlySubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final view = widget.observation.view;
    final inspection = _currentInspection(view: view);
    final busy = _activeActionToken != null;
    final canStart = !busy && _canRun(_ReadOnlyAction.start);
    final canRefresh = !busy && _canRun(_ReadOnlyAction.refresh);
    final canStop = !busy && _canRun(_ReadOnlyAction.stop);
    final canCopy = !busy && inspection != null;

    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: EdgeInsets.symmetric(
          horizontal: constraints.maxWidth < 560 ? 12 : 20,
          vertical: 12,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Card(
              child: Padding(
                padding: EdgeInsets.all(constraints.maxWidth < 560 ? 16 : 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '二课只读接口观测',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '手动登录后，在当前个人日程或活动列表开始观测。再使用学校页面已有的查询或刷新、日期或分页控件触发读取，回到此处更新或复制摘要。',
                      style: TextStyle(fontSize: 16),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '页面导航会停止本次观测，可在目标页面重新开始。这里只确认响应结构；业务身份和数据完整性仍待验证，不授予采集或导入许可。',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        FilledButton.icon(
                          onPressed: canStart
                              ? () => unawaited(_perform(_ReadOnlyAction.start))
                              : null,
                          icon: const Icon(Icons.sensors_outlined),
                          label: const Text('开始接口观测'),
                        ),
                        OutlinedButton.icon(
                          onPressed: canRefresh
                              ? () =>
                                    unawaited(_perform(_ReadOnlyAction.refresh))
                              : null,
                          icon: const Icon(Icons.refresh),
                          label: const Text('更新接口摘要'),
                        ),
                        OutlinedButton.icon(
                          onPressed: canStop
                              ? () => unawaited(_perform(_ReadOnlyAction.stop))
                              : null,
                          icon: const Icon(Icons.stop_circle_outlined),
                          label: const Text('停止接口观测'),
                        ),
                        if (inspection != null)
                          OutlinedButton.icon(
                            onPressed: canCopy
                                ? () => unawaited(_copyInspection(inspection))
                                : null,
                            icon: const Icon(Icons.copy_outlined),
                            label: Text(
                              _activeAction == _ReadOnlyAction.copy
                                  ? '正在复制接口摘要'
                                  : '复制接口脱敏摘要',
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _status(
                      context,
                      view,
                      inspection ?? _boundPortInspection(view: view),
                    ),
                    if (inspection != null) ...[
                      const SizedBox(height: 14),
                      _summary(context, inspection),
                    ],
                    if (busy) ...[
                      const SizedBox(height: 12),
                      const LinearProgressIndicator(),
                    ],
                    if (_actionMessage != null) ...[
                      const SizedBox(height: 12),
                      _notice(context, _actionMessage!),
                    ],
                    if (_copyStatus != null) ...[
                      const SizedBox(height: 8),
                      Text(_copyStatus!),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _status(
    BuildContext context,
    ObservationView view,
    YoungReadOnlyInspection? inspection,
  ) {
    final message = switch (view.phase) {
      ObservationPhase.open when view.ready =>
        inspection?.listening == true
            ? '当前正在观测候选只读响应。页面可达不证明业务身份或列表完整性。'
            : '页面已就绪。请开始观测后，在学校页面触发已有查询或刷新。',
      ObservationPhase.open => '二课观测窗口已打开，当前页面尚未就绪。请先在现有窗口进入个人日程或活动列表。',
      _ => '请先打开既有二课观测窗口，并等待个人日程或活动列表页面就绪。',
    };
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, color: colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _summary(BuildContext context, YoungReadOnlyInspection inspection) {
    final safe = inspection.safeSummary();
    final accepted = _safeCount(safe['accepted']);
    final rejected = _safeCount(safe['rejected']);
    final profile = _safeObservationCount(safe['profile']);
    final schedule = _safeObservationCount(safe['schedule']);
    final activities = _safeObservationCount(safe['activities']);
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '当前只读结构摘要',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          const Text('以下只显示观测计数，不显示响应字段值、URL 或实际标识。'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 14,
            runSpacing: 8,
            children: [
              Text('已接受候选：$accepted'),
              Text('已拒绝候选：$rejected'),
              Text('个人资料响应：$profile'),
              Text('个人日程响应：$schedule'),
              Text('活动列表响应：$activities'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _notice(BuildContext context, String message) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        message,
        style: TextStyle(color: colorScheme.onErrorContainer),
      ),
    );
  }

  Future<void> _perform(_ReadOnlyAction action) async {
    if (!mounted || _activeActionToken != null || !_canRun(action)) return;
    final controllerEpoch = _controllerEpoch;
    final contextEpoch = _contextEpoch;
    final view = widget.observation.view;
    final page = view.youngInspection;
    final token = ++_nextActionToken;
    setState(() {
      _activeActionToken = token;
      _activeAction = action;
      _actionMessage = null;
      _copyStatus = null;
      _invalidateCopy();
    });

    try {
      switch (action) {
        case _ReadOnlyAction.start:
          await widget.observation.startReadOnlyInspection();
          break;
        case _ReadOnlyAction.refresh:
          await widget.observation.refreshReadOnlyInspection();
          break;
        case _ReadOnlyAction.stop:
          await widget.observation.stopReadOnlyInspection();
          break;
        case _ReadOnlyAction.copy:
          return;
      }
    } on AppFailure catch (failure) {
      if (_isCurrentActionContext(
        controllerEpoch: controllerEpoch,
        contextEpoch: contextEpoch,
        page: page,
      )) {
        setState(
          () => _actionMessage = _messageForFailure(failure.code, action),
        );
      }
    } catch (_) {
      if (_isCurrentActionContext(
        controllerEpoch: controllerEpoch,
        contextEpoch: contextEpoch,
        page: page,
      )) {
        setState(() => _actionMessage = _messageForUnexpectedFailure(action));
      }
    } finally {
      if (_isCurrentController(controllerEpoch) &&
          _activeActionToken == token) {
        setState(() {
          _activeActionToken = null;
          _activeAction = null;
        });
      }
    }
  }

  Future<void> _copyInspection(YoungReadOnlyInspection inspection) async {
    if (!mounted || _activeActionToken != null || !_canCopy(inspection)) return;
    final controllerEpoch = _controllerEpoch;
    final contextEpoch = _contextEpoch;
    final copyGeneration = ++_copyGeneration;
    final operation = inspection.operation;
    final token = ++_nextActionToken;
    setState(() {
      _activeActionToken = token;
      _activeAction = _ReadOnlyAction.copy;
      _copyStatus = null;
      _actionMessage = null;
    });

    try {
      final safeJson = jsonEncode(inspection.safeSummary());
      if (!_isCurrentCopy(
        inspection: inspection,
        operation: operation,
        controllerEpoch: controllerEpoch,
        contextEpoch: contextEpoch,
        copyGeneration: copyGeneration,
      )) {
        return;
      }
      await Clipboard.setData(ClipboardData(text: safeJson));
      if (_isCurrentCopy(
        inspection: inspection,
        operation: operation,
        controllerEpoch: controllerEpoch,
        contextEpoch: contextEpoch,
        copyGeneration: copyGeneration,
      )) {
        setState(() => _copyStatus = '已复制接口脱敏摘要。');
      }
    } catch (_) {
      if (_isCurrentCopy(
        inspection: inspection,
        operation: operation,
        controllerEpoch: controllerEpoch,
        contextEpoch: contextEpoch,
        copyGeneration: copyGeneration,
      )) {
        setState(() => _copyStatus = '复制接口摘要失败，请稍后重试。');
      }
    } finally {
      if (_isCurrentController(controllerEpoch) &&
          _activeActionToken == token) {
        setState(() {
          _activeActionToken = null;
          _activeAction = null;
        });
      }
    }
  }

  bool _canRun(_ReadOnlyAction action) {
    final view = widget.observation.view;
    if (view.phase != ObservationPhase.open || !view.ready) return false;
    final inspection = _boundPortInspection(view: view);
    return switch (action) {
      _ReadOnlyAction.start => inspection == null || !inspection.listening,
      _ReadOnlyAction.refresh ||
      _ReadOnlyAction.stop => inspection != null && inspection.listening,
      _ReadOnlyAction.copy => false,
    };
  }

  bool _canCopy(YoungReadOnlyInspection inspection) =>
      _currentInspection(view: widget.observation.view) == inspection;

  YoungReadOnlyInspection? _currentInspection({required ObservationView view}) {
    final candidate = _boundPortInspection(view: view);
    if (!identical(_inspection, candidate) || candidate == null) {
      return null;
    }
    return candidate;
  }

  YoungReadOnlyInspection? _boundPortInspection({
    required ObservationView view,
  }) {
    final candidate = widget.observation.readOnlyInspection;
    return _matchesCurrentPage(candidate, view) ? candidate : null;
  }

  bool _matchesCurrentPage(
    YoungReadOnlyInspection? inspection,
    ObservationView view,
  ) {
    if (inspection == null ||
        view.phase != ObservationPhase.open ||
        !view.ready ||
        !identical(widget.observation.readOnlyInspection, inspection)) {
      return false;
    }
    final page = view.youngInspection;
    if (page == null) return true;
    return inspection.session == page.session &&
        inspection.document == page.document;
  }

  bool _isCurrentCopy({
    required YoungReadOnlyInspection inspection,
    required int operation,
    required int controllerEpoch,
    required int contextEpoch,
    required int copyGeneration,
  }) =>
      _isCurrentController(controllerEpoch) &&
      _contextEpoch == contextEpoch &&
      _copyGeneration == copyGeneration &&
      inspection.operation == operation &&
      identical(widget.observation.readOnlyInspection, inspection) &&
      _matchesCurrentPage(inspection, widget.observation.view);

  bool _isCurrentActionContext({
    required int controllerEpoch,
    required int contextEpoch,
    required YoungPageInspection? page,
  }) {
    if (!_isCurrentController(controllerEpoch) ||
        _contextEpoch != contextEpoch) {
      return false;
    }
    final view = widget.observation.view;
    return view.phase == ObservationPhase.open &&
        view.ready &&
        _samePage(page, view.youngInspection);
  }

  bool _isCurrentController(int epoch) => mounted && epoch == _controllerEpoch;

  void _invalidateContext() {
    _contextEpoch++;
    _invalidateCopy();
    _copyStatus = null;
    _actionMessage = null;
  }

  void _invalidateCopy() {
    _copyGeneration++;
    _copyStatus = null;
  }
}

enum _ReadOnlyAction { start, refresh, stop, copy }

bool _samePage(YoungPageInspection? left, YoungPageInspection? right) =>
    left?.session == right?.session && left?.document == right?.document;

int _safeCount(Object? value) => value is int && value >= 0 ? value : 0;

int _safeObservationCount(Object? value) {
  if (value is! Map) return 0;
  return _safeCount(value['observations']);
}

String _messageForFailure(FailureCode code, _ReadOnlyAction action) {
  if (code == FailureCode.closed) {
    return '二课观测窗口已关闭，本次操作无法继续。';
  }
  if (code == FailureCode.staleResult) {
    return '页面或观测已变化，本次结果已丢弃，请在当前目标页面重新开始。';
  }
  if (code == FailureCode.busy || code == FailureCode.ownerConflict) {
    return '另一个二课接口观测操作正在进行，请稍后重试。';
  }
  if (code == FailureCode.cancelled) {
    return '本次二课接口观测操作已取消。';
  }
  if (code == FailureCode.unsupportedPlatform) {
    return '当前平台不支持二课只读接口观测。';
  }
  return _messageForUnexpectedFailure(action);
}

String _messageForUnexpectedFailure(_ReadOnlyAction action) => switch (action) {
  _ReadOnlyAction.start => '二课只读接口观测未能开始，请确认当前页面后重试。',
  _ReadOnlyAction.refresh => '二课接口摘要更新失败，请重新触发学校页面查询后重试。',
  _ReadOnlyAction.stop => '二课接口观测未能停止，请稍后重试。',
  _ReadOnlyAction.copy => '复制接口摘要失败，请稍后重试。',
};
