import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/contracts.dart';
import '../data/jw_candidate_identity.dart';
import '../jobs/jw_probe_port.dart';
import '../source/jw_probe_contract.dart';

/// Lets the user compare a fixed read-only browser projection with a private
/// expected account code. The port owns the observation session lifecycle.
class JwProbePanel extends StatefulWidget {
  const JwProbePanel({super.key, required this.controller});

  final JwProbePort controller;

  @override
  State<JwProbePanel> createState() => _JwProbePanelState();
}

class _JwProbePanelState extends State<JwProbePanel> {
  final TextEditingController _accountCodeController = TextEditingController();
  StreamSubscription<JwProbeView>? _subscription;
  late JwProbeView _view;
  int _controllerEpoch = 0;
  int _runToken = 0;
  int _cancelToken = 0;
  bool _runPending = false;
  bool _cancelPending = false;
  bool _copyPending = false;
  String? _inputMessage;
  String? _actionMessage;

  @override
  void initState() {
    super.initState();
    _connect(widget.controller);
  }

  @override
  void didUpdateWidget(covariant JwProbePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;

    _controllerEpoch++;
    _runToken++;
    _cancelToken++;
    final oldSubscription = _subscription;
    _subscription = null;
    if (oldSubscription != null) unawaited(oldSubscription.cancel());
    _accountCodeController.clear();
    _runPending = false;
    _cancelPending = false;
    _copyPending = false;
    _inputMessage = null;
    _actionMessage = null;
    _connect(widget.controller);
  }

  void _connect(JwProbePort controller) {
    _view = controller.probeView;
    final epoch = _controllerEpoch;
    _subscription = controller.probeChanges.listen(
      (next) {
        if (!mounted || epoch != _controllerEpoch) return;
        setState(() {
          _view = next;
          if (!next.available || next.busy) _accountCodeController.clear();
        });
      },
      onError: (Object _, StackTrace _) {
        if (!mounted || epoch != _controllerEpoch) return;
        setState(() => _actionMessage = '读取验证进度失败，请检查观测窗口。');
      },
    );
  }

  @override
  void dispose() {
    _controllerEpoch++;
    _runToken++;
    _cancelToken++;
    _accountCodeController.clear();
    _accountCodeController.dispose();
    final subscription = _subscription;
    if (subscription != null) unawaited(subscription.cancel());
    super.dispose();
  }

  bool get _isBusy => _view.busy || _runPending || _cancelPending;

  bool get _canRun => _view.available && !_isBusy && !_copyPending;

  bool get _canCancel => (_view.busy || _runPending) && !_cancelPending;

  bool get _canCopy =>
      !_copyPending &&
      _view.phase != JwProbePhase.idle &&
      _view.phase != JwProbePhase.running;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
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
                      'M1 教务业务契约验证',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '请先在观测窗口手动登录并填写预期学号。上方入口按钮只用于打开业务页；点击“验证只读契约”后，会依次检查身份页、课表学期和考试表格。',
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '输入的是本次比较用的私有账号，不是密码；不会保存。',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      key: const ValueKey('jw-probe-expected-account'),
                      controller: _accountCodeController,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      enableIMEPersonalizedLearning: false,
                      autofillHints: const [],
                      enabled: _view.available && !_view.busy && !_isBusy,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                      decoration: const InputDecoration(
                        labelText: '预期学号',
                        hintText: '输入5至24位大写字母或数字',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (_inputMessage != null) ...[
                      const SizedBox(height: 8),
                      _notice(context, _inputMessage!),
                    ],
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        FilledButton.icon(
                          onPressed: _canRun ? _submit : null,
                          icon: const Icon(Icons.fact_check_outlined),
                          label: const Text('验证只读契约'),
                        ),
                        if (_canCancel)
                          OutlinedButton.icon(
                            onPressed: _cancelProbe,
                            icon: const Icon(Icons.stop_circle_outlined),
                            label: const Text('取消并清理观测窗口'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _status(context),
                    const SizedBox(height: 12),
                    Text(
                      '结构检查通过不代表身份可信或正式来源可用；候选匹配仍需确认与当前登录会话的绑定。',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '取消会关闭观测窗口并排空临时会话。',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (_view.summary case final summary?) ...[
                      const SizedBox(height: 18),
                      _summary(context, summary),
                      if (_view.semesters.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        Text(
                          '观察到的学期选项',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        for (final semester in _view.semesters)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  semester.selected
                                      ? Icons.radio_button_checked
                                      : Icons.radio_button_unchecked,
                                  size: 18,
                                  color: semester.selected
                                      ? colorScheme.primary
                                      : colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    semester.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ],
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _canCopy ? _copySafeSummary : null,
                      icon: const Icon(Icons.copy_outlined),
                      label: const Text('复制脱敏摘要'),
                    ),
                    if (_isBusy) ...[
                      const SizedBox(height: 12),
                      const LinearProgressIndicator(),
                    ],
                    if (_actionMessage != null) ...[
                      const SizedBox(height: 12),
                      _notice(context, _actionMessage!),
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

  Widget _status(BuildContext context) {
    final message = _statusMessage();
    final stageLabel = _stageMessage(_view.stage);
    final codeIsShownInStageResults =
        _view.summary?.stageResults.values.contains(_view.code) ??
        (_view.stage != null && _isStageCode(_view.code));
    final codeMessage = codeIsShownInStageResults
        ? null
        : _codeMessage(_view.code);
    final phaseColor = _view.phase == JwProbePhase.failed
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.primary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: phaseColor,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 5),
          Text('候选状态：${_identityMessage(_view.identity)}'),
          if (_view.phase == JwProbePhase.running)
            Text('正在检查：${_stageMessage(_progressStage) ?? '固定项目'}'),
          if (_view.phase == JwProbePhase.failed && stageLabel != null)
            Text('首个失败项：$stageLabel'),
          const SizedBox(height: 8),
          Text('三项独立结果', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          for (final stage in _stageNames.entries)
            _stageResultRow(context, stage.key, stage.value),
          if (codeMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(codeMessage),
            ),
          if (_failureMessage(_view.failure) case final failure?)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(failure),
            ),
        ],
      ),
    );
  }

  String? get _progressStage =>
      _view.stage ?? (_view.phase == JwProbePhase.running ? 'identity' : null);

  Widget _stageResultRow(BuildContext context, String key, String label) {
    final summaryResult = _view.summary?.stageResults[key];
    final currentStageCode = _view.stage == key && _isStageCode(_view.code)
        ? _view.code
        : null;
    final result =
        summaryResult == JwProbeCode.pending && currentStageCode != null
        ? currentStageCode
        : summaryResult ?? currentStageCode ?? JwProbeCode.pending;
    final message = switch (result) {
      JwProbeCode.ok => '通过',
      JwProbeCode.pending =>
        _view.phase == JwProbePhase.running && _progressStage == key
            ? '进行中'
            : '未检查',
      _ => '未通过：${_codeMessage(result) ?? '检查未通过。'}',
    };
    final color = switch (result) {
      JwProbeCode.ok => Theme.of(context).colorScheme.primary,
      JwProbeCode.pending => Theme.of(context).colorScheme.onSurfaceVariant,
      _ => Theme.of(context).colorScheme.error,
    };
    final icon = switch (result) {
      JwProbeCode.ok => Icons.check_circle_outline,
      JwProbeCode.pending =>
        _view.phase == JwProbePhase.running && _progressStage == key
            ? Icons.pending_outlined
            : Icons.radio_button_unchecked,
      _ => Icons.error_outline,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text('$label：$message')),
        ],
      ),
    );
  }

  String _statusMessage() {
    if (_cancelPending) return '正在取消并清理观测窗口，等待临时会话排空。';
    if (_isBusy) return '只读契约验证正在进行。';
    return switch (_view.phase) {
      JwProbePhase.idle => '尚未运行只读契约验证。',
      JwProbePhase.running => '只读契约验证正在进行。',
      JwProbePhase.done => '候选契约摘要已生成，仍待确认登录会话绑定。',
      JwProbePhase.failed => '只读契约验证未完成。',
      JwProbePhase.cancelled => '验证已取消，临时会话已请求排空。',
    };
  }

  Widget _summary(BuildContext context, JwProbeSummary summary) {
    final trueVariableCount = summary.semesterVariables.values
        .where((value) => value)
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('结构摘要', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        Text('候选数：${summary.identityLabels}'),
        Text('学期选项数：${summary.semesterOptions}'),
        Text('考试表/行数：${summary.examTables} / ${summary.examRows}'),
        Text('学期选择控件：${_yesNo(summary.semesterSelect)}'),
        Text('已识别学期变量：$trueVariableCount / 4'),
        Text('已识别八列表头：${_yesNo(summary.examHeader)}'),
        Text('发现分页：${_yesNo(summary.pagination)}'),
        const SizedBox(height: 10),
        Text('课表学期来源诊断', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text('服务端选项数：${summary.courseDiagnostics.serverOptions}'),
        Text('当前页面选项数（仅诊断）：${summary.courseDiagnostics.liveOptions}'),
        Text('脚本字面赋值数：${summary.courseDiagnostics.literalAssignments}'),
        Text('服务端 JSON 目录项数：${summary.courseDiagnostics.literalItems}'),
        Text(
          '服务端 JSON 目录解析：${_yesNo(summary.courseDiagnostics.literalParsed)}',
        ),
        Text(
          '学期目录读取来源：${_courseSourceMessage(summary.courseDiagnostics.source)}',
        ),
        if (_courseReasonMessage(summary.courseDiagnostics.reason)
            case final reason?)
          Text(
            '课表拒绝原因：$reason',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        if (summary.pagination) ...[
          const SizedBox(height: 6),
          Text(
            '发现分页结构；当前摘要不代表已读取所有分页。',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }

  Widget _notice(BuildContext context, String message) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.errorContainer,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      message,
      style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
    ),
  );

  void _submit() {
    if (!_canRun) return;
    final expectedAccountCode = _accountCodeController.text.trim();
    _accountCodeController.clear();
    if (!RegExp(r'^[A-Z0-9]{5,24}$').hasMatch(expectedAccountCode)) {
      setState(() {
        _inputMessage = '请输入5至24位大写英文字母或数字。';
        _actionMessage = null;
      });
      return;
    }

    final controller = widget.controller;
    final epoch = _controllerEpoch;
    final token = ++_runToken;
    setState(() {
      _runPending = true;
      _inputMessage = null;
      _actionMessage = null;
    });

    try {
      final request = controller.runProbe(expectedAccountCode);
      unawaited(_finishRun(request, controller, epoch, token));
    } catch (_) {
      _showRunFailure(epoch, token);
    }
  }

  Future<void> _finishRun(
    Future<void> request,
    JwProbePort controller,
    int epoch,
    int token,
  ) async {
    try {
      await request;
    } catch (_) {
      _showRunFailure(epoch, token);
    } finally {
      if (_isCurrent(controller, epoch) && token == _runToken) {
        setState(() => _runPending = false);
      }
    }
  }

  void _showRunFailure(int epoch, int token) {
    if (!mounted ||
        epoch != _controllerEpoch ||
        token != _runToken ||
        widget.controller.probeView.phase == JwProbePhase.failed) {
      return;
    }
    setState(() {
      _runPending = false;
      _actionMessage = '验证请求失败，请检查观测页面后重试。';
    });
  }

  void _cancelProbe() {
    if (!_canCancel) return;
    final controller = widget.controller;
    final epoch = _controllerEpoch;
    final token = ++_cancelToken;
    // Release the UI run guard as soon as cancellation is requested. The
    // controller owns cancellation and may settle this request independently.
    _runToken++;
    setState(() {
      _runPending = false;
      _cancelPending = true;
      _inputMessage = null;
      _actionMessage = null;
    });

    try {
      final request = controller.cancelProbe();
      unawaited(_finishCancel(request, controller, epoch, token));
    } catch (_) {
      _showCancelFailure(controller, epoch, token);
    }
  }

  Future<void> _finishCancel(
    Future<void> request,
    JwProbePort controller,
    int epoch,
    int token,
  ) async {
    try {
      await request;
    } catch (_) {
      _showCancelFailure(controller, epoch, token);
    } finally {
      if (_isCurrent(controller, epoch) && token == _cancelToken) {
        setState(() => _cancelPending = false);
      }
    }
  }

  void _showCancelFailure(JwProbePort controller, int epoch, int token) {
    if (!_isCurrent(controller, epoch) || token != _cancelToken) return;
    setState(() {
      _cancelPending = false;
      _actionMessage = '取消请求未完成，请检查观测窗口后重试。';
    });
  }

  Future<void> _copySafeSummary() async {
    if (!_canCopy) return;
    final controller = widget.controller;
    final epoch = _controllerEpoch;
    final safeSummary = _view.safeSummary;
    setState(() {
      _copyPending = true;
      _actionMessage = null;
    });
    try {
      await Clipboard.setData(ClipboardData(text: safeSummary));
      if (_isCurrent(controller, epoch)) {
        setState(() => _actionMessage = '已复制脱敏摘要');
      }
    } catch (_) {
      if (_isCurrent(controller, epoch)) {
        setState(() => _actionMessage = '脱敏摘要复制失败，请重试。');
      }
    } finally {
      if (_isCurrent(controller, epoch)) {
        setState(() => _copyPending = false);
      }
    }
  }

  bool _isCurrent(JwProbePort controller, int epoch) =>
      mounted && epoch == _controllerEpoch && widget.controller == controller;

  static String _identityMessage(JwCandidateIdentity identity) =>
      switch (identity) {
        JwCandidateIdentity.unavailable => '未取得候选',
        JwCandidateIdentity.candidateMatches => '候选匹配',
        JwCandidateIdentity.candidateMismatch => '候选不符',
        JwCandidateIdentity.candidateConflict => '候选冲突',
      };

  static String? _stageMessage(String? stage) => switch (stage) {
    'identity' => '身份页',
    'course' => '课表学期',
    'exams' => '考试表格',
    _ => null,
  };

  static const Map<String, String> _stageNames = {
    'identity': '身份页结构检查',
    'course': '课表学期检查',
    'exams': '考试表格检查',
  };

  static bool _isStageCode(JwProbeCode code) => switch (code) {
    JwProbeCode.identityHttp ||
    JwProbeCode.identityMime ||
    JwProbeCode.identityTooLarge ||
    JwProbeCode.identitySchema ||
    JwProbeCode.courseHttp ||
    JwProbeCode.courseMime ||
    JwProbeCode.courseTooLarge ||
    JwProbeCode.courseSchema ||
    JwProbeCode.examsHttp ||
    JwProbeCode.examsMime ||
    JwProbeCode.examsTooLarge ||
    JwProbeCode.examsSchema ||
    JwProbeCode.networkFailed ||
    JwProbeCode.timedOut ||
    JwProbeCode.helperUnavailable => true,
    _ => false,
  };

  static String? _codeMessage(JwProbeCode code) => switch (code) {
    JwProbeCode.pending || JwProbeCode.ok => null,
    JwProbeCode.cancelled => '本次验证已取消。',
    JwProbeCode.studentContextMissing => '请用上方“打开课表页面”或“打开考试安排”进入独立页面后重试。',
    JwProbeCode.identityHttp ||
    JwProbeCode.courseHttp ||
    JwProbeCode.examsHttp => '来源响应未满足固定契约（HTTP），该结果已拒绝。',
    JwProbeCode.identityMime ||
    JwProbeCode.courseMime ||
    JwProbeCode.examsMime => '来源响应类型不符合固定契约，该结果已拒绝。',
    JwProbeCode.identityTooLarge ||
    JwProbeCode.courseTooLarge ||
    JwProbeCode.examsTooLarge => '来源响应超过安全读取上限，该结果已拒绝。',
    JwProbeCode.identitySchema ||
    JwProbeCode.courseSchema ||
    JwProbeCode.examsSchema => '来源结构不符合固定契约，该结果已拒绝。',
    JwProbeCode.networkFailed => '网络读取失败，请检查观测页面后重试。',
    JwProbeCode.timedOut => '只读验证超时，请重新打开业务页后重试。',
    JwProbeCode.helperUnavailable => '验证组件暂不可用，请检查观测窗口。',
    JwProbeCode.staleResult => '页面上下文已变化，请打开课表或考试页后重试。',
    JwProbeCode.serviceWorkerControlled => '页面的后台处理器参与响应，当前探针无法确认服务端来源，请保留此摘要。',
  };

  static String? _failureMessage(FailureCode? failure) => switch (failure) {
    null => null,
    FailureCode.busy => '当前已有验证正在处理，请稍后重试。',
    FailureCode.cancelled => '验证已取消，临时会话正在排空。',
    FailureCode.staleResult => '页面上下文已变化，请打开业务详情页后重试。',
    FailureCode.incompleteSnapshot => '验证结果不完整，未接受该结果。',
    FailureCode.invalidSnapshot => '验证结果不符合固定结构，已拒绝。',
    FailureCode.idempotencyConflict => '验证操作状态冲突，请重新打开观测窗口。',
    FailureCode.sourceFailed => '来源读取失败，请检查观测窗口后重试。',
    FailureCode.storageFailed => '本地状态处理失败，请重试。',
    FailureCode.cleanupPending => '临时会话尚未排空，请先完成窗口清理。',
    FailureCode.followUpPending => '仍有验证收尾操作待完成，请稍后重试。',
    FailureCode.ownerConflict => '当前验证会话被其他操作占用。',
    FailureCode.unsafeDirectory => '本地安全状态不可用，请检查应用后重试。',
    FailureCode.ownershipLost => '验证会话状态已失效，请重新打开观测窗口。',
    FailureCode.unsupportedPlatform => '当前设备暂不支持这项验证。',
    FailureCode.closed => '观测窗口已关闭，请重新打开后重试。',
  };

  static String _yesNo(bool value) => value ? '是' : '否';

  static String _courseSourceMessage(String source) => switch (source) {
    'serverSelect' => '服务器选项',
    'serverJson' => '服务器 JSON 数据',
    'none' => '未接受',
    _ => '未接受',
  };

  static String? _courseReasonMessage(String reason) => switch (reason) {
    'none' => null,
    'select_missing' => '未找到学期选择控件。',
    'select_conflict' => '学期选择控件存在冲突。',
    'options_empty' => '学期控件中没有可接受的选项。',
    'options_limit' => '学期选项数量超过安全上限。',
    'option_value' => '存在格式无效的学期选项值。',
    'option_duplicate' => '学期选项值重复。',
    'option_name' => '存在格式无效的学期选项名称。',
    'selected_conflict' => '学期选项的当前选择状态冲突。',
    'literal_missing' => '未找到符合固定契约的服务端学期目录数据。',
    'literal_duplicate' => '服务端学期目录数据重复。',
    'literal_unsupported' => '服务端学期目录数据格式不受支持。',
    'literal_invalid' => '服务端学期目录数据无效。',
    'literal_limit' => '服务端学期目录数据超过安全上限。',
    'literal_key_conflict' => '服务端学期目录关键字段冲突。',
    'catalog_empty' => '可接受的学期目录为空。',
    'catalog_limit' => '学期目录数量超过安全上限。',
    'catalog_id' => '学期目录包含无效标识。',
    'catalog_duplicate' => '学期目录标识重复。',
    'catalog_name' => '学期目录包含无效名称。',
    'selection_missing' => '学期当前选择信息缺失。',
    'selection_invalid' => '学期当前选择信息无效。',
    'selection_unknown' => '当前学期未出现在可接受目录中。',
    _ => '课表诊断原因无法识别，已安全拒绝。',
  };
}
