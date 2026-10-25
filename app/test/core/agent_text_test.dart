import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/agent_text.dart';

void main() {
  test(
    'ordinary campus text stays usable and recognizable secrets are refused',
    () {
      expect(
        () => AgentText.requireSafe('教务通知：本周课程安排有调整，请查看课程页面。'),
        returnsNormally,
      );
      expect(
        () => AgentText.requireSafe('请查询课程列表，并说明每门课的上课地点。'),
        returnsNormally,
      );

      for (final text in [
        'key: sk-12345678abcdefgh',
        'Authorization: Bearer synthetic-token-123',
        'api_key = synthetic-value',
        'token: synthetic-value',
        'password=synthetic-value',
        '密钥：synthetic-value',
        '密码 = synthetic-value',
      ]) {
        expect(
          () => AgentText.requireSafe(text),
          throwsA(
            isA<AgentFailure>().having(
              (failure) => failure.code,
              'code',
              AgentFailureCode.secretDetected,
            ),
          ),
          reason: 'recognized secret form should be rejected',
        );
      }
    },
  );

  test('length and NUL limits are explicit failure boundaries', () {
    expect(
      () => AgentText.requireSafe(List.filled(24001, 'x').join()),
      throwsA(
        isA<AgentFailure>().having(
          (failure) => failure.code,
          'code',
          AgentFailureCode.resourceLimit,
        ),
      ),
    );
    expect(
      () => AgentText.requireSafe('campus\u0000text'),
      throwsA(
        isA<AgentFailure>().having(
          (failure) => failure.code,
          'code',
          AgentFailureCode.resourceLimit,
        ),
      ),
    );
  });

  test('diagnostic string forms never render synthetic values', () {
    const marker = 'synthetic-secret-marker-456';
    final authority = AgentAuthority(
      owner: marker,
      resetEpoch: 1,
      historyEpoch: 2,
      configRevision: 3,
    );
    final values = <Object>[
      const AgentFailure(AgentFailureCode.secretDetected),
      authority,
      AgentSettingsSnapshot(
        authority: authority,
        modelId: marker,
        modelIds: [marker],
      ),
      ModelSecretLease(Uint8List.fromList(marker.codeUnits)),
      AgentConversation(
        id: marker,
        title: marker,
        updatedAtUtc: DateTime.utc(2026, 10, 13),
      ),
      AgentMessage(
        id: 1,
        role: AgentMessageRole.user,
        text: marker,
        status: AgentMessageStatus.complete,
        createdAtUtc: DateTime.utc(2026, 10, 13),
      ),
      AgentRunTicket(
        authority: authority,
        runId: marker,
        conversationId: marker,
        conversationGeneration: 0,
        runGeneration: 1,
        assistantMessageId: 2,
      ),
      AgentHistoryIntent(operationId: marker, conversationId: marker),
    ];

    for (final value in values) {
      expect(value.toString(), isNot(contains(marker)));
    }
  });
}
