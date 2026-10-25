import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'agent_behavior_validation.dart';
import '../core/agent_contract.dart';

const _validationMuted = Color(0xFF66736C);

/// A caller-owned behavior runner rendered as a temporary review panel.
/// This widget may stop work when it exits, but never closes the runner.
final class AgentBehaviorValidationPanel extends StatefulWidget {
  const AgentBehaviorValidationPanel({super.key, required this.runner});

  final AgentBehaviorValidationRunner runner;

  @override
  State<AgentBehaviorValidationPanel> createState() =>
      _AgentBehaviorValidationPanelState();
}

final class _AgentBehaviorValidationPanelState
    extends State<AgentBehaviorValidationPanel> {
  late AgentBehaviorValidationView _view;
  StreamSubscription<AgentBehaviorValidationView>? _subscription;
  Future<void>? _stopFuture;
  bool _stopping = false;
  bool _copying = false;
  bool _allowPop = false;
  String? _copyStatus;
  String? _stopError;

  @override
  void initState() {
    super.initState();
    _bindRunner(widget.runner);
  }

  @override
  void didUpdateWidget(covariant AgentBehaviorValidationPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.runner, widget.runner)) {
      unawaited(_subscription?.cancel());
      unawaited(oldWidget.runner.stop());
      _bindRunner(widget.runner);
      _stopFuture = null;
      _stopping = false;
      _allowPop = false;
    }
  }

  void _bindRunner(AgentBehaviorValidationRunner runner) {
    _view = runner.view;
    _subscription = runner.changes.listen((next) {
      if (mounted) setState(() => _view = next);
    });
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    unawaited(widget.runner.stop());
    super.dispose();
  }

  Future<void> _stopAndDrain() {
    final current = _stopFuture;
    if (current != null) return current;
    if (mounted) {
      setState(() {
        _stopping = true;
        _stopError = null;
      });
    }
    final stop = widget.runner.stop();
    late final Future<void> tracked;
    tracked = stop.whenComplete(() {
      if (identical(_stopFuture, tracked)) _stopFuture = null;
      if (mounted) setState(() => _stopping = false);
    });
    _stopFuture = tracked;
    return tracked;
  }

  Future<void> _exitPanel() async {
    if (_allowPop) return;
    try {
      await _stopAndDrain();
    } on Object {
      if (mounted) {
        setState(() => _stopError = '停止或排空未完成，请重试后再退出。');
      }
      return;
    }
    if (!mounted) return;
    setState(() => _allowPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _stopFromButton() async {
    try {
      await _stopAndDrain();
    } on Object {
      if (mounted) {
        setState(() => _stopError = '停止或排空未完成，请重试。');
      }
    }
  }

  void _start() {
    if (_view.busy || _stopping) return;
    setState(() => _copyStatus = null);
    unawaited(widget.runner.start());
  }

  Future<void> _copySummary() async {
    if (_copying) return;
    setState(() {
      _copying = true;
      _copyStatus = null;
    });
    try {
      await Clipboard.setData(ClipboardData(text: widget.runner.safeSummary()));
      if (mounted) setState(() => _copyStatus = '已复制安全摘要。');
    } on Object {
      if (mounted) setState(() => _copyStatus = '复制失败，请稍后重试。');
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final usage = _view.inputTokens == null || _view.outputTokens == null
        ? '用量未知'
        : '累计输入 ${_view.inputTokens} · 输出 ${_view.outputTokens} tokens';
    return PopScope<void>(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_exitPanel());
      },
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          child: SizedBox(
            width: 640,
            height: size.height * 0.82,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 10, 8, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '合成模型核验',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('agent-validation-exit'),
                        tooltip: '退出核验',
                        onPressed: _stopping
                            ? null
                            : () => unawaited(_exitPanel()),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      const _ValidationNotice(),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            key: const ValueKey('agent-validation-start'),
                            onPressed: _view.busy || _stopping ? null : _start,
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: const Text('开始核验'),
                          ),
                          OutlinedButton.icon(
                            key: const ValueKey('agent-validation-stop'),
                            onPressed: !_view.busy || _stopping
                                ? null
                                : () => unawaited(_stopFromButton()),
                            icon: _stopping
                                ? const SizedBox.square(
                                    dimension: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.stop_circle_outlined),
                            label: const Text('停止并排空'),
                          ),
                          OutlinedButton.icon(
                            key: const ValueKey('agent-validation-copy'),
                            onPressed: _copying
                                ? null
                                : () => unawaited(_copySummary()),
                            icon: const Icon(Icons.copy_outlined),
                            label: Text(_copying ? '正在复制' : '复制安全摘要'),
                          ),
                        ],
                      ),
                      if (_stopError != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          _stopError!,
                          key: const ValueKey('agent-validation-stop-error'),
                          style: const TextStyle(color: Color(0xFF9B2C2C)),
                        ),
                      ],
                      if (_copyStatus != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          _copyStatus!,
                          key: const ValueKey('agent-validation-copy-status'),
                          style: const TextStyle(color: _validationMuted),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _view.busy
                                    ? '正在核验${_view.current == null ? '' : '：${_view.current!.label}'}'
                                    : _view.results.isEmpty
                                    ? '尚未开始'
                                    : '核验已停止或完成',
                                key: const ValueKey('agent-validation-status'),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '场景 ${_view.results.length}/${AgentBehaviorValidationRunner.caseCount} · 请求 ${_view.requests}/${AgentBehaviorValidationRunner.requestLimit}',
                              ),
                              const SizedBox(height: 4),
                              Text(
                                usage,
                                key: const ValueKey('agent-validation-usage'),
                              ),
                              if (_view.busy) ...[
                                const SizedBox(height: 8),
                                LinearProgressIndicator(
                                  value:
                                      _view.results.length /
                                      AgentBehaviorValidationRunner.caseCount,
                                ),
                              ],
                              if (_view.failure != null) ...[
                                const SizedBox(height: 8),
                                Text(
                                  _failureLabel(_view.failure!),
                                  key: const ValueKey(
                                    'agent-validation-failure',
                                  ),
                                  style: const TextStyle(
                                    color: Color(0xFF9B2C2C),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      if (_view.results.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 18),
                          child: Text(
                            '没有结果。选择“开始核验”后才会运行合成场景。',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: _validationMuted),
                          ),
                        )
                      else ...[
                        const Padding(
                          padding: EdgeInsets.fromLTRB(2, 8, 2, 6),
                          child: Text(
                            '逐项检查业务结果与约束结果，并人工判断合成回复。自动检查不代表回复质量通过。',
                            style: TextStyle(
                              color: _validationMuted,
                              height: 1.4,
                            ),
                          ),
                        ),
                        for (final result in _view.results)
                          _ValidationResultCard(result: result),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _ValidationNotice extends StatelessWidget {
  const _ValidationNotice();

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
    ),
    child: const Text(
      '共 14 个场景，最多 96 次模型请求。只操作内存中的合成课程、日程和任务，不读取学校或正式业务数据。开始后使用当前已同意的模型，会产生真实模型用量。请人工判断回复质量。',
      style: TextStyle(height: 1.4),
    ),
  );
}

final class _ValidationResultCard extends StatelessWidget {
  const _ValidationResultCard({required this.result});

  final AgentBehaviorCaseResult result;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            result.scenario.label,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              _ResultBadge(
                label: '业务结果：${result.businessPassed ? '通过' : '未通过'}',
                passed: result.businessPassed,
              ),
              _ResultBadge(
                label: '约束结果：${result.constraintPassed ? '通过' : '未通过'}',
                passed: result.constraintPassed,
              ),
              Text('请求 ${result.requests}'),
            ],
          ),
          if (result.failure != null) ...[
            const SizedBox(height: 4),
            Text(
              '场景未完成：${_failureLabel(result.failure!)}',
              style: const TextStyle(color: Color(0xFF9B2C2C)),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            '合成回复（供人工判断）：${_replyExcerpt(result.reply)}',
            key: ValueKey('agent-validation-reply-${result.scenario.name}'),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(height: 1.4),
          ),
          const SizedBox(height: 4),
          const Text(
            '回复质量需人工判断。',
            style: TextStyle(color: _validationMuted, fontSize: 12),
          ),
        ],
      ),
    ),
  );
}

final class _ResultBadge extends StatelessWidget {
  const _ResultBadge({required this.label, required this.passed});

  final String label;
  final bool passed;

  @override
  Widget build(BuildContext context) => Chip(
    visualDensity: VisualDensity.compact,
    avatar: Icon(
      passed ? Icons.check_circle_outline : Icons.error_outline,
      size: 16,
      color: passed ? const Color(0xFF1F6B45) : const Color(0xFF9B2C2C),
    ),
    label: Text(label),
  );
}

String _replyExcerpt(String value) {
  final reply = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (reply.isEmpty) return '暂无可审查回复。';
  if (reply.length <= 240) return reply;
  return '${reply.substring(0, 240)}…';
}

String _failureLabel(AgentFailureCode failure) => switch (failure) {
  AgentFailureCode.keyRequired => '模型配置或密钥不可用。',
  AgentFailureCode.consentRequired => '尚未同意模型调用。',
  AgentFailureCode.modelRequired => '当前模型能力未就绪。',
  AgentFailureCode.contextLimit => '当前模型服务的上下文容量不足。',
  AgentFailureCode.reasoningRejected => '模型服务拒绝了本次 high 思考参数。',
  AgentFailureCode.cancelled => '核验已停止。',
  AgentFailureCode.timeout => '核验超时。',
  _ => '核验未能完成。',
};
