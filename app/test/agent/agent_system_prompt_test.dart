import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/agent/agent_system_prompt.dart';
import 'package:ustc_assistant_m0/agent/model_gateway_contract.dart';
import 'package:ustc_assistant_m0/agent/student_language_prompt.dart';
import 'package:ustc_assistant_m0/core/agent_parameter_issue.dart';

void main() {
  test('local batch arguments do not become undo arguments', () {
    final prompt = buildAgentSystemPrompt(
      day: '2026-10-21',
      receivedAt: '2026-10-21 09:00:00+08:00',
      definitions: [_tool('propose_local_changes'), _tool('propose_undo')],
    );
    expect(prompt, contains('只有 propose_local_changes 使用 changes'));
    expect(
      prompt,
      contains(
        'propose_undo 的 arguments 必须精确为 {"scope":"latest_local_change"}',
      ),
    );
    expect(prompt, contains('invalidRequest 表示本次调用没有执行'));
    expect(prompt, contains('不要照抄失败调用或历史摘要中的参数'));
    expect(prompt, contains('模型不得自行批准或重放'));
    final noUndo = buildAgentSystemPrompt(
      day: '2026-10-21',
      receivedAt: '2026-10-21 09:00:00+08:00',
      definitions: [_tool('query_tasks')],
    );
    expect(noUndo, isNot(contains('propose_undo')));
    expect(noUndo, isNot(contains('propose_local_changes')));
  });

  test(
    'undo repair instruction is app owned and never quotes invalid input',
    () {
      const issue = AgentParameterIssue(
        reason: AgentParameterReason.unknownField,
        field: AgentParameterField.changes,
      );
      final repair = agentToolParameterRepair('propose_undo', issue);
      expect(repair, contains('【应用本轮参数校验】'));
      expect(repair, contains('arguments={"scope":"latest_local_change"}'));
      expect(repair, contains('未执行'));
      expect(repair, contains('当前审批'));
      expect(agentToolParameterRepair('propose_undo', null), isNull);
      expect(agentToolParameterRepair('UNTRUSTED_SOURCE_TEXT', issue), isNull);
      expect(agentToolParameterRepair('propose_local_changes', issue), isNull);
    },
  );

  test('reminder guidance distinguishes Android registration and delivery', () {
    final prompt = buildAgentSystemPrompt(
      day: '2026-10-17',
      receivedAt: '2026-10-17 08:00:00+08:00',
      definitions: [_tool('query_reminders'), _tool('propose_local_changes')],
    );
    expect(prompt, contains('registration_evidence'));
    expect(prompt, contains('后者不代表独立核验系统队列'));
    expect(prompt, contains('Android未允许精确提醒时可能延后'));
    expect(prompt, contains('不能说已送达'));
    expect(prompt, isNot(contains('Windows开关')));
  });
  test(
    'warm conversation guidance is assembled without changing action policy',
    () {
      final prompt = buildAgentSystemPrompt(
        day: '2026-10-15',
        receivedAt: '2026-10-15 17:00:00+08:00',
        definitions: [_tool('query_agenda'), _tool('propose_local_changes')],
      );
      // This verifies what the request supplies, not how a live model will speak.
      expect(agentPromptVersion, 'ustc-personal-maid-agent-v15');
      expect(prompt, startsWith(assistantPersonaPrefix));
      expect(prompt, contains('ROLE: DEDICATED_PERSONAL_MAID'));
      expect(prompt, contains('CHARACTER: ADULT_WOMAN'));
      expect(prompt, contains('HONESTY: AI_IDENTITY_NO_INVENTED_MEMORIES'));
      expect(prompt, isNot(contains('学长')));
      expect(prompt, isNot(contains('同学')));
      expect(prompt, contains('你好，主人。今天想先处理什么？'));
      expect(prompt, contains('围绕当前问题选信息'));
      expect(prompt, contains('不需要模仿旧回复'));
      expect(prompt, contains('只有应用回执明确 committed'));
      expect(prompt, contains('许可不足时仍可准备卡'));
      expect(prompt, contains('学校网站和学校业务记录始终只读'));
      expect(prompt, contains('模型不得自行批准或重放'));
      expect(prompt, contains('日程查询默认返回仍有效的本地场次'));
      expect(prompt, contains('正常旧学期仍在原日期显示'));
      expect(prompt, contains('不等于学校已取消或已核实退报名'));
    },
  );
  test('prompt names only tools supplied for this request', () {
    final prompt = buildAgentSystemPrompt(
      day: '2026-10-14',
      receivedAt: '2026-10-14 23:58:00+08:00',
      definitions: [
        _tool('query_tasks'),
        _tool('read_task'),
        _tool('search_knowledge'),
      ],
    );

    expect(prompt, contains('query_tasks、read_task、search_knowledge'));
    expect(prompt, isNot(contains('propose_local_changes')));
    expect(prompt, isNot(contains('find_free_slots')));
    expect(prompt, contains('不从名称或历史对话推断其他能力'));
  });

  test('policy flags describe bounded private reads and hard advice mode', () {
    final definitions = [_tool('read_task'), _tool('propose_local_changes')];
    final restricted = buildAgentSystemPrompt(
      day: '2026-10-14',
      receivedAt: '2026-10-14 12:00:00+08:00',
      definitions: definitions,
    );
    final allowed = buildAgentSystemPrompt(
      day: '2026-10-14',
      receivedAt: '2026-10-14 12:00:00+08:00',
      definitions: definitions,
      personalContentAllowed: true,
    );
    final adviceOnly = buildAgentSystemPrompt(
      day: '2026-10-14',
      receivedAt: '2026-10-14 12:00:00+08:00',
      definitions: definitions,
      personalContentAllowed: true,
      adviceOnly: true,
    );

    expect(restricted, contains('应用尚未允许'));
    expect(restricted, contains('permissionRequired'));
    expect(restricted, contains('许可不足时仍可准备卡'));
    expect(allowed, contains('应用已允许按需读取本地个人内容'));
    expect(allowed, contains('无需用户每轮精确点名字段'));
    expect(adviceOnly, contains('仅建议硬模式'));
    expect(adviceOnly, contains('可以查询、讨论和准备具体建议方案'));
    expect(adviceOnly, contains('拒绝本地提交'));
    expect(adviceOnly, isNot(contains('attendance=skip')));
  });

  test('preserves Beijing anchors and time-bearing conversation history', () {
    final prompt = buildAgentSystemPrompt(
      day: '2026-10-14',
      receivedAt: '2026-10-14 23:58:00+08:00',
      definitions: [_tool('query_agenda')],
    );

    expect(prompt, contains('当前北京时间日期为 2026-10-14'));
    expect(prompt, contains('本次问题收到时间为 2026-10-14 23:58:00+08:00'));
    expect(prompt, contains('每条消息都有各自收到时间'));
    expect(prompt, contains('理解跨日表达'));
    expect(prompt, contains('历史工具结果是带观察时间、来源和范围的历史事实'));
    expect(prompt, contains('历史工具结果'));
  });

  test(
    'reminder guidance follows the actual configured tools and saved-vs-OS boundary',
    () {
      final prompt = buildAgentSystemPrompt(
        day: '2026-10-15',
        receivedAt: '2026-10-15 12:00:00+08:00',
        definitions: [_tool('query_reminders'), _tool('propose_local_changes')],
      );
      expect(prompt, contains('set_reminders'));
      expect(prompt, contains('set_notification_preferences'));
      expect(prompt, contains('不顺带开启其他开关'));
      expect(prompt, contains('任务无截止不猜提醒时刻'));
      expect(prompt, contains('committed只证明本地规则保存'));
      expect(prompt, contains('本次和整组'));
    },
  );
}

ModelToolDefinition _tool(String name) => ModelToolDefinition(
  name: name,
  description: 'synthetic test tool',
  parameters: const {},
);
