import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/diagnostics_panel.dart';
import 'package:ustc_assistant_m0/core/diagnostics_contract.dart';

void main() {
  group('DiagnosticsExportButton', () {
    testWidgets('exports through the injected saver and records success', (
      tester,
    ) async {
      final diagnostics = _FakeDiagnostics();
      String? saved;

      await _pumpExport(
        tester,
        DiagnosticsExportButton(
          diagnostics: diagnostics,
          save: (contents) async {
            saved = contents;
            return true;
          },
        ),
      );
      await tester.tap(find.byKey(const ValueKey('diagnostics-export-button')));
      await tester.pumpAndSettle();

      expect(saved, diagnostics.exportContents);
      expect(diagnostics.exportCalls, 1);
      expect(diagnostics.records, hasLength(1));
      expect(diagnostics.records.single.name, DiagnosticEventName.logsExported);
      expect(diagnostics.records.single.stage, DiagnosticStage.export);
      expect(diagnostics.records.single.outcome, DiagnosticOutcome.complete);
      expect(find.text('日志已导出，请自行发送给维护者。'), findsOneWidget);
    });

    testWidgets('cancelled save produces no success, error, or export event', (
      tester,
    ) async {
      final diagnostics = _FakeDiagnostics();

      await _pumpExport(
        tester,
        DiagnosticsExportButton(
          diagnostics: diagnostics,
          save: (_) async => false,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('diagnostics-export-button')));
      await tester.pumpAndSettle();

      expect(diagnostics.records, isEmpty);
      expect(find.text('日志已导出，请自行发送给维护者。'), findsNothing);
      expect(find.text('未能导出日志，请稍后重试。'), findsNothing);
    });

    testWidgets(
      'hides saver exceptions and fixed error text contains no secret',
      (tester) async {
        final diagnostics = _FakeDiagnostics();
        const sentinel = 'secret-sentinel-should-not-render';

        await _pumpExport(
          tester,
          DiagnosticsExportButton(
            diagnostics: diagnostics,
            save: (_) async => throw StateError(sentinel),
          ),
        );
        await tester.tap(
          find.byKey(const ValueKey('diagnostics-export-button')),
        );
        await tester.pumpAndSettle();

        expect(find.text('未能导出日志，请稍后重试。'), findsOneWidget);
        expect(find.textContaining(sentinel), findsNothing);
        expect(diagnostics.records, isEmpty);
      },
    );

    testWidgets('ignores an export result after the diagnostics port changes', (
      tester,
    ) async {
      final first = _FakeDiagnostics()..pendingExport = Completer<String>();
      final second = _FakeDiagnostics()
        ..diagnosticsView = const DiagnosticsView(
          available: false,
          dropped: 2,
          invalid: 1,
        );
      var saverCalls = 0;
      Widget button(_FakeDiagnostics port) => DiagnosticsExportButton(
        diagnostics: port,
        save: (_) async {
          saverCalls++;
          return true;
        },
      );

      await _pumpExport(tester, button(first));
      await tester.tap(find.byKey(const ValueKey('diagnostics-export-button')));
      await tester.pump();
      expect(first.exportCalls, 1);

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: button(second))),
      );
      first.pendingExport!.complete('{"private":"$sentinel"}');
      await tester.pumpAndSettle();

      expect(saverCalls, 0);
      expect(first.records, isEmpty);
      expect(second.records, isEmpty);
      expect(find.textContaining('private'), findsNothing);
    });

    testWidgets('does not publish a late saver result after the port changes', (
      tester,
    ) async {
      final first = _FakeDiagnostics();
      final second = _FakeDiagnostics();
      final saver = Completer<bool>();
      Widget button(_FakeDiagnostics port) =>
          DiagnosticsExportButton(diagnostics: port, save: (_) => saver.future);

      await _pumpExport(tester, button(first));
      await tester.tap(find.byKey(const ValueKey('diagnostics-export-button')));
      await tester.pump();
      await tester.pump();
      expect(first.exportCalls, 1);

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: button(second))),
      );
      saver.complete(true);
      await tester.pumpAndSettle();

      expect(first.records, hasLength(1));
      expect(first.records.single.name, DiagnosticEventName.logsExported);
      expect(second.records, isEmpty);
      expect(find.text('日志已导出，请自行发送给维护者。'), findsNothing);
    });

    testWidgets('handles a saver completing after the button is disposed', (
      tester,
    ) async {
      final diagnostics = _FakeDiagnostics();
      final saver = Completer<bool>();

      await _pumpExport(
        tester,
        DiagnosticsExportButton(
          diagnostics: diagnostics,
          save: (_) => saver.future,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('diagnostics-export-button')));
      await tester.pump();
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      saver.complete(false);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(diagnostics.records, isEmpty);
    });

    testWidgets('keeps the button busy while the saver is pending', (
      tester,
    ) async {
      final diagnostics = _FakeDiagnostics();
      final saver = Completer<bool>();

      await _pumpExport(
        tester,
        DiagnosticsExportButton(
          diagnostics: diagnostics,
          save: (_) => saver.future,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('diagnostics-export-button')));
      await tester.pump();
      await tester.pump();

      final button = tester.widget<TextButton>(
        find.byKey(const ValueKey('diagnostics-export-button')),
      );
      expect(button.onPressed, isNull);
      expect(diagnostics.exportCalls, 1);

      saver.complete(false);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('diagnostics-export-button')),
            )
            .onPressed,
        isNotNull,
      );
    });
  });

  group('DiagnosticsPanel', () {
    testWidgets('shows bounded local retention and truthful health counters', (
      tester,
    ) async {
      final diagnostics = _FakeDiagnostics()
        ..diagnosticsView = const DiagnosticsView(
          available: false,
          dropped: 5,
          invalid: 3,
        );

      await _pumpPanel(tester, diagnostics, save: (_) async => false);

      expect(find.textContaining('最近 7 天'), findsOneWidget);
      expect(find.textContaining('1 MiB'), findsOneWidget);
      expect(find.textContaining('最多 1000 条'), findsOneWidget);
      expect(find.text('状态：不可用'), findsOneWidget);
      expect(find.text('丢弃记录：5　非法记录：3'), findsOneWidget);
      expect(find.textContaining('账号、密码、模型 Key'), findsOneWidget);
    });

    testWidgets('second confirmation cancellation leaves logs untouched', (
      tester,
    ) async {
      final diagnostics = _FakeDiagnostics();
      await _pumpPanel(tester, diagnostics, save: (_) async => false);

      await tester.tap(find.byKey(const ValueKey('diagnostics-clear-button')));
      await tester.pumpAndSettle();
      expect(diagnostics.clearCalls, 0);
      await tester.tap(find.text('继续确认'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('diagnostics-clear-confirmation-final')),
        findsOneWidget,
      );
      await tester.tap(find.text('返回'));
      await tester.pumpAndSettle();

      expect(diagnostics.clearCalls, 0);
    });

    testWidgets('clears only diagnostics after both confirmations', (
      tester,
    ) async {
      final diagnostics = _FakeDiagnostics()
        ..diagnosticsView = const DiagnosticsView(
          available: true,
          dropped: 4,
          invalid: 2,
        );
      diagnostics.onClear = () {
        diagnostics.diagnosticsView = const DiagnosticsView(available: true);
      };
      await _pumpPanel(tester, diagnostics, save: (_) async => false);

      await tester.tap(find.byKey(const ValueKey('diagnostics-clear-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('继续确认'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(
            const ValueKey('diagnostics-clear-confirmation-final'),
          ),
          matching: find.text('清除诊断日志'),
        ),
      );
      await tester.pumpAndSettle();

      expect(diagnostics.clearCalls, 1);
      expect(find.text('诊断日志已清除。'), findsOneWidget);
      expect(find.text('丢弃记录：0　非法记录：0'), findsOneWidget);
    });
  });
}

Future<void> _pumpExport(WidgetTester tester, Widget child) =>
    tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

Future<void> _pumpPanel(
  WidgetTester tester,
  _FakeDiagnostics diagnostics, {
  required DiagnosticLogSaver save,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: DiagnosticsPanel(diagnostics: diagnostics, save: save),
    ),
  ),
);

final class _FakeDiagnostics implements DiagnosticsPort {
  @override
  DiagnosticsView diagnosticsView = const DiagnosticsView(available: true);
  String exportContents = '{"kind":"ustc-diagnostics-export-v1","records":[]}';
  Completer<String>? pendingExport;
  Object? exportError;
  void Function()? onClear;
  int exportCalls = 0;
  int clearCalls = 0;
  final List<DiagnosticEvent> records = [];

  @override
  Future<void> close() async {}

  @override
  Future<void> clear() async {
    clearCalls++;
    onClear?.call();
  }

  @override
  Future<void> flush() async {}

  @override
  Future<String> exportRecent() async {
    exportCalls++;
    if (exportError != null) throw exportError!;
    return pendingExport?.future ?? exportContents;
  }

  @override
  DiagnosticTrace newTrace() => DiagnosticTrace('0' * 32);

  @override
  void record(DiagnosticEvent event) => records.add(event);
}

const sentinel = 'secret-sentinel-should-not-render';
