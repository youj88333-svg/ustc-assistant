import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/agent/agent_context_budget.dart';
import 'package:ustc_assistant_m0/agent/model_gateway_contract.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';

void main() {
  group('AgentContextBudget', () {
    test('estimates Chinese text, tool schemas, roles, and tool arguments', () {
      final budget = AgentContextBudget();
      final message = ModelChatMessage(role: 'user', content: '今天下午的课不想上？');
      final withoutText = budget.estimateMessages([
        ModelChatMessage(role: 'user'),
      ], const []);
      final withoutTools = budget.estimateMessages([message], const []);
      final withTools = budget.estimateMessages(
        [message],
        [
          ModelToolDefinition(
            name: 'query_agenda',
            description: 'Read a bounded local calendar window.',
            parameters: {
              'type': 'object',
              'properties': {
                'first_day': {'type': 'string'},
                'end_day_exclusive': {'type': 'string'},
              },
            },
          ),
        ],
      );
      final withoutCall = budget.estimateMessages([
        ModelChatMessage(role: 'assistant'),
      ], const []);
      final withCall = budget.estimateMessages([
        ModelChatMessage(
          role: 'assistant',
          toolCalls: const [
            ModelToolCall(
              id: 'agenda-call',
              name: 'query_agenda',
              argumentsJson: '{"first_day":"2026-10-14"}',
            ),
          ],
        ),
      ], const []);

      expect(withoutTools.textTokens, greaterThan(withoutText.textTokens));
      expect(withTools.textTokens, greaterThan(withoutTools.textTokens));
      expect(withCall.textTokens, greaterThan(withoutCall.textTokens));
    });

    test(
      'accounts for images separately and marks their actual cost unknown',
      () {
        final bytes = Uint8List(33)
          ..setRange(0, 8, [137, 80, 78, 71, 13, 10, 26, 10])
          ..setRange(12, 16, [73, 72, 68, 82]);
        ByteData.sublistView(bytes, 16, 24)
          ..setUint32(0, 1)
          ..setUint32(4, 1);
        final image = AgentImage(bytes);
        final estimate = AgentContextBudget().estimateMessages([
          ModelChatMessage(role: 'user', content: '看看这张图', images: [image]),
        ], const []);

        expect(estimate.imageCount, 1);
        expect(
          estimate.estimatedImageTokens,
          AgentContextBudget.imageTokenReservePerImage,
        );
        expect(estimate.imageTokenCostUnknown, isTrue);
        expect(estimate.estimatedInputTokens, greaterThan(estimate.textTokens));
      },
    );

    test('compacts at its soft threshold', () {
      final budget = AgentContextBudget();
      final small = budget.estimateMessages([
        ModelChatMessage(role: 'user', content: '继续'),
      ], const []);
      final large = budget.estimateMessages([
        ModelChatMessage(role: 'user', content: List.filled(42000, 'a').join()),
      ], const []);

      expect(budget.shouldCompact(small), isFalse);
      expect(large.estimatedInputTokens, greaterThan(12000));
      expect(budget.shouldCompact(large), isTrue);
    });

    test(
      'trims oldest whole tool groups first and preserves the newest pair',
      () {
        final budget = AgentContextBudget(maximumInputTokens: 4096);
        final fixed = ModelChatMessage(
          role: 'system',
          content: List.filled(7500, 'f').join(),
        );
        final fixedMessages = [fixed];
        final groups = [
          _toolGroup('old-call', 'o'),
          _toolGroup('middle-call', 'm'),
          _toolGroup('new-call', 'n'),
        ];

        final result = budget.trimCompleteGroups(
          groups,
          fixedMessages: fixedMessages,
          tools: const [],
        );

        expect(result.removedGroupCount, 2);
        expect(result.retainedGroups, hasLength(1));
        expect(result.retainedGroups.single, hasLength(2));
        expect(
          result.retainedGroups.single.first.toolCalls.single.id,
          'new-call',
        );
        expect(result.retainedGroups.single.last.toolCallId, 'new-call');
        expect(result.overflow, isFalse);
        expect(result.fixedOverflow, isFalse);
        expect(fixedMessages, hasLength(1));
        expect(identical(fixedMessages.single, fixed), isTrue);
        expect(() => result.retainedGroups.clear(), throwsUnsupportedError);
        expect(
          () => result.retainedGroups.single.clear(),
          throwsUnsupportedError,
        );
      },
    );

    test(
      'reports fixed overflow after removing history and preserving fixed text',
      () {
        final budget = AgentContextBudget(maximumInputTokens: 4096);
        final group = _toolGroup('keep-call', 'k');
        final fixed = ModelChatMessage(
          role: 'system',
          content: List.filled(15000, 'x').join(),
        );
        final fixedMessages = [fixed];
        final result = budget.trimCompleteGroups(
          [group],
          fixedMessages: fixedMessages,
          tools: const [],
        );

        expect(result.fixedOverflow, isTrue);
        expect(result.overflow, isTrue);
        expect(result.removedGroupCount, 1);
        expect(result.retainedGroups, isEmpty);
        expect(fixedMessages, hasLength(1));
        expect(identical(fixedMessages.single, fixed), isTrue);
      },
    );

    test(
      'trims oldest complete group when message count exceeds the transport limit',
      () {
        final budget = AgentContextBudget(maximumInputTokens: 8192);
        final fixed = [ModelChatMessage(role: 'system', content: 'stable')];
        final groups = [
          _toolGroup('older-call', 'o'),
          [ModelChatMessage(role: 'user', content: 'newest turn')],
        ];

        final result = budget.trimCompleteGroups(
          groups,
          fixedMessages: fixed,
          tools: const [],
          maximumMessages: 3,
        );

        expect(result.estimate.estimatedInputTokens, lessThan(8192));
        expect(result.removedGroupCount, 1);
        expect(result.retainedGroups, hasLength(1));
        expect(result.retainedGroups.single, hasLength(1));
        expect(result.retainedGroups.single.single.content, 'newest turn');
        expect(result.messageCount, 2);
        expect(result.maximumMessages, 3);
        expect(result.overflow, isFalse);
        expect(result.fixedOverflow, isFalse);
        expect(fixed, hasLength(1));
        expect(groups.first, hasLength(2));
      },
    );

    test('reports fixed message-count overflow after removing all history', () {
      final budget = AgentContextBudget(maximumInputTokens: 8192);
      final fixed = [
        ModelChatMessage(role: 'system', content: 'one'),
        ModelChatMessage(role: 'user', content: 'two'),
        ModelChatMessage(role: 'assistant', content: 'three'),
      ];
      final result = budget.trimCompleteGroups(
        [_toolGroup('old-call', 'o')],
        fixedMessages: fixed,
        tools: const [],
        maximumMessages: 2,
      );

      expect(result.estimate.estimatedInputTokens, lessThan(8192));
      expect(result.fixedOverflow, isTrue);
      expect(result.overflow, isTrue);
      expect(result.messageCount, 3);
      expect(result.maximumMessages, 2);
      expect(result.removedGroupCount, 1);
      expect(result.retainedGroups, isEmpty);
      expect(fixed, hasLength(3));
    });

    test('rejects out-of-range or non-finite settings', () {
      expect(
        () => AgentContextBudget(maximumInputTokens: 4095),
        throwsArgumentError,
      );
      expect(
        () => AgentContextBudget(maximumInputTokens: 65537),
        throwsArgumentError,
      );
      expect(
        () => AgentContextBudget(maximumOutputTokens: 0),
        throwsArgumentError,
      );
      expect(
        () => AgentContextBudget(maximumOutputTokens: 8193),
        throwsArgumentError,
      );
      expect(
        () => AgentContextBudget(maximumModelCalls: 0),
        throwsArgumentError,
      );
      expect(
        () => AgentContextBudget(maximumModelCalls: 65),
        throwsArgumentError,
      );
      expect(
        () => AgentContextBudget(maximumToolCalls: 257),
        throwsArgumentError,
      );
      expect(
        () => AgentContextBudget(maximumToolCalls: 0),
        throwsArgumentError,
      );
      expect(
        () => AgentContextBudget().trimCompleteGroups(
          const [],
          fixedMessages: const [],
          tools: const [],
          maximumMessages: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => AgentContextBudget().trimCompleteGroups(
          const [],
          fixedMessages: const [],
          tools: const [],
          maximumMessages: 513,
        ),
        throwsArgumentError,
      );
      expect(
        () => AgentContextBudget(activeTimeout: Duration.zero),
        throwsArgumentError,
      );
      expect(
        () => AgentContextBudget(activeTimeout: const Duration(hours: 2)),
        throwsArgumentError,
      );
      expect(
        () => AgentContextBudget(softFraction: double.nan),
        throwsArgumentError,
      );
      expect(() => AgentContextBudget(softFraction: 1), throwsArgumentError);
    });

    test('rejects empty groups instead of treating them as interactions', () {
      expect(
        () => AgentContextBudget().trimCompleteGroups(
          [[]],
          fixedMessages: const [],
          tools: const [],
        ),
        throwsArgumentError,
      );
    });
  });
}

List<ModelChatMessage> _toolGroup(String callId, String fill) => [
  ModelChatMessage(
    role: 'assistant',
    toolCalls: [ModelToolCall(id: callId, name: 'read', argumentsJson: '{}')],
  ),
  ModelChatMessage(
    role: 'tool',
    toolCallId: callId,
    content: List.filled(3000, fill).join(),
  ),
];
