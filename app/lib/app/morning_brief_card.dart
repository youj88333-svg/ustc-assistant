import 'dart:async';

import 'package:flutter/material.dart';

import '../core/morning_brief_contract.dart';
import '../core/morning_notice_contract.dart';
import '../core/public_query_contract.dart';

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
    final summary = _summaryForToday(brief, view.text, today);
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
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 560,
          maxHeight: MediaQuery.sizeOf(context).height * .88,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '晨报 · ${_dateOnly(today)}',
                      key: const ValueKey('morning-brief-details-date'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('morning-brief-details-close'),
                    tooltip: '关闭晨报',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  phaseLabel,
                  key: const ValueKey('morning-brief-details-phase'),
                ),
              ),
              const Divider(height: 20),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (facts == null)
                        const Text(
                          '本地日程尚未同步到今天，当前不展示旧日期的晨报。',
                          key: ValueKey('morning-brief-local-not-synced'),
                        )
                      else ...[
                        Text(
                          '今日安排 ${facts.agenda.length} 项 · 今日截止 ${facts.tasks.length} 项',
                          key: const ValueKey('morning-brief-facts-summary'),
                        ),
                        if (facts.conflicts > 0)
                          Text('冲突 ${facts.conflicts} 项'),
                        if (facts.overdueTasks > 0)
                          Text('过期任务 ${facts.overdueTasks} 项'),
                        Text(
                          facts.complete
                              ? '本地日程覆盖完整。'
                              : '本地日程覆盖不完整；未同步来源不代表今天没有安排。',
                        ),
                        if (!facts.hasSchoolImports)
                          const Text('尚无已导入的学校日程事实。'),
                        const SizedBox(height: 10),
                        Text(
                          '今日安排',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        if (facts.agenda.isEmpty)
                          const Text('今天没有已读取到的安排。')
                        else
                          for (final item in facts.agenda)
                            Padding(
                              padding: const EdgeInsets.only(top: 7),
                              child: Text(
                                '${item.allDay ? '全天' : '${_timeLabel(item)}–${_beijingTime(item.end)}'} · ${item.title}'
                                '${item.location.isEmpty ? '' : ' · ${item.location}'}'
                                ' · ${item.state}',
                                key: ValueKey(
                                  'morning-brief-agenda-${item.title}',
                                ),
                              ),
                            ),
                        if (facts.tasks.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Text(
                            '今日截止任务',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          for (final task in facts.tasks)
                            Padding(
                              padding: const EdgeInsets.only(top: 7),
                              child: Text(
                                '${task.title} · ${_beijingClock(task.deadline)}',
                                key: ValueKey(
                                  'morning-brief-task-${task.title}',
                                ),
                              ),
                            ),
                        ],
                      ],
                      const SizedBox(height: 14),
                      Text(
                        '晨报摘要',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        summary.isEmpty ? '摘要暂不可用，以上为当前可用的本地事实。' : summary,
                        key: const ValueKey('morning-brief-full-summary'),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        '昨天的公开通知',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _noticeStatus(noticeBatch, phase),
                        key: const ValueKey('morning-brief-notice-status'),
                      ),
                      if (noticeBatch != null) ...[
                        const SizedBox(height: 8),
                        _noticeDetails(
                          context,
                          noticeBatch,
                          onOpenSource: openSource,
                        ),
                      ],
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
}

Widget _noticeDetails(
  BuildContext context,
  MorningNoticeBatch batch, {
  required Future<void> Function(BuildContext context, Uri uri) onOpenSource,
}) {
  final children = <Widget>[
    for (final coverage in batch.coverage)
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          '${_providerLabel(coverage.provider)}：${coverage.matched} 条符合日期；'
          '${coverage.unknownDates} 条日期未知；'
          '${coverage.complete ? '昨日范围已读完' : '覆盖不完整'}'
          '${coverage.failure == null ? '' : '；${_publicFailureLabel(coverage.failure!)}'}',
        ),
      ),
  ];
  if (batch.notices.isEmpty) {
    children.add(const Text('没有可展示的昨日日告条目。'));
  }
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

String _summaryForToday(
  MorningBrief? brief,
  String runtimeText,
  DateTime today,
) {
  if (brief == null || !_sameDay(brief.day, today)) return '';
  final raw = runtimeText.trim().isNotEmpty
      ? runtimeText.trim()
      : brief.summary.trim();
  return morningSummaryForDisplay(raw, brief.notices);
}

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
  final unknown = batch.coverage.fold<int>(
    0,
    (sum, item) => sum + item.unknownDates,
  );
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
