import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/agent/model_gateway_contract.dart';
import 'package:ustc_assistant_m0/app/demo_runtime.dart';
import 'package:ustc_assistant_m0/app/diagnostics_panel.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/diagnostics_analysis.dart';
import 'package:ustc_assistant_m0/core/diagnostics_contract.dart';
import 'package:ustc_assistant_m0/core/settings_contract.dart';
import 'package:ustc_assistant_m0/m0_entry.dart';
import 'package:ustc_assistant_m0/platform/demo_directory.dart';
import 'package:ustc_assistant_m0/platform/diagnostic_journal.dart';
import 'support/onboarding_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native persisted reset clears old diagnostics before product activation',
    (tester) async {
      final root = await Directory.systemTemp.createTemp('ustc-m57-reset-');
      final handles = <RuntimeBootstrap>[];
      try {
        Future<RuntimeBootstrap> open() async {
          final bootstrap = (await tester.runAsync(
            () => RuntimeBootstrap.open(
              directoryPath: p.join(root.path, 'demo'),
              jwDirectoryPath: p.join(root.path, 'formal'),
            ),
          ))!;
          handles.add(bootstrap);
          return bootstrap;
        }

        final first = await open();
        final oldTrace = DiagnosticTrace('a' * 32);
        first.diagnostics.record(
          DiagnosticEvent(
            name: DiagnosticEventName.unexpectedFailure,
            stage: DiagnosticStage.ui,
            trace: oldTrace,
            code: DiagnosticCode.protocol,
          ),
        );
        await tester.runAsync(first.diagnostics.flush);
        final original = (await tester.runAsync(
          first.jwStore.applicationSettings.inspectSettings,
        ))!;
        final request = (await tester.runAsync(
          () => first.jwStore.applicationSettings.prepareMaintenance(
            original.context,
            MaintenanceKind.reset,
            confirmed: true,
          ),
        ))!;
        await tester.runAsync(
          () => first.jwStore.applicationSettings.beginMaintenance(request),
        );
        await tester.runAsync(first.close);

        final restored = await open();
        expect(restored.runtime, isNotNull);
        expect(restored.maintenance.view.phase, MaintenancePhase.idle);
        final settings = (await tester.runAsync(
          restored.jwStore.applicationSettings.inspectSettings,
        ))!;
        expect(settings.context.resetEpoch, original.context.resetEpoch + 1);
        final bundle =
            jsonDecode(
                  (await tester.runAsync(restored.diagnostics.exportRecent))!,
                )
                as Map<String, dynamic>;
        final records = bundle['records'] as List;
        expect(records.any((r) => r['trace'] == oldTrace.value), isFalse);
        expect(records.any((r) => r['event'] == 'logsCleared'), isTrue);

        // The normal product reset uses the same diagnostic clearing helper.
        final currentTrace = DiagnosticTrace('b' * 32);
        restored.diagnostics.record(
          DiagnosticEvent(
            name: DiagnosticEventName.unexpectedFailure,
            trace: currentTrace,
            code: DiagnosticCode.protocol,
          ),
        );
        await tester.runAsync(
          () => restored.maintenance.start(
            settings.context,
            MaintenanceKind.reset,
            confirmed: true,
          ),
        );
        expect(restored.maintenance.view.committed, isTrue);
        final resetBundle =
            jsonDecode(
                  (await tester.runAsync(restored.diagnostics.exportRecent))!,
                )
                as Map<String, dynamic>;
        expect(
          (resetBundle['records'] as List).any(
            (r) => r['trace'] == currentTrace.value,
          ),
          isFalse,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        for (final handle in handles.reversed) {
          await tester.runAsync(handle.close);
        }
        await _removeTemporaryRoot(root);
      }
    },
  );
  testWidgets(
    'native failed proposal exports safe recent logs, retains history on restart and clears only logs',
    (tester) async {
      final root = await Directory.systemTemp.createTemp('ustc-m57-native-');
      final handles = <RuntimeBootstrap>[];
      try {
        Future<RuntimeBootstrap> open() async {
          final b = await tester.runAsync(
            () => RuntimeBootstrap.open(
              directoryPath: p.join(root.path, 'demo'),
              jwDirectoryPath: p.join(root.path, 'formal'),
              modelGateway: _InvalidProposalGateway(),
            ),
          );
          handles.add(b!);
          return b;
        }

        final first = await open();
        final settings = await first.jwStore.agent.inspectAgent();
        await tester.runAsync(
          () => first.jwStore.agent.saveModelConfiguration(
            settings.authority,
            modelId: 'synthetic-m57-model',
            modelIds: const ['synthetic-m57-model'],
            report: const AgentCapabilityReport(
              text: true,
              streaming: true,
              toolCall: true,
              toolResult: true,
            ),
            consent: true,
            key: Uint8List.fromList('SYNTHETIC_KEY_NEVER_EXPORT'.codeUnits),
          ),
        );
        await tester.runAsync(first.agentCoordinator.refresh);
        await tester.runAsync(() => finishSyntheticSetup(first));
        await tester.pumpWidget(OwnedApplication(bootstrap: first));
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => first.agentCoordinator.send('请创建一个合成测试任务并安排一个小时'),
        );
        await tester.pumpAndSettle();
        expect(
          first.agentCoordinator.view.failure,
          AgentFailureCode.invalidInput,
        );
        expect(find.textContaining('模型生成的操作参数未能通过检查'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('diagnostics-export-button')),
          findsOneWidget,
        );
        final beforeMessages = first.agentCoordinator.view.messages.length;
        expect(beforeMessages, 2);

        final selected = p.join(root.path, 'selected-log.json');
        expect(await isPlainDiagnosticLogTarget(selected), isTrue);
        expect(
          await isPlainDiagnosticLogTarget(p.join(root.path, 'jw.sqlite')),
          isFalse,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DiagnosticsPanel(
                diagnostics: first.diagnostics,
                save: (contents) async {
                  await File(selected).writeAsString(contents, flush: true);
                  return true;
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('diagnostics-export-button')),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)),
        );
        await tester.pumpAndSettle();
        expect(find.text('日志已导出，请自行发送给维护者。'), findsOneWidget);
        final contents = await File(selected).readAsString();
        expect(contents, isNot(contains('SYNTHETIC_KEY_NEVER_EXPORT')));
        expect(contents, isNot(contains('PRIVATE_TITLE_NEVER_EXPORT')));
        expect(contents, isNot(contains('请创建一个合成测试任务')));
        final analysis = analyzeDiagnosticExport(contents);
        expect(
          (analysis['traces'] as List).any(
            (t) => (t['problems'] as List).any(
              (r) => r['validation']?['reason'] == 'missingTaskTarget',
            ),
          ),
          isTrue,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(first.close);

        final second = await open();
        final bundle =
            jsonDecode(
                  (await tester.runAsync(second.diagnostics.exportRecent))!,
                )
                as Map<String, dynamic>;
        expect(
          (bundle['records'] as List).any(
            (r) => r['event'] == 'applicationClosed',
          ),
          isTrue,
        );
        expect(
          (bundle['versions'] as Map)['schema'],
          second.jwStore.schemaVersion,
        );
        expect((await second.jwStore.agent.inspectAgent()).keySaved, isTrue);
        await tester.runAsync(second.agentCoordinator.refresh);
        expect(second.agentCoordinator.view.messages.length, beforeMessages);
        await tester.runAsync(second.diagnostics.clear);
        final cleared =
            jsonDecode(
                  (await tester.runAsync(second.diagnostics.exportRecent))!,
                )
                as Map<String, dynamic>;
        expect((cleared['records'] as List).map((r) => r['event']), [
          'logsCleared',
        ]);
        expect((await second.jwStore.agent.inspectAgent()).keySaved, isTrue);
        expect(second.agentCoordinator.view.messages.length, beforeMessages);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        for (final b in handles.reversed) {
          await tester.runAsync(b.close);
        }
        await _removeTemporaryRoot(root);
      }
    },
  );

  testWidgets(
    'native directory and export guards reject a static diagnostic junction',
    (tester) async {
      final root = await Directory.systemTemp.createTemp('ustc-m57-guard-');
      DemoDirectory? owner;
      DiagnosticJournal? journal;
      try {
        final ownedPath = p.join(root.path, 'owned');
        await Directory(ownedPath).create();
        final path = p.join(ownedPath, 'diagnostics');
        final target = p.join(root.path, 'isolated-target');
        expect(
          p.isWithin(root.path, ownedPath) &&
              p.isWithin(root.path, target) &&
              p.isWithin(root.path, path),
          isTrue,
        );
        await Directory(target).create();
        String literal(String value) => "'${value.replaceAll("'", "''")}'";
        final result = await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          'New-Item -ItemType Junction -Path ${literal(path)} -Target ${literal(target)} | Out-Null',
        ]);
        expect(
          result.exitCode,
          0,
          reason:
              'The fixture creates only a checked junction within its own TEMP root.',
        );
        owner = await DemoDirectory.acquire(ownedPath);
        final held = owner;
        journal = await DiagnosticJournal.open(
          directoryPath: path,
          ensureOwnership: held.ensureHeld,
          checkedPath: (name) =>
              held.checkedChildPath('diagnostics\\$name', directory: false),
        );
        expect(
          await isPlainDiagnosticLogTarget(p.join(path, 'export.json')),
          isFalse,
        );
        journal.record(
          const DiagnosticEvent(name: DiagnosticEventName.toolStarted),
        );
        await journal.flush();
        expect(journal.diagnosticsView.available, isFalse);
        expect(
          await File(
            p.join(target, DiagnosticJournal.segmentNames.first),
          ).exists(),
          isFalse,
        );
        await expectLater(
          journal.exportRecent(),
          throwsA(isA<DiagnosticsFailure>()),
        );
      } finally {
        await journal?.close();
        await owner?.release();
        await _removeTemporaryRoot(root);
      }
    },
  );
}

Future<void> _removeTemporaryRoot(Directory root) async {
  if (!await root.exists()) return;
  final absolute = p.normalize(await root.resolveSymbolicLinks());
  final temp = p.normalize(await Directory.systemTemp.resolveSymbolicLinks());
  if (!p.isWithin(temp, absolute) ||
      !p.basename(absolute).startsWith('ustc-m57-')) {
    throw StateError('test_cleanup_boundary');
  }
  if (await root.exists()) await root.delete(recursive: true);
}

final class _InvalidProposalGateway implements ModelGatewayPort {
  int calls = 0;
  @override
  Future<List<String>> listModels(ModelSecretLease secret) async {
    secret.revoke();
    return ['synthetic-m57-model'];
  }

  @override
  Stream<ModelEvent> generate(
    ModelRequest request,
    ModelSecretLease secret,
  ) async* {
    secret.revoke();
    calls++;
    yield ModelCompleted(
      finishReason: 'tool_calls',
      toolCalls: [
        ModelToolCall(
          id: 'call:$calls',
          name: 'propose_local_changes',
          argumentsJson: jsonEncode({
            'changes': [
              calls == 1
                  ? {
                      'type': 'create_task',
                      'title': 'PRIVATE_TITLE_NEVER_EXPORT',
                    }
                  : {
                      'type': 'create_block',
                      'start': '2026-10-19T13:00+08:00',
                      'end': '2026-10-19T14:00+08:00',
                    },
            ],
          }),
        ),
      ],
    );
  }

  @override
  Future<void> cancelAndDrain() async {}
  @override
  Future<void> close() async {}
}
