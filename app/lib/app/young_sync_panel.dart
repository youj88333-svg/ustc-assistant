import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/contracts.dart';
import '../core/jw_credentials.dart';
import '../core/young_work_contract.dart';
import '../data/young_import_contract.dart';
import '../jobs/young_sync_port.dart';
import '../source/jw_authentication_contract.dart';

/// M2.3 UI for Young's independent activity query and linked-calendar sync.
final class YoungSyncPanel extends StatefulWidget {
  const YoungSyncPanel({
    super.key,
    required this.controller,
    this.clock,
    this.productMode = false,
    this.blockNewActions = false,
    this.embedded = false,
  });

  final YoungSyncPort controller;
  final bool productMode;
  final bool blockNewActions;

  /// The containing settings page owns vertical scrolling when embedded.
  final bool embedded;

  /// Supplies a current instant. The panel converts it to a Beijing date.
  final DateTime Function()? clock;

  @override
  State<YoungSyncPanel> createState() => _YoungSyncPanelState();
}

final class _YoungSyncPanelState extends State<YoungSyncPanel> {
  final TextEditingController _expectedAccountController =
      TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  late final TextEditingController _firstDayController;
  late final TextEditingController _lastDayController;
  StreamSubscription<YoungSyncView>? _subscription;
  late YoungSyncView _view;
  final Set<int> _pendingHiddenChanges = <int>{};
  int _controllerEpoch = 0;
  int _copyGeneration = 0;
  String? _pendingAction;
  String? _actionMessage;
  String? _inputMessage;
  String? _copyMessage;
  bool _copyMessageIsError = false;
  bool _copyPending = false;
  bool _showHidden = false;
  bool _savePassword = false;

  @override
  void initState() {
    super.initState();
    _view = widget.controller.syncView;
    final (firstDay, lastDay) = _initialDateRange(_view.data, widget.clock);
    _firstDayController = TextEditingController(text: _formatDate(firstDay));
    _lastDayController = TextEditingController(text: _formatDate(lastDay));
    _listen();
  }

  @override
  void didUpdateWidget(covariant YoungSyncPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) {
      if (widget.productMode &&
          widget.blockNewActions &&
          !oldWidget.blockNewActions &&
          _view.phase == YoungSyncPhase.idle) {
        _expectedAccountController.clear();
        _passwordController.clear();
        _savePassword = false;
      }
      return;
    }

    _controllerEpoch++;
    final oldSubscription = _subscription;
    _subscription = null;
    if (oldSubscription != null) unawaited(oldSubscription.cancel());
    _expectedAccountController.clear();
    _passwordController.clear();
    _savePassword = false;
    _pendingHiddenChanges.clear();
    _pendingAction = null;
    _copyPending = false;
    _showHidden = false;
    _actionMessage = null;
    _inputMessage = null;
    _copyMessage = null;
    _view = widget.controller.syncView;
    final (firstDay, lastDay) = _initialDateRange(_view.data, widget.clock);
    _firstDayController.text = _formatDate(firstDay);
    _lastDayController.text = _formatDate(lastDay);
    _listen();
  }

  void _listen() {
    final epoch = _controllerEpoch;
    _subscription = widget.controller.syncChanges.listen(
      (next) {
        if (!mounted || epoch != _controllerEpoch) return;
        setState(() {
          _view = next;
          _actionMessage = null;
          _copyGeneration++;
          _copyMessage = null;
        });
      },
      onError: (_, _) {
        if (!mounted || epoch != _controllerEpoch) return;
        setState(() {
          _actionMessage = '读取二课作业进度失败，请检查应用状态。';
          _copyGeneration++;
          _copyMessage = null;
        });
      },
    );
  }

  @override
  void dispose() {
    _controllerEpoch++;
    _copyGeneration++;
    _expectedAccountController.clear();
    _passwordController.clear();
    _expectedAccountController.dispose();
    _passwordController.dispose();
    _firstDayController.dispose();
    _lastDayController.dispose();
    final subscription = _subscription;
    if (subscription != null) unawaited(subscription.cancel());
    super.dispose();
  }

  bool get _accountBound =>
      _view.accountBound || (_view.data?.accountBound ?? false);

  bool get _isIdle => _view.phase == YoungSyncPhase.idle;

  bool get _hasPendingAction => _pendingAction != null;

  bool get _canStart =>
      _isIdle &&
      !_hasPendingAction &&
      _pendingHiddenChanges.isEmpty &&
      !_copyPending &&
      !widget.blockNewActions;

  bool get _canContinue =>
      _view.phase == YoungSyncPhase.login &&
      _view.ready &&
      _view.automation == YoungAutomationState.manualRequired &&
      !_hasPendingAction;

  bool get _canCancel =>
      const <YoungSyncPhase>{
        YoungSyncPhase.opening,
        YoungSyncPhase.login,
        YoungSyncPhase.collecting,
        YoungSyncPhase.closing,
        YoungSyncPhase.committing,
      }.contains(_view.phase) &&
      _pendingAction != 'cancel';

  bool get _canRetryRecovery =>
      _view.phase == YoungSyncPhase.recovery && !_hasPendingAction;

  bool get _canClearSession => _canStart;

  bool get _canEditInputs =>
      _isIdle &&
      !_hasPendingAction &&
      _pendingHiddenChanges.isEmpty &&
      !widget.blockNewActions;

  ({DateTime first, DateTime last})? get _dateRange {
    final first = _parseDate(_firstDayController.text);
    final last = _parseDate(_lastDayController.text);
    if (first == null || last == null || last.isBefore(first)) return null;
    final days = last.difference(first).inDays + 1;
    if (days > 62) return null;
    return (first: first, last: last);
  }

  String? _expectedAccount() {
    if (_accountBound) return null;
    final expected = _expectedAccountController.text.trim();
    if (expected.isEmpty ||
        expected.length > 64 ||
        expected.runes.any(
          (rune) => rune <= 32 || (rune >= 127 && rune <= 159),
        ) ||
        RegExp(r'\s').hasMatch(expected)) {
      setState(() => _inputMessage = '请输入有效的预期学号后再开始。');
      return '';
    }
    return expected;
  }

  Future<void> _startCalendar() async {
    if (!_canStart) return;
    final expectedAccountCode = _expectedAccount();
    if (expectedAccountCode == '') return;
    final dates = _dateRange;
    if (dates == null) {
      setState(() => _inputMessage = '请检查日期格式、顺序，并将范围控制在 62 天内。');
      return;
    }
    final password = _passwordController.text.isEmpty
        ? null
        : _passwordController.text;
    final savePassword = _savePassword && password != null;
    setState(() {
      _expectedAccountController.clear();
      _passwordController.clear();
      _savePassword = false;
    });
    await _runAction(
      'calendar',
      () => widget.controller.startCalendar(
        expectedAccountCode: expectedAccountCode,
        firstDay: dates.first,
        lastDay: dates.last,
        password: password,
        savePassword: savePassword,
      ),
    );
  }

  Future<void> _startActivities() async {
    if (!_canStart) return;
    final expectedAccountCode = _expectedAccount();
    if (expectedAccountCode == '') return;
    final password = _passwordController.text.isEmpty
        ? null
        : _passwordController.text;
    final savePassword = _savePassword && password != null;
    setState(() {
      _expectedAccountController.clear();
      _passwordController.clear();
      _savePassword = false;
    });
    await _runAction(
      'activities',
      () => widget.controller.startActivities(
        expectedAccountCode: expectedAccountCode,
        password: password,
        savePassword: savePassword,
      ),
    );
  }

  Future<void> _continueAfterLogin() async {
    if (!_canContinue) return;
    await _runAction('continue', widget.controller.continueAfterLogin);
  }

  Future<void> _cancel() async {
    if (!_canCancel) return;
    await _runAction(
      'cancel',
      widget.controller.cancel,
      supersedePending: true,
    );
  }

  Future<void> _retryRecovery() async {
    if (!_canRetryRecovery) return;
    await _runAction('recovery', widget.controller.retryRecovery);
  }

  Future<void> _clearSession() async {
    if (!_canClearSession) return;
    if (widget.productMode) {
      final epoch = _controllerEpoch;
      final confirmed = await _confirmYoungAction(
        context,
        title: '清除二课登录资料？',
        message: '只清除二课浏览器登录资料。二课账号绑定、本地日程、教务登录资料和教务与二课共用的加密学校密码会保留。',
        confirmLabel: '清除登录资料',
      );
      if (!confirmed || !_isCurrentController(epoch)) return;
      if (!_canClearSession) return;
    }
    await _runAction('clearSession', widget.controller.clearSession);
  }

  Future<void> _deleteSavedCredential() async {
    if (!_canStart || !(_view.data?.credentialSaved ?? false)) return;
    if (widget.productMode) {
      final epoch = _controllerEpoch;
      final confirmed = await _confirmYoungAction(
        context,
        title: '删除保存的学校密码？',
        message: '这份加密密码由教务和二课共用。删除后，两来源都不能再自动使用它；教务和二课账号绑定、已保存日程及浏览器登录资料会保留。',
        confirmLabel: '删除密码',
      );
      if (!confirmed || !_isCurrentController(epoch)) return;
      if (!_canStart || !(_view.data?.credentialSaved ?? false)) return;
    }
    await _runAction(
      'deleteCredential',
      widget.controller.deleteSavedCredential,
    );
  }

  Future<void> _runAction(
    String key,
    Future<void> Function() action, {
    bool supersedePending = false,
  }) async {
    if (!mounted || (_pendingAction != null && !supersedePending)) return;
    final epoch = _controllerEpoch;
    setState(() {
      _pendingAction = key;
      _actionMessage = null;
      _inputMessage = null;
      _copyMessage = null;
      _copyGeneration++;
    });
    try {
      await action();
    } on AppFailure catch (failure) {
      if (!_isCurrentController(epoch)) return;
      setState(() => _actionMessage = _failureLabel(failure.code));
    } catch (_) {
      if (!_isCurrentController(epoch)) return;
      setState(() => _actionMessage = '二课作业未能完成，请检查应用状态后重试。');
    } finally {
      if (_isCurrentController(epoch) && _pendingAction == key) {
        setState(() => _pendingAction = null);
      }
    }
  }

  Future<void> _setHidden(YoungStoredEvent event) async {
    if (!_canStart || _pendingHiddenChanges.contains(event.localId)) return;
    final epoch = _controllerEpoch;
    setState(() {
      _pendingHiddenChanges.add(event.localId);
      _actionMessage = null;
    });
    try {
      await widget.controller.setHidden(
        localId: event.localId,
        expectedVersion: event.version,
        hidden: !event.hidden,
      );
    } on AppFailure catch (failure) {
      if (!_isCurrentController(epoch)) return;
      setState(() => _actionMessage = _failureLabel(failure.code));
    } catch (_) {
      if (!_isCurrentController(epoch)) return;
      setState(() => _actionMessage = '更新本地二课日程显示状态失败，请刷新后重试。');
    } finally {
      if (_isCurrentController(epoch)) {
        setState(() => _pendingHiddenChanges.remove(event.localId));
      }
    }
  }

  Future<void> _copySummary() async {
    if (!mounted || _copyPending) return;
    final epoch = _controllerEpoch;
    final copyGeneration = ++_copyGeneration;
    final view = _view;
    final summary = view.safeSummary;
    setState(() {
      _copyPending = true;
      _actionMessage = null;
      _copyMessage = null;
    });
    try {
      if (!_isCurrentCopy(epoch, copyGeneration, view)) return;
      await Clipboard.setData(ClipboardData(text: summary));
      if (_isCurrentCopy(epoch, copyGeneration, view)) {
        setState(() {
          _copyMessage = '已复制二课同步摘要。';
          _copyMessageIsError = false;
        });
      }
    } catch (_) {
      if (_isCurrentCopy(epoch, copyGeneration, view)) {
        setState(() {
          _copyMessage = '复制二课同步摘要失败，请稍后重试。';
          _copyMessageIsError = true;
        });
      }
    } finally {
      if (_isCurrentController(epoch)) {
        setState(() => _copyPending = false);
      }
    }
  }

  bool _isCurrentCopy(int epoch, int copyGeneration, YoungSyncView view) =>
      _isCurrentController(epoch) &&
      _copyGeneration == copyGeneration &&
      identical(widget.controller.syncView, view);

  bool _isCurrentController(int epoch) => mounted && epoch == _controllerEpoch;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final content = Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Card(
              child: Padding(
                padding: EdgeInsets.all(constraints.maxWidth < 560 ? 16 : 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      widget.productMode ? '二课日程与活动' : 'M2 二课日程与报名查询',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.productMode
                          ? '同步二课个人日历中的活动关联记录，或只读查询报名活动。未关联日历记录不会导入；活动关联不单独证明本人报名成功或取消。'
                          : '个人日历中与活动关联的记录用于日程同步，未关联记录会排除。活动列表只读查询；活动关联不代表已独立验证本人报名成功或取消。',
                    ),
                    const SizedBox(height: 14),
                    _statusCard(context),
                    const SizedBox(height: 14),
                    if (!_accountBound) ...[
                      TextField(
                        key: const ValueKey('young-sync-expected-account'),
                        controller: _expectedAccountController,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        enableIMEPersonalizedLearning: false,
                        autofillHints: const [],
                        enabled: _canEditInputs,
                        onChanged: (_) => _clearInputMessage(),
                        textInputAction: TextInputAction.done,
                        decoration: const InputDecoration(
                          labelText: '首次绑定时的预期学号',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    TextField(
                      key: const ValueKey('young-sync-password'),
                      controller: _passwordController,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      enableIMEPersonalizedLearning: false,
                      autofillHints: const [],
                      enabled: _canEditInputs,
                      onChanged: (_) => _clearInputMessage(),
                      textInputAction: TextInputAction.done,
                      decoration: InputDecoration(
                        labelText: _credentialSaved
                            ? '学校密码（可留空使用已保存密码）'
                            : '学校密码（可留空并在学校窗口手动登录）',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    CheckboxListTile(
                      key: const ValueKey('young-sync-save-password'),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('成功后加密保存学校密码'),
                      subtitle: widget.productMode
                          ? const Text(
                              '仅在本次身份核验和查询成功后加密保存；学校窗口手动输入的密码不会被读取或保存。',
                            )
                          : null,
                      value: _savePassword,
                      onChanged: _canEditInputs
                          ? (value) =>
                                setState(() => _savePassword = value ?? false)
                          : null,
                    ),
                    Text(
                      widget.productMode
                          ? _credentialSaved
                                ? '教务和二课共用此密码；本机已保存且不会回填。清除二课登录资料会保留密码和日程。'
                                : '教务和二课共用此密码。清除二课登录资料会保留密码和日程。'
                          : _credentialSaved
                          ? '教务和二课共用这份加密学校密码；本机已保存，可留空使用。清除二课登录资料会保留密码和日程。'
                          : '教务和二课共用一份加密学校密码；输入后可选择在本机加密保存，或在学校窗口手动登录。清除二课登录资料会保留已保存密码和日程。',
                    ),
                    const SizedBox(height: 12),
                    _dateInputs(context),
                    if (_inputMessage != null) ...[
                      const SizedBox(height: 8),
                      _message(context, _inputMessage!, error: true),
                    ],
                    const SizedBox(height: 12),
                    _actions(context),
                    if (_actionMessage != null) ...[
                      const SizedBox(height: 10),
                      _message(context, _actionMessage!, error: true),
                    ],
                    if (_view.profileRetained) ...[
                      const SizedBox(height: 10),
                      const Text('已保留二课登录资料，学校仍可能要求重新登录。'),
                    ],
                    if (!widget.productMode) ...[
                      const SizedBox(height: 18),
                      _localCalendar(context),
                    ],
                    const SizedBox(height: 18),
                    _activityResults(context),
                    if (!widget.productMode) ...[
                      const SizedBox(height: 14),
                      OutlinedButton.icon(
                        key: const ValueKey('young-sync-copy-summary'),
                        onPressed: _copyPending ? null : _copySummary,
                        icon: const Icon(Icons.copy_outlined),
                        label: Text(_copyPending ? '正在复制摘要' : '复制二课同步摘要'),
                      ),
                      if (_copyMessage != null) ...[
                        const SizedBox(height: 8),
                        _message(
                          context,
                          _copyMessage!,
                          error: _copyMessageIsError,
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
        final padding = EdgeInsets.symmetric(
          horizontal: constraints.maxWidth < 560 ? 12 : 20,
          vertical: 12,
        );
        return widget.embedded
            ? Padding(padding: padding, child: content)
            : SingleChildScrollView(padding: padding, child: content);
      },
    );
  }

  Widget _statusCard(BuildContext context) {
    final messages = <String>[
      widget.productMode ? _productPhaseMessage() : _phaseMessage(_view),
    ];
    if (_view.identityFailure case final failure?) {
      messages.add(_identityFailureLabel(failure));
    }
    if (_view.credentialFailure case final failure?) {
      messages.add(_credentialFailureMessage(failure));
    }
    if (!widget.productMode &&
        _view.collectionReason != null &&
        _view.collectionStage != null) {
      messages.add('二课业务读取失败阶段：${_view.collectionStage!.name}。');
    }
    if (_view.failure != null &&
        !(widget.productMode &&
            _view.phase == YoungSyncPhase.recovery &&
            _view.committed)) {
      final failure = _view.failure!;
      messages.add(
        _view.committed
            ? widget.productMode
                  ? '数据已保存，仍有后续处理待完成。'
                  : '结果已保存，后续处理未完成，请重试二课收口。'
            : _failureLabel(failure),
      );
    }
    if (!widget.productMode && _view.profileReused == true) {
      messages.add('本次复用了保留的二课登录资料；学校仍可能要求重新登录。');
    } else if (!widget.productMode && _view.profileReused == false) {
      messages.add('本次使用新的二课登录资料。');
    }
    if (_view.committed && !widget.productMode) {
      messages.add(
        _view.kind == YoungJobKind.activities
            ? '活动查询已完成；查询结果不会写入日程。'
            : '二课日程已保存。',
      );
    }
    final colorScheme = Theme.of(context).colorScheme;
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
          for (var index = 0; index < messages.length; index++) ...[
            if (index > 0) const SizedBox(height: 5),
            Text(
              messages[index],
              style: index == 0
                  ? Theme.of(context).textTheme.titleMedium
                  : Theme.of(context).textTheme.bodyMedium,
            ),
          ],
          if (_view.phase == YoungSyncPhase.login) ...[
            const SizedBox(height: 6),
            Text(_loginProgressMessage(_view)),
            if (_view.automation == YoungAutomationState.manualRequired) ...[
              const SizedBox(height: 5),
              Text(_loginPauseMessage(_view.loginPauseReason)),
            ],
          ],
          if (!widget.productMode &&
              _view.phase == YoungSyncPhase.recovery &&
              _view.committed) ...[
            const SizedBox(height: 6),
            const Text('结果已保存，二课窗口关闭仍待恢复。'),
          ],
        ],
      ),
    );
  }

  String _productPhaseMessage() {
    if (_view.phase == YoungSyncPhase.recovery && _view.committed) {
      return '数据已保存，窗口关闭待恢复。';
    }
    if (_view.failure == FailureCode.unsupportedPlatform) {
      return '当前设备暂不能打开二课网页。';
    }
    if (_view.phase == YoungSyncPhase.recovery) return '二课登录窗口需要恢复。';
    if (_view.phase == YoungSyncPhase.idle && _view.committed) {
      return _view.kind == YoungJobKind.activities
          ? '活动查询已完成；查询结果不会写入日程。'
          : '二课日程已保存。';
    }
    if (_view.automation == YoungAutomationState.manualRequired) {
      return '请在学校窗口完成所需操作。';
    }
    return switch (_view.phase) {
      YoungSyncPhase.idle =>
        _accountBound ? '二课账号已绑定，可同步日程或查询活动。' : '首次使用时同步或查询并绑定学校账号。',
      YoungSyncPhase.opening => '正在打开二课登录窗口。',
      YoungSyncPhase.login => '二课登录窗口已打开。',
      YoungSyncPhase.collecting =>
        _view.kind == YoungJobKind.activities ? '正在查询报名活动。' : '正在同步二课日程。',
      YoungSyncPhase.closing => '正在关闭二课登录窗口。',
      YoungSyncPhase.committing => '正在保存二课日程。',
      YoungSyncPhase.recovery => '二课登录窗口需要恢复。',
      YoungSyncPhase.closed => '二课登录窗口已关闭。',
    };
  }

  Widget _dateInputs(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '日程同步范围（北京时间日期，最多 62 天）',
        style: Theme.of(context).textTheme.titleSmall,
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 10,
        runSpacing: 8,
        children: [
          SizedBox(
            width: 190,
            child: TextField(
              key: const ValueKey('young-sync-first-day'),
              controller: _firstDayController,
              enabled: _canEditInputs,
              keyboardType: TextInputType.datetime,
              maxLength: 10,
              onChanged: (_) => _clearInputMessage(),
              decoration: const InputDecoration(
                labelText: '开始日期',
                hintText: 'YYYY-MM-DD',
                border: OutlineInputBorder(),
                counterText: '',
              ),
            ),
          ),
          SizedBox(
            width: 190,
            child: TextField(
              key: const ValueKey('young-sync-last-day'),
              controller: _lastDayController,
              enabled: _canEditInputs,
              keyboardType: TextInputType.datetime,
              maxLength: 10,
              onChanged: (_) => _clearInputMessage(),
              decoration: const InputDecoration(
                labelText: '结束日期',
                hintText: 'YYYY-MM-DD',
                border: OutlineInputBorder(),
                counterText: '',
              ),
            ),
          ),
        ],
      ),
    ],
  );

  Widget _actions(BuildContext context) {
    final datesValid = _dateRange != null;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        FilledButton.icon(
          key: const ValueKey('young-sync-start-calendar'),
          onPressed: _canStart && datesValid ? _startCalendar : null,
          icon: const Icon(Icons.sync),
          label: const Text('同步二课日程'),
        ),
        FilledButton.tonalIcon(
          key: const ValueKey('young-sync-start-activities'),
          onPressed: _canStart ? _startActivities : null,
          icon: const Icon(Icons.search),
          label: const Text('查询报名活动'),
        ),
        if (_view.phase == YoungSyncPhase.login &&
            _view.automation == YoungAutomationState.manualRequired &&
            _view.ready)
          OutlinedButton.icon(
            key: const ValueKey('young-sync-continue-login'),
            onPressed: _canContinue ? _continueAfterLogin : null,
            icon: const Icon(Icons.login),
            label: const Text('登录完成，继续'),
          ),
        if (_canCancel)
          OutlinedButton.icon(
            key: const ValueKey('young-sync-cancel'),
            onPressed: _cancel,
            icon: const Icon(Icons.stop_circle_outlined),
            label: Text(
              _pendingAction == 'cancel'
                  ? '正在取消本次二课作业'
                  : widget.productMode
                  ? '取消本次操作'
                  : '取消本次二课作业',
            ),
          ),
        if (_view.phase == YoungSyncPhase.recovery)
          FilledButton.icon(
            key: const ValueKey('young-sync-retry-recovery'),
            onPressed: _canRetryRecovery ? _retryRecovery : null,
            icon: const Icon(Icons.refresh),
            label: Text(
              widget.productMode
                  ? _view.failure == FailureCode.unsupportedPlatform
                        ? '检查环境并重试恢复'
                        : '重试关闭窗口'
                  : '重试二课收口',
            ),
          ),
        if (_isIdle)
          OutlinedButton.icon(
            key: const ValueKey('young-sync-clear-session'),
            onPressed: _canClearSession ? _clearSession : null,
            icon: const Icon(Icons.key_off_outlined),
            label: const Text('清除二课登录资料'),
          ),
        if (_credentialSaved)
          OutlinedButton.icon(
            key: const ValueKey('young-sync-delete-saved-credential'),
            onPressed: _canStart ? _deleteSavedCredential : null,
            icon: const Icon(Icons.key_off),
            label: const Text('删除保存的学校密码'),
          ),
      ],
    );
  }

  Widget _localCalendar(BuildContext context) {
    final events = _view.data?.events ?? const <YoungStoredEvent>[];
    final hiddenCount = events.where((event) => event.hidden).length;
    final retiredCount = events.where((event) => event.sourceRetired).length;
    final visibleEvents = events
        .where((event) => _showHidden || !event.hidden)
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('本地二课日程', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          '有效日程：${events.length - retiredCount} · 保留的来源失效历史：$retiredCount · '
          '同步次数：${_view.data?.importCount ?? 0}',
        ),
        CheckboxListTile(
          key: const ValueKey('young-sync-show-hidden'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('显示隐藏日程'),
          subtitle: Text('隐藏记录：$hiddenCount'),
          value: _showHidden,
          onChanged: (value) => setState(() => _showHidden = value ?? false),
        ),
        if (visibleEvents.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Text('本地暂无活动关联日程。'),
          )
        else
          for (final event in visibleEvents) _calendarTile(context, event),
      ],
    );
  }

  Widget _calendarTile(BuildContext context, YoungStoredEvent event) {
    final pending = _pendingHiddenChanges.contains(event.localId);
    return Card(
      key: ValueKey('young-local-event-${event.localId}'),
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(event.title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('地点：${event.place.isEmpty ? '未提供' : event.place}'),
            Text(
              '北京时间：${formatBeijing(event.startsAtUtc)} — '
              '${formatBeijing(event.endsAtUtc)}',
            ),
            const Text('来源：二课个人日历中的活动关联记录'),
            Text(_presenceLabel(event.presence)),
            if (event.sourceRetired) const Text('来源已不再返回，已退出有效日程。'),
            if (event.hidden) const Text('此日程已隐藏。'),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: ValueKey('young-local-event-toggle-${event.localId}'),
                onPressed: _canStart && !pending
                    ? () => _setHidden(event)
                    : null,
                icon: Icon(
                  event.hidden
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                label: Text(
                  pending
                      ? '正在更新'
                      : event.hidden
                      ? '恢复显示'
                      : '隐藏日程',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _activityResults(BuildContext context) {
    final delivered =
        _view.phase == YoungSyncPhase.idle &&
        _view.committed &&
        _view.kind == YoungJobKind.activities;
    final activities = delivered
        ? _view.activityResults
        : const <YoungActivityView>[];
    final completedEmpty = delivered && activities.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('报名活动查询结果', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        const Text('只读查询，不会执行学校报名操作；查询结果不会写入日程。'),
        if (completedEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Text('本次活动查询未返回记录。'),
          )
        else if (activities.isNotEmpty)
          for (var index = 0; index < activities.length; index++)
            _activityTile(context, activities[index], index),
      ],
    );
  }

  Widget _activityTile(
    BuildContext context,
    YoungActivityView activity,
    int index,
  ) => Card(
    key: ValueKey('young-activity-result-$index'),
    margin: const EdgeInsets.only(top: 8),
    child: ExpansionTile(
      title: Text(activity.title),
      subtitle: Text(
        '活动时间：${formatBeijing(activity.startsAtUtc)} — '
        '${formatBeijing(activity.endsAtUtc)}',
      ),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '地点：${activity.place?.isNotEmpty == true ? activity.place : '未提供'}',
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            (activity.registrationStartsAtUtc != null ||
                    activity.registrationEndsAtUtc != null)
                ? '报名时段：${_optionalTime(activity.registrationStartsAtUtc)} — '
                      '${_optionalTime(activity.registrationEndsAtUtc)}'
                : '报名时段：未提供',
          ),
        ),
      ],
    ),
  );

  Widget _message(BuildContext context, String message, {required bool error}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: error ? scheme.errorContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        message,
        style: TextStyle(
          color: error ? scheme.onErrorContainer : scheme.onSurfaceVariant,
        ),
      ),
    );
  }

  void _clearInputMessage() {
    setState(() => _inputMessage = null);
  }

  bool get _credentialSaved => _view.data?.credentialSaved ?? false;
}

String _phaseMessage(YoungSyncView view) => switch (view.phase) {
  YoungSyncPhase.idle =>
    view.accountBound || (view.data?.accountBound ?? false)
        ? '二课账号已在本机绑定，可分别同步日程或查询活动。'
        : '首次成功同步或查询后会绑定本机账号；预期学号仅用于本次核对。',
  YoungSyncPhase.opening => '正在打开独立的二课登录资料。',
  YoungSyncPhase.login => switch (view.automation) {
    YoungAutomationState.none =>
      view.ready ? '二课页面已就绪；当前可能仍在 CAS，账号身份尚未核验。' : '正在准备二课页面；页面就绪不代表账号身份已经核验。',
    YoungAutomationState.waitingForLogin => '正在等待学校登录页面；账号身份尚未核验。',
    YoungAutomationState.submitting => '正在向固定学校认证页面提交信息；账号身份尚未核验。',
    YoungAutomationState.preparing => '正在自动处理学校登录跳转；账号身份尚未核验。',
    YoungAutomationState.manualRequired => '需要在学校窗口完成后续操作，再继续本次作业。',
  },
  YoungSyncPhase.collecting =>
    view.kind == YoungJobKind.activities ? '正在只读查询活动列表。' : '正在读取所选范围内的个人日历。',
  YoungSyncPhase.closing =>
    view.failure == null
        ? '正在关闭并排空二课窗口。'
        : view.committed
        ? '二课结果已保存，正在完成必要收尾。'
        : view.failure == FailureCode.cancelled
        ? '本次二课作业已取消，未提交结果。'
        : '二课作业未完成，正在处理安全收尾。',
  YoungSyncPhase.committing => '正在保存二课结果。',
  YoungSyncPhase.recovery => '二课窗口关闭需要恢复；已保存的结果会保留。',
  YoungSyncPhase.closed => '二课登录窗口已关闭。',
};

String _loginProgressMessage(YoungSyncView view) => switch (view.automation) {
  YoungAutomationState.none =>
    view.ready ? '学校页面已就绪；就绪状态不代表已离开 CAS 或已核验账号身份。' : '正在准备学校页面；账号身份仍待核验。',
  YoungAutomationState.waitingForLogin => '正在等待学校登录页面；页面可达与账号身份核验分别判断。',
  YoungAutomationState.submitting => '正在向固定学校认证页面提交信息；账号身份仍待核验。',
  YoungAutomationState.preparing => '正在自动推进学校认证；账号身份仍待核验。',
  YoungAutomationState.manualRequired =>
    view.ready
        ? '学校页面已就绪；完成下方暂停原因后继续，账号身份仍待核验。'
        : '正在准备学校页面；就绪后可完成下方暂停原因，账号身份仍待核验。',
};

String _loginPauseMessage(JwLoginPauseReason? reason) => switch (reason) {
  null || JwLoginPauseReason.manualRequired => '请在学校窗口完成登录、验证码或学校额外授权，然后继续。',
  JwLoginPauseReason.pageStructureChanged => '学校登录控件与已验证结构不同；请在学校窗口手动完成登录后继续。',
  JwLoginPauseReason.challengeRequired => '学校要求验证码或额外授权；请在学校窗口完成后继续。',
  JwLoginPauseReason.contextUnavailable => '无法确认固定登录页面；请在学校窗口手动登录后继续。',
  JwLoginPauseReason.noCredentials => '没有可用的已保存密码，也未输入本次密码；请在学校窗口手动登录后继续。',
  JwLoginPauseReason.alreadySubmitted => '本次认证信息已提交，不会重复发送；请在学校窗口完成后继续。',
  JwLoginPauseReason.timedOut => '等待学校登录响应超时；请检查学校窗口，必要时手动登录后继续。',
};

String _credentialFailureMessage(JwCredentialFailure failure) =>
    switch (failure) {
      JwCredentialFailure.unavailable => '此设备暂不支持加密保存学校密码。',
      JwCredentialFailure.protectionFailed => '本机加密保存学校密码失败。',
      JwCredentialFailure.invalidCredential => '已保存的学校密码不可用，请重新输入。',
    };

String _identityFailureLabel(YoungIdentityFailure failure) => switch (failure) {
  YoungIdentityFailure.identityUnverified => '无法核验二课身份，本次结果未交付。',
  YoungIdentityFailure.evidenceConflict => '二课身份依据不一致，本次结果未交付。',
  YoungIdentityFailure.accountMismatch => '二课登录账号与本机绑定账号不一致，作业已停止。',
  YoungIdentityFailure.identityMismatch => '预期账号与本机绑定账号不一致，未更改本机绑定。',
};

String _failureLabel(FailureCode failure) => switch (failure) {
  FailureCode.busy => '另一项作业仍在运行，请等待后重试。',
  FailureCode.cancelled => '本次二课作业已取消，未交付未提交结果。',
  FailureCode.staleResult => '页面或作业状态已变化，请重新开始。',
  FailureCode.incompleteSnapshot => '读取未完成，结果未提交。',
  FailureCode.invalidSnapshot => '二课返回内容不符合已验证结构，结果未提交。',
  FailureCode.idempotencyConflict => '本地作业回执冲突，结果未提交。',
  FailureCode.sourceFailed => '读取二课来源失败，结果未提交。',
  FailureCode.storageFailed => '保存二课本地数据失败。',
  FailureCode.cleanupPending => '二课登录资料仍待安全收口。',
  FailureCode.followUpPending => '二课结果已提交，仍有收尾工作待完成。',
  FailureCode.ownerConflict => '本机数据所有权冲突，操作已停止。',
  FailureCode.unsafeDirectory => '应用数据目录不安全，操作已停止。',
  FailureCode.ownershipLost => '应用数据所有权已变化，操作已停止。',
  FailureCode.unsupportedPlatform =>
    '系统网页组件不支持学校同步。请更新 Android System WebView，或使用受支持的环境；更改模拟机型不会更新网页组件。',
  FailureCode.closed => '应用已关闭，无法继续本次作业。',
};

String _presenceLabel(YoungPresence presence) => switch (presence) {
  YoungPresence.observed => '来源：本次读取范围内已观察到',
  YoungPresence.outsideScope => '来源：本次读取范围外，本地记录保留',
  YoungPresence.missingWithinScope => '来源：本次范围内未观察到，本地记录仍保留',
};

String _optionalTime(DateTime? value) =>
    value == null ? '未提供' : formatBeijing(value);

(DateTime, DateTime) _initialDateRange(
  YoungDataView? data,
  DateTime Function()? clock,
) {
  final first = data?.firstDay;
  final last = data?.lastDay;
  if (first != null && last != null) {
    final from = DateTime.utc(first.year, first.month, first.day);
    final through = DateTime.utc(last.year, last.month, last.day);
    if (!through.isBefore(from) && through.difference(from).inDays < 62) {
      return (from, through);
    }
  }
  final now = (clock?.call() ?? DateTime.now()).toUtc().add(
    const Duration(hours: 8),
  );
  return (
    DateTime.utc(now.year, now.month, 1),
    DateTime.utc(now.year, now.month + 1, 0),
  );
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

Future<bool> _confirmYoungAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
}) => showDialog<bool>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(title),
    content: Text(message),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(true),
        child: Text(confirmLabel),
      ),
    ],
  ),
).then((confirmed) => confirmed ?? false);
