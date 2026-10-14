import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/agent/agent_context.dart';
import 'package:ustc_assistant_m0/agent/model_gateway_contract.dart';
import 'package:ustc_assistant_m0/core/agent_context_contract.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/agent_conversation_contract.dart';

void main() {
  group('buildAgentConversationGroups', () {
    test('the screenshot follow-up can see the actual first two turns', () {
      final snapshot = _snapshot(
        messages: [
          _message(1, AgentMessageRole.user, '今天下午的课不想上'),
          _message(2, AgentMessageRole.assistant, '我查到课程候选。'),
          _message(3, AgentMessageRole.user, 'approve'),
          _message(4, AgentMessageRole.assistant, '我会检查并准备。'),
          _message(5, AgentMessageRole.user, '请继续'),
        ],
        turns: [
          _turn(2, DateTime.utc(2026, 10, 14, 5), [
            AgentContextItem(
              role: 'assistant',
              text: '下午课程有候选 A《线性代数》和候选 B《概率论》，你指哪门？',
              calls: const [
                AgentContextCall(
                  id: 'call_read_1',
                  name: 'query_agenda',
                  argumentsJson: '{"date":"2026-10-14","period":"afternoon"}',
                ),
              ],
            ),
            AgentContextItem(
              role: 'tool',
              toolCallId: 'call_read_1',
              text: '候选 A：线性代数；候选 B：概率论。',
            ),
            AgentContextItem(role: 'assistant', text: '请告诉我你选哪一门。'),
          ]),
          _turn(4, DateTime.utc(2026, 10, 14, 5, 1), [
            AgentContextItem(role: 'assistant', text: '好的，我会检查并准备。'),
          ]),
        ],
      );

      final groups = buildAgentConversationGroups(snapshot);
      final requestMessages = [
        ...groups.expand((group) => group),
        ModelChatMessage(role: 'user', content: '请继续'),
      ];
      final content = _contents(requestMessages);

      expect(content, contains('候选 A《线性代数》和候选 B《概率论》'));
      expect(content, contains('候选 B：概率论'));
      expect(content, contains('approve'));
      expect(content, contains('我会检查并准备'));
      expect(content, contains('请继续'));
      expect(requestMessages.first.content, contains('2026-10-14 13:00:00'));
      expect(
        requestMessages.map((message) => message.role),
        isNot(contains('system')),
      );
      expect(
        requestMessages
            .where((message) => message.role == 'assistant')
            .expand((message) => message.toolCalls)
            .where((call) => call.name == 'propose_local_changes'),
        isEmpty,
      );
    });

    test('retains second candidate and remaps repeated call IDs by turn', () {
      final snapshot = _snapshot(
        messages: [
          _message(1, AgentMessageRole.user, '查询今天下午的课程'),
          _message(2, AgentMessageRole.assistant, '找到两个候选。'),
          _message(3, AgentMessageRole.user, '选第二个'),
          _message(4, AgentMessageRole.assistant, '收到，我按第二个候选继续。'),
        ],
        turns: [
          _turn(2, DateTime.utc(2026, 10, 14), [
            AgentContextItem(
              role: 'assistant',
              calls: const [
                AgentContextCall(
                  id: 'same_call_id',
                  name: 'query_agenda',
                  argumentsJson: '{"period":"afternoon"}',
                ),
              ],
            ),
            AgentContextItem(
              role: 'tool',
              toolCallId: 'same_call_id',
              text: '候选 A：数据库原理；候选 B：概率统计。',
            ),
            AgentContextItem(role: 'assistant', text: '有两门候选课程。'),
          ]),
          _turn(4, DateTime.utc(2026, 10, 14, 1), [
            AgentContextItem(
              role: 'assistant',
              calls: const [
                AgentContextCall(
                  id: 'same_call_id',
                  name: 'read_event',
                  argumentsJson:
                      '{"target":"event_0123456789abcdef0123456789abcdef"}',
                ),
              ],
            ),
            AgentContextItem(
              role: 'tool',
              toolCallId: 'same_call_id',
              text: '已解析到候选 B：概率统计。',
            ),
            AgentContextItem(role: 'assistant', text: '我会按第二个候选继续。'),
          ]),
        ],
      );

      final groups = buildAgentConversationGroups(snapshot);
      final flat = groups.expand((group) => group).toList();
      final calls = flat.expand((message) => message.toolCalls).toList();
      final toolResults = flat
          .where((message) => message.role == 'tool')
          .toList();

      expect(_contents(flat), contains('候选 B：概率统计'));
      expect(_contents(flat), contains('选第二个'));
      expect(calls, hasLength(2));
      expect(calls.map((call) => call.id).toSet(), hasLength(2));
      expect(calls[0].argumentsJson, '{"period":"afternoon"}');
      expect(
        calls[1].argumentsJson,
        '{"target":"event_0123456789abcdef0123456789abcdef"}',
      );
      expect(toolResults, hasLength(2));
      expect(toolResults[0].toolCallId, calls[0].id);
      expect(toolResults[1].toolCallId, calls[1].id);
      expect(() => groups.add(const []), throwsUnsupportedError);
      expect(
        () => groups.first.add(ModelChatMessage(role: 'user')),
        throwsUnsupportedError,
      );
    });

    test(
      'chat-only history becomes readable data without unsupported protocol',
      () {
        final original = _historicalToolGroup();

        final projected = projectAgentGroupsForAvailableTools([
          original,
        ], const {});
        final flat = projected.single;

        expect(flat.first, same(original.first));
        expect(
          flat.map((message) => message.role),
          everyElement(isNot('tool')),
        );
        expect(
          flat.map((message) => message.role),
          everyElement(isNot('system')),
        );
        expect(flat.expand((message) => message.toolCalls), isEmpty);
        expect(_contents(flat), contains('原始角色：assistant'));
        expect(_contents(flat), contains('工具名：query_agenda'));
        expect(_contents(flat), contains('{"period":"afternoon"}'));
        expect(_contents(flat), contains('原始角色：tool'));
        expect(_contents(flat), contains('候选 A：线性代数；候选 B：概率统计。'));
        expect(_contents(flat), contains('你选了候选 B。'));
        expect(
          () => flat.add(ModelChatMessage(role: 'user')),
          throwsUnsupportedError,
        );
      },
    );

    test('available tool history keeps the original protocol unchanged', () {
      final original = _historicalToolGroup();

      final projected = projectAgentGroupsForAvailableTools(
        [original],
        const {'query_agenda'},
      );

      expect(projected.single.first, same(original.first));
      expect(projected.single[1], same(original[1]));
      expect(projected.single[2], same(original[2]));
      expect(projected.single.map((message) => message.role), [
        'user',
        'assistant',
        'tool',
        'assistant',
      ]);
      expect(
        projected.single[1].toolCalls.single.argumentsJson,
        '{"period":"afternoon"}',
      );
      expect(
        projected.single[2].toolCallId,
        projected.single[1].toolCalls.single.id,
      );
    });

    test(
      'withheld assistant turn drops all derived items but retains user text',
      () {
        final snapshot = _snapshot(
          messages: [
            _message(1, AgentMessageRole.user, '帮我看一下这条私人备注'),
            _message(2, AgentMessageRole.assistant, '私人备注内容 marker'),
          ],
          turns: [
            _turn(2, DateTime.utc(2026, 10, 14), [
              AgentContextItem(
                role: 'assistant',
                text: '私人备注内容 marker',
                calls: const [
                  AgentContextCall(
                    id: 'private_call',
                    name: 'read_task',
                    argumentsJson: '{"includePrivate":true}',
                  ),
                ],
              ),
              AgentContextItem(
                role: 'tool',
                toolCallId: 'private_call',
                text: 'private note body marker',
              ),
            ], includesPersonalContent: true),
          ],
          withheld: const {2},
        );

        final groups = buildAgentConversationGroups(snapshot);

        expect(groups, hasLength(1));
        expect(groups.single, hasLength(1));
        expect(groups.single.single.role, 'user');
        expect(groups.single.single.content, contains('帮我看一下这条私人备注'));
        expect(
          _contents(groups.expand((group) => group)),
          isNot(contains('私人备注内容 marker')),
        );
        expect(
          _contents(groups.expand((group) => group)),
          isNot(contains('private note body marker')),
        );
      },
    );

    test(
      'withheld legacy assistant also keeps only its original user message',
      () {
        final snapshot = _snapshot(
          messages: [
            _message(1, AgentMessageRole.user, '请继续看这条记录'),
            _message(
              2,
              AgentMessageRole.assistant,
              'legacy private derived text',
            ),
          ],
          withheld: const {2},
        );

        final groups = buildAgentConversationGroups(snapshot);
        final compact = buildAgentCompactContextInput(snapshot);

        expect(groups.single, hasLength(1));
        expect(groups.single.single.content, contains('请继续看这条记录'));
        expect(compact, contains('请继续看这条记录'));
        expect(
          _contents(groups.expand((group) => group)),
          isNot(contains('legacy private derived text')),
        );
        expect(compact, isNot(contains('legacy private derived text')));
      },
    );

    test(
      'image turn keeps original user wording and prior safe interpretation only',
      () {
        final snapshot = _snapshot(
          messages: [
            _message(1, AgentMessageRole.user, '看图里第二项是什么？', imageCount: 1),
            _message(2, AgentMessageRole.assistant, '图中第二项是概率统计。'),
          ],
          turns: [
            _turn(2, DateTime.utc(2026, 10, 14), [
              AgentContextItem(
                role: 'assistant',
                text: '图片安全解读：第一项线性代数，第二项概率统计。',
              ),
            ]),
          ],
        );

        final flat = buildAgentConversationGroups(
          snapshot,
        ).expand((group) => group).toList();

        expect(flat.first.content, contains('看图里第二项是什么？'));
        expect(flat.first.content, contains('附件图片数：1'));
        expect(flat.first.content, contains('原图未保存且不会随历史重传'));
        expect(_contents(flat), contains('图片安全解读：第一项线性代数，第二项概率统计。'));
        expect(flat.every((message) => message.images.isEmpty), isTrue);
      },
    );

    test(
      'stopped turn keeps complete protocol prefix, visible partial, and terminal state',
      () {
        final snapshot = _snapshot(
          messages: [
            _message(1, AgentMessageRole.user, '查询并准备课程变更'),
            _message(
              2,
              AgentMessageRole.assistant,
              '停止前实际显示的部分回复',
              status: AgentMessageStatus.cancelled,
            ),
          ],
          turns: [
            _turn(2, DateTime.utc(2026, 10, 14), [
              AgentContextItem(role: 'assistant', text: '已找到两个候选。'),
              AgentContextItem(
                role: 'assistant',
                calls: const [
                  AgentContextCall(
                    id: 'read_id',
                    name: 'query_agenda',
                    argumentsJson: '{"period":"afternoon"}',
                  ),
                ],
              ),
              AgentContextItem(
                role: 'tool',
                toolCallId: 'read_id',
                text: '候选 A 和候选 B。',
              ),
              AgentContextItem(
                role: 'assistant',
                calls: const [
                  AgentContextCall(
                    id: 'incomplete_write',
                    name: 'propose_local_changes',
                    argumentsJson: '{"target":"candidate_b"}',
                  ),
                ],
              ),
            ]),
          ],
        );

        final flat = buildAgentConversationGroups(
          snapshot,
        ).expand((group) => group).toList();
        final calls = flat.expand((message) => message.toolCalls).toList();
        final results = flat
            .where((message) => message.role == 'tool')
            .toList();

        expect(calls, hasLength(1));
        expect(calls.single.name, 'query_agenda');
        expect(results, hasLength(1));
        expect(results.single.toolCallId, calls.single.id);
        expect(flat.map((message) => message.role), [
          'user',
          'assistant',
          'assistant',
          'tool',
          'assistant',
          'assistant',
        ]);
        expect(_contents(flat), contains('已找到两个候选。'));
        expect(_contents(flat), contains('候选 A 和候选 B。'));
        expect(_contents(flat), contains('未完成回复；不代表业务已提交'));
        expect(_contents(flat), contains('停止前实际显示的部分回复'));
        expect(_contents(flat), contains('历史运行终态'));
        expect(_contents(flat), contains('cancelled'));
        expect(_contents(flat), isNot(contains('committed')));
        expect(_contents(flat), isNot(contains('实际提交项数记录')));
        expect(_contents(flat), isNot(contains('incomplete_write')));
        expect(_contents(flat), isNot(contains('candidate_b')));
      },
    );

    test(
      'covered turns are summarized except the latest complete recent tail',
      () {
        final snapshot = _snapshot(
          coveredMessageId: 4,
          summary: '已整理到第四条；第二轮选中了候选 B。',
          messages: [
            _message(1, AgentMessageRole.user, '第一轮问题'),
            _message(2, AgentMessageRole.assistant, '第一轮回答'),
            _message(3, AgentMessageRole.user, '第二轮问题'),
            _message(4, AgentMessageRole.assistant, '第二轮选择了候选 B'),
            _message(5, AgentMessageRole.user, '第三轮问题'),
            _message(6, AgentMessageRole.assistant, '第三轮回答'),
          ],
          turns: [
            _turn(2, DateTime.utc(2026, 10, 14), [
              AgentContextItem(role: 'assistant', text: '第一轮回答'),
            ]),
            _turn(4, DateTime.utc(2026, 10, 14, 1), [
              AgentContextItem(role: 'assistant', text: '第二轮选择了候选 B'),
            ]),
            _turn(6, DateTime.utc(2026, 10, 14, 2), [
              AgentContextItem(role: 'assistant', text: '第三轮回答'),
            ]),
          ],
        );

        final groups = buildAgentConversationGroups(snapshot);
        final content = _contents(groups.expand((group) => group));
        final compact = buildAgentCompactContextInput(snapshot);

        expect(groups, hasLength(2));
        expect(content, contains('第二轮选择了候选 B'));
        expect(content, contains('第三轮回答'));
        expect(content, isNot(contains('第一轮回答')));
        expect(compact, contains('已有历史摘要'));
        expect(compact, contains('第二轮选择了候选 B'));
        expect(compact, contains('第三轮回答'));
        expect(compact, isNot(contains('第一轮回答')));
      },
    );

    test(
      'compaction keeps actual tool result, selection, unresolved item and receipt',
      () {
        final committed = AgentActionView(
          id: 'action-id',
          kind: AgentActionKind.localPlan,
          status: AgentActionStatus.committed,
          title: 'private action title',
          details: const ['private action details'],
          committedCount: 1,
        );
        final snapshot = _snapshot(
          messages: [
            _message(1, AgentMessageRole.user, '选第二个候选并继续'),
            _message(
              2,
              AgentMessageRole.assistant,
              '第二个候选已处理；还需要确认是否调整任务提醒。',
              actions: [committed],
            ),
          ],
          turns: [
            _turn(2, DateTime.utc(2026, 10, 14), [
              AgentContextItem(
                role: 'assistant',
                calls: const [
                  AgentContextCall(
                    id: 'query_id',
                    name: 'query_agenda',
                    argumentsJson: '{"period":"afternoon"}',
                  ),
                ],
              ),
              AgentContextItem(
                role: 'tool',
                toolCallId: 'query_id',
                text: '候选 A：线性代数；候选 B：概率统计；用户选择候选 B。',
              ),
              AgentContextItem(
                role: 'assistant',
                text: '第二个候选已处理；还需要确认是否调整任务提醒。',
              ),
            ]),
          ],
        );

        final compact = buildAgentCompactContextInput(snapshot);

        expect(compact, contains('候选 B：概率统计'));
        expect(compact, contains('用户选择候选 B'));
        expect(compact, contains('还需要确认是否调整任务提醒'));
        expect(compact, contains('committed'));
        expect(compact, contains('实际提交项数记录：1'));
        expect(compact, isNot(contains('private action title')));
        expect(compact, isNot(contains('private action details')));
      },
    );
  });
}

AgentConversationTurn _turn(
  int assistantMessageId,
  DateTime receivedAtUtc,
  List<AgentContextItem> items, {
  bool includesPersonalContent = false,
}) => AgentConversationTurn(
  assistantMessageId: assistantMessageId,
  receivedAtUtc: receivedAtUtc,
  includesPersonalContent: includesPersonalContent,
  items: items,
);

AgentConversationContext _snapshot({
  int coveredMessageId = 0,
  String summary = '',
  required List<AgentMessage> messages,
  List<AgentConversationTurn> turns = const [],
  Set<int> withheld = const {},
}) => AgentConversationContext(
  conversationId: 'synthetic-conversation',
  revision: 1,
  coveredMessageId: coveredMessageId,
  lastMessageId: messages.last.id,
  summary: summary,
  messages: messages,
  turns: turns,
  withheldAssistantMessageIds: withheld,
);

AgentMessage _message(
  int id,
  AgentMessageRole role,
  String text, {
  AgentMessageStatus status = AgentMessageStatus.complete,
  int imageCount = 0,
  List<AgentActionView> actions = const [],
}) => AgentMessage(
  id: id,
  role: role,
  text: text,
  status: status,
  createdAtUtc: DateTime.utc(2026, 10, 14, 5),
  imageCount: imageCount,
  actions: actions,
);

String _contents(Iterable<ModelChatMessage> messages) =>
    messages.map((message) => message.content ?? '').join('\n');

List<ModelChatMessage> _historicalToolGroup() => [
  ModelChatMessage(role: 'user', content: '请查询下午的课程'),
  ModelChatMessage(
    role: 'assistant',
    content: '我找到了两个候选。',
    toolCalls: const [
      ModelToolCall(
        id: 'history_m22_c0',
        name: 'query_agenda',
        argumentsJson: '{"period":"afternoon"}',
      ),
    ],
  ),
  ModelChatMessage(
    role: 'tool',
    toolCallId: 'history_m22_c0',
    content: '候选 A：线性代数；候选 B：概率统计。',
  ),
  ModelChatMessage(role: 'assistant', content: '你选了候选 B。'),
];
