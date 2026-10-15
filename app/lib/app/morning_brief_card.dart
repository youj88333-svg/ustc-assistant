import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/morning_brief_contract.dart';
import '../core/morning_notice_contract.dart';
import '../core/public_query_contract.dart';
import 'assistant_markdown.dart';

final class MorningBriefCard extends StatelessWidget {
  const MorningBriefCard({
    super.key,
    required this.view,
    required this.nowUtc,
    required this.onRetry,
    required this.onHideToday,
    required this.openSource,
    this.changes,
  });

  final MorningRuntimeView view;
  final DateTime nowUtc;
  final VoidCallback onRetry, onHideToday;
  final Future<void> Function(Uri) openSource;
  final Stream<MorningRuntimeView>? changes;

  @override
  Widget build(BuildContext context) {
    if (!view.enabled) return const SizedBox.shrink();

    final today = _beijingDay(nowUtc);
    final brief = view.brief != null && _sameDay(view.brief!.day, today)
        ? view.brief
        : null;
    final candidateBatch = brief?.notices;
    final noticeBatch =
        candidateBatch != null &&
            _sameDay(candidateBatch.day, _yesterday(today))
        ? candidateBatch
        : null;
    final phase = view.phase;
    final canRetry =
        phase == MorningBriefPhase.failed ||
        phase == MorningBriefPhase.interrupted ||
        view.failure != null ||
        (noticeBatch != null && !noticeBatch.complete);

    return Card(
      key: const ValueKey('morning-brief-card'),
      margin: EdgeInsets.zero,
      child: SizedBox(
        height: 48,
        child: Padding(
          padding: const EdgeInsets.only(left: 12, right: 4),
          child: Row(
            children: [
              const Icon(Icons.wb_twilight_outlined, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '晨报 · ${_dateOnly(today)}',
                  key: const ValueKey('morning-brief-date'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  _compactStatus(view, phase, noticeBatch),
                  key: const ValueKey('morning-brief-phase'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              IconButton(
                key: const ValueKey('morning-brief-open'),
                tooltip: '查看晨报',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 36,
                  height: 36,
                ),
                padding: EdgeInsets.zero,
                onPressed: () => _showDetails(context),
                icon: const Icon(Icons.open_in_full_rounded, size: 19),
              ),
              if (canRetry)
                IconButton(
                  key: const ValueKey('morning-brief-retry'),
                  tooltip: '重试晨报',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(
                    width: 36,
                    height: 36,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: view.busy ? null : onRetry,
                  icon: const Icon(Icons.refresh_rounded, size: 19),
                ),
              IconButton(
                key: const ValueKey('morning-brief-hide'),
                tooltip: '隐藏今天的晨报',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 36,
                  height: 36,
                ),
                padding: EdgeInsets.zero,
                onPressed: onHideToday,
                icon: const Icon(Icons.close_rounded, size: 19),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showDetails(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (_) => StreamBuilder<MorningRuntimeView>(
        stream: changes,
        initialData: view,
        builder: (context, snapshot) => _MorningBriefDetailsDialog(
          view: snapshot.data ?? view,
          nowUtc: nowUtc,
          onRetry: onRetry,
          openSource: (sourceContext, uri) => _openSource(sourceContext, uri),
        ),
      ),
    );
  }

  Future<void> _openSource(BuildContext context, Uri uri) async {
    try {
      await openSource(uri);
    } on Object {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法打开通知来源，请稍后重试。')));
      }
    }
  }
}

final class _MorningBriefDetailsDialog extends StatelessWidget {
  const _MorningBriefDetailsDialog({
    required this.view,
    required this.nowUtc,
    required this.onRetry,
    required this.openSource,
  });

  final MorningRuntimeView view;
  final DateTime nowUtc;
  final VoidCallback onRetry;
  final Future<void> Function(BuildContext, Uri) openSource;

  @override
  Widget build(BuildContext context) {
    final today = _beijingDay(nowUtc);
    final facts = view.facts != null && _sameDay(view.facts!.day, today)
        ? view.facts
        : null;
    final brief = view.brief != null && _sameDay(view.brief!.day, today)
        ? view.brief
        : null;
    final candidateBatch = brief?.notices;
    final noticeBatch =
        candidateBatch != null &&
            _sameDay(candidateBatch.day, _yesterday(today))
        ? candidateBatch
        : null;
    final phase = view.phase;
    final summary = _summaryForToday(brief, view.text, today, noticeBatch);
    final attention = _attentionFor(view, facts, noticeBatch, phase);
    final canRetry =
        phase == MorningBriefPhase.failed ||
        phase == MorningBriefPhase.interrupted ||
        view.failure != null ||
        (noticeBatch != null && !noticeBatch.complete);
    final phaseLabel = view.failure != null
        ? '失败，可重试'
        : phase == MorningBriefPhase.ready &&
              noticeBatch != null &&
              !noticeBatch.complete
        ? '部分完成'
        : _phaseLabel(phase);

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      backgroundColor: Theme.of(context).colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 560,
          maxHeight: MediaQuery.sizeOf(context).height * .88,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(
                context,
                today,
                phase,
                phaseLabel,
                noticeBatch != null && !noticeBatch.complete,
              ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (attention.isNotEmpty) ...[
                        _attentionPanel(context, attention),
                        const SizedBox(height: 16),
                      ],
                      Text(
                        '今日重点',
                        key: const ValueKey('morning-brief-summary-heading'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      if (summary.today.isEmpty)
                        const Text(
                          '摘要暂不可用，以下为当前可用的本地事实。',
                          key: ValueKey('morning-brief-summary-fallback'),
                        )
                      else
                        AssistantMarkdown(
                          key: const ValueKey('morning-brief-full-summary'),
                          data: summary.today,
                        ),
                      if (summary.notices.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        Text(
                          '昨日公告摘要',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 4),
                        AssistantMarkdown(
                          key: const ValueKey('morning-brief-notice-summary'),
                          data: summary.notices,
                        ),
                      ] else if (_isConfirmedEmpty(noticeBatch) &&
                          (summary.structured || summary.today.isEmpty)) ...[
                        const SizedBox(height: 12),
                        const Text(
                          '昨天没有符合条件的公开通知。',
                          key: ValueKey('morning-brief-notice-empty'),
                        ),
                      ] else if (noticeBatch != null &&
                          noticeBatch.notices.isNotEmpty &&
                          summary.notices.isEmpty) ...[
                        const SizedBox(height: 12),
                        Text('昨天已取得 ${noticeBatch.notices.length} 条公开通知。'),
                      ],
                      const SizedBox(height: 16),
                      if (facts != null) _todayDetails(context, facts),
                      _sourceCoverage(context, noticeBatch, phase),
                    ],
                  ),
                ),
              ),
              if (canRetry) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton.icon(
                    key: const ValueKey('morning-brief-details-retry'),
                    onPressed: view.busy ? null : onRetry,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('重试晨报'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(
    BuildContext context,
    DateTime today,
    MorningBriefPhase phase,
    String phaseLabel,
    bool isPartial,
  ) {
    final colors = Theme.of(context).colorScheme;
    final isError = phase == MorningBriefPhase.failed || view.failure != null;
    final foreground = isError
        ? colors.error
        : isPartial
        ? Colors.brown.shade800
        : colors.onSurfaceVariant;
    final icon = isError
        ? Icons.error_outline_rounded
        : isPartial
        ? Icons.warning_amber_rounded
        : phase == MorningBriefPhase.ready
        ? Icons.check_circle_outline_rounded
        : Icons.schedule_rounded;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('晨报', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 2),
              Text(
                _dateOnly(today),
                key: const ValueKey('morning-brief-details-date'),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 17, color: foreground),
              const SizedBox(width: 5),
              Text(
                phaseLabel,
                key: const ValueKey('morning-brief-details-phase'),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: foreground),
              ),
            ],
          ),
        ),
        IconButton(
          key: const ValueKey('morning-brief-details-close'),
          tooltip: '关闭晨报',
          visualDensity: VisualDensity.compact,
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    );
  }

  List<_Attention> _attentionFor(
    MorningRuntimeView currentView,
    MorningFacts? facts,
    MorningNoticeBatch? batch,
    MorningBriefPhase phase,
  ) {
    final items = <_Attention>[];
    if (facts == null) {
      items.add(
        const _Attention('本地日程尚未同步到今天，当前安排未知。', Icons.info_outline_rounded),
      );
    } else {
      if (!facts.complete) {
        items.add(
          const _Attention('本地日程覆盖不完整，今天的安排可能不全。', Icons.warning_amber_rounded),
        );
      }
      if (facts.conflicts > 0) {
        items.add(
          _Attention(
            '今天有 ${facts.conflicts} 处时间冲突。',
            Icons.event_busy_outlined,
          ),
        );
      }
      if (facts.tasks.isNotEmpty) {
        items.add(
          _Attention(
            '今天有 ${facts.tasks.length} 项任务截止。',
            Icons.schedule_rounded,
          ),
        );
      }
      if (facts.overdueTasks > 0) {
        items.add(
          _Attention(
            '还有 ${facts.overdueTasks} 项逾期任务。',
            Icons.error_outline_rounded,
            level: _AttentionLevel.error,
          ),
        );
      }
    }

    if (currentView.failure != null) {
      items.add(
        const _Attention(
          '晨报生成失败，可重试。',
          Icons.error_outline_rounded,
          level: _AttentionLevel.error,
        ),
      );
    } else if (batch == null &&
        (phase == MorningBriefPhase.failed ||
            phase == MorningBriefPhase.interrupted ||
            phase == MorningBriefPhase.cleared ||
            phase == MorningBriefPhase.ready)) {
      items.add(
        _Attention(
          _noticeStatus(null, phase),
          phase == MorningBriefPhase.failed
              ? Icons.error_outline_rounded
              : Icons.warning_amber_rounded,
          level: phase == MorningBriefPhase.failed
              ? _AttentionLevel.error
              : _AttentionLevel.warning,
        ),
      );
    }

    if (batch != null) {
      final unknownDates = _unknownDateCount(batch);
      if (!batch.complete || unknownDates > 0) {
        final hasHardFailure = batch.coverage.any(
          (coverage) =>
              coverage.failure != null &&
              coverage.failure != PublicFailureCode.resourceLimit,
        );
        final message = !batch.complete && unknownDates > 0
            ? '昨天的通知覆盖不完整，另有 $unknownDates 条日期未知。'
            : !batch.complete
            ? '昨天的公开通知覆盖不完整，当前结果可能不全。'
            : '$unknownDates 条通知日期未知，无法确认是否属于昨天。';
        items.add(
          _Attention(
            message,
            hasHardFailure
                ? Icons.error_outline_rounded
                : Icons.warning_amber_rounded,
            level: hasHardFailure
                ? _AttentionLevel.error
                : _AttentionLevel.warning,
          ),
        );
      }
    }
    return items;
  }

  Widget _attentionPanel(BuildContext context, List<_Attention> items) =>
      Column(
        key: const ValueKey('morning-brief-attention'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('需留意', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          for (final item in items) ...[
            _attentionItem(context, item),
            if (item != items.last) const SizedBox(height: 6),
          ],
        ],
      );

  Widget _attentionItem(BuildContext context, _Attention item) {
    final isError = item.level == _AttentionLevel.error;
    final foreground = isError ? Colors.red.shade900 : Colors.brown.shade900;
    final background = isError ? Colors.red.shade50 : Colors.amber.shade100;
    return Container(
      key: ValueKey('morning-brief-attention-${item.message}'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(item.icon, size: 19, color: foreground),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              item.message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: foreground,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _todayDetails(BuildContext context, MorningFacts facts) =>
      ExpansionTile(
        key: const ValueKey('morning-brief-agenda-expand'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        title: const Text('今日明细'),
        subtitle: const Text('安排与截止任务'),
        children: [
          if (facts.agenda.isEmpty && facts.tasks.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('今天没有已读取到的安排或截止任务。'),
              ),
            ),
          for (final item in facts.agenda) _agendaLine(context, item),
          if (facts.tasks.isNotEmpty) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '今日截止任务',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            for (final task in facts.tasks) _taskLine(context, task),
          ],
        ],
      );

  Widget _agendaLine(BuildContext context, MorningAgendaItem item) {
    final colors = Theme.of(context).colorScheme;
    final stateLabel = _agendaStateLabel(item.state);
    return Padding(
      key: ValueKey('morning-brief-agenda-${item.title}'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                item.allDay
                    ? '全天'
                    : '${_timeLabel(item)}–${_beijingTime(item.end)}',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              if (stateLabel.isNotEmpty)
                Container(
                  key: ValueKey('morning-brief-agenda-state-${item.title}'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    stateLabel,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            item.title,
            key: ValueKey('morning-brief-agenda-title-${item.title}'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          if (item.location.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              '地点 · ${item.location}',
              key: ValueKey('morning-brief-agenda-location-${item.title}'),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }

  Widget _taskLine(BuildContext context, MorningTaskItem task) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      key: ValueKey('morning-brief-task-${task.title}'),
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${_beijingTime(task.deadline)} 截止',
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 2),
          Text(task.title, style: Theme.of(context).textTheme.titleSmall),
        ],
      ),
    );
  }

  Widget _sourceCoverage(
    BuildContext context,
    MorningNoticeBatch? batch,
    MorningBriefPhase phase,
  ) => ExpansionTile(
    key: const ValueKey('morning-brief-source-expand'),
    tilePadding: EdgeInsets.zero,
    childrenPadding: const EdgeInsets.only(bottom: 8),
    title: const Text('来源与覆盖'),
    subtitle: const Text('通知条目与读取状态'),
    children: [_noticeDetails(context, batch, phase, onOpenSource: openSource)],
  );
}

enum _AttentionLevel { warning, error }

final class _Attention {
  const _Attention(
    this.message,
    this.icon, {
    this.level = _AttentionLevel.warning,
  });
  final String message;
  final IconData icon;
  final _AttentionLevel level;
}

final class _SummaryPresentation {
  const _SummaryPresentation({
    required this.today,
    required this.notices,
    required this.structured,
  });
  final String today, notices;
  final bool structured;
}

Widget _noticeDetails(
  BuildContext context,
  MorningNoticeBatch? batch,
  MorningBriefPhase phase, {
  required Future<void> Function(BuildContext context, Uri uri) onOpenSource,
}) {
  if (batch == null) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        _noticeStatus(null, phase),
        key: const ValueKey('morning-brief-notice-status'),
      ),
    );
  }

  final children = <Widget>[
    if (!_isConfirmedEmpty(batch))
      Align(
        alignment: Alignment.centerLeft,
        child: Text(
          _noticeStatus(batch, phase),
          key: const ValueKey('morning-brief-notice-status'),
        ),
      ),
    const SizedBox(height: 8),
    for (final coverage in batch.coverage)
      Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _providerLabel(coverage.provider),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 2),
            Text(
              '${coverage.pages} 页 · ${coverage.matched} 条符合日期 · '
              '${coverage.unknownDates} 条日期未知 · '
              '${coverage.complete ? '范围已读完' : '覆盖不完整'}'
              '${coverage.failure == null ? '' : ' · ${_publicFailureLabel(coverage.failure!)}'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    if (batch.operations > 0)
      Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '本次读取操作 ${batch.operations} 次',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
  ];

  if (batch.notices.isNotEmpty) {
    children.add(const Divider(height: 20));
    for (var index = 0; index < batch.notices.length; index++) {
      final notice = batch.notices[index];
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(notice.title, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 3),
              Text(
                '${_providerLabel(notice.provider)} · 发布 ${_dateOnly(notice.publishedDay)} · '
                '本地读取 ${_beijingClock(notice.observedAtUtc)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (notice.excerpt.isNotEmpty) ...[
                const SizedBox(height: 5),
                Text(notice.excerpt),
              ],
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: ValueKey(
                    'morning-notice-source-$index-${notice.provider.name}',
                  ),
                  onPressed: () =>
                      unawaited(onOpenSource(context, notice.articleUrl)),
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: const Text('打开通知来源'),
                ),
              ),
            ],
          ),
        ),
      );
    }
  }

  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: children,
  );
}

String _compactStatus(
  MorningRuntimeView view,
  MorningBriefPhase phase,
  MorningNoticeBatch? noticeBatch,
) {
  if (view.failure != null || phase == MorningBriefPhase.failed) {
    return '失败，可重试';
  }
  if (phase == MorningBriefPhase.interrupted) return '已暂停，可重试';
  if (noticeBatch != null && !noticeBatch.complete) {
    return '部分完成 · 可重试';
  }
  return _phaseLabel(phase);
}

_SummaryPresentation _summaryForToday(
  MorningBrief? brief,
  String runtimeText,
  DateTime today,
  MorningNoticeBatch? noticeBatch,
) {
  if (brief == null || !_sameDay(brief.day, today)) {
    return const _SummaryPresentation(
      today: '',
      notices: '',
      structured: false,
    );
  }
  final raw = runtimeText.trim().isNotEmpty
      ? runtimeText.trim()
      : brief.summary.trim();
  final visible = morningSummaryForDisplay(raw, noticeBatch);
  if (visible.isEmpty) {
    return const _SummaryPresentation(
      today: '',
      notices: '',
      structured: false,
    );
  }

  try {
    final encoded = jsonDecode(raw);
    if (encoded is Map<String, dynamic> &&
        const {
          'morning-summary-v2',
          'morning-facts-v1',
        }.contains(encoded['kind'])) {
      final parsed = MorningSummary.fromModel(
        jsonEncode({'today': encoded['today'], 'notices': encoded['notices']}),
      );
      return _SummaryPresentation(
        today: parsed.today,
        notices:
            noticeBatch?.complete == true && noticeBatch!.notices.isNotEmpty
            ? parsed.notices
            : '',
        structured: true,
      );
    }
  } on Object {
    // The existing display gate above decides whether legacy prose is usable.
  }
  return _SummaryPresentation(today: visible, notices: '', structured: false);
}

bool _isConfirmedEmpty(MorningNoticeBatch? batch) =>
    batch != null &&
    batch.complete &&
    batch.notices.isEmpty &&
    _unknownDateCount(batch) == 0;

int _unknownDateCount(MorningNoticeBatch batch) =>
    batch.coverage.fold<int>(0, (sum, coverage) => sum + coverage.unknownDates);

String _noticeStatus(MorningNoticeBatch? batch, MorningBriefPhase phase) {
  if (batch == null) {
    return switch (phase) {
      MorningBriefPhase.notices => '正在更新昨天的公开通知。',
      MorningBriefPhase.failed => '公开通知或晨报生成失败；已取得的本地事实仍可查看。',
      MorningBriefPhase.interrupted => '公开通知更新已暂停，尚未完成。',
      MorningBriefPhase.cleared => '晨报已清除，昨天的公开通知尚未重新读取。',
      _ => '昨天的公开通知尚未同步。',
    };
  }

  final failedSources = batch.coverage
      .where(
        (item) =>
            item.failure != null &&
            item.failure != PublicFailureCode.resourceLimit,
      )
      .length;
  final limitedSources = batch.coverage
      .where((item) => item.failure == PublicFailureCode.resourceLimit)
      .length;
  final unknown = _unknownDateCount(batch);
  final fullyCovered = batch.complete;
  final pieces = <String>[];
  if (batch.notices.isEmpty) {
    if (fullyCovered && unknown == 0) {
      pieces.add('昨天没有符合条件的公开通知');
    } else if (failedSources == batch.coverage.length && failedSources > 0) {
      pieces.add('公开通知来源读取失败');
    } else {
      pieces.add('没有匹配条目，读取覆盖不完整');
    }
  } else {
    pieces.add('已取得 ${batch.notices.length} 条昨天发布的通知');
  }
  if (failedSources > 0 && !pieces.any((piece) => piece.contains('来源读取失败'))) {
    pieces.add(
      failedSources == batch.coverage.length ? '公开通知来源读取失败' : '部分来源读取失败',
    );
  }
  if (limitedSources > 0) pieces.add('昨日读取范围达到上限');
  if (!fullyCovered) pieces.add('覆盖不完整');
  if (unknown > 0) pieces.add('$unknown 条公告日期未知，未计入昨天条数');
  return '${pieces.join('；')}。';
}

String _phaseLabel(MorningBriefPhase phase) => switch (phase) {
  MorningBriefPhase.idle => '待开始',
  MorningBriefPhase.facts => '整理本地事实',
  MorningBriefPhase.notices => '更新公开通知',
  MorningBriefPhase.waiting => '等待模型空闲',
  MorningBriefPhase.generating => '生成摘要',
  MorningBriefPhase.ready => '已完成',
  MorningBriefPhase.interrupted => '已暂停',
  MorningBriefPhase.failed => '失败，可重试',
  MorningBriefPhase.cleared => '已清除',
};

String _agendaStateLabel(String state) => switch (state) {
  'skip' => '计划不参加',
  'skipped' => '已跳过',
  'completed' || 'done' => '已完成',
  'planned' => '待进行',
  '' => '',
  _ => '状态待确认',
};

String _providerLabel(PublicProvider provider) => switch (provider) {
  PublicProvider.teach => '教务通知',
  PublicProvider.finance => '财务公告',
  PublicProvider.icourse => '评课来源',
};

String _publicFailureLabel(PublicFailureCode code) => switch (code) {
  PublicFailureCode.invalidRequest => '查询参数无效',
  PublicFailureCode.busy => '来源正在忙',
  PublicFailureCode.consentRequired => '需要联网授权',
  PublicFailureCode.cancelled => '查询已取消',
  PublicFailureCode.staleReference => '来源结果已过期',
  PublicFailureCode.unavailable => '来源暂不可用',
  PublicFailureCode.accessRestricted => '来源访问受限',
  PublicFailureCode.campusOnly => '需在校园网访问',
  PublicFailureCode.networkFailed => '网络读取失败',
  PublicFailureCode.sourceSchema => '来源格式发生变化',
  PublicFailureCode.unsafeTarget => '来源地址未通过检查',
  PublicFailureCode.resourceLimit => '读取范围达到上限',
  PublicFailureCode.storageFailed => '本地保存失败',
  PublicFailureCode.cleanupPending => '仍有清理待办',
  PublicFailureCode.closed => '来源服务已关闭',
};

DateTime _beijingDay(DateTime nowUtc) {
  final beijing = nowUtc.toUtc().add(const Duration(hours: 8));
  return DateTime.utc(beijing.year, beijing.month, beijing.day);
}

DateTime _yesterday(DateTime today) =>
    DateTime.utc(today.year, today.month, today.day - 1);

bool _sameDay(DateTime left, DateTime right) =>
    left.year == right.year &&
    left.month == right.month &&
    left.day == right.day;

String _dateOnly(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

String _timeLabel(MorningAgendaItem item) {
  if (item.allDay) return '全天';
  final beijing = item.start.toUtc().add(const Duration(hours: 8));
  return '${beijing.hour.toString().padLeft(2, '0')}:'
      '${beijing.minute.toString().padLeft(2, '0')}';
}

String _beijingTime(DateTime value) {
  final beijing = value.toUtc().add(const Duration(hours: 8));
  return '${beijing.hour.toString().padLeft(2, '0')}:'
      '${beijing.minute.toString().padLeft(2, '0')}';
}

String _beijingClock(DateTime value) {
  final beijing = value.toUtc().add(const Duration(hours: 8));
  return '${_dateOnly(DateTime.utc(beijing.year, beijing.month, beijing.day))} '
      '${beijing.hour.toString().padLeft(2, '0')}:'
      '${beijing.minute.toString().padLeft(2, '0')}';
}
