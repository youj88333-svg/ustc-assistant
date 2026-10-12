import 'dart:async';

import 'package:flutter/material.dart';

import '../core/contracts.dart';
import '../data/import_contract.dart';
import '../jobs/coordinator_contract.dart';
import '../source/source_contract.dart';
import 'demo_controller.dart';

class M0App extends StatefulWidget {
  const M0App({super.key, required this.controller, this.observationPanel});

  final DemoController controller;
  final Widget? observationPanel;

  @override
  State<M0App> createState() => _M0AppState();
}

class _M0AppState extends State<M0App> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.initialize());
  }

  @override
  void didUpdateWidget(covariant M0App oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      unawaited(widget.controller.initialize());
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'USTC Assistant',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF087F78),
        brightness: Brightness.light,
      ),
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xFFF3F7F6),
    ),
    home: _DemoHome(
      controller: widget.controller,
      observationPanel: widget.observationPanel,
    ),
  );
}

class M0StartupFailureApp extends StatelessWidget {
  const M0StartupFailureApp({super.key, required this.code});

  final FailureCode code;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'USTC Assistant',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF087F78)),
      useMaterial3: true,
    ),
    home: Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.error_outline, size: 36),
                      const SizedBox(height: 16),
                      Text(
                        'USTC Assistant',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      const Text('应用无法启动。'),
                      const SizedBox(height: 12),
                      Text(_startupFailureMessage(code)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _DemoHome extends StatefulWidget {
  const _DemoHome({required this.controller, this.observationPanel});

  final DemoController controller;
  final Widget? observationPanel;

  @override
  State<_DemoHome> createState() => _DemoHomeState();
}

class _DemoHomeState extends State<_DemoHome> {
  DemoScenario _scenario = DemoScenario.normal;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('USTC Assistant'),
      backgroundColor: Theme.of(context).colorScheme.surface,
    ),
    body: SafeArea(
      child: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final controller = widget.controller;
          final view = controller.view;
          final data = controller.dataView;
          final busy = view.isBusy || controller.loading;
          final canCancel =
              (view.phase == JobPhase.collecting ||
                  view.phase == JobPhase.settling) &&
              !view.cancelRequested;
          final canRetryRecovery =
              view.phase == JobPhase.recovery && !controller.loading;
          final canRetryFollowUps =
              view.phase == JobPhase.idle &&
              (data?.pendingFollowUps ?? 0) > 0 &&
              !controller.loading;
          final canReplay =
              view.phase == JobPhase.idle &&
              (data?.importCount ?? 0) > 0 &&
              !controller.loading;
          final showFormalHome = widget.observationPanel != null;
          final showDemoAttention =
              showFormalHome && (busy || view.phase == JobPhase.recovery);

          return LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: EdgeInsets.symmetric(
                horizontal: constraints.maxWidth < 560 ? 14 : 24,
                vertical: 18,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1040),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      showFormalHome ? _formalIntro(context) : _intro(context),
                      if (showFormalHome) ...[
                        const SizedBox(height: 14),
                        widget.observationPanel!,
                      ],
                      if (showDemoAttention) ...[
                        const SizedBox(height: 14),
                        _demoAttention(
                          context,
                          controller: controller,
                          busy: busy,
                          canCancel: canCancel,
                          canRetryRecovery: canRetryRecovery,
                        ),
                      ],
                      const SizedBox(height: 14),
                      if (showFormalHome)
                        _offlineDemo(
                          context,
                          busy: busy,
                          canCancel: canCancel,
                          canReplay: canReplay,
                          canRetryRecovery: canRetryRecovery,
                          canRetryFollowUps: canRetryFollowUps,
                          controller: controller,
                          data: data,
                        )
                      else ...[
                        _operations(
                          context,
                          busy: busy,
                          canCancel: canCancel,
                          canReplay: canReplay,
                          canRetryRecovery: canRetryRecovery,
                          canRetryFollowUps: canRetryFollowUps,
                          controller: controller,
                        ),
                        const SizedBox(height: 14),
                        _status(context, controller),
                        const SizedBox(height: 14),
                        _summary(context, data),
                        const SizedBox(height: 14),
                        _schedule(context, data),
                      ],
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    ),
  );

  Widget _intro(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 10,
            runSpacing: 8,
            children: [
              Text(
                'USTC Assistant',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const _Tag(label: 'M0 合成演示'),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '本地合成的周日程，用于演示采集、收口、提交与恢复状态。',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 8),
          Text(
            '教务、二课日程、二课报名、评课、校园信息和 Agent 尚未接入；演示不联网、不使用学校账号。',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _formalIntro(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '教务与本地日程',
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          Text(
            '教务登录与采集会自动进行，课程和考试会导入本地日程。遇到验证码、通行密钥或学校额外授权时，需要你在学校页面完成操作。',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ],
      ),
    ),
  );

  Widget _offlineDemo(
    BuildContext context, {
    required bool busy,
    required bool canCancel,
    required bool canReplay,
    required bool canRetryRecovery,
    required bool canRetryFollowUps,
    required DemoController controller,
    required DemoDataView? data,
  }) => Card(
    clipBehavior: Clip.antiAlias,
    child: ExpansionTile(
      key: const ValueKey('offline-m0-demo'),
      initiallyExpanded: false,
      maintainState: true,
      leading: const Icon(Icons.science_outlined),
      title: const Text('离线 M0 合成演示'),
      subtitle: const Text('使用独立演示数据，不访问学校或修改教务日程。'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _operations(
                context,
                busy: busy,
                canCancel: canCancel,
                canReplay: canReplay,
                canRetryRecovery: canRetryRecovery,
                canRetryFollowUps: canRetryFollowUps,
                controller: controller,
                heading: '离线演示操作',
              ),
              const SizedBox(height: 12),
              _status(context, controller),
              const SizedBox(height: 12),
              _summary(context, data, heading: '离线演示计数'),
              const SizedBox(height: 12),
              _schedule(context, data, heading: '离线合成周日程'),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _demoAttention(
    BuildContext context, {
    required DemoController controller,
    required bool busy,
    required bool canCancel,
    required bool canRetryRecovery,
  }) {
    final view = controller.view;
    final colorScheme = Theme.of(context).colorScheme;
    final isRecovery = view.phase == JobPhase.recovery;
    final pendingCount = controller.dataView?.pendingFollowUps;
    final hasPendingFollowUps = pendingCount == null
        ? view.outcome?.followUpPending ?? false
        : pendingCount > 0;
    final message = _statusMessage(
      view,
      controller.cancellationDisposition,
      hasPendingFollowUps: hasPendingFollowUps,
    );

    return Semantics(
      liveRegion: true,
      child: Card(
        key: const ValueKey('offline-m0-attention'),
        color: isRecovery
            ? colorScheme.errorContainer
            : colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    isRecovery ? Icons.error_outline : Icons.sync,
                    color: isRecovery
                        ? colorScheme.onErrorContainer
                        : colorScheme.onPrimaryContainer,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isRecovery
                              ? '离线演示需要恢复'
                              : view.phase == JobPhase.idle
                              ? '离线演示正在准备'
                              : '离线演示正在运行',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          view.phase == JobPhase.idle && busy
                              ? '正在准备演示状态。'
                              : message,
                        ),
                        if (controller.error case final error?) ...[
                          const SizedBox(height: 4),
                          Text(_failureMessage(error)),
                        ],
                        if (view.cancelRequested) ...[
                          const SizedBox(height: 4),
                          const Text('取消请求已受理，正在等待安全收口。'),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              if (controller.loading) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
              ],
              if (canCancel || canRetryRecovery) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    if (canCancel)
                      OutlinedButton.icon(
                        onPressed: controller.cancel,
                        icon: const Icon(Icons.stop_circle_outlined),
                        label: const Text('取消演示采集'),
                      ),
                    if (canRetryRecovery)
                      FilledButton.tonalIcon(
                        onPressed: controller.retryRecovery,
                        icon: const Icon(Icons.refresh),
                        label: const Text('重试演示收口'),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _operations(
    BuildContext context, {
    required bool busy,
    required bool canCancel,
    required bool canReplay,
    required bool canRetryRecovery,
    required bool canRetryFollowUps,
    required DemoController controller,
    String heading = '演示操作',
  }) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(heading, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final selector = DropdownButtonFormField<DemoScenario>(
                initialValue: _scenario,
                decoration: const InputDecoration(
                  labelText: '合成场景',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final scenario in _selectableScenarios)
                    DropdownMenuItem(
                      value: scenario,
                      child: Text(_scenarioLabel(scenario)),
                    ),
                ],
                onChanged: busy
                    ? null
                    : (scenario) {
                        if (scenario != null) {
                          setState(() => _scenario = scenario);
                        }
                      },
              );
              final startButton = FilledButton.icon(
                onPressed: busy || controller.view.phase != JobPhase.idle
                    ? null
                    : () => controller.run(_scenario),
                icon: const Icon(Icons.play_arrow),
                label: const Text('开始合成采集'),
              );
              if (constraints.maxWidth < 600) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [selector, const SizedBox(height: 10), startButton],
                );
              }
              return Row(
                children: [
                  Expanded(child: selector),
                  const SizedBox(width: 12),
                  startButton,
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: canReplay
                    ? () => controller.run(DemoScenario.replay)
                    : null,
                icon: const Icon(Icons.replay),
                label: const Text('重复上一导入'),
              ),
              OutlinedButton.icon(
                onPressed: canCancel ? controller.cancel : null,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('取消当前作业'),
              ),
              OutlinedButton.icon(
                onPressed: canRetryRecovery ? controller.retryRecovery : null,
                icon: const Icon(Icons.refresh),
                label: const Text('重试收口'),
              ),
              OutlinedButton.icon(
                onPressed: canRetryFollowUps ? controller.retryFollowUps : null,
                icon: const Icon(Icons.checklist),
                label: const Text('重试待办'),
              ),
            ],
          ),
          if (controller.loading) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
        ],
      ),
    ),
  );

  Widget _status(BuildContext context, DemoController controller) {
    final view = controller.view;
    final outcome = view.outcome;
    final pendingCount = controller.dataView?.pendingFollowUps;
    final hasPendingFollowUps = pendingCount == null
        ? outcome?.followUpPending ?? false
        : pendingCount > 0;
    final message = _statusMessage(
      view,
      controller.cancellationDisposition,
      hasPendingFollowUps: hasPendingFollowUps,
    );
    final error = controller.error;
    final committedPending =
        outcome?.kind == OutcomeKind.committed && hasPendingFollowUps;
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('当前状态', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  _statusIcon(view),
                  color: view.phase == JobPhase.recovery
                      ? colorScheme.error
                      : colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        message,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      if (view.phase == JobPhase.collecting ||
                          view.phase == JobPhase.settling) ...[
                        const SizedBox(height: 4),
                        Text(
                          view.phase == JobPhase.collecting
                              ? '正在读取合成日程。'
                              : '正在关闭采集会话并完成提交裁决。',
                        ),
                      ],
                      if (view.cancelRequested) ...[
                        const SizedBox(height: 4),
                        const Text('取消请求已受理，正在等待安全收口。'),
                      ],
                      if (outcome?.kind == OutcomeKind.committed) ...[
                        const SizedBox(height: 4),
                        Text('本次记录 ${outcome!.recordCount} 条。'),
                      ],
                      if (committedPending) ...[
                        const SizedBox(height: 4),
                        const Text('导入已提交；仍有后续待办等待处理。'),
                      ],
                      if (outcome?.kind == OutcomeKind.committed &&
                          outcome!.replayed) ...[
                        const SizedBox(height: 4),
                        const Text('本次为重复上一导入，沿用已提交结果。'),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (error != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  committedPending
                      ? '导入已提交，待办处理状态：${_failureMessage(error)}'
                      : _failureMessage(error),
                  style: TextStyle(color: colorScheme.onErrorContainer),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _summary(
    BuildContext context,
    DemoDataView? data, {
    String heading = '本地安全计数',
  }) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(heading, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _CountTile(label: '已提交导入', count: data?.importCount),
              _CountTile(label: '审计记录', count: data?.auditCount),
              _CountTile(label: '待办', count: data?.pendingFollowUps),
              _CountTile(label: '日程记录', count: data?.events.length),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _schedule(
    BuildContext context,
    DemoDataView? data, {
    String heading = '合成周日程',
  }) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  heading,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              const _Tag(label: '北京时间'),
            ],
          ),
          const SizedBox(height: 12),
          if (data == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('正在读取本地演示记录…'),
            )
          else if (data.events.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('目前没有已导入的合成日程。'),
            )
          else
            for (final event in data.events) ...[
              _EventRow(event: event),
              if (event != data.events.last) const Divider(height: 20),
            ],
        ],
      ),
    ),
  );
}

const _selectableScenarios = <DemoScenario>[
  DemoScenario.normal,
  DemoScenario.empty,
  DemoScenario.incomplete,
  DemoScenario.sourceFailure,
  DemoScenario.storageFailure,
  DemoScenario.followUpFailure,
  DemoScenario.cleanupFailure,
];

String _scenarioLabel(DemoScenario scenario) => switch (scenario) {
  DemoScenario.normal => '正常采集',
  DemoScenario.replay => '重复上一导入',
  DemoScenario.empty => '空日程',
  DemoScenario.incomplete => '不完整快照',
  DemoScenario.sourceFailure => '采集失败',
  DemoScenario.storageFailure => '存储失败',
  DemoScenario.followUpFailure => '待办失败',
  DemoScenario.cleanupFailure => '收口失败',
};

String _statusMessage(
  CoordinatorView view,
  CancellationDisposition? cancellation, {
  required bool hasPendingFollowUps,
}) {
  if (view.phase == JobPhase.collecting) return '正在采集';
  if (view.phase == JobPhase.settling) return '正在收口与提交裁决';
  if (view.phase == JobPhase.recovery) {
    if (view.outcome?.failure == FailureCode.cleanupPending) {
      return '收口失败 · 本次尚未提交';
    }
    return '收口未完成，等待重试';
  }
  if (view.phase == JobPhase.closed) return '演示已关闭';

  final outcome = view.outcome;
  if (outcome != null) {
    switch (outcome.kind) {
      case OutcomeKind.committed:
        if (hasPendingFollowUps) return '已提交 · 后续待办未完成';
        if (outcome.replayed) return '已提交 · 重放上一导入';
        return '已提交';
      case OutcomeKind.cancelled:
        return '已取消 · 本次未提交';
      case OutcomeKind.failed:
        if (outcome.failure == FailureCode.cleanupPending) {
          return '收口失败 · 本次尚未提交';
        }
        if (outcome.failure == FailureCode.followUpPending) {
          return '后续待办未完成 · 请核对提交状态';
        }
        return '作业失败 · 本次未提交';
    }
  }
  if (cancellation == CancellationDisposition.alreadyCommitted) {
    return '作业已提交，取消没有撤销提交';
  }
  if (hasPendingFollowUps) return '已有提交 · 后续待办未完成';
  return '等待开始演示';
}

IconData _statusIcon(CoordinatorView view) {
  if (view.phase == JobPhase.collecting) return Icons.download_outlined;
  if (view.phase == JobPhase.settling) return Icons.sync;
  if (view.phase == JobPhase.recovery) return Icons.warning_amber_rounded;
  if (view.outcome?.kind == OutcomeKind.committed) return Icons.check_circle;
  if (view.outcome?.kind == OutcomeKind.cancelled ||
      view.outcome?.kind == OutcomeKind.failed) {
    return Icons.info_outline;
  }
  return Icons.hourglass_empty;
}

String _startupFailureMessage(FailureCode code) => switch (code) {
  FailureCode.ownerConflict => '应用数据目录正被另一个应用实例使用。',
  FailureCode.unsafeDirectory => '应用数据目录检查未通过。',
  FailureCode.ownershipLost => '应用数据目录所有权已失效。',
  FailureCode.storageFailed => '本地应用数据操作失败。',
  _ => _failureMessage(code),
};

String _failureMessage(FailureCode code) => switch (code) {
  FailureCode.busy => '已有作业正在处理。',
  FailureCode.cancelled => '作业已取消。',
  FailureCode.staleResult => '收到过期结果，未写入。',
  FailureCode.incompleteSnapshot => '来源快照不完整，未提交。',
  FailureCode.invalidSnapshot => '演示数据校验失败，未提交。',
  FailureCode.idempotencyConflict => '重复导入内容冲突，未提交。',
  FailureCode.sourceFailed => '合成采集失败，未提交。',
  FailureCode.storageFailed => '本地演示数据操作失败。',
  FailureCode.cleanupPending => '收口失败，等待重试；本次尚未提交。',
  FailureCode.followUpPending => '待办处理未完成；已提交状态仍保留。',
  FailureCode.ownerConflict => '演示目录正被另一个演示实例使用。',
  FailureCode.unsafeDirectory => '演示目录检查未通过。',
  FailureCode.ownershipLost => '演示目录所有权已失效。',
  FailureCode.unsupportedPlatform => '当前平台暂不支持此演示。',
  FailureCode.closed => '演示组件已关闭。',
};

class _Tag extends StatelessWidget {
  const _Tag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        child: Text(
          label,
          style: TextStyle(
            color: colors.onSecondaryContainer,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _CountTile extends StatelessWidget {
  const _CountTile({required this.label, required this.count});

  final String label;
  final int? count;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 126),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 3),
        Text(
          count?.toString() ?? '—',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event});

  final StoredEvent event;

  @override
  Widget build(BuildContext context) {
    final time =
        '${formatBeijing(event.startsAtUtc)} – '
        '${formatBeijing(event.endsAtUtc)}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.event_note_outlined,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    Text(
                      event.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (event.sourceMissing) const _Tag(label: '来源缺失，记录保留'),
                  ],
                ),
                const SizedBox(height: 4),
                Text(time, style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
