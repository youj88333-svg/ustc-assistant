import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/contracts.dart';
import '../data/jw_candidate_identity.dart';
import '../jobs/jw_data_probe_port.dart';
import '../jobs/jw_probe_port.dart';
import '../source/jw_data_probe_contract.dart';
import '../source/jw_probe_contract.dart';

/// Lets the user inspect the fixed read-only data contract for an accepted semester.
class JwDataProbePanel extends StatefulWidget {
  const JwDataProbePanel({
    super.key,
    required this.probeController,
    required this.controller,
  });

  final JwProbePort probeController;
  final JwDataProbePort controller;

  @override
  State<JwDataProbePanel> createState() => _JwDataProbePanelState();
}

class _JwDataProbePanelState extends State<JwDataProbePanel> {
  final TextEditingController _accountCodeController = TextEditingController();
  StreamSubscription<JwProbeView>? _probeSubscription;
  StreamSubscription<JwDataProbeView>? _dataSubscription;
  late JwProbeView _probeView;
  late JwDataProbeView _view;
  int? _semesterId;
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
    _connect(widget.probeController, widget.controller);
  }

  @override
  void didUpdateWidget(covariant JwDataProbePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.probeController == widget.probeController &&
        oldWidget.controller == widget.controller) {
      return;
    }

    _controllerEpoch++;
    _runToken++;
    _cancelToken++;
    final oldProbeSubscription = _probeSubscription;
    final oldDataSubscription = _dataSubscription;
    _probeSubscription = null;
    _dataSubscription = null;
    if (oldProbeSubscription != null) {
      unawaited(oldProbeSubscription.cancel());
    }
    if (oldDataSubscription != null) unawaited(oldDataSubscription.cancel());
    _accountCodeController.clear();
    _semesterId = null;
    _runPending = false;
    _cancelPending = false;
    _copyPending = false;
    _inputMessage = null;
    _actionMessage = null;
    _connect(widget.probeController, widget.controller);
  }

  void _connect(JwProbePort probeController, JwDataProbePort controller) {
    _probeView = probeController.probeView;
    _view = controller.dataProbeView;
    _setDefaultSemester(_acceptedSemesters(_probeView));
    final epoch = _controllerEpoch;
    _probeSubscription = probeController.probeChanges.listen(
      (next) {
        if (!mounted || epoch != _controllerEpoch) return;
        setState(() {
          _probeView = next;
          _setDefaultSemester(_acceptedSemesters(next));
          if (!_probeView.available || _probeView.busy) {
            _accountCodeController.clear();
          }
        });
      },
      onError: (Object _, StackTrace _) {
        if (!mounted || epoch != _controllerEpoch) return;
        setState(() => _actionMessage = '读取目录验证结果失败，请重新检查目录。');
      },
    );
    _dataSubscription = controller.dataProbeChanges.listen(
      (next) {
        if (!mounted || epoch != _controllerEpoch) return;
        setState(() {
          _view = next;
          if (!_view.available || _view.busy) _accountCodeController.clear();
        });
      },
      onError: (Object _, StackTrace _) {
        if (!mounted || epoch != _controllerEpoch) return;
        setState(() => _actionMessage = '读取数据接口检查进度失败，请检查观测窗口。');
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
    final probeSubscription = _probeSubscription;
    final dataSubscription = _dataSubscription;
    if (probeSubscription != null) unawaited(probeSubscription.cancel());
    if (dataSubscription != null) unawaited(dataSubscription.cancel());
    super.dispose();
  }

  List<JwSemesterOption> get _semesters => _acceptedSemesters(_probeView);

  bool get _anyControllerBusy =>
      _probeView.busy ||
      _probeView.phase == JwProbePhase.running ||
      _view.busy ||
      _view.phase == JwProbePhase.running ||
      _runPending ||
      _cancelPending;

  bool get _canRun =>
      _probeView.available &&
      _view.available &&
      !_anyControllerBusy &&
      !_copyPending &&
      _semesterId != null &&
      _semesters.any((semester) => semester.id == _semesterId);

  bool get _canCancel =>
      (_view.busy || _view.phase == JwProbePhase.running || _runPending) &&
      !_cancelPending;

  bool get _canCopy =>
      !_copyPending &&
      !_anyControllerBusy &&
      _view.phase != JwProbePhase.idle &&
      _view.phase != JwProbePhase.running;

  bool get _canChangeSemester => !_anyControllerBusy;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final semesters = _semesters;
    final selectedId = semesters.any((item) => item.id == _semesterId)
        ? _semesterId
        : null;
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
                      'M1 只读数据接口验证',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '请先运行上方目录验证。然后选择已验证的学期并填写本次预期学号，检查固定的课表、考试只读接口。',
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '此入口只检查固定数据结构；当前来源不可用，不会导入数据。学期名称仅用于本地选择。',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 14),
                    if (semesters.isEmpty)
                      const InputDecorator(
                        decoration: InputDecoration(
                          labelText: '已验证学期',
                          border: OutlineInputBorder(),
                        ),
                        child: Text('请先完成目录验证并取得可用学期。'),
                      )
                    else
                      DropdownButtonFormField<int>(
                        key: const ValueKey('jw-data-probe-semester'),
                        initialValue: selectedId,
                        decoration: const InputDecoration(
                          labelText: '选择已验证学期',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          for (final semester in semesters)
                            DropdownMenuItem<int>(
                              value: semester.id,
                              child: Text(
                                semester.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: _canChangeSemester
                            ? (id) {
                                setState(() {
                                  _semesterId = id;
                                  _inputMessage = null;
                                });
                              }
                            : null,
                      ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey('jw-data-probe-expected-account'),
                      controller: _accountCodeController,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      enableIMEPersonalizedLearning: false,
                      autofillHints: const [],
                      enabled:
                          _probeView.available &&
                          _view.available &&
                          !_anyControllerBusy,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                      decoration: const InputDecoration(
                        labelText: '本次预期学号',
                        hintText: '输入5至24位大写英文字母或数字',
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
                          label: const Text('验证数据接口'),
                        ),
                        if (_canCancel)
                          OutlinedButton.icon(
                            onPressed: _cancelDataProbe,
                            icon: const Icon(Icons.stop_circle_outlined),
                            label: const Text('取消并清理观测窗口'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _status(context),
                    if (_view.diagnostics case final diagnostics?) ...[
                      const SizedBox(height: 12),
                      _diagnostics(context, diagnostics),
                    ],
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _canCopy ? _copySafeSummary : null,
                      icon: const Icon(Icons.copy_outlined),
                      label: const Text('复制数据脱敏摘要'),
                    ),
                    if (_anyControllerBusy) ...[
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
    final color = _view.phase == JwProbePhase.failed
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
            _statusMessage(),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 5),
          Text('身份比较：${_identityMessage(_view.identity)}'),
          if (_view.stage case final stage? when _stageNames.containsKey(stage))
            Text('当前检查：${_stageNames[stage]}'),
          if (_codeMessage(_view.code) case final message?)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(message),
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

  Widget _diagnostics(BuildContext context, JwDataDiagnostics diagnostics) {
    final projection = diagnostics.safeProjection;
    final checks = projection['checks']! as Map<String, String>;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('固定检查', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        for (final entry in _stageNames.entries)
          _checkRow(context, entry.key, entry.value, checks[entry.key]!),
        const SizedBox(height: 10),
        Text('结构计数', style: Theme.of(context).textTheme.titleSmall),
        Text('身份读取：${projection['identityReads']}'),
        Text('课程 ID：${projection['lessonIds']}'),
        Text('课程：${projection['lessons']}'),
        Text('课表组：${projection['groups']}'),
        Text('课表：${projection['schedules']}'),
        Text('含日期课表：${projection['datedSchedules']}'),
        Text('含时间课表：${projection['timedSchedules']}'),
        Text('关联课表：${projection['linkedSchedules']}'),
        Text('考试行：${projection['examRows']}'),
        Text('含日期考试：${projection['datedExams']}'),
        const SizedBox(height: 8),
        Text('目录学期已接受：${_yesNo(diagnostics.semesterAccepted)}'),
        Text('本人路线已绑定：${_yesNo(diagnostics.selfRouteBound)}'),
        Text('前后身份稳定：${_yesNo(diagnostics.identityStable)}'),
        Text('课表为空：${_yesNo(diagnostics.emptyCourse)}'),
        Text('考试为空：${_yesNo(diagnostics.emptyExams)}'),
        Text('发现分页：${_yesNo(diagnostics.pagination)}'),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            '结构原因：${_reasonMessage(projection['reason']! as String)}',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: diagnostics.reason == 'none'
                  ? Theme.of(context).colorScheme.onSurfaceVariant
                  : Theme.of(context).colorScheme.error,
            ),
          ),
        ),
        if (diagnostics.pagination)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '发现分页；当前摘要不表示已读取全部考试分页。',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }

  Widget _checkRow(
    BuildContext context,
    String key,
    String label,
    String state,
  ) {
    final text = switch (state) {
      'ok' => '通过',
      'skipped' => '跳过',
      'error' => '未通过',
      _ =>
        _view.phase == JwProbePhase.running && _view.stage == key
            ? '进行中'
            : '未检查',
    };
    final color = switch (state) {
      'ok' => Theme.of(context).colorScheme.primary,
      'error' => Theme.of(context).colorScheme.error,
      _ => Theme.of(context).colorScheme.onSurfaceVariant,
    };
    final icon = switch (state) {
      'ok' => Icons.check_circle_outline,
      'error' => Icons.error_outline,
      'skipped' => Icons.remove_circle_outline,
      _ => Icons.radio_button_unchecked,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text('$label：$text')),
        ],
      ),
    );
  }

  String _statusMessage() {
    if (_cancelPending) return '正在取消并清理观测窗口，等待临时会话排空。';
    if (_anyControllerBusy) return '只读数据接口检查正在进行。';
    return switch (_view.phase) {
      JwProbePhase.idle => '尚未运行数据接口检查。',
      JwProbePhase.running => '只读数据接口检查正在进行。',
      JwProbePhase.done => '固定数据结构检查完成；来源仍不可用。',
      JwProbePhase.failed => '只读数据接口检查未通过。',
      JwProbePhase.cancelled => '检查已取消，临时会话已请求排空。',
    };
  }

  void _submit() {
    if (!_canRun) return;
    final expectedAccountCode = _accountCodeController.text.trim();
    final semesterId = _semesterId;
    _accountCodeController.clear();
    if (!RegExp(r'^[A-Z0-9]{5,24}$').hasMatch(expectedAccountCode)) {
      setState(() {
        _inputMessage = '请输入5至24位大写英文字母或数字。';
        _actionMessage = null;
      });
      return;
    }
    if (semesterId == null ||
        !_semesters.any((item) => item.id == semesterId)) {
      setState(() {
        _inputMessage = '请从已验证目录中选择一个学期。';
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
      final request = controller.runDataProbe(
        expectedAccountCode,
        semesterId: semesterId,
      );
      unawaited(_finishRun(request, controller, epoch, token));
    } catch (_) {
      _showRunFailure(controller, epoch, token);
    }
  }

  Future<void> _finishRun(
    Future<void> request,
    JwDataProbePort controller,
    int epoch,
    int token,
  ) async {
    try {
      await request;
    } catch (_) {
      _showRunFailure(controller, epoch, token);
    } finally {
      if (_isCurrent(controller, epoch) && token == _runToken) {
        setState(() => _runPending = false);
      }
    }
  }

  void _showRunFailure(JwDataProbePort controller, int epoch, int token) {
    if (!_isCurrent(controller, epoch) ||
        token != _runToken ||
        controller.dataProbeView.phase == JwProbePhase.failed) {
      return;
    }
    setState(() {
      _runPending = false;
      _actionMessage = '数据接口检查请求失败，请检查观测页面后重试。';
    });
  }

  void _cancelDataProbe() {
    if (!_canCancel) return;
    final controller = widget.controller;
    final epoch = _controllerEpoch;
    final token = ++_cancelToken;
    _runToken++;
    setState(() {
      _runPending = false;
      _cancelPending = true;
      _inputMessage = null;
      _actionMessage = null;
    });
    try {
      final request = controller.cancelDataProbe();
      unawaited(_finishCancel(request, controller, epoch, token));
    } catch (_) {
      _showCancelFailure(controller, epoch, token);
    }
  }

  Future<void> _finishCancel(
    Future<void> request,
    JwDataProbePort controller,
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

  void _showCancelFailure(JwDataProbePort controller, int epoch, int token) {
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
        setState(() => _actionMessage = '已复制数据脱敏摘要');
      }
    } catch (_) {
      if (_isCurrent(controller, epoch)) {
        setState(() => _actionMessage = '数据脱敏摘要复制失败，请重试。');
      }
    } finally {
      if (_isCurrent(controller, epoch)) {
        setState(() => _copyPending = false);
      }
    }
  }

  bool _isCurrent(JwDataProbePort controller, int epoch) =>
      mounted && epoch == _controllerEpoch && widget.controller == controller;

  void _setDefaultSemester(List<JwSemesterOption> semesters) {
    if (_semesterId != null &&
        semesters.any((item) => item.id == _semesterId)) {
      return;
    }
    final selected = semesters.where((item) => item.selected).toList();
    _semesterId = selected.length == 1 ? selected.single.id : null;
  }

  static List<JwSemesterOption> _acceptedSemesters(JwProbeView view) {
    final summary = view.summary;
    if (view.phase != JwProbePhase.done ||
        view.code != JwProbeCode.ok ||
        summary == null ||
        summary.stageResults['course'] != JwProbeCode.ok ||
        summary.courseDiagnostics.reason != 'none' ||
        !{
          'serverSelect',
          'serverJson',
        }.contains(summary.courseDiagnostics.source) ||
        summary.semesterOptions != view.semesters.length) {
      return const [];
    }
    return view.semesters;
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

  static String _identityMessage(JwCandidateIdentity identity) =>
      switch (identity) {
        JwCandidateIdentity.unavailable => '未取得候选',
        JwCandidateIdentity.candidateMatches => '候选匹配',
        JwCandidateIdentity.candidateMismatch => '候选不符',
        JwCandidateIdentity.candidateConflict => '候选冲突',
      };

  static const Map<String, String> _stageNames = {
    'identityBefore': '身份复验（前）',
    'course': '课表页面',
    'index': '课表目录接口',
    'datum': '课程详情接口',
    'exams': '考试页面',
    'identityAfter': '身份复验（后）',
  };

  static String _yesNo(bool value) => value ? '是' : '否';

  static String _reasonMessage(String reason) => switch (reason) {
    'none' => '无',
    'semester_unknown' => '所选学期不在已接受目录中。',
    'identity_missing' => '未取得唯一身份候选。',
    'identity_changed' => '前后身份候选发生变化。',
    'index_shape' => '课表目录结构不符合固定格式。',
    'index_ids' => '课表目录包含无效或重复标识。',
    'index_limit' => '课表目录超过安全数量上限。',
    'json_invalid' => '响应不是有效 JSON。',
    'json_duplicate' => '响应 JSON 含重复字段。',
    'json_depth' => '响应 JSON 嵌套超过安全深度。',
    'datum_shape' => '课程详情结构不符合固定格式。',
    'datum_limit' => '课程详情超过安全数量上限。',
    'lesson_id' => '课程标识无效。',
    'lesson_set' => '课程详情与目录不一致。',
    'lesson_title' => '课程名称字段不符合固定格式。',
    'group_id' => '课表组标识无效。',
    'group_lesson' => '课表组关联到未知课程。',
    'schedule_link' => '课表项与课程或课表组关联不完整。',
    'schedule_date' => '课表日期字段无效。',
    'schedule_time' => '课表时间字段无效。',
    'exam_structure' => '考试表格结构不符合固定格式。',
    'exam_pagination' => '考试结果存在未完成的分页。',
    'exam_date' => '考试日期字段无效。',
    'exam_time' => '考试时间字段无效。',
    'field_conflict' => '字段类型或关联存在冲突。',
    _ => '结构原因无法识别，已安全拒绝。',
  };

  static String? _codeMessage(JwDataProbeCode code) => switch (code) {
    JwDataProbeCode.pending || JwDataProbeCode.ok => null,
    JwDataProbeCode.cancelled => '本次检查已取消。',
    JwDataProbeCode.studentContextMissing => '请先从已登录的教务页面启动目录验证。',
    JwDataProbeCode.identityHttp ||
    JwDataProbeCode.courseHttp ||
    JwDataProbeCode.indexHttp ||
    JwDataProbeCode.datumHttp ||
    JwDataProbeCode.examsHttp => '来源响应状态不符合固定契约，结果已拒绝。',
    JwDataProbeCode.identityMime ||
    JwDataProbeCode.courseMime ||
    JwDataProbeCode.indexMime ||
    JwDataProbeCode.datumMime ||
    JwDataProbeCode.examsMime => '来源响应类型不符合固定契约，结果已拒绝。',
    JwDataProbeCode.identityTooLarge ||
    JwDataProbeCode.courseTooLarge ||
    JwDataProbeCode.indexTooLarge ||
    JwDataProbeCode.datumTooLarge ||
    JwDataProbeCode.examsTooLarge => '来源响应超过安全读取上限，结果已拒绝。',
    JwDataProbeCode.identitySchema ||
    JwDataProbeCode.courseSchema ||
    JwDataProbeCode.indexSchema ||
    JwDataProbeCode.datumSchema ||
    JwDataProbeCode.examsSchema => '来源结构不符合固定契约，结果已拒绝。',
    JwDataProbeCode.networkFailed => '网络读取失败，请检查观测页面后重试。',
    JwDataProbeCode.timedOut => '只读验证超时，请重新打开业务页后重试。',
    JwDataProbeCode.helperUnavailable => '验证组件暂不可用，请检查观测窗口。',
    JwDataProbeCode.staleResult => '页面上下文已变化，请重新运行目录验证。',
    JwDataProbeCode.serviceWorkerControlled => '页面后台处理器参与响应，本次结果已拒绝。',
    JwDataProbeCode.semesterUnknown => '所选学期不在已验证的目录中。',
    JwDataProbeCode.identityChanged => '前后身份候选不一致，本次结果已拒绝。',
  };

  static String? _failureMessage(FailureCode? failure) => switch (failure) {
    null => null,
    FailureCode.busy => '已有检查正在处理，请稍后重试。',
    FailureCode.cancelled => '检查已取消，临时会话正在排空。',
    FailureCode.staleResult => '页面上下文已变化，请重新运行目录验证。',
    FailureCode.incompleteSnapshot => '检查结果不完整，未接受该结果。',
    FailureCode.invalidSnapshot => '检查结果不符合固定结构，已拒绝。',
    FailureCode.idempotencyConflict => '检查操作状态冲突，请重新打开观测窗口。',
    FailureCode.sourceFailed => '来源读取失败，请检查观测窗口后重试。',
    FailureCode.storageFailed => '本地状态处理失败，请重试。',
    FailureCode.cleanupPending => '临时会话尚未排空，请先完成窗口清理。',
    FailureCode.followUpPending => '仍有检查收尾操作待完成，请稍后重试。',
    FailureCode.ownerConflict => '检查会话被其他操作占用。',
    FailureCode.unsafeDirectory => '本地安全状态不可用，请检查应用后重试。',
    FailureCode.ownershipLost => '检查会话状态已失效，请重新打开观测窗口。',
    FailureCode.unsupportedPlatform => '当前设备暂不支持这项检查。',
    FailureCode.closed => '观测窗口已关闭，请重新打开后重试。',
  };
}
