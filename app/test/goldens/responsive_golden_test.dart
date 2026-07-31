import 'dart:async';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/security/credential_protector.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_configuration_service.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_context_builder.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_session_service.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_tool_registry.dart';
import 'package:ustc_assistant_app/features/agent/application/cancellation_signal.dart';
import 'package:ustc_assistant_app/features/agent/application/outbound_privacy_filter.dart';
import 'package:ustc_assistant_app/features/agent/data/drift_chat_repository.dart';
import 'package:ustc_assistant_app/features/agent/data/protected_agent_secret_store.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_models.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_tool.dart';
import 'package:ustc_assistant_app/features/agent/domain/llm_protocol.dart';
import 'package:ustc_assistant_app/features/agent/presentation/agent_chat_page.dart';
import 'package:ustc_assistant_app/features/schedule/domain/overlap_engine.dart';
import 'package:ustc_assistant_app/features/schedule/domain/schedule_projection.dart';
import 'package:ustc_assistant_app/features/schedule/presentation/week_timetable.dart';
import 'package:ustc_assistant_app/features/settings/presentation/official_websites_page.dart';

class _FakeLlmProvider implements LlmProvider {
  @override
  Future<List<String>> listModels({
    required String apiKey,
    required CancellationSignal cancellation,
  }) async => ['deepseek-v4-flash'];

  @override
  Stream<LlmEvent> stream({
    required String apiKey,
    required LlmRequest request,
    required CancellationSignal cancellation,
  }) => const Stream.empty();

  @override
  Future<void> probeText({
    required String apiKey,
    required String model,
    required CancellationSignal cancellation,
  }) async {}

  @override
  Future<void> probeTools({
    required String apiKey,
    required String model,
    required CancellationSignal cancellation,
  }) async {}
}

class _NoopProtector implements CredentialProtector {
  @override
  Future<ProtectedSecret> protect(Uint8List plaintext) async {
    return ProtectedSecret(bytes: Uint8List.fromList([0]), scheme: 'noop', version: 1, metadata: const {});
  }

  @override
  Future<Uint8List> unprotect(ProtectedSecret protected) async => Uint8List(0);
}

class _GoldConfigService extends AgentConfigurationService {
  _GoldConfigService(AppDatabase db, DriftChatRepository repo)
    : super(database: db, chatRepository: repo);

  @override
  Future<AgentSettingsSnapshot> load(String accountId) async {
    return AgentSettingsSnapshot(
      accountId: accountId,
      model: 'deepseek-v4-flash',
      enabled: true,
      icourseConsent: false,
      systemPromptVersion: 1,
      updatedAt: null,
    );
  }
}

class _GoldSecretStore extends ProtectedAgentSecretStore {
  static final _noop = _NoopProtector();

  _GoldSecretStore(AppDatabase db) : super(
    database: db,
    protector: _noop,
    now: () => 1,
  );

  @override
  Future<bool> hasKey(String accountId) async => true;
  @override
  Future<String?> readKey(String accountId) async => 'fake-key';
}

class _GoldSessionService extends AgentSessionService {
  _GoldSessionService(AppDatabase db, DriftChatRepository repo)
    : super(
        chatRepository: repo,
        database: db,
        provider: _FakeLlmProvider(),
        contextBuilder: const AgentContextBuilder(),
        privacyFilter: OutboundPrivacyFilter(protectedAccount: '', toolBuilders: const {}),
        registry: AgentToolRegistry(tools: [], privacyFilter: OutboundPrivacyFilter(protectedAccount: '', toolBuilders: const {})),
        clock: const SystemBeijingClock(),
        model: 'deepseek-v4-flash',
        apiKeyProvider: ({required accountId}) async => '',
      );

  @override
  Stream<AgentRunViewState> send({
    required String accountId,
    required String userText,
  }) async* {
    yield AgentRunViewState(
      runId: 'golden-run',
      state: AgentRunState.running,
      text: '你好！我是校园助手。我可以帮你查询课程安排、任务和校园信息。',
    );
    yield AgentRunViewState(
      runId: 'golden-run',
      state: AgentRunState.completed,
      text: '你好！我是校园助手。我可以帮你查询课程安排、任务和校园信息。',
      toolSummaries: const [
        AgentToolSummary(toolName: 'get_schedule', status: AgentToolStatus.success),
      ],
      sourceReferences: const [
        AgentSourceReference(kind: 'event', ref: 'ref_test'),
      ],
    );
  }
}

class _FakeWebsiteLauncher implements OfficialWebsiteLauncher {
  @override
  Future<bool> launch(Uri uri) async => true;
}

void main() {
  for (final viewport in const {
    'windows-1440x900': Size(1440, 900),
    'phone-390x844': Size(390, 844),
    'phone-412x915': Size(412, 915),
  }.entries) {
    testWidgets('agent chat ${viewport.key}', (tester) async {
      tester.view.physicalSize = viewport.value;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(() => database.close());

      final repo = DriftChatRepository(database);
      final page = AgentChatPage(
        accountId: 'test-account',
        config: _GoldConfigService(database, repo),
        secrets: _GoldSecretStore(database),
        provider: _FakeLlmProvider(),
        sessionService: _GoldSessionService(database, repo),
        chatRepository: repo,
        websiteLauncher: _FakeWebsiteLauncher(),
      );

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: page)),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await expectLater(
        find.byType(AgentChatPage),
        matchesGoldenFile('chat-${viewport.key}.png'),
      );
    });

    testWidgets('seven day week ${viewport.key}', (tester) async {
      tester.view.physicalSize = viewport.value;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final sunday = EffectiveEvent.timed(
        id: 'sunday',
        title: 'Sunday event',
        location: 'West Campus',
        startAt: DateTime(2026, 7, 26, 9, 45),
        endAt: DateTime(2026, 7, 26, 11, 20),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WeekTimetable(
              projection: buildWeek(
                ScheduleQuery(
                  selectedDate: DateTime(2026, 7, 20),
                  events: [sunday],
                ),
              ),
              onEventSelected: (_) {},
            ),
          ),
        ),
      );
      if (viewport.value.width < 600) {
        await tester.drag(
          find.byKey(const Key('week-horizontal-scroll')),
          const Offset(-900, 0),
        );
        await tester.pumpAndSettle();
        expect(find.text('周日').hitTestable(), findsOneWidget);
        expect(find.text('Sunday event').hitTestable(), findsOneWidget);
      }
      await expectLater(
        find.byType(WeekTimetable),
        matchesGoldenFile('week-${viewport.key}.png'),
      );
    });
  }
}