import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/contracts.dart';
import '../jobs/observation_port.dart';
import '../jobs/young_business_probe_port.dart';
import '../source/young_active_contract.dart';
import '../source/young_observation_contract.dart';

/// A user-driven interface for bounded Young identity and data candidates.
///
/// It displays only closed counts and fixed state labels. Candidate responses
/// are never rendered or copied to the clipboard.
final class YoungBusinessProbePanel extends StatefulWidget {
  const YoungBusinessProbePanel({super.key, required this.observation});

  final YoungBusinessProbePort observation;

  @override
  State<YoungBusinessProbePanel> createState() =>
      _YoungBusinessProbePanelState();
}

final class _YoungBusinessProbePanelState
    extends State<YoungBusinessProbePanel> {
  late ObservationView _observationView;
  late YoungBusinessView _businessView;
  late final TextEditingController _accountController;
  late final TextEditingController _firstDayController;
  late final TextEditingController _lastDayController;
  StreamSubscription<ObservationView>? _observationSubscription;
  StreamSubscription<YoungBusinessView>? _businessSubscription;

  int _controllerEpoch = 0;
  int _contextEpoch = 0;
  int _copyGeneration = 0;
  int _nextActionToken = 0;
  int? _activeActionToken;
  bool _canceling = false;
  String? _actionMessage;
  String? _copyStatus;

  @override
  void initState() {
    super.initState();
    _observationView = widget.observation.view;
    _businessView = widget.observation.businessView;
    _accountController = TextEditingController();
    final month = _currentBeijingMonth();
    _firstDayController = TextEditingController(text: _formatDate(month.$1));
    _lastDayController = TextEditingController(text: _formatDate(month.$2));
    _listen();
  }

  @override
  void didUpdateWidget(covariant YoungBusinessProbePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.observation != widget.observation) {
      _controllerEpoch++;
      _contextEpoch++;
      _copyGeneration++;
      unawaited(_observationSubscription?.cancel());
      unawaited(_businessSubscription?.cancel());
      _activeActionToken = null;
      _canceling = false;
      _actionMessage = null;
      _copyStatus = null;
      _observationView = widget.observation.view;
      _businessView = widget.observation.businessView;
      _listen();
    }
  }

  void _listen() {
    final controllerEpoch = _controllerEpoch;
    final observation = widget.observation;
    _observationView = observation.view;
    _businessView = observation.businessView;

    _observationSubscription = observation.changes.listen((view) {
      if (!_isCurrentController(controllerEpoch) ||
          !identical(observation.view, view)) {
        return;
      }
      final previous = _observationView;
      final pageChanged = !_samePage(
        previous.youngInspection,
        view.youngInspection,
      );
      final lostReadyContext =
          previous.phase == ObservationPhase.open &&
          previous.ready &&
          (view.phase != ObservationPhase.open || !view.ready);
      if (pageChanged || lostReadyContext) {
        _contextEpoch++;
        _invalidateCopy();
        _actionMessage = null;
      }
      setState(() => _observationView = view);
    });

    _businessSubscription = observation.businessChanges.listen((view) {
      if (!_isCurrentController(controllerEpoch) ||
          !identical(observation.businessView, view)) {
        return;
      }
      _invalidateCopy();
      setState(() {
        _businessView = view;
        _actionMessage = null;
      });
    });
  }

  @override
  void dispose() {
    _controllerEpoch++;
    _contextEpoch++;
    _copyGeneration++;
    unawaited(_observationSubscription?.cancel());
    unawaited(_businessSubscription?.cancel());
    _accountController.dispose();
    _firstDayController.dispose();
    _lastDayController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final busy = _isBusy;
    final sharedOpen = _observationView.phase == ObservationPhase.open;
    final sharedReady = sharedOpen && _observationView.ready;
    final canNavigate = sharedOpen && !busy;
    final canProbe = sharedReady && _businessView.available && !busy;
    final canCancel = _isProbeRunning && !_canceling;
    final narrow = MediaQuery.sizeOf(context).width < 520;

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
                      'M2 二课身份与数据验证',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '活动查询和个人日程同步分别验证。这里仅生成候选结果，尚未导入本地；同步候选只包含学校个人日历中关联活动的记录，不证明本人独立报名成功或取消状态。',
                      style: TextStyle(fontSize: 16),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 12,
                      runSpacing: 10,
                      children: [
                        SizedBox(
                          width: narrow ? double.infinity : 230,
                          child: TextField(
                            key: const ValueKey<String>(
                              'young-business-account',
                            ),
                            controller: _accountController,
                            enabled: !busy,
                            maxLength: 64,
                            decoration: const InputDecoration(
                              labelText: '预期学号',
                              counterText: '',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: narrow ? double.infinity : 170,
                          child: TextField(
                            key: const ValueKey<String>(
                              'young-business-first-day',
                            ),
                            controller: _firstDayController,
                            enabled: !busy,
                            maxLength: 10,
                            keyboardType: TextInputType.datetime,
                            decoration: const InputDecoration(
                              labelText: '开始日期',
                              hintText: 'YYYY-MM-DD',
                              counterText: '',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: narrow ? double.infinity : 170,
                          child: TextField(
                            key: const ValueKey<String>(
                              'young-business-last-day',
                            ),
                            controller: _lastDayController,
                            enabled: !busy,
                            maxLength: 10,
                            keyboardType: TextInputType.datetime,
                            decoration: const InputDecoration(
                              labelText: '结束日期',
                              hintText: 'YYYY-MM-DD',
                              counterText: '',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        OutlinedButton.icon(
                          onPressed: canNavigate
                              ? () => unawaited(
                                  _navigate(YoungBusinessPage.activities),
                                )
                              : null,
                          icon: const Icon(Icons.event_available_outlined),
                          label: const Text('打开活动列表'),
                        ),
                        OutlinedButton.icon(
                          onPressed: canNavigate
                              ? () => unawaited(
                                  _navigate(YoungBusinessPage.calendar),
                                )
                              : null,
                          icon: const Icon(Icons.calendar_month_outlined),
                          label: const Text('打开个人日程'),
                        ),
                        FilledButton.icon(
                          onPressed: canProbe
                              ? () => unawaited(_submitActivities())
                              : null,
                          icon: const Icon(Icons.fact_check_outlined),
                          label: const Text('验证活动查询'),
                        ),
                        FilledButton.icon(
                          onPressed: canProbe
                              ? () => unawaited(_submitCalendar())
                              : null,
                          icon: const Icon(Icons.date_range_outlined),
                          label: const Text('验证日程范围'),
                        ),
                        if (canCancel)
                          OutlinedButton.icon(
                            onPressed: () => unawaited(_cancelProbe()),
                            icon: const Icon(Icons.cancel_outlined),
                            label: Text(_canceling ? '正在取消验证' : '取消本次验证'),
                          ),
                        OutlinedButton.icon(
                          onPressed: busy
                              ? null
                              : () => unawaited(_copySummary()),
                          icon: const Icon(Icons.copy_outlined),
                          label: const Text('复制二课验证摘要'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _statusCard(context),
                    if (_isProbeRunning) ...[
                      const SizedBox(height: 12),
                      const LinearProgressIndicator(),
                    ],
                    if (_businessView.phase == YoungBusinessPhase.done ||
                        _businessView.phase == YoungBusinessPhase.failed) ...[
                      const SizedBox(height: 14),
                      _summaryCard(context),
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

  Widget _statusCard(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final stage = _businessView.stage;
    final failure = _businessView.failure;
    final text = switch (_businessView.phase) {
      YoungBusinessPhase.idle =>
        _observationView.phase == ObservationPhase.open &&
                _observationView.ready &&
                _businessView.available
            ? '目标页面已就绪，可以开始本次候选验证。'
            : '请先打开二课观测窗口，并进入活动列表或个人日程。来源能力仍不可用。',
      YoungBusinessPhase.running =>
        '正在验证：${stage == null ? '准备中' : _stageLabel(stage)}。',
      YoungBusinessPhase.done => '候选读取完成；结果尚未获得生产许可，也未写入本地业务数据。',
      YoungBusinessPhase.failed =>
        '本次验证未完成：${failure == null ? '请求失败' : _failureLabel(failure)}。',
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text('身份候选：${_identityLabel(_businessView.identity)}'),
          const SizedBox(height: 2),
          const Text('生产来源能力：不可用'),
        ],
      ),
    );
  }

  Widget _summaryCard(BuildContext context) {
    final summary = _businessView.safeSummary();
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
            '候选结构计数',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          const Text('只显示固定阶段和数量，不显示学号、日期、业务记录或原始响应。'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 14,
            runSpacing: 8,
            children: [
              Text('活动：${_summaryCount(summary, 'activities')}'),
              Text('活动页：${_summaryCount(summary, 'activityPages')}'),
              Text('日程行：${_summaryCount(summary, 'calendarRows')}'),
              Text('关联日程：${_summaryCount(summary, 'linkedSchedules')}'),
              Text('排除未关联：${_summaryCount(summary, 'excludedSchedules')}'),
              Text('覆盖日期：${_summaryCount(summary, 'days')}'),
              Text('日历页：${_summaryCount(summary, 'calendarPages')}'),
              Text('身份读取：${_summaryCount(summary, 'identityReads')}'),
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

  Future<void> _submitActivities() async {
    if (!_canProbeNow) return;
    final expectedAccountCode = _accountController.text.trim();
    if (!_validAccountCode(expectedAccountCode)) {
      setState(() => _actionMessage = '请输入有效的预期学号后再开始验证。');
      return;
    }
    _accountController.clear();
    await _perform(
      _YoungPanelAction.activities,
      expectedAccountCode: expectedAccountCode,
    );
  }

  Future<void> _submitCalendar() async {
    if (!_canProbeNow) return;
    final expectedAccountCode = _accountController.text.trim();
    if (!_validAccountCode(expectedAccountCode)) {
      setState(() => _actionMessage = '请输入有效的预期学号后再开始验证。');
      return;
    }
    final firstDay = _parseDate(_firstDayController.text);
    final lastDay = _parseDate(_lastDayController.text);
    if (firstDay == null || lastDay == null || lastDay.isBefore(firstDay)) {
      setState(() => _actionMessage = '请检查日期格式及开始、结束日期顺序。');
      return;
    }
    _accountController.clear();
    await _perform(
      _YoungPanelAction.calendar,
      expectedAccountCode: expectedAccountCode,
      firstDay: firstDay,
      lastDay: lastDay,
    );
  }

  Future<void> _navigate(YoungBusinessPage page) =>
      _perform(_YoungPanelAction.navigate, page: page);

  Future<void> _perform(
    _YoungPanelAction action, {
    String? expectedAccountCode,
    DateTime? firstDay,
    DateTime? lastDay,
    YoungBusinessPage? page,
  }) async {
    if (!mounted || _activeActionToken != null || _businessView.busy) return;
    if (action == _YoungPanelAction.navigate && !_canNavigateNow) return;
    if ((action == _YoungPanelAction.activities ||
            action == _YoungPanelAction.calendar) &&
        !_canProbeNow) {
      return;
    }

    final controllerEpoch = _controllerEpoch;
    final contextEpoch = _contextEpoch;
    final pageAtStart = widget.observation.view.youngInspection;
    final token = ++_nextActionToken;
    setState(() {
      _activeActionToken = token;
      _actionMessage = null;
      _copyStatus = null;
      _invalidateCopy();
    });

    try {
      switch (action) {
        case _YoungPanelAction.activities:
          await widget.observation.probeYoungActivities(expectedAccountCode!);
          break;
        case _YoungPanelAction.calendar:
          await widget.observation.probeYoungCalendar(
            expectedAccountCode: expectedAccountCode!,
            firstDay: firstDay!,
            lastDay: lastDay!,
          );
          break;
        case _YoungPanelAction.navigate:
          await widget.observation.navigateYoungPage(page!);
          break;
      }
    } on AppFailure catch (failure) {
      if (_isCurrentActionContext(
        controllerEpoch: controllerEpoch,
        contextEpoch: contextEpoch,
        page: pageAtStart,
      )) {
        setState(() => _actionMessage = _failureLabel(failure.code));
      }
    } catch (_) {
      if (_isCurrentActionContext(
        controllerEpoch: controllerEpoch,
        contextEpoch: contextEpoch,
        page: pageAtStart,
      )) {
        setState(() => _actionMessage = '二课候选验证操作失败，请检查目标页面后重试。');
      }
    } finally {
      if (_isCurrentController(controllerEpoch) &&
          _activeActionToken == token) {
        setState(() => _activeActionToken = null);
      }
    }
  }

  Future<void> _cancelProbe() async {
    if (!mounted || !_isProbeRunning || _canceling) return;
    final controllerEpoch = _controllerEpoch;
    final contextEpoch = _contextEpoch;
    final pageAtStart = widget.observation.view.youngInspection;
    setState(() {
      _canceling = true;
      _actionMessage = null;
    });
    try {
      await widget.observation.cancelYoungBusinessProbe();
    } on AppFailure catch (failure) {
      if (_isCurrentActionContext(
        controllerEpoch: controllerEpoch,
        contextEpoch: contextEpoch,
        page: pageAtStart,
      )) {
        setState(() => _actionMessage = _failureLabel(failure.code));
      }
    } catch (_) {
      if (_isCurrentActionContext(
        controllerEpoch: controllerEpoch,
        contextEpoch: contextEpoch,
        page: pageAtStart,
      )) {
        setState(() => _actionMessage = '取消二课候选验证失败，请重试。');
      }
    } finally {
      if (_isCurrentController(controllerEpoch)) {
        setState(() => _canceling = false);
      }
    }
  }

  Future<void> _copySummary() async {
    if (!mounted || _isBusy) return;
    final controllerEpoch = _controllerEpoch;
    final contextEpoch = _contextEpoch;
    final businessView = _businessView;
    final pageAtStart = widget.observation.view.youngInspection;
    final copyGeneration = ++_copyGeneration;
    final token = ++_nextActionToken;
    setState(() {
      _activeActionToken = token;
      _copyStatus = null;
      _actionMessage = null;
    });

    try {
      final safeJson = jsonEncode(businessView.safeSummary());
      if (!_isCurrentCopy(
        businessView: businessView,
        controllerEpoch: controllerEpoch,
        contextEpoch: contextEpoch,
        copyGeneration: copyGeneration,
        page: pageAtStart,
      )) {
        return;
      }
      await Clipboard.setData(ClipboardData(text: safeJson));
      if (_isCurrentCopy(
        businessView: businessView,
        controllerEpoch: controllerEpoch,
        contextEpoch: contextEpoch,
        copyGeneration: copyGeneration,
        page: pageAtStart,
      )) {
        setState(() => _copyStatus = '已复制二课验证摘要。');
      }
    } catch (_) {
      if (_isCurrentCopy(
        businessView: businessView,
        controllerEpoch: controllerEpoch,
        contextEpoch: contextEpoch,
        copyGeneration: copyGeneration,
        page: pageAtStart,
      )) {
        setState(() => _copyStatus = '复制二课验证摘要失败，请稍后重试。');
      }
    } finally {
      if (_isCurrentController(controllerEpoch) &&
          _activeActionToken == token) {
        setState(() => _activeActionToken = null);
      }
    }
  }

  bool get _isBusy =>
      _activeActionToken != null ||
      _businessView.busy ||
      _businessView.phase == YoungBusinessPhase.running ||
      _canceling;

  bool get _isProbeRunning =>
      _businessView.phase == YoungBusinessPhase.running || _businessView.busy;

  bool get _canNavigateNow =>
      widget.observation.view.phase == ObservationPhase.open && !_isBusy;

  bool get _canProbeNow =>
      widget.observation.view.phase == ObservationPhase.open &&
      widget.observation.view.ready &&
      widget.observation.businessView.available &&
      !_isBusy;

  bool _isCurrentActionContext({
    required int controllerEpoch,
    required int contextEpoch,
    required YoungPageInspection? page,
  }) {
    if (!_isCurrentController(controllerEpoch) ||
        _contextEpoch != contextEpoch) {
      return false;
    }
    final current = widget.observation.view;
    return current.phase == ObservationPhase.open &&
        _samePage(page, current.youngInspection);
  }

  bool _isCurrentCopy({
    required YoungBusinessView businessView,
    required int controllerEpoch,
    required int contextEpoch,
    required int copyGeneration,
    required YoungPageInspection? page,
  }) =>
      _isCurrentController(controllerEpoch) &&
      _contextEpoch == contextEpoch &&
      _copyGeneration == copyGeneration &&
      identical(widget.observation.businessView, businessView) &&
      _samePage(page, widget.observation.view.youngInspection);

  bool _isCurrentController(int epoch) => mounted && epoch == _controllerEpoch;

  void _invalidateCopy() {
    _copyGeneration++;
    _copyStatus = null;
  }
}

enum _YoungPanelAction { activities, calendar, navigate }

bool _samePage(YoungPageInspection? left, YoungPageInspection? right) =>
    left?.session == right?.session && left?.document == right?.document;

bool _validAccountCode(String value) => value.isNotEmpty && value.length <= 64;

(DateTime, DateTime) _currentBeijingMonth() {
  final beijingNow = DateTime.now().toUtc().add(const Duration(hours: 8));
  final firstDay = DateTime.utc(beijingNow.year, beijingNow.month, 1);
  final lastDay = DateTime.utc(beijingNow.year, beijingNow.month + 1, 0);
  return (firstDay, lastDay);
}

String _formatDate(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${value.year.toString().padLeft(4, '0')}-${two(value.month)}-'
      '${two(value.day)}';
}

DateTime? _parseDate(String value) {
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value.trim());
  if (match == null) return null;
  final year = int.tryParse(match.group(1)!);
  final month = int.tryParse(match.group(2)!);
  final day = int.tryParse(match.group(3)!);
  if (year == null || month == null || day == null) return null;
  final parsed = DateTime.utc(year, month, day);
  if (parsed.year != year || parsed.month != month || parsed.day != day) {
    return null;
  }
  return parsed;
}

int _summaryCount(Map<String, Object?> summary, String field) {
  final value = summary[field];
  return value is int && value >= 0 ? value : 0;
}

String _identityLabel(YoungBusinessIdentity identity) => switch (identity) {
  YoungBusinessIdentity.notValidated => '未核验',
  YoungBusinessIdentity.candidateMatches => '候选匹配',
  YoungBusinessIdentity.accountMismatch => '账号不匹配',
  YoungBusinessIdentity.unverified => '未能核验',
};

String _stageLabel(YoungBusinessStage stage) => switch (stage) {
  YoungBusinessStage.starting => '准备读取',
  YoungBusinessStage.profileBefore => '读取开始前身份',
  YoungBusinessStage.activities => '读取活动列表',
  YoungBusinessStage.calendar => '读取个人日程',
  YoungBusinessStage.profileAfter => '复核结束后身份',
  YoungBusinessStage.stopping => '停止并收口',
};

String _failureLabel(FailureCode failure) => switch (failure) {
  FailureCode.cancelled => '本次操作已取消。',
  FailureCode.staleResult => '页面或操作已变化，本次候选结果已丢弃。',
  FailureCode.invalidSnapshot => '候选数据不符合当前格式，本次结果已丢弃。',
  FailureCode.incompleteSnapshot => '候选数据覆盖不完整，本次结果已丢弃。',
  FailureCode.busy || FailureCode.ownerConflict => '另一个观测操作正在进行，请稍后重试。',
  FailureCode.closed => '二课观测窗口已关闭，本次操作无法继续。',
  FailureCode.cleanupPending ||
  FailureCode.followUpPending => '观测资源仍在收口，请等待完成后重试。',
  _ => '二课候选验证失败，请检查目标页面后重试。',
};
