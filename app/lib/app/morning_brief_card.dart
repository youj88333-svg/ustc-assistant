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
    required this.onDiscuss,
    required this.openSource,
  });

  final MorningRuntimeView view;
  final DateTime nowUtc;
  final VoidCallback onRetry, onDiscuss;
  final Future<void> Function(Uri) openSource;

  @override
  Widget build(BuildContext context) {
    if (!view.enabled) return const SizedBox.shrink();

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
    final next = facts == null ? null : _nextPlannedItem(facts, nowUtc);

    return Card(
      key: const ValueKey('morning-brief-card'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.wb_twilight_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '晨报 · ${_dateOnly(today)}',
                    key: const ValueKey('morning-brief-date'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(_phaseLabel(phase)),
              ],
            ),
            const SizedBox(height: 8),
            if (facts == null)
              const Text(
                '本地日程尚未同步到今天，当前不展示旧日期的晨报。',
                key: ValueKey('morning-brief-local-not-synced'),
              )
            else ...[
              Wrap(
                spacing: 14,
                runSpacing: 4,
                children: [
                  Text('今日安排 ${facts.agenda.length} 项'),
                  if (facts.tasks.isNotEmpty)
                    Text('今日截止 ${facts.tasks.length} 项'),
                  if (facts.conflicts > 0) Text('冲突 ${facts.conflicts} 项'),
                  if (facts.overdueTasks > 0)
                    Text('过期任务 ${facts.overdueTasks} 项'),
                ],
              ),
              if (!facts.complete) ...[
                const SizedBox(height: 4),
                const Text('本地日程覆盖不完整；未同步来源不代表今天没有安排。'),
              ],
              if (!facts.hasSchoolImports) ...[
                const SizedBox(height: 4),
                const Text('尚无已导入的学校日程事实。'),
              ],
              const SizedBox(height: 4),
              Text(
                next == null
                    ? '下一个未开始安排：暂无'
                    : '下一个未开始：${next.title} · ${_timeLabel(next)}',
                key: const ValueKey('morning-brief-next-item'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (facts.tasks.isNotEmpty) ...[
                const SizedBox(height: 4),
                for (final task in facts.tasks.take(2))
                  Text(
                    '截止：${task.title} · ${_beijingClock(task.deadline)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (facts.tasks.length > 2)
                  Text('另有 ${facts.tasks.length - 2} 项今日截止任务。'),
              ],
            ],
            const SizedBox(height: 8),
            Text(
              _noticeStatus(noticeBatch, phase),
              key: const ValueKey('morning-brief-notice-status'),
            ),
            if (summary.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                summary,
                key: const ValueKey('morning-brief-summary'),
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (noticeBatch != null) ...[
              const SizedBox(height: 4),
              ExpansionTile(
                key: const ValueKey('morning-brief-details'),
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 4),
                title: const Text('更多内容：通知出处与正文'),
                initiallyExpanded: false,
                children: [
                  _noticeDetails(
                    context,
                    noticeBatch,
                    onOpenSource: _openSource,
                  ),
                ],
              ),
            ],
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                if (phase == MorningBriefPhase.failed ||
                    phase == MorningBriefPhase.interrupted ||
                    view.failure != null)
                  OutlinedButton.icon(
                    key: const ValueKey('morning-brief-retry'),
                    onPressed: view.busy ? null : onRetry,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('重试晨报'),
                  ),
                TextButton.icon(
                  key: const ValueKey('morning-brief-discuss'),
                  onPressed: onDiscuss,
                  icon: const Icon(Icons.chat_bubble_outline_rounded),
                  label: const Text('和 Agent 讨论'),
                ),
              ],
            ),
          ],
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
          '${coverage.complete ? '遍历完整' : '覆盖不完整'}'
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

MorningAgendaItem? _nextPlannedItem(MorningFacts facts, DateTime nowUtc) {
  final now = nowUtc.toUtc();
  final planned =
      facts.agenda
          .where(
            (item) =>
                item.state == 'planned' && item.start.toUtc().isAfter(now),
          )
          .toList()
        ..sort((a, b) => a.start.compareTo(b.start));
  return planned.isEmpty ? null : planned.first;
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
  if (raw.runes.length <= 500) return raw;
  return '${String.fromCharCodes(raw.runes.take(500))}…';
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

  final failures = batch.coverage.where((item) => item.failure != null).length;
  final unknown = batch.coverage.fold<int>(
    0,
    (sum, item) => sum + item.unknownDates,
  );
  final fullyCovered =
      batch.coverage.isNotEmpty &&
      batch.coverage.every((item) => item.complete && item.failure == null);
  final pieces = <String>[];
  if (batch.notices.isEmpty) {
    if (fullyCovered && unknown == 0) {
      pieces.add('昨天没有符合条件的公开通知');
    } else if (failures == batch.coverage.length && failures > 0) {
      pieces.add('公开通知来源读取失败');
    } else {
      pieces.add('没有匹配条目，读取覆盖不完整');
    }
  } else {
    pieces.add('已取得 ${batch.notices.length} 条昨天发布的通知');
  }
  if (failures > 0 && !pieces.any((piece) => piece.contains('来源读取失败'))) {
    pieces.add(failures == batch.coverage.length ? '公开通知来源读取失败' : '部分来源读取失败');
  }
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
  PublicFailureCode.resourceLimit => '已达到读取范围上限',
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

String _beijingClock(DateTime value) {
  final beijing = value.toUtc().add(const Duration(hours: 8));
  return '${_dateOnly(DateTime.utc(beijing.year, beijing.month, beijing.day))} '
      '${beijing.hour.toString().padLeft(2, '0')}:'
      '${beijing.minute.toString().padLeft(2, '0')}';
}
