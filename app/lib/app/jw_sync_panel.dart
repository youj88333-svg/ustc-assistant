import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/contracts.dart';
import '../core/jw_credentials.dart';
import '../core/jw_work_contract.dart';
import '../data/jw_import_contract.dart';
import '../jobs/jw_sync_port.dart';
import '../source/jw_authentication_contract.dart';
import '../source/jw_collection_failure.dart';
import '../source/jw_data_probe_contract.dart';
import '../source/jw_probe_contract.dart';
import '../source/observation_contract.dart';

/// The user-facing entry point for a complete local JW collection and import.
final class JwSyncPanel extends StatefulWidget {
  const JwSyncPanel({super.key, required this.controller});

  final JwSyncPort controller;

  @override
  State<JwSyncPanel> createState() => _JwSyncPanelState();
}

class _JwSyncPanelState extends State<JwSyncPanel> {
  final TextEditingController _accountCodeController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  StreamSubscription<JwSyncView>? _subscription;
  late JwSyncView _view;
  final Set<String> _pendingOperations = <String>{};
  final Set<int> _pendingHiddenChanges = <int>{};
  int? _semesterId;
  int? _displaySemesterId;
  int? _preSyncSemesterId;
  int? _activeSyncSemesterId;
  bool _preSyncSelectionDirty = false;
  bool _hasActiveSyncRequest = false;
  int _preSyncDropdownGeneration = 0;
  List<JwSemesterOption> _semesterDirectorySnapshot = const [];
  int _controllerEpoch = 0;
  bool _cancelPending = false;
  bool _copyPending = false;
  bool _showHidden = false;
  String _dateRange = '7';
  String? _inputMessage;
  String? _actionMessage;
  bool _savePassword = false;
  bool _resetSelectionForDirectoryRefresh = false;

  @override
  void initState() {
    super.initState();
    _connect(widget.controller);
  }

  @override
  void didUpdateWidget(covariant JwSyncPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;

    _controllerEpoch++;
    final oldSubscription = _subscription;
    _subscription = null;
    if (oldSubscription != null) unawaited(oldSubscription.cancel());
    _accountCodeController.clear();
    _passwordController.clear();
    _pendingOperations.clear();
    _pendingHiddenChanges.clear();
    _semesterId = null;
    _displaySemesterId = null;
    _preSyncSemesterId = null;
    _activeSyncSemesterId = null;
    _preSyncSelectionDirty = false;
    _hasActiveSyncRequest = false;
    _semesterDirectorySnapshot = const [];
    _cancelPending = false;
    _copyPending = false;
    _showHidden = false;
    _dateRange = '7';
    _inputMessage = null;
    _actionMessage = null;
    _savePassword = false;
    _resetSelectionForDirectoryRefresh = false;
    _connect(widget.controller);
  }

  void _connect(JwSyncPort controller) {
    _view = controller.syncView;
    _semesterDirectorySnapshot = _view.semesters;
    _preSyncSemesterId = _cachedSemesterDefault(_view.data);
    _synchronizeSemesterSelection();
    final epoch = _controllerEpoch;
    _subscription = controller.syncChanges.listen(
      (next) {
        if (!mounted || epoch != _controllerEpoch) return;
        final newDirectory = !_sameSemesterDirectory(
          _semesterDirectorySnapshot,
          next.semesters,
        );
        final enteringAutomatedSelection =
            _view.automation != JwAutomationState.choosingSemester &&
            next.automation == JwAutomationState.choosingSemester;
        final completedSync =
            _hasActiveSyncRequest &&
            next.phase == JwSyncPhase.idle &&
            next.importCommitted;
        final cachedCatalogChanged = !_sameSemesterDirectory(
          _view.data?.cachedSemesters ?? const <JwSemesterOption>[],
          next.data?.cachedSemesters ?? const <JwSemesterOption>[],
        );
        setState(() {
          _view = next;
          _synchronizeDisplaySemesterSelection();
          if (next.semesters.isNotEmpty &&
              (_resetSelectionForDirectoryRefresh ||
                  newDirectory ||
                  enteringAutomatedSelection)) {
            _semesterId = null;
          }
          if (completedSync) {
            _preSyncSelectionDirty = false;
            _preSyncSemesterId = _cachedSemesterDefault(next.data);
            _preSyncDropdownGeneration++;
            _activeSyncSemesterId = null;
            _hasActiveSyncRequest = false;
          } else if (next.phase == JwSyncPhase.idle &&
              !_preSyncSelectionDirty) {
            final newDefault = _cachedSemesterDefault(next.data);
            if (cachedCatalogChanged || newDefault != _preSyncSemesterId) {
              _preSyncDropdownGeneration++;
              _preSyncSemesterId = newDefault;
            }
          }
          _synchronizeSemesterSelection();
          _semesterDirectorySnapshot = next.semesters;
          if (next.semesters.isNotEmpty) {
            _resetSelectionForDirectoryRefresh = false;
          }
        });
      },
      onError: (_, _) {
        if (!mounted || epoch != _controllerEpoch) return;
        setState(() {
          _actionMessage = '读取本次作业进度失败，请检查观测窗口。';
        });
      },
    );
  }

  void _synchronizeSemesterSelection() {
    final options = _view.semesters;
    if (options.isEmpty) {
      _semesterId = null;
      return;
    }
    if (options.any((option) => option.id == _semesterId)) return;
    if (_hasActiveSyncRequest) {
      final requestedSemesterId = _activeSyncSemesterId;
      _semesterId =
          requestedSemesterId != null &&
              options.any((option) => option.id == requestedSemesterId)
          ? requestedSemesterId
          : null;
      return;
    }
    final lastSemesterId = _view.data?.lastSemesterId;
    if (lastSemesterId != null) {
      _semesterId = options.any((option) => option.id == lastSemesterId)
          ? lastSemesterId
          : null;
      return;
    }
    final selected = options.where((option) => option.selected).toList();
    _semesterId = selected.isNotEmpty ? selected.first.id : options.first.id;
  }

  void _synchronizeDisplaySemesterSelection() {
    final selectedId = _displaySemesterId;
    if (selectedId == null) return;
    if (!_courseEventsBySemester(
      _view.data?.events ?? const <JwStoredEvent>[],
    ).containsKey(selectedId)) {
      _displaySemesterId = null;
    }
  }

  Map<int, List<JwStoredEvent>> _courseEventsBySemester(
    Iterable<JwStoredEvent> events,
  ) {
    final courses = <int, List<JwStoredEvent>>{};
    for (final event in events) {
      final semesterId = event.semesterId;
      if (event.kind != JwEventKind.course ||
          semesterId == null ||
          semesterId <= 0) {
        continue;
      }
      courses.putIfAbsent(semesterId, () => <JwStoredEvent>[]).add(event);
    }
    return courses;
  }

  String _displaySemesterLabel(
    int semesterId,
    Map<int, List<JwStoredEvent>> coursesBySemester,
  ) {
    final cachedSemesters =
        _view.data?.cachedSemesters ?? const <JwSemesterOption>[];
    for (final semester in cachedSemesters) {
      if (semester.id == semesterId && semester.name.trim().isNotEmpty) {
        return semester.name.trim();
      }
    }
    return _historicalSemesterLabel(
      coursesBySemester[semesterId] ?? const <JwStoredEvent>[],
    );
  }

  String _historicalSemesterLabel(List<JwStoredEvent> events) {
    if (events.isEmpty) return '历史课表';
    final days = <DateTime>[];
    for (final event in events) {
      days
        ..add(_beijingDay(event.startsAtUtc))
        ..add(_beijingDay(event.endsAtUtc));
    }
    days.sort();
    final first = days.first;
    final last = days.last;
    final start = _formatHistoricalDay(first);
    final end = _formatHistoricalDay(last);
    return start == end ? '历史课表（$start）' : '历史课表（$start—$end）';
  }

  String _formatHistoricalDay(DateTime day) =>
      '${day.year}年${day.month}月${day.day}日';

  String? _eventSemesterLabel(
    JwStoredEvent event,
    Map<int, String> semesterLabels,
  ) {
    final semesterId = event.semesterId;
    if (event.kind != JwEventKind.course ||
        semesterId == null ||
        semesterId <= 0) {
      return null;
    }
    return semesterLabels[semesterId];
  }

  String get _displaySemesterDropdownValue =>
      _displaySemesterId == null ? 'all' : 'semester:$_displaySemesterId';

  int? _cachedSemesterDefault(JwDataView? data) {
    if (data == null) return null;
    final lastSemesterId = data.lastSemesterId;
    if (lastSemesterId == null ||
        !data.cachedSemesters.any((option) => option.id == lastSemesterId)) {
      return null;
    }
    return lastSemesterId;
  }

  bool _sameSemesterDirectory(
    List<JwSemesterOption> left,
    List<JwSemesterOption> right,
  ) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      final oldOption = left[index];
      final newOption = right[index];
      if (oldOption.id != newOption.id ||
          oldOption.name != newOption.name ||
          oldOption.selected != newOption.selected) {
        return false;
      }
    }
    return true;
  }

  @override
  void dispose() {
    _controllerEpoch++;
    _accountCodeController.clear();
    _passwordController.clear();
    _accountCodeController.dispose();
    _passwordController.dispose();
    final subscription = _subscription;
    if (subscription != null) unawaited(subscription.cancel());
    super.dispose();
  }

  bool get _hasPendingOperation =>
      _pendingOperations.isNotEmpty ||
      _pendingHiddenChanges.isNotEmpty ||
      _copyPending;

  bool get _isIdle => _view.phase == JwSyncPhase.idle;

  bool get _isLoginReady => _view.phase == JwSyncPhase.login && _view.ready;

  bool get _canOpen => _isIdle && !_hasPendingOperation && !_cancelPending;

  bool get _canStartSync => _canOpen;

  bool get _canContinueSync =>
      _view.automation == JwAutomationState.manualRequired &&
      !_hasPendingOperation &&
      !_cancelPending;

  bool get _canNavigate =>
      _isLoginReady && !_hasPendingOperation && !_cancelPending;

  bool get _canVerifyDirectory => _canNavigate;

  bool get _canCollect =>
      _canNavigate &&
      _semesterId != null &&
      _view.semesters.any((option) => option.id == _semesterId);

  bool get _canChangeSemester => _canNavigate && _view.semesters.isNotEmpty;

  bool get _canCancel =>
      const {
        JwSyncPhase.opening,
        JwSyncPhase.login,
        JwSyncPhase.verifying,
        JwSyncPhase.collecting,
        JwSyncPhase.closing,
        JwSyncPhase.committing,
      }.contains(_view.phase) &&
      !_cancelPending;

  bool get _canRetryRecovery =>
      _view.phase == JwSyncPhase.recovery &&
      !_hasPendingOperation &&
      !_cancelPending;

  bool get _canClearSession =>
      _isIdle && !_hasPendingOperation && !_cancelPending;

  bool get _credentialSaved => _view.data?.credentialSaved ?? false;

  int? get _lastSemesterId => _view.data?.lastSemesterId;

  bool get _rememberedSemesterMissing =>
      _lastSemesterId != null &&
      _view.semesters.isNotEmpty &&
      !_view.semesters.any((option) => option.id == _lastSemesterId);

  bool get _requestedSemesterMissing =>
      _hasActiveSyncRequest &&
      (_activeSyncSemesterId == null ||
          !_view.semesters.any((option) => option.id == _activeSyncSemesterId));

  bool get _canDeleteSavedCredential =>
      _isIdle && _credentialSaved && !_hasPendingOperation && !_cancelPending;

  bool get _canCopy => !_copyPending;

  bool get _canEditAccount => _canOpen && !_view.accountBound;

  String? get _semesterDropdownValue {
    if (_view.semesters.any((option) => option.id == _semesterId)) {
      return _semesterId.toString();
    }
    return null;
  }

  String? get _preSyncSemesterDropdownValue {
    final cached = _view.data?.cachedSemesters ?? const <JwSemesterOption>[];
    if (cached.any((option) => option.id == _preSyncSemesterId)) {
      return _preSyncSemesterId.toString();
    }
    return null;
  }

  String _freshSelectionMessage() {
    if (_hasActiveSyncRequest) {
      if (!_requestedSemesterMissing || _semesterId != null) {
        return '自动读取了最新学期目录，请确认要采集的学期。';
      }
      if (_activeSyncSemesterId == null) {
        return '自动确定的学期未能在登录后新目录中确认，请手动选择；不会自动切换到其他学期。';
      }
      return '开始前选择的学期不在登录后新目录中，请手动选择；不会自动切换到其他学期。';
    }
    if (_rememberedSemesterMissing && _semesterId == null) {
      return '上次成功学期不在本次新目录中，请手动选择；不会自动切换到当前学期。';
    }
    return '自动读取了最新学期目录，请确认要采集的学期。';
  }

  Future<void> _open() async {
    if (!_canOpen) return;
    _hasActiveSyncRequest = false;
    _activeSyncSemesterId = null;
    if (_view.accountBound) {
      _passwordController.clear();
      setState(() => _savePassword = false);
      await _runOperation(
        'open',
        () => widget.controller.open(),
        '无法打开教务观测窗口，请检查应用状态后重试。',
      );
      return;
    }

    final expectedAccountCode = _accountCodeController.text
        .trim()
        .toUpperCase();
    _accountCodeController.clear();
    _passwordController.clear();
    setState(() {
      _savePassword = false;
      _inputMessage = null;
      _actionMessage = null;
    });
    if (!RegExp(r'^[A-Z0-9]{5,24}$').hasMatch(expectedAccountCode)) {
      setState(() {
        _inputMessage = '请输入5至24位英文字母或数字。';
      });
      return;
    }
    await _runOperation(
      'open',
      () => widget.controller.open(expectedAccountCode: expectedAccountCode),
      '无法打开教务观测窗口，请检查应用状态后重试。',
    );
  }

  Future<void> _startSync() async {
    if (!_canStartSync) return;
    final semesterId = _preSyncSemesterId;
    _hasActiveSyncRequest = false;
    _activeSyncSemesterId = null;
    final expectedAccountCode = _view.accountBound
        ? null
        : _accountCodeController.text.trim().toUpperCase();
    var password = _passwordController.text;
    final savePassword = password.isNotEmpty && _savePassword;

    // Clear secret-bearing controls before validation and before the async call.
    _accountCodeController.clear();
    _passwordController.clear();
    setState(() {
      _savePassword = false;
      _inputMessage = null;
      _actionMessage = null;
    });
    if (expectedAccountCode != null &&
        !RegExp(r'^[A-Z0-9]{5,24}$').hasMatch(expectedAccountCode)) {
      setState(() => _inputMessage = '请输入5至24位英文字母或数字。');
      return;
    }
    if (password.length > 1024) {
      setState(() => _inputMessage = '密码不能超过1024个字符。');
      return;
    }
    _activeSyncSemesterId = semesterId;
    _hasActiveSyncRequest = true;
    await _runOperation('startSync', () {
      final supplied = password;
      password = '';
      return widget.controller.startSync(
        expectedAccountCode: expectedAccountCode,
        password: supplied.isEmpty ? null : supplied,
        savePassword: savePassword,
        semesterId: semesterId,
      );
    }, '登录或采集未能完成，请检查学校窗口后重试。');
  }

  Future<void> _continueSync() async {
    if (!_canContinueSync) return;
    await _runOperation(
      'continueSync',
      widget.controller.continueSync,
      '继续采集未能完成，请检查学校窗口后重试。',
    );
  }

  Future<void> _deleteSavedCredential() async {
    if (!_canDeleteSavedCredential) return;
    await _runOperation(
      'deleteSavedCredential',
      widget.controller.deleteSavedCredential,
      '删除本机加密保存的密码失败。',
    );
  }

  Future<void> _navigate(JwObservationPage page) async {
    if (!_canNavigate) return;
    await _runOperation(
      'navigate',
      () => widget.controller.navigateJwPage(page),
      '无法打开所选教务页面，请确认学校页面已就绪。',
    );
  }

  Future<void> _verifyDirectory() async {
    if (!_canVerifyDirectory) return;
    _resetSelectionForDirectoryRefresh = true;
    await _runOperation(
      'verifyDirectory',
      widget.controller.verifyDirectory,
      '读取学期目录失败，请确认学校页面已就绪。',
    );
    if (_actionMessage != null) {
      _resetSelectionForDirectoryRefresh = false;
    }
  }

  Future<void> _collect() async {
    final semesterId = _semesterId;
    if (!_canCollect || semesterId == null) return;
    await _runOperation(
      'collect',
      () => widget.controller.collect(semesterId),
      '采集请求未能完成，请检查观测窗口后重试。',
    );
  }

  Future<void> _runOperation(
    String key,
    Future<void> Function() operation,
    String safeFailureMessage,
  ) async {
    if (_pendingOperations.contains(key)) return;
    final epoch = _controllerEpoch;
    setState(() {
      _pendingOperations.add(key);
      _actionMessage = null;
    });
    try {
      await operation();
    } catch (_) {
      if (!mounted || epoch != _controllerEpoch) return;
      setState(() {
        _actionMessage = safeFailureMessage;
      });
    } finally {
      if (mounted && epoch == _controllerEpoch) {
        setState(() {
          _pendingOperations.remove(key);
        });
      }
    }
  }

  Future<void> _cancel() async {
    if (!_canCancel) return;
    final epoch = _controllerEpoch;
    setState(() {
      _cancelPending = true;
      _actionMessage = null;
    });
    try {
      await widget.controller.cancel();
    } catch (_) {
      if (!mounted || epoch != _controllerEpoch) return;
      setState(() {
        _actionMessage = '关闭本次作业请求未能完成，请检查观测窗口。';
      });
    } finally {
      if (mounted && epoch == _controllerEpoch) {
        setState(() => _cancelPending = false);
      }
    }
  }

  Future<void> _retryRecovery() async {
    if (!_canRetryRecovery) return;
    await _runOperation(
      'recovery',
      widget.controller.retryRecovery,
      '恢复请求未能完成，请稍后重试。',
    );
  }

  Future<void> _clearSession() async {
    if (!_canClearSession) return;
    await _runOperation(
      'clearSession',
      widget.controller.clearSession,
      '清除浏览器登录资料失败，请检查应用状态。',
    );
  }

  Future<void> _setHidden(JwStoredEvent event) async {
    if (!_isIdle || _hasPendingOperation || _cancelPending) return;
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
    } catch (_) {
      if (!mounted || epoch != _controllerEpoch) return;
      setState(() {
        _actionMessage = '更新本地日程显示状态失败，请刷新本地数据后重试。';
      });
    } finally {
      if (mounted && epoch == _controllerEpoch) {
        setState(() {
          _pendingHiddenChanges.remove(event.localId);
        });
      }
    }
  }

  Future<void> _copySafeSummary() async {
    if (!_canCopy) return;
    final epoch = _controllerEpoch;
    setState(() {
      _copyPending = true;
      _actionMessage = null;
    });
    try {
      await Clipboard.setData(
        ClipboardData(text: widget.controller.syncView.safeSummary),
      );
      if (!mounted || epoch != _controllerEpoch) return;
      setState(() {
        _actionMessage = '已复制导入脱敏摘要。';
      });
    } catch (_) {
      if (!mounted || epoch != _controllerEpoch) return;
      setState(() {
        _actionMessage = '复制摘要失败，请检查剪贴板权限。';
      });
    } finally {
      if (mounted && epoch == _controllerEpoch) {
        setState(() => _copyPending = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
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
                      'M1 教务采集与本地日程',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '应用会自动进入登录流程并准备学期目录。需要验证码或额外授权时，请在学校窗口完成。来源数据只读，导入结果保存为本地日程。',
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 16),
                    _operationStatus(context),
                    if (!_view.accountBound && _isIdle) ...[
                      const SizedBox(height: 14),
                      TextField(
                        key: const ValueKey('jw-sync-expected-account'),
                        controller: _accountCodeController,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        enableIMEPersonalizedLearning: false,
                        autofillHints: const [],
                        enabled: _canEditAccount,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _startSync(),
                        decoration: const InputDecoration(
                          labelText: '本次预期学号',
                          hintText: '输入5至24位英文字母或数字',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                    if (_isIdle) ...[
                      const SizedBox(height: 12),
                      TextField(
                        key: const ValueKey('jw-sync-password'),
                        controller: _passwordController,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        enableIMEPersonalizedLearning: false,
                        autofillHints: const [],
                        enabled: _canOpen,
                        textInputAction: TextInputAction.done,
                        onChanged: (value) => setState(() {
                          if (value.isEmpty) _savePassword = false;
                        }),
                        onSubmitted: (_) => _startSync(),
                        decoration: const InputDecoration(
                          labelText: '学校密码（可留空）',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      CheckboxListTile(
                        key: const ValueKey('jw-sync-save-password'),
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: const Text('在本机加密保存密码'),
                        subtitle: const Text('仅在本次身份核验与日程导入成功后保存。'),
                        value: _savePassword,
                        onChanged:
                            _canOpen && _passwordController.text.isNotEmpty
                            ? (value) =>
                                  setState(() => _savePassword = value ?? false)
                            : null,
                      ),
                      _preSyncSemesterPicker(context),
                      Text(
                        _credentialSaved ? '本机已有加密保存的密码，不会回填显示。' : '尚未保存密码。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (_credentialSaved) ...[
                        const SizedBox(height: 6),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            key: const ValueKey(
                              'jw-sync-delete-saved-credential',
                            ),
                            onPressed: _canDeleteSavedCredential
                                ? _deleteSavedCredential
                                : null,
                            icon: const Icon(Icons.key_off_outlined),
                            label: const Text('删除保存的密码'),
                          ),
                        ),
                        Text(
                          '只删除本机加密密码，保留账号绑定、本地日程和浏览器登录资料。',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                    if (_inputMessage != null) ...[
                      const SizedBox(height: 8),
                      _message(context, _inputMessage!, error: true),
                    ],
                    const SizedBox(height: 12),
                    _primaryActions(context),
                    if (_canCancel) ...[
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: _cancel,
                        icon: const Icon(Icons.stop_circle_outlined),
                        label: Text(_cancelPending ? '正在关闭本次作业' : '关闭本次作业'),
                      ),
                    ],
                    if (_actionMessage != null) ...[
                      const SizedBox(height: 10),
                      _message(context, _actionMessage!, error: true),
                    ],
                    const SizedBox(height: 18),
                    _localCounts(context),
                    const SizedBox(height: 12),
                    _localSchedule(context),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _canCopy ? _copySafeSummary : null,
                      icon: const Icon(Icons.copy_outlined),
                      label: const Text('复制导入脱敏摘要'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _operationStatus(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final messages = <String>[
      _phaseMessage(),
      if (_view.automation != JwAutomationState.none) _automationMessage(),
      if (_view.credentialFailure case final failure?)
        _credentialFailureMessage(failure),
      if (_view.failure case final failure?) _failureMessage(failure),
      if (_view.identityFailure case final failure?)
        _identityFailureMessage(failure),
      if (_view.sourceFailure case final failure?)
        _sourceFailureMessage(failure),
      if (_view.collectionValidation case final failure?)
        _collectionFailureMessage(failure),
    ];
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
          if (_view.phase == JwSyncPhase.login)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _view.ready
                    ? '学校页面已就绪。若需要验证码或额外授权，请在学校窗口完成。'
                    : '正在准备学校页面；页面就绪后可继续操作。',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          if (_view.phase == JwSyncPhase.recovery && _view.importCommitted) ...[
            const SizedBox(height: 8),
            const Text('数据已保存，登录资料仍需恢复'),
          ] else if (_view.importCommitted) ...[
            const SizedBox(height: 8),
            Text(
              '本次课表日程：${_view.courseCount}；本次考试日程：${_view.examCount}；本地事务：已提交；登录资料：${_view.profileRetained ? '已保留' : '未保留'}。',
            ),
          ],
          if (_view.profileRetained) ...[
            const SizedBox(height: 6),
            const Text('已保留登录资料，学校仍可能要求重新登录。'),
          ],
          if (_view.emptyExams) ...[
            const SizedBox(height: 6),
            const Text('本次未观察到考试，保留已有考试记录。'),
          ],
          if (_view.normalization case final counts?
              when counts.hasDuplicates) ...[
            const SizedBox(height: 6),
            Text(
              '本次已合并完全一致的重复记录：课表 ${counts.duplicateCourses} 条、考试 ${counts.duplicateExams} 条。日程数按合并后计。',
            ),
          ],
          if (_view.phase == JwSyncPhase.recovery &&
              !_view.importCommitted) ...[
            const SizedBox(height: 8),
            const Text('本次作业需要恢复；请重试收口或认领。'),
          ],
        ],
      ),
    );
  }

  String _phaseMessage() => switch (_view.phase) {
    JwSyncPhase.idle => _view.accountBound ? '教务账号已在本地绑定。' : '等待登录并采集。',
    JwSyncPhase.opening => '正在打开教务观测窗口。',
    JwSyncPhase.login => '教务观测窗口已打开。',
    JwSyncPhase.verifying => '正在读取学期目录。',
    JwSyncPhase.collecting => '正在只读采集所选学期。',
    JwSyncPhase.closing => '正在关闭本次作业。',
    JwSyncPhase.committing => '窗口已关闭，正在保存本地事务。',
    JwSyncPhase.recovery => '本次作业需要恢复。',
    JwSyncPhase.closed => '本次作业已关闭。',
  };

  String _automationMessage() => switch (_view.automation) {
    JwAutomationState.none => '',
    JwAutomationState.waitingForLogin => '正在进入学校登录页并等待认证。',
    JwAutomationState.submitting => '正在自动提交本次登录信息（仅一次）。',
    JwAutomationState.preparing => '身份确认后，正在自动准备学期目录。',
    JwAutomationState.choosingSemester => '最新学期目录已读取，请确认要采集的学期。',
    JwAutomationState.manualRequired => _loginPauseMessage(
      _view.loginPauseReason,
    ),
  };

  String _loginPauseMessage(JwLoginPauseReason? reason) => switch (reason) {
    null || JwLoginPauseReason.manualRequired => '请在学校窗口完成验证码、额外授权或登录，然后继续采集。',
    JwLoginPauseReason.pageStructureChanged => '学校登录控件不兼容，请在学校窗口手动登录后继续采集。',
    JwLoginPauseReason.challengeRequired => '学校要求验证码或额外授权，请在学校窗口完成后继续采集。',
    JwLoginPauseReason.contextUnavailable => '无法确认密码投递目标，请在学校窗口手动登录后继续采集。',
    JwLoginPauseReason.noCredentials => '本机未保存密码且本次未提供密码，请在学校窗口手动登录后继续采集。',
    JwLoginPauseReason.alreadySubmitted => '本次已提交一次登录信息，不会重复发送；请在学校窗口完成后继续采集。',
    JwLoginPauseReason.timedOut => '等待学校响应超时，请在学校窗口检查登录状态后继续采集。',
  };

  String _credentialFailureMessage(JwCredentialFailure failure) =>
      switch (failure) {
        JwCredentialFailure.unavailable => '此设备暂不支持加密保存密码。',
        JwCredentialFailure.protectionFailed => '本机加密保存密码失败。',
        JwCredentialFailure.invalidCredential => '已保存的密码不可用，请重新输入。',
      };

  Widget _primaryActions(BuildContext context) {
    final actions = <Widget>[];
    if (_isIdle) {
      actions.add(
        FilledButton.icon(
          key: const ValueKey('jw-sync-start'),
          onPressed: _canStartSync ? _startSync : null,
          icon: Icon(_view.accountBound ? Icons.sync : Icons.login),
          label: Text(_view.accountBound ? '自动采集' : '登录并采集'),
        ),
      );
      actions.add(
        OutlinedButton.icon(
          onPressed: _canClearSession ? _clearSession : null,
          icon: const Icon(Icons.logout),
          label: const Text('清除浏览器登录资料'),
        ),
      );
    }
    if (_view.automation == JwAutomationState.manualRequired) {
      actions.add(
        FilledButton.icon(
          key: const ValueKey('jw-sync-continue'),
          onPressed: _canContinueSync ? _continueSync : null,
          icon: const Icon(Icons.play_arrow),
          label: const Text('登录完成，继续采集'),
        ),
      );
    }
    if (_view.phase == JwSyncPhase.login &&
        _view.automation == JwAutomationState.choosingSemester) {
      actions.add(
        Text(
          _freshSelectionMessage(),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
      actions.add(_semesterSelector(context));
      actions.add(
        FilledButton.icon(
          key: const ValueKey('jw-sync-collect-semester'),
          onPressed: _canCollect ? _collect : null,
          icon: const Icon(Icons.download_outlined),
          label: const Text('采集并导入所选学期'),
        ),
      );
    }
    if (_view.phase == JwSyncPhase.recovery) {
      actions.add(
        FilledButton.icon(
          onPressed: _canRetryRecovery ? _retryRecovery : null,
          icon: const Icon(Icons.refresh),
          label: const Text('重试收口/认领'),
        ),
      );
    }
    actions.add(_manualTools(context));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: actions,
        ),
        if (_isIdle) ...[
          const SizedBox(height: 6),
          Text(
            '清除浏览器登录资料与删除加密保存的密码相互独立；清除登录资料不会删除账号绑定或本地日程。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  Widget _manualTools(BuildContext context) {
    final showManualSemesterControls =
        _view.phase == JwSyncPhase.login &&
        _view.automation != JwAutomationState.choosingSemester;
    return ExpansionTile(
      key: const ValueKey('jw-sync-diagnostics'),
      tilePadding: EdgeInsets.zero,
      title: const Text('手动观测与目录诊断'),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '常规登录与学期目录准备会自动进行。以下控制用于手动打开学校窗口或排查目录。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 10),
        if (_isIdle)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey('jw-sync-manual-open'),
              onPressed: _canOpen ? _open : null,
              icon: const Icon(Icons.open_in_browser),
              label: const Text('仅打开登录窗口'),
            ),
          ),
        if (_view.phase == JwSyncPhase.login) ...[
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('jw-sync-course-page'),
                onPressed: _canNavigate
                    ? () => _navigate(JwObservationPage.courseTable)
                    : null,
                icon: const Icon(Icons.calendar_month_outlined),
                label: const Text('打开课表页面'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('jw-sync-exam-page'),
                onPressed: _canNavigate
                    ? () => _navigate(JwObservationPage.examArrange)
                    : null,
                icon: const Icon(Icons.assignment_outlined),
                label: const Text('打开考试安排'),
              ),
              FilledButton.icon(
                onPressed: _canVerifyDirectory ? _verifyDirectory : null,
                icon: const Icon(Icons.list_alt_outlined),
                label: const Text('重新读取学期目录'),
              ),
            ],
          ),
          if (showManualSemesterControls) ...[
            const SizedBox(height: 10),
            if (_rememberedSemesterMissing && _semesterId == null)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text('上次成功学期不在此目录中，请手动选择；不会自动切换学期。'),
              ),
            _semesterSelector(context),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: _canCollect ? _collect : null,
                icon: const Icon(Icons.download_outlined),
                label: const Text('采集并导入所选学期'),
              ),
            ),
          ],
        ],
      ],
    );
  }

  Widget _semesterSelector(BuildContext context) {
    if (_view.semesters.isEmpty) {
      return const InputDecorator(
        decoration: InputDecoration(
          labelText: '已读取学期目录',
          border: OutlineInputBorder(),
        ),
        child: Text('请先读取学期目录。'),
      );
    }
    return SizedBox(
      width: 320,
      child: DropdownButtonFormField<String>(
        key: const ValueKey('jw-sync-semester'),
        initialValue: _semesterDropdownValue,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: '选择已读取学期',
          border: OutlineInputBorder(),
        ),
        items: [
          for (final semester in _view.semesters)
            DropdownMenuItem<String>(
              value: semester.id.toString(),
              child: Text(
                semester.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: _canChangeSemester
            ? (value) {
                setState(() {
                  _semesterId = value == null ? null : int.tryParse(value);
                  _actionMessage = null;
                });
              }
            : null,
      ),
    );
  }

  Widget _preSyncSemesterPicker(BuildContext context) {
    final cached = _view.data?.cachedSemesters ?? const <JwSemesterOption>[];
    if (cached.isEmpty) {
      final message = _lastSemesterId != null
          ? '已记录上次成功学期，本次会沿用该学期，并在成功后保存目录。之后每次登录仍会重新读取并验证目录。'
          : '首次采集会按北京时间当前月份自动选择学期并保存目录；之后每次登录仍会重新读取并验证目录。';
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(message, style: Theme.of(context).textTheme.bodySmall),
      );
    }
    final lastSemesterId = _lastSemesterId;
    final rememberedMissing =
        lastSemesterId != null &&
        !cached.any((option) => option.id == lastSemesterId);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          KeyedSubtree(
            key: ValueKey(
              'jw-sync-pre-sync-semester-$_controllerEpoch-$_preSyncDropdownGeneration',
            ),
            child: SizedBox(
              width: 360,
              child: DropdownButtonFormField<String>(
                key: const ValueKey('jw-sync-pre-sync-semester'),
                initialValue: _preSyncSemesterDropdownValue,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '本次同步学期（可选）',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final semester in cached)
                    DropdownMenuItem<String>(
                      value: semester.id.toString(),
                      child: Text(
                        semester.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _canOpen
                    ? (value) {
                        setState(() {
                          _preSyncSemesterId = value == null
                              ? null
                              : int.tryParse(value);
                          _preSyncSelectionDirty = true;
                          _actionMessage = null;
                        });
                      }
                    : null,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            rememberedMissing
                ? '上次成功学期不在已保存目录中，请选择本次学期；不会自动替换。缓存只用于此处选择，每次登录仍会重新读取并验证。'
                : '缓存只用于开始前选择；每次登录仍会重新读取并验证学期目录。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _localCounts(BuildContext context) {
    final data = _view.data;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: data == null
          ? const Text('本地日程尚未导入。')
          : Wrap(
              spacing: 14,
              runSpacing: 8,
              children: [
                Text('本地课表日程：${data.courseCount}'),
                Text('本地考试日程：${data.examCount}'),
                Text('导入操作数：${data.importCount}'),
              ],
            ),
    );
  }

  Widget _localSchedule(BuildContext context) {
    final data = _view.data;
    final events = data?.events ?? const <JwStoredEvent>[];
    final coursesBySemester = _courseEventsBySemester(events);
    final semesterIds = coursesBySemester.keys.toList()..sort();
    final semesterLabels = <int, String>{
      for (final semesterId in semesterIds)
        semesterId: _displaySemesterLabel(semesterId, coursesBySemester),
    };
    final hasHiddenEvents = events.any((event) => event.hidden);
    final visibleEvents =
        events.where((event) {
          if (!_showHidden && event.hidden) return false;
          if (event.kind == JwEventKind.course &&
              _displaySemesterId != null &&
              event.semesterId != _displaySemesterId) {
            return false;
          }
          if (_dateRange == 'all') return true;
          final day = _beijingDay(event.startsAtUtc);
          final today = _beijingDay(DateTime.now().toUtc());
          return !day.isBefore(today) &&
              day.isBefore(today.add(const Duration(days: 7)));
        }).toList()..sort(
          (left, right) => left.startsAtUtc.compareTo(right.startsAtUtc),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '本地日程',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          '时间均为北京时间；来源范围状态只说明本次观察结果，缺失记录仍会显示。课表学期仅筛选课程，考试独立显示。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 240;
            final dateWidth = compact ? constraints.maxWidth : 180.0;
            final semesterWidth = compact ? constraints.maxWidth : 250.0;
            final semesterLabelWidth = (semesterWidth - 72)
                .clamp(0.0, 178.0)
                .toDouble();
            return Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: dateWidth,
                  child: DropdownButtonFormField<String>(
                    key: const ValueKey('jw-sync-date-range'),
                    initialValue: _dateRange,
                    decoration: const InputDecoration(
                      labelText: '日期范围',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: '7', child: Text('未来7天')),
                      DropdownMenuItem(value: 'all', child: Text('全部日程')),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _dateRange = value);
                    },
                  ),
                ),
                SizedBox(
                  width: semesterWidth,
                  child: DropdownButtonFormField<String>(
                    key: ValueKey(
                      'jw-sync-display-semester-$_displaySemesterDropdownValue',
                    ),
                    initialValue: _displaySemesterDropdownValue,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '课表学期',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: 'all',
                        child: SizedBox(
                          width: semesterLabelWidth,
                          child: Text(
                            '全部已导入学期',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      for (final semesterId in semesterIds)
                        DropdownMenuItem(
                          value: 'semester:$semesterId',
                          child: SizedBox(
                            width: semesterLabelWidth,
                            child: Text(
                              semesterLabels[semesterId]!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      if (value == 'all') {
                        setState(() => _displaySemesterId = null);
                        return;
                      }
                      final semesterId = int.tryParse(
                        value.replaceFirst('semester:', ''),
                      );
                      final available = _courseEventsBySemester(
                        _view.data?.events ?? const <JwStoredEvent>[],
                      );
                      setState(() {
                        _displaySemesterId =
                            semesterId != null &&
                                available.containsKey(semesterId)
                            ? semesterId
                            : null;
                      });
                    },
                  ),
                ),
                if (hasHiddenEvents)
                  SizedBox(
                    width: compact ? constraints.maxWidth : 220,
                    child: CheckboxListTile(
                      key: const ValueKey('jw-sync-show-hidden'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('显示已隐藏'),
                      value: _showHidden,
                      onChanged: (value) {
                        setState(() => _showHidden = value ?? false);
                      },
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 8),
        if (events.isEmpty)
          const InputDecorator(
            decoration: InputDecoration(border: OutlineInputBorder()),
            child: Text('尚未导入日程。'),
          )
        else if (visibleEvents.isEmpty)
          const InputDecorator(
            decoration: InputDecoration(border: OutlineInputBorder()),
            child: Text('当前筛选条件下没有可显示的日程。'),
          )
        else
          SizedBox(
            height: 360,
            child: ListView.separated(
              key: const ValueKey('jw-sync-event-list'),
              itemCount: visibleEvents.length,
              separatorBuilder: (context, index) =>
                  const Divider(height: 1, indent: 14, endIndent: 14),
              itemBuilder: (context, index) {
                final event = visibleEvents[index];
                return _eventTile(
                  context,
                  event,
                  semesterLabel: _eventSemesterLabel(event, semesterLabels),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _eventTile(
    BuildContext context,
    JwStoredEvent event, {
    String? semesterLabel,
  }) {
    final isHiddenPending = _pendingHiddenChanges.contains(event.localId);
    return ListTile(
      key: ValueKey('jw-sync-event-${event.localId}'),
      title: Text(event.title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(event.kind == JwEventKind.course ? '课程' : '考试'),
          if (semesterLabel != null) Text('课表学期：$semesterLabel'),
          Text(
            '${formatBeijing(event.startsAtUtc)} — ${formatBeijing(event.endsAtUtc)}',
          ),
          Text(_presenceMessage(event.presence)),
          if (event.hidden) const Text('已隐藏'),
        ],
      ),
      trailing: TextButton(
        onPressed: _isIdle && !_hasPendingOperation && !_cancelPending
            ? () => _setHidden(event)
            : null,
        child: Text(
          isHiddenPending
              ? '正在保存'
              : event.hidden
              ? '恢复显示'
              : '隐藏',
        ),
      ),
    );
  }

  DateTime _beijingDay(DateTime utc) {
    final beijing = utc.toUtc().add(const Duration(hours: 8));
    return DateTime.utc(beijing.year, beijing.month, beijing.day);
  }

  String _presenceMessage(JwPresence presence) => switch (presence) {
    JwPresence.observed => '来源：本次已观察',
    JwPresence.outsideScope => '来源：本次范围外，保留历史记录',
    JwPresence.missingWithinScope => '来源：本次范围内缺失，仍保留记录',
  };

  Widget _message(BuildContext context, String value, {required bool error}) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: error
            ? colorScheme.errorContainer
            : colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        value,
        style: TextStyle(
          color: error
              ? colorScheme.onErrorContainer
              : colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  String _failureMessage(FailureCode failure) => switch (failure) {
    FailureCode.busy => '已有作业正在执行。',
    FailureCode.cancelled => '本次作业已取消。',
    FailureCode.staleResult => '本次结果已过期，已安全丢弃。',
    FailureCode.incompleteSnapshot => '本次来源数据不完整，未接受结果。',
    FailureCode.invalidSnapshot => '本次来源数据不符合固定契约，未接受结果。',
    FailureCode.idempotencyConflict => '导入记录冲突，需要恢复本次作业。',
    FailureCode.sourceFailed => '读取学校来源失败。',
    FailureCode.storageFailed => '本地保存失败。',
    FailureCode.cleanupPending => '观测窗口仍需关闭，请重试收口。',
    FailureCode.followUpPending => '本地提交后的收尾仍未完成。',
    FailureCode.ownerConflict => '本地作业归属冲突，已停止操作。',
    FailureCode.unsafeDirectory => '本地观测目录不安全，已停止操作。',
    FailureCode.ownershipLost => '观测窗口归属已变化，已停止操作。',
    FailureCode.unsupportedPlatform => '当前平台不支持此项教务操作。',
    FailureCode.closed => '本次作业已关闭。',
  };

  String _collectionFailureMessage(JwCollectionValidationFailure failure) =>
      switch (failure.reason) {
        JwCollectionRejectionReason.duplicateCourseKey =>
          failure.duplicateIdentical == false
              ? '课表中同一日程的记录内容冲突，本次未导入。'
              : '课表中有重复日程记录，本次未导入。',
        JwCollectionRejectionReason.duplicateExamKey => '考试安排中有重复日程记录，本次未导入。',
        JwCollectionRejectionReason.selfRouteUnbound => '本次采集未确认本人业务页面，未接受结果。',
        JwCollectionRejectionReason.proofInvalid => '采集结果的身份或完整性证明未通过。',
        JwCollectionRejectionReason.projectionInvalid => '采集结果结构无法解析。',
        JwCollectionRejectionReason.snapshotShape => '采集结果缺少完整日程。',
        JwCollectionRejectionReason.eventCount => '日程条数与验证计数不一致。',
        JwCollectionRejectionReason.courseFields => '课表日程字段校验未通过。',
        JwCollectionRejectionReason.examFields => '考试日程字段校验未通过。',
        JwCollectionRejectionReason.sealMetadataMismatch =>
          '采集结果与当前作业不一致，未接受结果。',
      };

  String _identityFailureMessage(JwIdentityFailure failure) =>
      switch (failure) {
        JwIdentityFailure.identityUnverified => '当前登录身份尚未核验。',
        JwIdentityFailure.evidenceConflict => '身份来源证据不一致，已停止导入。',
        JwIdentityFailure.accountMismatch => '登录身份与本地绑定不一致。',
        JwIdentityFailure.identityMismatch => '本次登录身份发生变化，已停止导入。',
      };

  String _sourceFailureMessage(JwDataProbeCode failure) => switch (failure) {
    JwDataProbeCode.pending => '正在等待固定来源检查结果。',
    JwDataProbeCode.ok => '固定来源检查通过。',
    JwDataProbeCode.cancelled => '固定来源检查已取消。',
    JwDataProbeCode.studentContextMissing => '学校页面未提供可用的学生上下文。',
    JwDataProbeCode.identityHttp => '身份来源请求失败。',
    JwDataProbeCode.identityMime => '身份来源格式无法识别。',
    JwDataProbeCode.identityTooLarge => '身份来源数据超过安全上限。',
    JwDataProbeCode.identitySchema => '身份来源结构不符合固定契约。',
    JwDataProbeCode.courseHttp => '课表来源请求失败。',
    JwDataProbeCode.courseMime => '课表来源格式无法识别。',
    JwDataProbeCode.courseTooLarge => '课表来源数据超过安全上限。',
    JwDataProbeCode.courseSchema => '课表来源结构不符合固定契约。',
    JwDataProbeCode.indexHttp => '课表索引读取失败。',
    JwDataProbeCode.indexMime => '课表索引格式无法识别。',
    JwDataProbeCode.indexTooLarge => '课表索引数据超过安全上限。',
    JwDataProbeCode.indexSchema => '课表索引结构不符合固定契约。',
    JwDataProbeCode.datumHttp => '课表详情读取失败。',
    JwDataProbeCode.datumMime => '课表详情格式无法识别。',
    JwDataProbeCode.datumTooLarge => '课表详情数据超过安全上限。',
    JwDataProbeCode.datumSchema => '课表详情结构不符合固定契约。',
    JwDataProbeCode.examsHttp => '考试安排读取失败。',
    JwDataProbeCode.examsMime => '考试安排格式无法识别。',
    JwDataProbeCode.examsTooLarge => '考试安排数据超过安全上限。',
    JwDataProbeCode.examsSchema => '考试安排结构不符合固定契约。',
    JwDataProbeCode.networkFailed => '学校来源连接失败。',
    JwDataProbeCode.timedOut => '学校来源响应超时。',
    JwDataProbeCode.helperUnavailable => '页面读取能力暂不可用。',
    JwDataProbeCode.staleResult => '来源结果已过期，已安全丢弃。',
    JwDataProbeCode.serviceWorkerControlled => '来源页面由服务工作线程控制，已停止读取。',
    JwDataProbeCode.semesterUnknown => '所选学期不在已读取目录中。',
    JwDataProbeCode.identityChanged => '采集过程中登录身份发生变化。',
  };
}
