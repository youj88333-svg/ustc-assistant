import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_design.dart';
import '../core/contracts.dart';
import '../core/young_work_contract.dart';
import '../data/jw_import_contract.dart';
import '../data/young_import_contract.dart';
import '../jobs/jw_sync_port.dart';
import '../jobs/young_sync_port.dart';
import '../source/jw_authentication_contract.dart';
import '../source/jw_probe_contract.dart';
import 'app_shell_contract.dart';

/// A compact, user-started first-run entry to the two fixed school sources.
/// The surrounding wizard owns navigation, draft lifetime, and scrolling.
final class OnboardingSourceStep extends StatefulWidget {
  const OnboardingSourceStep({
    super.key,
    required this.controller,
    required this.account,
    required this.password,
    required this.savePassword,
    required this.today,
    this.onBusyChanged,
  });

  final AppShellPort controller;
  final String? Function() account;
  final String? Function() password;
  final bool Function() savePassword;
  final DateTime Function() today;
  final ValueChanged<bool>? onBusyChanged;

  @override
  State<OnboardingSourceStep> createState() => _OnboardingSourceStepState();
}

final class _OnboardingSourceStepState extends State<OnboardingSourceStep> {
  final Set<String> _pendingCommands = <String>{};
  int _generation = 0;
  String? _jwMessage;
  String? _youngMessage;
  int? _preSyncSemesterId;
  bool _preSyncSemesterTouched = false;
  String? _cachedSemesterSignature;
  bool _wasChoosingSemester = false;
  int? _choosingSemesterId;
  bool _youngDateTouched = false;
  String? _youngRangeSignature;
  late DateTime _firstDay;
  late DateTime _lastDay;
  bool? _reportedBusy;
  ValueChanged<bool>? _reportedCallback;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onShellChanged);
    _syncCachedSemesterSelection(widget.controller.view.jw.data);
    _syncChoosingSemester(widget.controller.view.jw);
    _syncYoungRange(widget.controller.view.young.data);
    _reportBusy(force: true);
  }

  @override
  void didUpdateWidget(covariant OnboardingSourceStep oldWidget) {
    super.didUpdateWidget(oldWidget);
    final controllerChanged = !identical(
      oldWidget.controller,
      widget.controller,
    );
    final busyCallbackChanged = oldWidget.onBusyChanged != widget.onBusyChanged;
    if (controllerChanged) {
      _generation++;
      oldWidget.controller.removeListener(_onShellChanged);
      widget.controller.addListener(_onShellChanged);
      _pendingCommands.clear();
      _cachedSemesterSignature = null;
      _youngRangeSignature = null;
      _wasChoosingSemester = false;
      _choosingSemesterId = null;
      _jwMessage = null;
      _youngMessage = null;
    }
    _syncCachedSemesterSelection(widget.controller.view.jw.data);
    _syncChoosingSemester(widget.controller.view.jw);
    _syncYoungRange(widget.controller.view.young.data);
    if (controllerChanged || busyCallbackChanged) {
      _reportBusy(force: true);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onShellChanged);
    // The shell/root owns active-job draining. This view never cancels in dispose.
    super.dispose();
  }

  void _onShellChanged() {
    if (!mounted) return;
    final view = widget.controller.view;
    _syncCachedSemesterSelection(view.jw.data);
    _syncChoosingSemester(view.jw);
    _syncYoungRange(view.young.data);
    setState(() {});
    _reportBusy();
  }

  void _syncCachedSemesterSelection(JwDataView? data) {
    final options = data?.cachedSemesters ?? const <JwSemesterOption>[];
    final signature = <String>[
      data?.lastSemesterId?.toString() ?? '-',
      for (final option in options) '${option.id}:${option.name}',
    ].join('|');
    if (signature == _cachedSemesterSignature) return;
    _cachedSemesterSignature = signature;

    if (_preSyncSemesterTouched &&
        (_preSyncSemesterId == null ||
            options.any((option) => option.id == _preSyncSemesterId))) {
      return;
    }
    _preSyncSemesterTouched = false;
    final last = data?.lastSemesterId;
    _preSyncSemesterId =
        last != null && options.any((option) => option.id == last)
        ? last
        : null;
  }

  void _syncChoosingSemester(JwSyncView view) {
    final choosing =
        view.phase == JwSyncPhase.login &&
        view.automation == JwAutomationState.choosingSemester;
    if (!choosing) {
      _wasChoosingSemester = false;
      _choosingSemesterId = null;
      return;
    }
    if (!_wasChoosingSemester ||
        (_choosingSemesterId != null &&
            !view.semesters.any(
              (option) => option.id == _choosingSemesterId,
            ))) {
      _choosingSemesterId = null;
    }
    _wasChoosingSemester = true;
  }

  void _syncYoungRange(YoungDataView? data) {
    final signature =
        '${_dateComponent(data?.firstDay)}|'
        '${_dateComponent(data?.lastDay)}';
    if (signature == _youngRangeSignature) return;
    _youngRangeSignature = signature;
    if (_youngDateTouched) return;
    final initial = _initialYoungRange(data, widget.today());
    _firstDay = initial.$1;
    _lastDay = initial.$2;
  }

  String _dateComponent(DateTime? value) => value == null
      ? '-'
      : '${value.year.toString().padLeft(4, '0')}-'
            '${value.month.toString().padLeft(2, '0')}-'
            '${value.day.toString().padLeft(2, '0')}';

  bool get _navigationBlocked {
    final view = widget.controller.view;
    return _pendingCommands.isNotEmpty ||
        view.globallyBusy ||
        view.jw.busy ||
        view.young.busy ||
        view.actionPending ||
        view.progressUnavailable;
  }

  void _reportBusy({bool force = false}) {
    final callback = widget.onBusyChanged;
    final blocked = _navigationBlocked;
    if (callback == null) {
      _reportedBusy = blocked;
      _reportedCallback = null;
      return;
    }
    if (!force && blocked == _reportedBusy && callback == _reportedCallback) {
      return;
    }
    _reportedBusy = blocked;
    _reportedCallback = callback;
    final generation = _generation;
    scheduleMicrotask(() {
      if (!mounted ||
          generation != _generation ||
          widget.onBusyChanged != callback) {
        return;
      }
      callback(blocked);
    });
  }

  bool get _canStartNew {
    final view = widget.controller.view;
    return _pendingCommands.isEmpty &&
        !view.globallyBusy &&
        !view.jw.busy &&
        !view.young.busy &&
        !view.actionPending &&
        !view.progressUnavailable;
  }

  bool _canControlSource({
    required bool jw,
    bool allowCancel = false,
    bool allowResumeFromStart = false,
  }) {
    final view = widget.controller.view;
    final otherBusy = jw ? view.young.busy : view.jw.busy;
    final prefix = jw ? 'jw' : 'young';
    final otherPrefix = jw ? 'young' : 'jw';
    final cancelPending = _pendingCommands.contains('$prefix-cancel');
    final otherPending = _pendingCommands.any(
      (command) => command.startsWith('$otherPrefix-'),
    );
    final pendingStartOnly =
        _pendingCommands.length == 1 &&
        _pendingCommands.contains('$prefix-start');
    return !otherBusy &&
        !view.actionPending &&
        !view.progressUnavailable &&
        (allowCancel
            ? !cancelPending && !otherPending
            : _pendingCommands.isEmpty ||
                  (allowResumeFromStart && pendingStartOnly));
  }

  Future<void> _runCommand(
    String commandName,
    Future<void> Function() issue,
  ) async {
    final generation = _generation;
    if (!mounted) return;
    setState(() => _pendingCommands.add(commandName));
    _reportBusy();

    Future<void> operation;
    try {
      operation = issue();
    } catch (error) {
      issue = _emptyCommand;
      if (_isCurrent(generation)) {
        setState(
          () => _setCommandMessage(commandName, _safeCommandError(error)),
        );
      }
      setState(() => _pendingCommands.remove(commandName));
      _reportBusy();
      return;
    }
    // Drop the closure that captured this tap's candidate/password before await.
    issue = _emptyCommand;
    try {
      await operation;
    } catch (error) {
      if (_isCurrent(generation)) {
        setState(
          () => _setCommandMessage(commandName, _safeCommandError(error)),
        );
      }
    } finally {
      if (_isCurrent(generation)) {
        setState(() => _pendingCommands.remove(commandName));
        _reportBusy();
      }
    }
  }

  Future<void> _emptyCommand() async {}

  bool _isCurrent(int generation) => mounted && generation == _generation;

  void _setCommandMessage(String commandName, String? message) {
    if (commandName.startsWith('jw-')) {
      _jwMessage = message;
    } else {
      _youngMessage = message;
    }
  }

  String _safeCommandError(Object error) =>
      error is AppFailure ? _failureMessage(error.code) : '本次操作未完成，请检查来源状态后重试。';

  void _startJw() {
    if (!_canStartNew || widget.controller.view.jw.phase != JwSyncPhase.idle) {
      return;
    }
    final view = widget.controller.view.jw;
    final isBound = view.accountBound || (view.data?.accountBound ?? false);
    final expectedAccountCode = isBound ? null : _readCandidateAccount();
    if (!isBound && expectedAccountCode == null) {
      setState(() => _jwMessage = '请先返回上一步填写学号；也可跳过同步。');
      return;
    }
    _jwMessage = null;
    final password = _readPassword();
    final savePassword = password != null && widget.savePassword();
    final semesterId = _preSyncSemesterId;
    unawaited(
      _runCommand(
        'jw-start',
        () => widget.controller.jw.startSync(
          expectedAccountCode: expectedAccountCode,
          password: password,
          savePassword: savePassword,
          semesterId: semesterId,
        ),
      ),
    );
  }

  void _startYoung() {
    if (!_canStartNew ||
        widget.controller.view.young.phase != YoungSyncPhase.idle) {
      return;
    }
    final dateError = _youngDateError;
    if (dateError != null) {
      setState(() => _youngMessage = dateError);
      return;
    }
    final view = widget.controller.view.young;
    final isBound = view.accountBound || (view.data?.accountBound ?? false);
    final expectedAccountCode = isBound ? null : _readCandidateAccount();
    if (!isBound && expectedAccountCode == null) {
      setState(() => _youngMessage = '请先返回上一步填写学号；也可跳过同步。');
      return;
    }
    _youngMessage = null;
    final password = _readPassword();
    final savePassword = password != null && widget.savePassword();
    final firstDay = _firstDay;
    final lastDay = _lastDay;
    unawaited(
      _runCommand(
        'young-start',
        () => widget.controller.young.startCalendar(
          expectedAccountCode: expectedAccountCode,
          firstDay: firstDay,
          lastDay: lastDay,
          password: password,
          savePassword: savePassword,
        ),
      ),
    );
  }

  String? _readCandidateAccount() {
    final candidate = widget.account();
    if (candidate == null || candidate.trim().isEmpty) return null;
    return candidate.trim();
  }

  String? _readPassword() {
    final supplied = widget.password();
    return supplied == null || supplied.isEmpty ? null : supplied;
  }

  void _continueJw() {
    final view = widget.controller.view.jw;
    if (!_canControlSource(jw: true) ||
        view.phase != JwSyncPhase.login ||
        view.automation != JwAutomationState.manualRequired) {
      return;
    }
    _jwMessage = null;
    unawaited(_runCommand('jw-continue', widget.controller.jw.continueSync));
  }

  void _collectChosenSemester() {
    final view = widget.controller.view.jw;
    final semesterId = _choosingSemesterId;
    if (!_canControlSource(jw: true) ||
        view.phase != JwSyncPhase.login ||
        view.automation != JwAutomationState.choosingSemester ||
        semesterId == null ||
        !view.semesters.any((option) => option.id == semesterId)) {
      setState(() {
        _choosingSemesterId = null;
        _jwMessage = '学期目录已变化，请从最新目录重新选择。';
      });
      return;
    }
    _jwMessage = null;
    unawaited(
      _runCommand('jw-collect', () => widget.controller.jw.collect(semesterId)),
    );
  }

  void _continueYoung() {
    final view = widget.controller.view.young;
    if (!_canControlSource(jw: false) ||
        view.phase != YoungSyncPhase.login ||
        !view.ready ||
        view.automation != YoungAutomationState.manualRequired) {
      return;
    }
    _youngMessage = null;
    unawaited(
      _runCommand('young-continue', widget.controller.young.continueAfterLogin),
    );
  }

  void _cancelJw() {
    final view = widget.controller.view.jw;
    if (!_canControlSource(jw: true, allowCancel: true) ||
        !_jwCanCancel(view)) {
      return;
    }
    unawaited(_runCommand('jw-cancel', widget.controller.jw.cancel));
  }

  void _cancelYoung() {
    final view = widget.controller.view.young;
    if (!_canControlSource(jw: false, allowCancel: true) ||
        !_youngCanCancel(view)) {
      return;
    }
    unawaited(_runCommand('young-cancel', widget.controller.young.cancel));
  }

  void _retryJwRecovery() {
    final view = widget.controller.view.jw;
    if (!_canControlSource(jw: true) || view.phase != JwSyncPhase.recovery) {
      return;
    }
    unawaited(_runCommand('jw-recovery', widget.controller.jw.retryRecovery));
  }

  void _retryYoungRecovery() {
    final view = widget.controller.view.young;
    if (!_canControlSource(jw: false) ||
        view.phase != YoungSyncPhase.recovery) {
      return;
    }
    unawaited(
      _runCommand('young-recovery', widget.controller.young.retryRecovery),
    );
  }

  Future<void> _pickFirstDay() async {
    final generation = _generation;
    final chosen = await _showDatePicker(_firstDay);
    if (chosen == null || !_isCurrent(generation)) return;
    setState(() {
      _youngDateTouched = true;
      _firstDay = chosen;
      _youngMessage = null;
    });
  }

  Future<void> _pickLastDay() async {
    final generation = _generation;
    final chosen = await _showDatePicker(_lastDay);
    if (chosen == null || !_isCurrent(generation)) return;
    setState(() {
      _youngDateTouched = true;
      _lastDay = chosen;
      _youngMessage = null;
    });
  }

  Future<DateTime?> _showDatePicker(DateTime initialDay) =>
      showDatePicker(
        context: context,
        initialDate: DateTime(
          initialDay.year,
          initialDay.month,
          initialDay.day,
        ),
        firstDate: DateTime(2000),
        lastDate: DateTime(2100, 12, 31),
        helpText: '选择北京时间日期',
        cancelText: '取消',
        confirmText: '确定',
      ).then(
        (value) => value == null
            ? null
            : DateTime.utc(value.year, value.month, value.day),
      );

  String? get _youngDateError {
    if (_lastDay.isBefore(_firstDay)) return '结束日期不能早于开始日期。';
    if (_lastDay.difference(_firstDay).inDays + 1 > 62) {
      return '一次最多同步62天，请缩短日期范围。';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final view = widget.controller.view;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('学校来源同步', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        const Text(
          '同步由你分别启动。需要验证码或额外授权时，请在学校窗口完成后继续。',
          style: TextStyle(color: AppUi.muted),
        ),
        WorkspaceSection(
          title: '教务课表与考试',
          description: '只读同步课表与考试；首次同步使用上一步填写的学号。',
          child: _jwSection(context, view),
        ),
        WorkspaceSection(
          title: '二课个人日程',
          description: '读取个人日历中的活动关联日程，不办理报名；一次最多62天。',
          divider: false,
          child: _youngSection(context, view),
        ),
      ],
    );
  }

  Widget _jwSection(BuildContext context, AppShellView shellView) {
    final view = shellView.jw;
    final cached = view.data?.cachedSemesters ?? const <JwSemesterOption>[];
    final bound = view.accountBound || (view.data?.accountBound ?? false);
    final canStart = _canStartNew && view.phase == JwSyncPhase.idle;
    final choosing =
        view.phase == JwSyncPhase.login &&
        view.automation == JwAutomationState.choosingSemester;
    final manual =
        view.phase == JwSyncPhase.login &&
        view.automation == JwAutomationState.manualRequired;
    final canContinue =
        manual && _canControlSource(jw: true, allowResumeFromStart: true);
    final canCollect =
        choosing &&
        _canControlSource(jw: true, allowResumeFromStart: true) &&
        _choosingSemesterId != null &&
        view.semesters.any((option) => option.id == _choosingSemesterId);
    final canCancel =
        _jwCanCancel(view) && _canControlSource(jw: true, allowCancel: true);
    final canRecover =
        view.phase == JwSyncPhase.recovery && _canControlSource(jw: true);
    final status = _jwStatus(view);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(status, key: const ValueKey('onboarding-jw-status')),
        if (!bound) ...[
          const SizedBox(height: 6),
          const Text(
            '首次同步会核对上一步填写的学号，成功后才会绑定账号。',
            style: TextStyle(color: AppUi.muted),
          ),
        ],
        if (cached.isNotEmpty) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey('onboarding-jw-cached-$_cachedSemesterSignature'),
            initialValue:
                _preSyncSemesterId != null &&
                    cached.any((option) => option.id == _preSyncSemesterId)
                ? _preSyncSemesterId.toString()
                : 'automatic',
            decoration: const InputDecoration(
              labelText: '首次同步学期',
              helperText: '可使用最近成功学期，也可让教务规则自动选择。',
              border: OutlineInputBorder(),
            ),
            items: [
              const DropdownMenuItem<String>(
                value: 'automatic',
                child: Text('自动选择'),
              ),
              for (final option in cached)
                DropdownMenuItem<String>(
                  value: option.id.toString(),
                  child: Text(
                    option.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: canStart
                ? (value) {
                    setState(() {
                      _preSyncSemesterTouched = true;
                      _preSyncSemesterId = value == null || value == 'automatic'
                          ? null
                          : int.tryParse(value);
                      _jwMessage = null;
                    });
                  }
                : null,
          ),
        ] else ...[
          const SizedBox(height: 8),
          const Text(
            '首次同步将按教务当前学期规则处理；需要确认学期时会显示最新目录。',
            style: TextStyle(color: AppUi.muted),
          ),
        ],
        if (choosing) ...[
          const SizedBox(height: 12),
          const Text('请选择本次刚读取的学期目录；选择后仍需点击同步。'),
          if (view.semesters.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('当前目录为空，请取消本次同步或重试。'),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: DropdownButtonFormField<int>(
                key: ValueKey(
                  'onboarding-jw-latest-${view.semesters.map((e) => e.id).join(',')}',
                ),
                initialValue:
                    view.semesters.any(
                      (option) => option.id == _choosingSemesterId,
                    )
                    ? _choosingSemesterId
                    : null,
                decoration: const InputDecoration(
                  labelText: '最新教务学期目录',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final option in view.semesters)
                    DropdownMenuItem<int>(
                      value: option.id,
                      child: Text(
                        option.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged:
                    _canControlSource(jw: true, allowResumeFromStart: true)
                    ? (value) => setState(() => _choosingSemesterId = value)
                    : null,
              ),
            ),
        ],
        if (manual) ...[
          const SizedBox(height: 10),
          const _PauseNotice(text: '请在教务窗口完成登录、验证码或额外授权，再回来继续。'),
        ],
        if (_jwMessage != null) ...[
          const SizedBox(height: 8),
          _InlineMessage(text: _jwMessage!, error: true),
        ],
        if (shellView.progressUnavailable) ...[
          const SizedBox(height: 8),
          const _InlineMessage(text: '同步状态暂不可用，请返回或重新打开应用后再继续。', error: true),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (view.phase == JwSyncPhase.idle)
              FilledButton.icon(
                key: const ValueKey('onboarding-jw-start'),
                style: _controlStyle,
                onPressed: canStart ? _startJw : null,
                icon: const Icon(Icons.sync),
                label: Text(
                  _pendingCommands.contains('jw-start')
                      ? '正在启动教务同步'
                      : bound
                      ? '同步教务'
                      : '登录并同步教务',
                ),
              ),
            if (manual)
              FilledButton.icon(
                key: const ValueKey('onboarding-jw-continue'),
                style: _controlStyle,
                onPressed: canContinue ? _continueJw : null,
                icon: const Icon(Icons.login),
                label: Text(
                  _pendingCommands.contains('jw-continue') ? '正在继续' : '登录完成，继续',
                ),
              ),
            if (choosing && view.semesters.isNotEmpty)
              FilledButton.icon(
                key: const ValueKey('onboarding-jw-collect'),
                style: _controlStyle,
                onPressed: canCollect ? _collectChosenSemester : null,
                icon: const Icon(Icons.download_outlined),
                label: Text(
                  _pendingCommands.contains('jw-collect') ? '正在同步' : '同步所选学期',
                ),
              ),
            if (canCancel ||
                (_jwCanCancel(view) && _pendingCommands.contains('jw-cancel')))
              OutlinedButton.icon(
                key: const ValueKey('onboarding-jw-cancel'),
                style: _controlStyle,
                onPressed: canCancel ? _cancelJw : null,
                icon: const Icon(Icons.stop_circle_outlined),
                label: Text(
                  _pendingCommands.contains('jw-cancel') ? '正在取消' : '取消本次同步',
                ),
              ),
            if (view.phase == JwSyncPhase.recovery)
              OutlinedButton.icon(
                key: const ValueKey('onboarding-jw-recovery'),
                style: _controlStyle,
                onPressed: canRecover ? _retryJwRecovery : null,
                icon: const Icon(Icons.refresh),
                label: Text(
                  _pendingCommands.contains('jw-recovery') ? '正在恢复' : '重试安全收尾',
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _youngSection(BuildContext context, AppShellView shellView) {
    final view = shellView.young;
    final bound = view.accountBound || (view.data?.accountBound ?? false);
    final canStart = _canStartNew && view.phase == YoungSyncPhase.idle;
    final manual =
        view.phase == YoungSyncPhase.login &&
        view.ready &&
        view.automation == YoungAutomationState.manualRequired;
    final canContinue =
        manual && _canControlSource(jw: false, allowResumeFromStart: true);
    final canCancel =
        _youngCanCancel(view) &&
        _canControlSource(jw: false, allowCancel: true);
    final canRecover =
        view.phase == YoungSyncPhase.recovery && _canControlSource(jw: false);
    final dateError = _youngDateError;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _youngStatus(view),
          key: const ValueKey('onboarding-young-status'),
        ),
        if (!bound) ...[
          const SizedBox(height: 6),
          const Text(
            '首次同步会核对学校身份，只导入个人日历中的活动关联日程。',
            style: TextStyle(color: AppUi.muted),
          ),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('onboarding-young-first-day'),
              style: _controlStyle,
              onPressed: canStart ? _pickFirstDay : null,
              icon: const Icon(Icons.calendar_today_outlined),
              label: Text('开始：${_formatDate(_firstDay)}'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('onboarding-young-last-day'),
              style: _controlStyle,
              onPressed: canStart ? _pickLastDay : null,
              icon: const Icon(Icons.event_outlined),
              label: Text('结束：${_formatDate(_lastDay)}'),
            ),
          ],
        ),
        if (dateError != null) ...[
          const SizedBox(height: 6),
          Text(
            dateError,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        if (manual) ...[
          const SizedBox(height: 10),
          const _PauseNotice(text: '请在二课窗口完成登录、验证码或额外授权，再回来继续。'),
        ],
        if (_youngMessage != null) ...[
          const SizedBox(height: 8),
          _InlineMessage(text: _youngMessage!, error: true),
        ],
        if (shellView.progressUnavailable) ...[
          const SizedBox(height: 8),
          const _InlineMessage(text: '同步状态暂不可用，请返回或重新打开应用后再继续。', error: true),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (view.phase == YoungSyncPhase.idle)
              FilledButton.icon(
                key: const ValueKey('onboarding-young-start'),
                style: _controlStyle,
                onPressed: canStart && dateError == null ? _startYoung : null,
                icon: const Icon(Icons.sync),
                label: Text(
                  _pendingCommands.contains('young-start')
                      ? '正在启动二课同步'
                      : bound
                      ? '同步二课日程'
                      : '登录并同步二课',
                ),
              ),
            if (manual)
              FilledButton.icon(
                key: const ValueKey('onboarding-young-continue'),
                style: _controlStyle,
                onPressed: canContinue ? _continueYoung : null,
                icon: const Icon(Icons.login),
                label: Text(
                  _pendingCommands.contains('young-continue')
                      ? '正在继续'
                      : '登录完成，继续',
                ),
              ),
            if (canCancel ||
                (_youngCanCancel(view) &&
                    _pendingCommands.contains('young-cancel')))
              OutlinedButton.icon(
                key: const ValueKey('onboarding-young-cancel'),
                style: _controlStyle,
                onPressed: canCancel ? _cancelYoung : null,
                icon: const Icon(Icons.stop_circle_outlined),
                label: Text(
                  _pendingCommands.contains('young-cancel') ? '正在取消' : '取消本次同步',
                ),
              ),
            if (view.phase == YoungSyncPhase.recovery)
              OutlinedButton.icon(
                key: const ValueKey('onboarding-young-recovery'),
                style: _controlStyle,
                onPressed: canRecover ? _retryYoungRecovery : null,
                icon: const Icon(Icons.refresh),
                label: Text(
                  _pendingCommands.contains('young-recovery')
                      ? '正在恢复'
                      : '重试安全收尾',
                ),
              ),
          ],
        ),
      ],
    );
  }

  String _jwStatus(JwSyncView view) {
    if (view.phase == JwSyncPhase.opening) return '正在准备教务来源。';
    if (view.phase == JwSyncPhase.login &&
        view.automation == JwAutomationState.manualRequired) {
      return _jwPauseMessage(view.loginPauseReason);
    }
    if (view.phase == JwSyncPhase.login &&
        view.automation == JwAutomationState.choosingSemester) {
      return '教务已读取最新学期目录，请选择后明确启动同步。';
    }
    if (view.phase == JwSyncPhase.login) return '正在准备教务登录；账号身份仍待核验。';
    if (view.phase == JwSyncPhase.verifying) return '正在核验教务身份。';
    if (view.phase == JwSyncPhase.collecting) return '正在只读读取课表与考试。';
    if (view.phase == JwSyncPhase.committing) return '正在保存教务结果。';
    if (view.phase == JwSyncPhase.closing) {
      return view.importCommitted
          ? '教务结果已提交，正在完成必要收尾。'
          : view.failure == FailureCode.cancelled
          ? '本次教务同步已取消，未提交结果。'
          : '教务同步未完成，正在处理安全收尾。';
    }
    if (view.phase == JwSyncPhase.recovery) {
      return view.importCommitted
          ? '教务结果已提交，仍需完成安全收尾。'
          : '教务登录资料仍需安全恢复；原有本地结果会保留。';
    }
    if (view.phase == JwSyncPhase.closed) return '教务来源已关闭。';
    if (view.importCommitted) {
      return '已提交的教务结果：课程 ${view.courseCount} 条、考试 ${view.examCount} 条。';
    }
    if (view.failure != null) return _failureMessage(view.failure!);
    final imports = view.data?.importCount ?? 0;
    if (imports > 0) return '本机已有 $imports 次教务结果保存记录。';
    return '尚无本地教务同步结果。';
  }

  String _youngStatus(YoungSyncView view) {
    if (view.phase == YoungSyncPhase.opening) return '正在准备二课来源。';
    if (view.phase == YoungSyncPhase.login &&
        view.automation == YoungAutomationState.manualRequired) {
      return _jwPauseMessage(view.loginPauseReason);
    }
    if (view.phase == YoungSyncPhase.login) return '正在准备二课登录；账号身份仍待核验。';
    if (view.phase == YoungSyncPhase.collecting) return '正在只读读取个人日历中的活动关联日程。';
    if (view.phase == YoungSyncPhase.committing) return '正在保存二课日程。';
    if (view.phase == YoungSyncPhase.closing) {
      return view.committed
          ? '二课日程结果已提交，正在完成必要收尾。'
          : view.failure == FailureCode.cancelled
          ? '本次二课同步已取消，未提交结果。'
          : '二课同步未完成，正在处理安全收尾。';
    }
    if (view.phase == YoungSyncPhase.recovery) {
      return view.committed ? '二课日程结果已提交，仍需完成安全收尾。' : '二课登录资料仍需安全恢复；已保存日程会保留。';
    }
    if (view.phase == YoungSyncPhase.closed) return '二课来源已关闭。';
    if (view.committed && view.kind == YoungJobKind.calendar) {
      return '二课日程结果已提交。';
    }
    if (view.failure != null) return _failureMessage(view.failure!);
    final imports = view.data?.importCount ?? 0;
    if (imports > 0) return '本机已有 $imports 次二课日程保存记录。';
    return '尚无本地二课日程同步结果。';
  }

  String _jwPauseMessage(JwLoginPauseReason? reason) => switch (reason) {
    JwLoginPauseReason.pageStructureChanged => '教务登录页面结构需要人工确认，请在学校窗口处理后继续。',
    JwLoginPauseReason.contextUnavailable => '暂时无法确认固定教务登录页面，请在学校窗口检查后继续。',
    JwLoginPauseReason.noCredentials => '当前没有可用的已保存密码，请在学校窗口登录后继续。',
    JwLoginPauseReason.alreadySubmitted => '本次登录信息已提交，不会重复发送；请在学校窗口完成后继续。',
    JwLoginPauseReason.timedOut => '等待教务登录响应超时，请检查学校窗口后继续或取消。',
    JwLoginPauseReason.challengeRequired ||
    JwLoginPauseReason.manualRequired ||
    null => '需要在学校窗口完成登录、验证码或额外授权，再回来继续。',
  };

  String _failureMessage(FailureCode failure) => switch (failure) {
    FailureCode.busy => '另一项作业仍在运行，请等待后重试。',
    FailureCode.cancelled => '本次同步已取消，未提交结果。',
    FailureCode.staleResult => '来源状态已变化，请重新开始。',
    FailureCode.incompleteSnapshot => '读取未完成，结果未提交。',
    FailureCode.invalidSnapshot => '来源返回内容无法确认，结果未提交。',
    FailureCode.idempotencyConflict => '本地结果状态冲突，结果未提交。',
    FailureCode.sourceFailed => '来源读取失败，结果未提交。',
    FailureCode.storageFailed => '保存本地结果失败。',
    FailureCode.cleanupPending || FailureCode.followUpPending => '结果仍需完成安全收尾。',
    FailureCode.ownerConflict ||
    FailureCode.unsafeDirectory ||
    FailureCode.ownershipLost => '本机数据所有权无法确认，操作已停止。',
    FailureCode.unsupportedPlatform => '此设备当前不支持学校同步。',
    FailureCode.closed => '应用正在关闭，无法继续本次操作。',
  };

  bool _jwCanCancel(JwSyncView view) => const <JwSyncPhase>{
    JwSyncPhase.opening,
    JwSyncPhase.login,
    JwSyncPhase.verifying,
    JwSyncPhase.collecting,
    JwSyncPhase.closing,
    JwSyncPhase.committing,
  }.contains(view.phase);

  bool _youngCanCancel(YoungSyncView view) => const <YoungSyncPhase>{
    YoungSyncPhase.opening,
    YoungSyncPhase.login,
    YoungSyncPhase.collecting,
    YoungSyncPhase.closing,
    YoungSyncPhase.committing,
  }.contains(view.phase);
}

const ButtonStyle _controlStyle = ButtonStyle(
  minimumSize: WidgetStatePropertyAll<Size>(Size(48, 48)),
);

final class _PauseNotice extends StatelessWidget {
  const _PauseNotice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      border: Border(left: BorderSide(color: AppUi.warning, width: 3)),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 0, 8),
      child: Text(text, style: const TextStyle(color: AppUi.warning)),
    ),
  );
}

final class _InlineMessage extends StatelessWidget {
  const _InlineMessage({required this.text, required this.error});

  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      color: error ? Theme.of(context).colorScheme.error : AppUi.muted,
    ),
  );
}

DateTime _dateOnly(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day);

(DateTime, DateTime) _initialYoungRange(YoungDataView? data, DateTime today) {
  final first = data?.firstDay;
  final last = data?.lastDay;
  if (first != null && last != null) {
    final start = _dateOnly(first);
    final end = _dateOnly(last);
    if (!end.isBefore(start) && end.difference(start).inDays + 1 <= 62) {
      return (start, end);
    }
  }
  final beijingToday = _dateOnly(today);
  return (
    DateTime.utc(beijingToday.year, beijingToday.month, 1),
    DateTime.utc(beijingToday.year, beijingToday.month + 1, 0),
  );
}

String _formatDate(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${value.year.toString().padLeft(4, '0')}-${two(value.month)}-'
      '${two(value.day)}';
}
