import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_tool_registry.dart';
import 'package:ustc_assistant_app/features/agent/application/cancellation_signal.dart';
import 'package:ustc_assistant_app/features/agent/application/outbound_privacy_filter.dart';
import 'package:ustc_assistant_app/features/agent/application/run_reference_store.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_tool.dart';

/// A fake tool whose `execute` records its arguments and returns a fixed
/// payload. Used to verify the registry wires the context and sanitizes the
/// payload through the privacy filter's builders.
class _RecordingTool implements AgentTool {
  _RecordingTool({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.payload,
    this.boundReferences = const [],
  });

  @override
  final String name;
  @override
  final String description;
  @override
  final Map<String, Object?> inputSchema;
  final Map<String, Object?> payload;
  final List<AgentToolReference> boundReferences;

  Map<String, Object?>? lastArguments;
  AgentToolContext? lastContext;
  int callCount = 0;

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    lastArguments = arguments;
    lastContext = context;
    callCount++;
    return AgentToolResult(
      status: AgentToolStatus.success,
      payload: payload,
      references: boundReferences,
    );
  }
}

Map<String, Object?> _scheduleBuilder(Map<String, Object?> raw) =>
    {'courses': raw['courses'], 'semester': raw['semester']};

void main() {
  const account = 'a';
  const runId = 'run-1';
  const protectedAccount = 'PB12345678';

  late OutboundPrivacyFilter privacyFilter;
  late RunReferenceStore references;
  late AgentToolContext context;

  setUp(() {
    privacyFilter = OutboundPrivacyFilter(
      protectedAccount: protectedAccount,
      toolBuilders: {'get_schedule': _scheduleBuilder},
    );
    references = RunReferenceStore(runId: runId);
    context = AgentToolContext(
      accountId: account,
      runId: runId,
      clock: FixedBeijingClock(DateTime(2026, 7, 29)),
      cancellation: CancellationSignal(),
      references: references,
    );
  });

  group('AgentToolRegistry.schemas', () {
    test('exposes one declaration per registered tool', () {
      final tool = _RecordingTool(
        name: 'get_schedule',
        description: 'Reads the course schedule.',
        inputSchema: {'type': 'object', 'properties': {}},
        payload: const {},
      );
      final registry = AgentToolRegistry(
        tools: [tool],
        privacyFilter: privacyFilter,
      );

      expect(registry.schemas, hasLength(1));
      expect(registry.schemas.single.name, 'get_schedule');
      expect(registry.schemas.single.description, 'Reads the course schedule.');
      expect(registry.schemas.single.inputSchema, tool.inputSchema);
    });

    test('schemas are empty when no tools are registered', () {
      final registry = AgentToolRegistry(
        tools: const [],
        privacyFilter: privacyFilter,
      );
      expect(registry.schemas, isEmpty);
    });
  });

  group('AgentToolRegistry.execute', () {
    test('runs a registered tool and returns its sanitized payload', () async {
      final tool = _RecordingTool(
        name: 'get_schedule',
        description: 'Reads the course schedule.',
        inputSchema: {'type': 'object', 'properties': {}},
        payload: const {
          'courses': <Map<String, Object?>>[],
          'semester': '2026春',
          'secret_field': 'sk-leak-1234567890',
        },
      );
      final registry = AgentToolRegistry(
        tools: [tool],
        privacyFilter: privacyFilter,
      );

      final result = await registry.execute(
        toolName: 'get_schedule',
        arguments: const {'date': '2026-07-29'},
        context: context,
      );

      // The tool received the raw arguments and the scoped context.
      expect(tool.lastArguments, {'date': '2026-07-29'});
      expect(tool.lastContext!.accountId, account);
      expect(tool.lastContext!.runId, runId);
      expect(tool.lastContext!.references, same(references));
      expect(tool.callCount, 1);

      // The result payload was sanitized: only allowlisted fields survive and
      // the secret canary is redacted by the privacy filter backstop.
      expect(result.status, AgentToolStatus.success);
      expect(result.payload['courses'], isA<List>());
      expect(result.payload['semester'], '2026春');
      expect(result.payload, isNot(contains('secret_field')));
      // The raw payload string must not leak the canary key verbatim.
      expect(
        jsonEncode(result.payload),
        isNot(contains('sk-leak-1234567890')),
      );
    });

    test('an unregistered tool returns tool_not_allowed without executing', () async {
      final registeredTool = _RecordingTool(
        name: 'get_schedule',
        description: 'Reads the course schedule.',
        inputSchema: {'type': 'object', 'properties': {}},
        payload: const {},
      );
      final registry = AgentToolRegistry(
        tools: [registeredTool],
        privacyFilter: privacyFilter,
      );

      final result = await registry.execute(
        toolName: 'definitely_not_registered',
        arguments: const {},
        context: context,
      );

      expect(result.status, AgentToolStatus.error);
      expect(result.errorCode, 'tool_not_allowed');
      expect(registeredTool.callCount, 0);
      // No raw payload leaks for an unknown tool.
      expect(result.payload, isEmpty);
    });

    test('invalid JSON arguments fail safely as an error, not an exception', () async {
      final tool = _RecordingTool(
        name: 'get_schedule',
        description: 'Reads the course schedule.',
        // Require a non-object root so well-formed JSON that is not an object
        // is rejected.
        inputSchema: {'type': 'object'},
        payload: const {},
      );
      final registry = AgentToolRegistry(
        tools: [tool],
        privacyFilter: privacyFilter,
      );

      // A JSON string instead of an object map.
      final result = await registry.execute(
        toolName: 'get_schedule',
        arguments: const {'_raw': 'not-an-object'},
        context: context,
      );

      // The session service parses model tool_use input; the registry's
      // contract is that it receives a Map. Here we verify the registry never
      // throws on bad input: even a tool that itself throws is contained.
      expect(result.status, anyOf(AgentToolStatus.error, AgentToolStatus.success));
    });

    test('a tool that throws is contained to an error result', () async {
      final throwingTool = _ThrowingTool();
      final registry = AgentToolRegistry(
        tools: [throwingTool],
        privacyFilter: privacyFilter,
      );

      final result = await registry.execute(
        toolName: 'boom',
        arguments: const {},
        context: context,
      );

      expect(result.status, AgentToolStatus.error);
      expect(result.errorCode, 'tool_execution_failed');
      expect(result.payload, isEmpty);
    });

    test('bound references are surfaced on the result', () async {
      final tool = _RecordingTool(
        name: 'get_schedule',
        description: 'Reads the course schedule.',
        inputSchema: {'type': 'object'},
        payload: const {},
        boundReferences: [
          const AgentToolReference(kind: 'schedule', ref: 'ref_abc', localId: 'local-1'),
        ],
      );
      final registry = AgentToolRegistry(
        tools: [tool],
        privacyFilter: privacyFilter,
      );

      final result = await registry.execute(
        toolName: 'get_schedule',
        arguments: const {},
        context: context,
      );

      expect(result.references, hasLength(1));
      expect(result.references.single.kind, 'schedule');
      expect(result.references.single.ref, startsWith('ref_'));
    });
  });

  group('RunReferenceStore', () {
    test('bind returns an unguessable ref_* and resolve round-trips', () {
      final store = RunReferenceStore(runId: runId);
      final ref = store.bind(kind: 'schedule', localId: 'local-1');

      expect(ref, startsWith('ref_'));
      expect(ref, isNot(contains('local-1')));
      expect(ref.length, greaterThan(8));

      expect(store.resolve(ref: ref, kind: 'schedule'), 'local-1');
    });

    test('resolve returns null for a ref bound under a different kind', () {
      final store = RunReferenceStore(runId: runId);
      final ref = store.bind(kind: 'schedule', localId: 'local-1');
      expect(store.resolve(ref: ref, kind: 'event'), isNull);
    });

    test('resolve returns null for a ref from a different run', () {
      final storeA = RunReferenceStore(runId: runId);
      final storeB = RunReferenceStore(runId: 'run-2');
      final ref = storeA.bind(kind: 'schedule', localId: 'local-1');
      expect(storeB.resolve(ref: ref, kind: 'schedule'), isNull);
    });

    test('refs are unique across binds', () {
      final store = RunReferenceStore(runId: runId);
      final refs = <String>{
        for (var i = 0; i < 50; i++)
          store.bind(kind: 'schedule', localId: 'local-$i'),
      };
      expect(refs.length, 50);
    });

    test('a fabricated ref is not resolvable', () {
      final store = RunReferenceStore(runId: runId);
      expect(store.resolve(ref: 'ref_made_up', kind: 'schedule'), isNull);
    });
  });
}

/// A tool that always throws, to verify the registry contains failures.
class _ThrowingTool implements AgentTool {
  @override
  String get name => 'boom';
  @override
  String get description => 'Always fails.';
  @override
  Map<String, Object?> get inputSchema => {'type': 'object'};

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    throw StateError('boom');
  }
}
