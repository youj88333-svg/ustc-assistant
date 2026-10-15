import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/agent/agent_context_budget.dart';
import 'package:ustc_assistant_m0/agent/agent_system_prompt.dart';
import 'package:ustc_assistant_m0/agent/model_gateway_contract.dart';
import 'package:ustc_assistant_m0/agent/student_language_prompt.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/morning_brief_contract.dart';
import 'package:ustc_assistant_m0/core/morning_notice_contract.dart';
import 'package:ustc_assistant_m0/core/public_query_contract.dart';
import 'package:ustc_assistant_m0/jobs/morning_brief_coordinator.dart';

final _day = DateTime.utc(2026, 10, 15);

void main() {
  test(
    'conversation and morning requests receive the same meaning and voice',
    () {
      final chat = buildAgentSystemPrompt(
        day: '2026-10-15',
        receivedAt: '2026-10-15 08:00:00+08:00',
        definitions: [
          ModelToolDefinition(
            name: 'query_agenda',
            description: 'synthetic',
            parameters: {},
          ),
        ],
      );
      final morning = buildMorningRequest(
        'synthetic-model',
        _facts(),
        _notices(),
      );
      expect(chat, contains(studentLanguageInstruction));
      expect(
        morning.messages.first.content,
        contains(studentLanguageInstruction),
      );
      // The assembly is tested; a fake model cannot certify conversational tone.
      expect(chat, contains('普通问候、闲聊就自然接话'));
      expect(chat, contains('明确在续接事情时'));
      expect(chat, contains('第二个'));
      expect(chat, contains('只有应用回执明确 committed'));
      expect(morning.toolChoice, 'none');
      expect(morning.tools, isEmpty);
      expect(morning.messages.first.content, contains('仅供应用解析的交付格式'));
    },
  );

  test(
    'morning projects kind-aware meanings without changing stored states',
    () {
      final facts = _facts(
        agenda: [
          _item('合成课程', 'course', 'skip'),
          _item('合成个人安排', 'personal', 'skipped'),
          _item('合成报告复习', 'planBlock', 'completed'),
          _item('合成另一门课', 'course', 'planned'),
          _item('合成考试', 'exam', 'skip'),
        ],
      );
      final original = jsonEncode(
        facts.agenda.map((item) => item.canonical).toList(),
      );
      final request = buildMorningRequest('synthetic-model', facts, _notices());
      final payload = jsonDecode(request.messages.last.content!) as Map;
      final rows = (payload['今日日程'] as List).cast<Map>();
      expect(rows[0]['类型'], '课程');
      expect(rows[0]['个人安排'], '你不打算去上这节课');
      expect(rows[1]['个人安排'], '这次不按原计划做了');
      expect(rows[2]['类型'], '为任务留出的时间');
      expect(rows[2]['个人安排'], '这段安排已经做过了');
      expect(rows[3]['个人安排'], '仍在今天原定的安排里');
      expect(rows[4]['个人安排'], '你不打算参加这场考试');
      expect(rows.every((row) => !row.containsKey('状态')), isTrue);
      expect(jsonEncode(rows), isNot(contains('"skip"')));
      expect(jsonEncode(rows), isNot(contains('"planBlock"')));
      expect(
        jsonEncode(facts.agenda.map((item) => item.canonical).toList()),
        original,
      );
      expect(request.maxTokens, 600);
      expect(
        AgentContextBudget()
            .estimateMessages(request.messages, request.tools)
            .estimatedInputTokens,
        lessThanOrEqualTo(4000),
      );
      expect(
        utf8.encode(request.messages.last.content!).length,
        lessThanOrEqualTo(12000),
      );
    },
  );

  test(
    'host fact brief describes course intentions instead of labels or no classes',
    () {
      final text = morningFactsSummary(
        _facts(
          agenda: [
            for (var index = 0; index < 3; index++)
              _item('合成课程$index', 'course', 'skip'),
          ],
        ),
      );
      expect(text, contains('今天这 3 节课你都不打算去。'));
      expect(text, isNot(contains('没课')));
      expect(text, isNot(contains('停课')));
      expect(text, isNot(contains('缺勤')));
      expect(text, isNot(contains('跳过')));
      expect(text, isNot(contains('本地')));
      expect(text, isNot(contains('合成课程0')));
    },
  );

  test('host brief keeps a finished study period separate from a due task', () {
    final text = morningFactsSummary(
      _facts(
        agenda: [_item('合成报告复习', 'planBlock', 'completed')],
        tasks: [MorningTaskItem('合成报告', _day.add(const Duration(hours: 10)))],
      ),
    );
    expect(text, contains('合成报告复习：这段安排已经做过了。'));
    expect(text, contains('有 1 件事今天到期。'));
    expect(text, isNot(contains('合成报告已经完成')));
  });

  test(
    'missing and truncated information stays uncertain in ordinary words',
    () {
      final text = morningFactsSummary(
        _facts(agenda: [], complete: false, hasSchoolImports: false),
      );
      expect(text, contains('可能有遗漏'));
      expect(text, contains('有没有课暂时说不准'));
      expect(text, isNot(contains('覆盖')));
      expect(text, isNot(contains('今天没课')));
    },
  );

  test('long notice excerpts still trim within the unchanged model budget', () {
    final request = buildMorningRequest(
      'synthetic-model',
      _facts(),
      _notices(count: 20, excerpt: List.filled(500, '文').join()),
    );
    final payload = jsonDecode(request.messages.last.content!) as Map;
    final notices = (payload['昨日公告'] as List).cast<Map>();
    expect(notices, hasLength(12));
    expect(notices.every((notice) => !notice.containsKey('内容摘录')), isTrue);
    expect(notices.first['来源'], '教务处');
    expect(payload['公告摘要有省略'], isTrue);
    expect(
      AgentContextBudget()
          .estimateMessages(request.messages, request.tools)
          .estimatedInputTokens,
      lessThanOrEqualTo(4000),
    );
    expect(request.maxTokens, 600);
  });
}

MorningAgendaItem _item(String title, String kind, String state) =>
    MorningAgendaItem(
      title: title,
      location: '合成教室',
      start: _day.add(const Duration(hours: 2)),
      end: _day.add(const Duration(hours: 3)),
      allDay: false,
      kind: kind,
      state: state,
    );

MorningFacts _facts({
  List<MorningAgendaItem>? agenda,
  List<MorningTaskItem> tasks = const [],
  bool complete = true,
  bool hasSchoolImports = true,
}) => MorningFacts(
  context: const CalendarContext(
    owner: 'synthetic-owner',
    resetEpoch: 1,
    agendaEpoch: 2,
  ),
  day: _day,
  digest: 'synthetic-digest',
  agenda: agenda ?? [_item('合成课程', 'course', 'planned')],
  tasks: tasks,
  conflicts: 0,
  overdueTasks: 0,
  complete: complete,
  hasSchoolImports: hasSchoolImports,
);

MorningNoticeBatch _notices({int count = 0, String excerpt = ''}) =>
    MorningNoticeBatch(
      day: _day.subtract(const Duration(days: 1)),
      operations: 2,
      coverage: [
        for (final provider in [PublicProvider.teach, PublicProvider.finance])
          MorningNoticeCoverage(
            provider: provider,
            pages: 1,
            matched: provider == PublicProvider.teach ? count : 0,
            unknownDates: 0,
            complete: true,
          ),
      ],
      notices: [
        for (var index = 0; index < count; index++)
          MorningNotice(
            provider: PublicProvider.teach,
            title: '合成通知$index',
            articleUrl: Uri.parse('https://example.invalid/notice/$index'),
            publishedDay: _day.subtract(const Duration(days: 1)),
            observedAtUtc: _day,
            excerpt: excerpt,
          ),
      ],
    );
