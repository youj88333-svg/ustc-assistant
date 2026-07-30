import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_context_builder.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_system_prompt.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_models.dart';
import 'package:ustc_assistant_app/features/agent/domain/llm_protocol.dart';

/// Builds `count` completed turns (user + assistant pairs) ending at the given
/// starting ordinal, plus one assistant draft in each requested terminal state
/// to verify that the builder excludes failed/cancelled/interrupted drafts.
List<ChatMessageRecord> _buildMessages({
  required int completedTurns,
  List<ChatMessageState> extraDraftStates = const [],
  int startOrdinal = 1,
}) {
  final messages = <ChatMessageRecord>[];
  var ordinal = startOrdinal;
  for (var i = 0; i < completedTurns; i++) {
    messages.add(
      ChatMessageRecord(
        id: 'u-$ordinal',
        accountId: 'a',
        runId: 'run-$ordinal',
        ordinal: ordinal,
        role: ChatRole.user,
        state: ChatMessageState.completed,
        content: '用户消息 $ordinal',
        createdAt: ordinal,
        updatedAt: ordinal,
      ),
    );
    ordinal += 1;
    messages.add(
      ChatMessageRecord(
        id: 'a-$ordinal',
        accountId: 'a',
        runId: 'run-${ordinal - 1}',
        ordinal: ordinal,
        role: ChatRole.assistant,
        state: ChatMessageState.completed,
        content: '助手回复 $ordinal',
        createdAt: ordinal,
        updatedAt: ordinal,
      ),
    );
    ordinal += 1;
  }
  for (final state in extraDraftStates) {
    messages.add(
      ChatMessageRecord(
        id: 'draft-$ordinal-$state',
        accountId: 'a',
        runId: 'run-$ordinal',
        ordinal: ordinal,
        role: ChatRole.assistant,
        state: state,
        content: '被丢弃的草稿 $ordinal',
        createdAt: ordinal,
        updatedAt: ordinal,
      ),
    );
    ordinal += 1;
  }
  return messages;
}

void main() {
  const model = 'deepseek-v4-flash';
  late AgentContextBuilder builder;

  setUp(() {
    builder = const AgentContextBuilder();
  });

  group('build', () {
    test(
      'assembles versioned system rule, summary, newest turns, and current '
      'message',
      () {
        // 30 messages (15 complete turns) plus one summary.
        final history = _buildMessages(completedTurns: 15);
        const summary = ConversationSummaryRecord(
          id: 's1',
          accountId: 'a',
          throughOrdinal: 10,
          content: '此前用户询问了本周课程冲突情况，已建议核对考勤与听课记录。',
          model: model,
          createdAt: 0,
        );
        const currentUserText = '明天上午有空吗？';

        final request = builder.build(
          model: model,
          accountId: 'a',
          history: history,
          summary: summary,
          currentUserText: currentUserText,
          toolDeclarations: const [],
          clock: FixedBeijingClock(DateTime(2026, 7, 29, 9, 0, 0)),
        );

        // 1. The versioned system rule is present as the system prompt.
        expect(request.system, isNotNull);
        expect(request.system, contains(AgentSystemPrompt.version2));

        // 2. The summary text is present as an assistant context message,
        //    framed as a prior summary (data), NOT as a local business fact.
        final messageTexts =
            request.messages
                .map((m) => m.content.whereType<LlmTextBlock>().map((b) => b.text))
                .expand((t) => t)
                .toList();
        expect(messageTexts, anyElement(contains('此前用户询问了本周课程冲突情况')));
        // The summary is NOT reasserted as a verbatim user claim or treated
        // as ground truth; it must be introduced with a framing that marks it
        // as a summary.
        final summaryMessages =
            request.messages
                .where(
                  (m) => m.content.whereType<LlmTextBlock>().any(
                    (b) => b.text.contains('此前用户询问了本周课程冲突情况'),
                  ),
                )
                .toList();
        expect(summaryMessages, isNotEmpty);
        final summaryText =
            summaryMessages.first.content
                .whereType<LlmTextBlock>()
                .single
                .text;
        expect(summaryText.toLowerCase(), contains('summary'));

        // 3. The newest complete turns are included. With 15 turns the user
        //    messages sit at odd ordinals (..29) and assistant replies at
        //    even ordinals (..30).
        expect(messageTexts, anyElement(contains('用户消息 29')));
        expect(messageTexts, anyElement(contains('助手回复 30')));

        // 4. The current user message is included and is the last message.
        final lastMessage = request.messages.last;
        expect(lastMessage.role, 'user');
        expect(
          lastMessage.content.whereType<LlmTextBlock>().single.text,
          currentUserText,
        );

        // 5. Tools are passed through.
        expect(request.tools, isEmpty);
        expect(request.model, model);
      },
    );

    test(
      'excludes failed, cancelled, and interrupted assistant drafts',
      () {
        final history = _buildMessages(
          completedTurns: 3,
          extraDraftStates: [
            ChatMessageState.failed,
            ChatMessageState.cancelled,
            ChatMessageState.interrupted,
          ],
        );

        final request = builder.build(
          model: model,
          accountId: 'a',
          history: history,
          summary: null,
          currentUserText: '继续',
          toolDeclarations: const [],
          clock: FixedBeijingClock(DateTime(2026, 7, 29, 9, 0, 0)),
        );

        final allText =
            request.messages
                .map((m) => m.content.whereType<LlmTextBlock>().map((b) => b.text))
                .expand((t) => t)
                .join('\n');
        expect(allText, isNot(contains('被丢弃的草稿')));
        // The complete turns are all present.
        for (var i = 1; i <= 6; i++) {
          if (i.isOdd) {
            expect(allText, contains('用户消息 $i'));
          } else {
            expect(allText, contains('助手回复 $i'));
          }
        }
      },
    );

    test('never treats summary text as a local business fact', () {
      const summary = ConversationSummaryRecord(
        id: 's1',
        accountId: 'a',
        throughOrdinal: 4,
        content: '用户下周二有一节冲突课在3C101。',
        model: model,
        createdAt: 0,
      );
      final history = _buildMessages(completedTurns: 2);

      final request = builder.build(
        model: model,
        accountId: 'a',
        history: history,
        summary: summary,
        currentUserText: '现在呢？',
        toolDeclarations: const [],
        clock: FixedBeijingClock(DateTime(2026, 7, 29, 9, 0, 0)),
      );

      final allText =
          request.messages
              .map((m) => m.content.whereType<LlmTextBlock>().map((b) => b.text))
              .expand((t) => t)
              .join('\n');
      // The summary content is surfaced as a *summary to be treated as
      // untrusted context*, not asserted as a fact the assistant should act
      // on. The framing must mark it as a prior summary / not ground truth.
      expect(allText, contains('用户下周二有一节冲突课在3C101'));
      // The summary-bearing message must include a framing clause that tells
      // the model this is a summary, not a verified local fact.
      final summaryMessages =
          request.messages
              .where(
                (m) => m.content.whereType<LlmTextBlock>().any(
                  (b) => b.text.contains('用户下周二有一节冲突课在3C101'),
                ),
              )
              .toList();
      expect(summaryMessages, isNotEmpty);
      final summaryText =
          summaryMessages.first.content
              .whereType<LlmTextBlock>()
              .single
              .text;
      expect(summaryText.toLowerCase(), contains('summary'));
      // And the summary is NOT presented as a bare user message — it is an
      // assistant/system-style context note, so its role is 'assistant'.
      expect(summaryMessages.first.role, 'assistant');
    });

    test('system prompt appends current time to the second with weekday', () {
      final builder = const AgentContextBuilder();
      final clock = FixedBeijingClock(DateTime(2026, 7, 31, 14, 30, 5));
      final request = builder.build(
        model: model,
        accountId: 'a',
        history: const [],
        summary: null,
        currentUserText: '今天有什么课？',
        toolDeclarations: const [],
        clock: clock,
      );
      // system 同时包含 version2 文本和动态时间。
      expect(request.system, isNotNull);
      expect(request.system, contains('学长'));
      expect(request.system, contains('2026-07-31T14:30:05'));
      // 2026-07-31 是周五。
      expect(request.system, contains('周五'));
      expect(request.system, contains('Asia/Shanghai'));
    });

    test('history messages carry a YYYY-MM-DDTHH:mm timestamp prefix', () {
      final builder = const AgentContextBuilder();
      final clock = FixedBeijingClock(DateTime(2026, 7, 31, 14, 30, 5));
      // 一条历史用户消息，createdAt = 2026-07-30 14:30 北京时间（毫秒）。
      final history = [
        ChatMessageRecord(
          id: 'u-1',
          accountId: 'a',
          runId: 'run-1',
          ordinal: 1,
          role: ChatRole.user,
          state: ChatMessageState.completed,
          content: '我明天有什么课',
          createdAt: DateTime(2026, 7, 30, 14, 30).millisecondsSinceEpoch,
          updatedAt: DateTime(2026, 7, 30, 14, 30).millisecondsSinceEpoch,
        ),
      ];
      final request = builder.build(
        model: model,
        accountId: 'a',
        history: history,
        summary: null,
        currentUserText: '今天呢',
        toolDeclarations: const [],
        clock: clock,
      );
      // 历史用户消息文本前带 [2026-07-30T14:30] 前缀。
      final userTexts = request.messages
          .where((m) => m.role == 'user')
          .map((m) => m.content.whereType<LlmTextBlock>().map((b) => b.text))
          .expand((t) => t)
          .toList();
      expect(userTexts, anyElement(contains('[2026-07-30T14:30] 我明天有什么课')));
      // 当前用户消息不带前缀。
      expect(userTexts, anyElement(equals('今天呢')));
    });

    test('respects the 24,000 token budget by trimming oldest turns', () {
      // Build a large history: many turns with long, UNIQUE content so the
      // total exceeds the budget. The builder must drop the oldest turns first
      // and keep the newest plus the current message under the budget.
      const charsPerMessage = 2000; // ~2,000 tokens each at 1.0 chars/token
      final history = <ChatMessageRecord>[];
      var ordinal = 1;
      for (var i = 0; i < 60; i++) {
        // Unique filler so the oldest and newest messages are distinguishable.
        final userFiller = '用户#$ordinal-' * (charsPerMessage ~/ 6);
        final asstFiller = '助手#$ordinal-' * (charsPerMessage ~/ 6);
        history.add(
          ChatMessageRecord(
            id: 'u-$ordinal',
            accountId: 'a',
            runId: 'run-$ordinal',
            ordinal: ordinal,
            role: ChatRole.user,
            state: ChatMessageState.completed,
            content: userFiller,
            createdAt: ordinal,
            updatedAt: ordinal,
          ),
        );
        ordinal += 1;
        history.add(
          ChatMessageRecord(
            id: 'a-$ordinal',
            accountId: 'a',
            runId: 'run-${ordinal - 1}',
            ordinal: ordinal,
            role: ChatRole.assistant,
            state: ChatMessageState.completed,
            content: asstFiller,
            createdAt: ordinal,
            updatedAt: ordinal,
          ),
        );
        ordinal += 1;
      }

      final request = builder.build(
        model: model,
        accountId: 'a',
        history: history,
        summary: null,
        currentUserText: '汇总',
        toolDeclarations: const [],
        clock: FixedBeijingClock(DateTime(2026, 7, 29, 9, 0, 0)),
      );

      // The oldest turn must be dropped; the newest must be kept.
      final allText =
          request.messages
              .map((m) => m.content.whereType<LlmTextBlock>().map((b) => b.text))
              .expand((t) => t)
              .join('\n');
      // First turn (ordinals 1,2) dropped.
      expect(
        allText,
        isNot(contains(history.first.content)),
        reason: 'oldest turn must be trimmed to fit the budget',
      );
      // Newest turn (last two messages) kept.
      expect(allText, contains(history.last.content));
      // Current message always kept.
      expect(allText, contains('汇总'));
    });
  });

  group('needsSummary', () {
    test('returns false when history is empty', () {
      expect(
        builder.needsSummary(
          accountId: 'a',
          history: const [],
          summary: null,
          lastRunUsage: null,
        ),
        isFalse,
      );
    });

    test('returns false when estimated tokens are below 18,000', () {
      final history = _buildMessages(completedTurns: 5);
      expect(
        builder.needsSummary(
          accountId: 'a',
          history: history,
          summary: null,
          lastRunUsage: null,
        ),
        isFalse,
      );
    });

    test('returns true when estimated tokens exceed 18,000 and no summary', () {
      // 60 turns of ~500 tokens each (2000 chars) -> well above 18,000.
      const charsPerMessage = 2000;
      final history = <ChatMessageRecord>[];
      var ordinal = 1;
      for (var i = 0; i < 60; i++) {
        history.add(
          ChatMessageRecord(
            id: 'u-$ordinal',
            accountId: 'a',
            runId: 'run-$ordinal',
            ordinal: ordinal,
            role: ChatRole.user,
            state: ChatMessageState.completed,
            content: '用户' * (charsPerMessage ~/ 2),
            createdAt: ordinal,
            updatedAt: ordinal,
          ),
        );
        ordinal += 1;
        history.add(
          ChatMessageRecord(
            id: 'a-$ordinal',
            accountId: 'a',
            runId: 'run-${ordinal - 1}',
            ordinal: ordinal,
            role: ChatRole.assistant,
            state: ChatMessageState.completed,
            content: '助手' * (charsPerMessage ~/ 2),
            createdAt: ordinal,
            updatedAt: ordinal,
          ),
        );
        ordinal += 1;
      }

      expect(
        builder.needsSummary(
          accountId: 'a',
          history: history,
          summary: null,
          lastRunUsage: null,
        ),
        isTrue,
      );
    });

    test('prefers real usage from completed runs over the fallback estimator', () {
      // Same large history, but a completed run reports the real input usage
      // as well below threshold -> needsSummary should be false.
      const charsPerMessage = 2000;
      final history = <ChatMessageRecord>[];
      var ordinal = 1;
      for (var i = 0; i < 60; i++) {
        history.add(
          ChatMessageRecord(
            id: 'u-$ordinal',
            accountId: 'a',
            runId: 'run-$ordinal',
            ordinal: ordinal,
            role: ChatRole.user,
            state: ChatMessageState.completed,
            content: '用户' * (charsPerMessage ~/ 2),
            createdAt: ordinal,
            updatedAt: ordinal,
          ),
        );
        ordinal += 1;
        history.add(
          ChatMessageRecord(
            id: 'a-$ordinal',
            accountId: 'a',
            runId: 'run-${ordinal - 1}',
            ordinal: ordinal,
            role: ChatRole.assistant,
            state: ChatMessageState.completed,
            content: '助手' * (charsPerMessage ~/ 2),
            createdAt: ordinal,
            updatedAt: ordinal,
          ),
        );
        ordinal += 1;
      }

      const usage = AgentRunRecord(
        id: 'run-final',
        accountId: 'a',
        model: model,
        status: AgentRunState.completed,
        errorCode: null,
        inputTokens: 5000,
        outputTokens: 800,
        startedAt: 0,
        finishedAt: 1,
      );

      expect(
        builder.needsSummary(
          accountId: 'a',
          history: history,
          summary: null,
          lastRunUsage: usage,
        ),
        isFalse,
        reason: 'real usage (5,000) is below the 18,000 threshold',
      );
    });
  });

  group('buildSummaryRequest', () {
    test('disables tools, sets temperature 0, and caps output at 1,024', () {
      final history = _buildMessages(completedTurns: 12);
      const summary = ConversationSummaryRecord(
        id: 's1',
        accountId: 'a',
        throughOrdinal: 10,
        content: '旧摘要',
        model: model,
        createdAt: 0,
      );

      final request = builder.buildSummaryRequest(
        model: model,
        accountId: 'a',
        history: history,
        previousSummary: summary,
        clock: FixedBeijingClock(DateTime(2026, 7, 29, 9, 0, 0)),
      );

      expect(request.tools, isEmpty);
      expect(request.temperature, 0);
      expect(request.maxTokens, 1024);
      expect(request.system, isNotNull);
      // The summary request must include the prior summary and the recent
      // turns to summarize.
      final allText =
          request.messages
              .map((m) => m.content.whereType<LlmTextBlock>().map((b) => b.text))
              .expand((t) => t)
              .join('\n');
      expect(allText, contains('旧摘要'));
      expect(allText, contains('用户消息'));
    });

    test('builds a summary request without a prior summary', () {
      final history = _buildMessages(completedTurns: 12);

      final request = builder.buildSummaryRequest(
        model: model,
        accountId: 'a',
        history: history,
        previousSummary: null,
        clock: FixedBeijingClock(DateTime(2026, 7, 29, 9, 0, 0)),
      );

      expect(request.tools, isEmpty);
      expect(request.temperature, 0);
      expect(request.maxTokens, 1024);
    });

    test('summary request system also appends current time', () {
      final builder = const AgentContextBuilder();
      final clock = FixedBeijingClock(DateTime(2026, 7, 31, 14, 30, 5));
      final request = builder.buildSummaryRequest(
        model: model,
        accountId: 'a',
        history: const [],
        previousSummary: null,
        clock: clock,
      );
      expect(request.system, isNotNull);
      expect(request.system, contains('2026-07-31T14:30:05'));
      expect(request.system, contains('周五'));
    });
  });

  group('AgentSystemPrompt', () {
    test('version is 2', () {
      expect(AgentSystemPrompt.version, 2);
    });

    test('version2 contains the six sections and the 15 tool names', () {
      const prompt = AgentSystemPrompt.version2;
      // §1 角色与风格：友善引导型学长 + 中文默认。
      expect(prompt, contains('学长'));
      expect(prompt, contains('默认中文'));
      // §2 工具使用规范：一句话意图 + 直接调用 + 禁止空话铺垫 + 场景映射。
      expect(prompt, contains('一句话'));
      expect(prompt, contains('立即调用'));
      expect(prompt, contains('不重复'));
      // 全部 15 个工具名都应在场景映射中出现。
      const toolNames = [
        'get_schedule', 'get_event_details', 'get_free_time', 'get_conflicts',
        'get_tasks', 'get_task_details', 'get_plan_blocks',
        'get_pending_planblock_reviews', 'get_pending_event_reviews',
        'get_sync_status', 'get_safe_action_history',
        'search_current_second_class_activities', 'search_icourse',
        'search_campus_catalog', 'read_campus_detail',
      ];
      for (final name in toolNames) {
        expect(prompt, contains(name), reason: '场景映射应包含工具 $name');
      }
      expect(prompt, contains('course_summary'));
      // 二课必须区分"正在报名"（外部开放列表）与"我已报名"（本地日程 second_class 事件）。
      expect(prompt, contains('正在报名的二课'));
      expect(prompt, contains('我已报名的二课'));
      expect(prompt, contains('second_class'));
      // §3 反幻觉：外部硬、本地柔。
      expect(prompt, contains('外部数据'));
      expect(prompt, contains('本轮必须重新调用工具'));
      expect(prompt, contains('本地数据'));
      // §4 同步/登录引导：明确告知 + 操作路径 + 不重试。
      expect(prompt, contains('未同步'));
      expect(prompt, contains('需要登录'));
      expect(prompt, contains('不重试'));
      // §5 数据可信与引用。
      expect(prompt, contains('不可信数据'));
      expect(prompt, contains('conflictState'));
      // §6 能力边界：二课报名需用户在官方页面操作。
      expect(prompt, contains('二课报名'));
    });

    test('version2 has no secrets, accounts, semester literals, or raw ids', () {
      const prompt = AgentSystemPrompt.version2;
      expect(prompt, isNot(contains('PB12345678')));
      expect(prompt, isNot(contains('sk-')));
      expect(prompt, isNot(contains('421')));
      expect(prompt, isNot(contains('461')));
      expect(prompt, isNot(contains('2026spring')));
      expect(prompt, isNot(contains('2026fall')));
    });
  });

  // The deterministic fallback estimator (used on the first run before the
  // real provider `inputTokens` is available) must be conservative for CJK
  // text. Chinese BPE tokenizers yield ~1 token per character, so a 1.0
  // chars/token denominator estimates ≈ tokens (not ~0.67× as a 1.5 divisor
  // would). This guards against a first-run over-context that exceeds the
  // 24k budget.
  group('CJK token estimator (fallback)', () {
    test('estimates ~1 token per CJK char, not ~0.67 (no under-estimate)', () {
      // The deterministic fallback estimator (chars / _charsPerToken, ceil) is
      // used when no real provider usage is available (first run). Chinese BPE
      // tokenizers yield ~1 token per char, so a 1.0 divisor is conservative.
      // We assert this via the public needsSummary API: a ~26,400-char CJK
      // history should reach the 18,000-token threshold at the 1.0 ratio
      // (26,400 >= 18,000 => true). The old 1.5 divisor would under-estimate
      // to 17,600 (< 18,000 => false), the regression this test guards.
      final bigCjk = '明天下雨课程冲突考勤听课记录笔记日程查询教室' * 1200; // 22 chars * 1200 = 26,400
      expect(bigCjk.length, 26400);
      final bigHistory = [
        ChatMessageRecord(
          id: 'u-2',
          accountId: 'a',
          runId: 'run-2',
          ordinal: 1,
          role: ChatRole.user,
          state: ChatMessageState.completed,
          content: bigCjk,
          createdAt: 1,
          updatedAt: 1,
        ),
      ];
      // Conservative 1.0 ratio: 26,400 chars => 26,400 tokens >= 18,000 => true.
      // The old 1.5 ratio: 26,400 / 1.5 = 17,600 < 18,000 => false (under-estimate,
      // the regression this test guards against).
      expect(
        builder.needsSummary(
          accountId: 'a',
          history: bigHistory,
          summary: null,
          lastRunUsage: null,
        ),
        isTrue,
        reason: '26,400 CJK chars must estimate >= 18,000 tokens (1.0 ratio); '
            'the old 1.5 divisor would under-estimate to 17,600 and miss the '
            'threshold, risking first-run over-context.',
      );
    });
  });

  // Regression: the fixed request overhead (system prompt + JSON-encoded tool
  // declarations) must be subtracted from the 24k input budget BEFORE history
  // trimming. A request whose system + tools + messages would exceed 24k must
  // trim history to fit, not silently overflow.
  group('fixed request overhead budgeting', () {
    final bigToolDeclarations = List<LlmToolDeclaration>.generate(
      20,
      (i) => LlmToolDeclaration(
        name: 'tool_$i',
        description: '描述' * 200,
        inputSchema: {
          'type': 'object',
          'properties': {
            'a': {'type': 'string', 'description': '参数说明' * 50},
          },
        },
      ),
    );

    test(
      'system + tool schema + messages exceeding 24k trims history to fit',
      () {
        // Large history with UNIQUE filler per message so the oldest and
        // newest are distinguishable. Together with the big tool declarations
        // and system prompt, this exceeds 24k if the overhead is not budgeted.
        const charsPerMessage = 2000;
        final history = <ChatMessageRecord>[];
        var ordinal = 1;
        for (var i = 0; i < 30; i++) {
          final userFiller = '用户#$ordinal-' * (charsPerMessage ~/ 6);
          final asstFiller = '助手#$ordinal-' * (charsPerMessage ~/ 6);
          history.add(
            ChatMessageRecord(
              id: 'u-$ordinal',
              accountId: 'a',
              runId: 'run-$ordinal',
              ordinal: ordinal,
              role: ChatRole.user,
              state: ChatMessageState.completed,
              content: userFiller,
              createdAt: ordinal,
              updatedAt: ordinal,
            ),
          );
          ordinal += 1;
          history.add(
            ChatMessageRecord(
              id: 'a-$ordinal',
              accountId: 'a',
              runId: 'run-${ordinal - 1}',
              ordinal: ordinal,
              role: ChatRole.assistant,
              state: ChatMessageState.completed,
              content: asstFiller,
              createdAt: ordinal,
              updatedAt: ordinal,
            ),
          );
          ordinal += 1;
        }

        final request = builder.build(
          model: model,
          accountId: 'a',
          history: history,
          summary: null,
          currentUserText: '汇总',
          toolDeclarations: bigToolDeclarations,
          clock: FixedBeijingClock(DateTime(2026, 7, 29, 9, 0, 0)),
        );

        // Estimate the total request size: system + JSON(tools) + messages.
        // It must fit within the 24k budget.
        final systemTokens = request.system!.length;
        final toolsJson = jsonEncode(
          request.tools.map((t) => t.toJson()).toList(),
        );
        final toolsTokens = toolsJson.length;
        final messagesTokens = request.messages
            .expand((m) => m.content.whereType<LlmTextBlock>())
            .map((b) => b.text.length)
            .fold<int>(0, (a, b) => a + b);
        final total = systemTokens + toolsTokens + messagesTokens;
        expect(
          total,
          lessThanOrEqualTo(AgentContextBuilder.inputTokenBudget),
          reason: 'system + tools + messages must fit within the 24k budget; '
              'got $total',
        );
        // The oldest turn was trimmed (its unique filler no longer appears).
        final allText = request.messages
            .map((m) => m.content.whereType<LlmTextBlock>().map((b) => b.text))
            .expand((t) => t)
            .join('\n');
        expect(
          allText,
          isNot(contains(history.first.content)),
          reason: 'oldest turn must be trimmed to fit the budgeted overhead',
        );
        // The newest turn survives.
        expect(allText, contains(history.last.content));
      },
    );

    test(
      'estimateTurnTokens returns question_too_large for an oversized question',
      () {
        // A current question so large that it alone (plus the fixed overhead)
        // exceeds the budget must be detected before provider invocation.
        final hugeQuestion = '问' * 30000;
        final estimate = builder.estimateTurnTokens(
          currentUserText: hugeQuestion,
          toolDeclarations: bigToolDeclarations,
          clock: FixedBeijingClock(DateTime(2026, 7, 29, 9, 0, 0)),
        );
        expect(estimate.isTooLarge, isTrue);
        expect(estimate.code, 'question_too_large');
      },
    );

    test(
      'estimateTurnTokens accepts a question that fits with overhead',
      () {
        final estimate = builder.estimateTurnTokens(
          currentUserText: '明天有什么课？',
          toolDeclarations: bigToolDeclarations,
          clock: FixedBeijingClock(DateTime(2026, 7, 29, 9, 0, 0)),
        );
        expect(estimate.isTooLarge, isFalse);
      },
    );
  });

  // Regression: the summary request has its own input budget. If the
  // history-to-summarize plus the fixed overhead exceeds the budget, the
  // builder must signal it (so the caller can skip/trim rather than overflow).
  group('summary request independent budget', () {
    test(
      'buildSummaryRequest signals when history-to-summarize exceeds budget',
      () {
        // A history so large that summarizing it all would exceed 24k even
        // before the summary instruction.
        const charsPerMessage = 2000;
        final history = <ChatMessageRecord>[];
        var ordinal = 1;
        for (var i = 0; i < 60; i++) {
          history.add(
            ChatMessageRecord(
              id: 'u-$ordinal',
              accountId: 'a',
              runId: 'run-$ordinal',
              ordinal: ordinal,
              role: ChatRole.user,
              state: ChatMessageState.completed,
              content: '用户' * (charsPerMessage ~/ 2),
              createdAt: ordinal,
              updatedAt: ordinal,
            ),
          );
          ordinal += 1;
          history.add(
            ChatMessageRecord(
              id: 'a-$ordinal',
              accountId: 'a',
              runId: 'run-${ordinal - 1}',
              ordinal: ordinal,
              role: ChatRole.assistant,
              state: ChatMessageState.completed,
              content: '助手' * (charsPerMessage ~/ 2),
              createdAt: ordinal,
              updatedAt: ordinal,
            ),
          );
          ordinal += 1;
        }

        // The builder should either trim the summary history to fit or signal
        // that it does not fit. We assert via the public helper: the summary
        // history it would send must fit within the budget.
        final fits = builder.summaryHistoryFits(history: history, clock: FixedBeijingClock(DateTime(2026, 7, 29, 9, 0, 0)));
        // With 60 turns of 2000 chars = 120,000 chars >> 24,000, the raw
        // history does NOT fit. The builder must report false so the caller
        // can trim before sending.
        expect(fits, isFalse,
            reason: 'oversized summary history must be detected as not fitting');
      },
    );

    test('summaryHistoryFits accepts a small history', () {
      final history = _buildMessages(completedTurns: 3);
      expect(builder.summaryHistoryFits(history: history, clock: FixedBeijingClock(DateTime(2026, 7, 29, 9, 0, 0))), isTrue);
    });
  });
}
