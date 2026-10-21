import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/diagnostics_contract.dart';

void main() {
  test(
    'context metadata round-trips through the fixed diagnostic whitelist',
    () {
      const metadata = DiagnosticContextMetadata(
        readScope: DiagnosticReadScope.personal,
        executionMode: DiagnosticExecutionMode.daily,
        decision: DiagnosticContextDecision.softCompaction,
        estimatedInputTokens: 1000000,
        outputReserve: 8192,
        availableTools: 20,
        wholeGroupsRemoved: 1000000,
      );
      final record = _record(
        context: metadata,
        code: DiagnosticCode.contextLimit,
      );

      final encoded = record.encode();
      final wire = jsonDecode(encoded) as Map<String, dynamic>;
      final contextWire = wire['context'] as Map<String, dynamic>;
      final decoded = DiagnosticRecord.decode(encoded);

      expect(contextWire.keys.toSet(), {
        'readScope',
        'executionMode',
        'decision',
        'estimatedInputTokens',
        'outputReserve',
        'availableTools',
        'wholeGroupsRemoved',
      });
      expect(contextWire['readScope'], 'personal');
      expect(contextWire['executionMode'], 'daily');
      expect(contextWire['decision'], 'softCompaction');
      expect(contextWire['availableTools'], 20);
      expect(decoded.event.context!.toSafeMap(), metadata.toSafeMap());
      expect(decoded.event.code, DiagnosticCode.contextLimit);
      expect(
        utf8.encode(encoded).length,
        lessThanOrEqualTo(diagnosticMaximumRecordBytes),
      );
    },
  );

  test('each metadata field is independently optional when present', () {
    const values = [
      DiagnosticContextMetadata(readScope: DiagnosticReadScope.basic),
      DiagnosticContextMetadata(executionMode: DiagnosticExecutionMode.confirm),
      DiagnosticContextMetadata(executionMode: DiagnosticExecutionMode.advice),
      DiagnosticContextMetadata(decision: DiagnosticContextDecision.assembled),
      DiagnosticContextMetadata(
        decision: DiagnosticContextDecision.wholeTurnTrim,
      ),
      DiagnosticContextMetadata(
        decision: DiagnosticContextDecision.serviceCapacityRetry,
      ),
      DiagnosticContextMetadata(
        decision: DiagnosticContextDecision.policySaved,
      ),
      DiagnosticContextMetadata(
        decision: DiagnosticContextDecision.policyRevoked,
      ),
      DiagnosticContextMetadata(estimatedInputTokens: 0),
      DiagnosticContextMetadata(outputReserve: 1),
      DiagnosticContextMetadata(availableTools: 0),
      DiagnosticContextMetadata(wholeGroupsRemoved: 0),
    ];

    for (final metadata in values) {
      final decoded = DiagnosticRecord.decode(
        _record(context: metadata).encode(),
      );
      expect(decoded.event.context!.toSafeMap(), metadata.toSafeMap());
    }
  });

  test('legacy diagnostic records without context remain readable', () {
    final legacy = jsonDecode(_record().encode()) as Map<String, dynamic>;
    legacy.remove('context');

    final decoded = DiagnosticRecord.decode(jsonEncode(legacy));

    expect(decoded.event.context, isNull);
    expect(decoded.event.name, DiagnosticEventName.agentRunFinished);
  });

  test(
    'context decoder rejects unknown keys, values, and malformed shapes',
    () {
      final malformed = <Object?>[
        <String, Object?>{},
        'not-an-object',
        <String, Object?>{'extra': 1},
        <String, Object?>{'readScope': 'owner-private-scope'},
        <String, Object?>{'executionMode': 'private prompt text'},
        <String, Object?>{'decision': 'exception contents'},
        <String, Object?>{'estimatedInputTokens': '123'},
        <String, Object?>{'estimatedInputTokens': true},
        <String, Object?>{'estimatedInputTokens': 1.5},
        <String, Object?>{'outputReserve': false},
        <String, Object?>{'availableTools': '19'},
        <String, Object?>{'wholeGroupsRemoved': 0.0},
        <String, Object?>{
          'decision': 'assembled',
          'prompt': 'user question sentinel',
        },
        <String, Object?>{'request': 'request body sentinel'},
        <String, Object?>{'response': 'model reply sentinel'},
        <String, Object?>{'ownerId': 'synthetic owner sentinel'},
      ];

      for (final context in malformed) {
        expect(
          () => DiagnosticRecord.decode(_recordLine(context)),
          throwsA(isA<FormatException>()),
          reason: 'context=$context',
        );
      }
    },
  );

  test(
    'context counters enforce inclusive fixed ranges on decode and encode',
    () {
      final outOfRange = <Map<String, Object?>>[
        {'estimatedInputTokens': -1},
        {'estimatedInputTokens': 1000001},
        {'outputReserve': 0},
        {'outputReserve': 8193},
        {'availableTools': -1},
        {'availableTools': 21},
        {'wholeGroupsRemoved': -1},
        {'wholeGroupsRemoved': 1000001},
      ];
      for (final context in outOfRange) {
        expect(
          () => DiagnosticRecord.decode(_recordLine(context)),
          throwsA(isA<FormatException>()),
          reason: 'context=$context',
        );
      }

      expect(
        () => const DiagnosticContextMetadata(
          estimatedInputTokens: -1,
        ).toSafeMap(),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => const DiagnosticContextMetadata(outputReserve: 8193).toSafeMap(),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => const DiagnosticContextMetadata(availableTools: 21).toSafeMap(),
        throwsA(isA<FormatException>()),
      );
      expect(
        () =>
            const DiagnosticContextMetadata(wholeGroupsRemoved: -1).toSafeMap(),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => const DiagnosticContextMetadata().toSafeMap(),
        throwsA(isA<FormatException>()),
      );
    },
  );
}

DiagnosticRecord _record({
  DiagnosticContextMetadata? context,
  DiagnosticCode? code,
}) => DiagnosticRecord(
  atUtc: DateTime.utc(2026, 10, 14),
  event: DiagnosticEvent(
    name: DiagnosticEventName.agentRunFinished,
    code: code,
    context: context,
  ),
);

String _recordLine(Object? context) {
  final map = jsonDecode(_record().encode()) as Map<String, dynamic>;
  map['context'] = context;
  return jsonEncode(map);
}
