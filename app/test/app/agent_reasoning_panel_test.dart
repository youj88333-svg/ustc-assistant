import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/agent_reasoning_panel.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';

void main() {
  testWidgets(
    'thinking is live and bounded, then collapses when the answer starts',
    (tester) async {
      tester.view.physicalSize = const Size(320, 560);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Widget page(AgentReasoningView reasoning) => MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 560),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 288,
                child: AgentReasoningPanel(messageId: 9, reasoning: reasoning),
              ),
            ),
          ),
        ),
      );
      final longText = '先核对日期，再读取当天安排。\n' * 200;
      await tester.pumpWidget(
        page(AgentReasoningView(text: longText, active: true)),
      );
      await tester.pump();
      expect(find.text('正在思考'), findsOneWidget);
      final content = find.byKey(const ValueKey('agent-reasoning-content-9'));
      expect(tester.getSize(content).height, lessThanOrEqualTo(144));
      expect(find.byType(SelectableText), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(page(AgentReasoningView(text: longText)));
      await tester.pumpAndSettle();
      expect(content, findsNothing);
      expect(find.text('思考过程'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('agent-reasoning-toggle-9')));
      await tester.pumpAndSettle();
      expect(content, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a manual fold is respected while more reasoning arrives', (
    tester,
  ) async {
    Widget page(String text) => MaterialApp(
      home: Scaffold(
        body: AgentReasoningPanel(
          messageId: 1,
          reasoning: AgentReasoningView(text: text, active: true),
        ),
      ),
    );
    await tester.pumpWidget(page('第一个片段'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('agent-reasoning-toggle-1')));
    await tester.pump();
    await tester.pumpWidget(page('第一个片段，第二个片段'));
    await tester.pump();
    expect(find.byType(SelectableText), findsNothing);
    await tester.tap(find.byKey(const ValueKey('agent-reasoning-toggle-1')));
    await tester.pump();
    expect(find.text('第一个片段，第二个片段'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
