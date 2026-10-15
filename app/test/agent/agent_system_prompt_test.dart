import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/agent/agent_system_prompt.dart';
import 'package:ustc_assistant_m0/agent/model_gateway_contract.dart';

void main() {
  test(
    'warm conversation guidance is assembled without changing action policy',
    () {
      final prompt = buildAgentSystemPrompt(
        day: '2026-10-15',
        receivedAt: '2026-10-15 17:00:00+08:00',
        definitions: [_tool('query_agenda'), _tool('propose_local_changes')],
      );
      // This verifies what the request supplies, not how a live model will speak.
      expect(agentPromptVersion, 'ustc-student-agent-v10');
      expect(prompt, contains('热心、靠谱的学长'));
      expect(prompt, contains('不编造自己在科大读书'));
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
