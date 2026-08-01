import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_permission_policy.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_write_proposal.dart';
import 'package:ustc_assistant_app/features/agent/presentation/agent_write_confirmation_card.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  AgentWriteProposalView proposal({
    bool rememberAllowed = true,
    RiskLevel risk = RiskLevel.medium,
  }) => AgentWriteProposalView(
    operationLabel: '新建日程',
    riskLevel: risk,
    actionType: 'create_event',
    targetType: 'event',
    previewLines: const ['标题：健身', '时间：2026-08-01T15:00:00 至 2026-08-01T16:00:00'],
    rememberAllowed: rememberAllowed,
  );

  testWidgets('renders preview, risk badge and approve/reject buttons', (tester) async {
    var approved = false;
    var rejected = false;
    await tester.pumpWidget(wrap(AgentWriteConfirmationCard(
      proposal: proposal(),
      onApprove: () async => approved = true,
      onReject: () async => rejected = true,
      onRemember: () async {},
      onGoToSettings: () async {},
    )));
    expect(find.text('新建日程'), findsOneWidget);
    expect(find.text('标题：健身'), findsOneWidget);
    expect(find.text('确认本次'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('此类型以后不再确认'), findsOneWidget);

    await tester.tap(find.text('确认本次'));
    expect(approved, isTrue);
    await tester.tap(find.text('取消'));
    expect(rejected, isTrue);
  });

  testWidgets('hides remember option when rememberAllowed is false', (tester) async {
    await tester.pumpWidget(wrap(AgentWriteConfirmationCard(
      proposal: proposal(rememberAllowed: false),
      onApprove: () async {},
      onReject: () async {},
      onRemember: () async {},
      onGoToSettings: () async {},
    )));
    expect(find.text('此类型以后不再确认'), findsNothing);
  });

  testWidgets('shows a risk badge label', (tester) async {
    await tester.pumpWidget(wrap(AgentWriteConfirmationCard(
      proposal: proposal(risk: RiskLevel.high),
      onApprove: () async {},
      onReject: () async {},
      onRemember: () async {},
      onGoToSettings: () async {},
    )));
    // 风险徽标：卡片把风险标签渲染为单个「风险：高」文本（见 _riskStyle 的 label）。
    // 用精确匹配 `find.text('风险：高')`，而非 `find.text('高')`（后者做整串匹配，命中 0 个）。
    expect(find.text('风险：高'), findsOneWidget);
  });

  testWidgets('double-tap while submitting invokes the action once', (tester) async {
    final completer = Completer<void>();
    var invocations = 0;
    await tester.pumpWidget(wrap(AgentWriteConfirmationCard(
      proposal: proposal(),
      onApprove: () {
        invocations++;
        return completer.future;
      },
      onReject: () async {},
      onRemember: () async {},
      onGoToSettings: () async {},
    )));

    await tester.tap(find.text('确认本次'));
    await tester.pump();

    // 提交中：四个动作全部禁用，且出现「处理中」。
    expect(find.text('处理中'), findsOneWidget);
    expect(_enabled('确认本次', tester), isFalse, reason: 'approve disabled while submitting');
    expect(_enabled('取消', tester), isFalse, reason: 'reject disabled while submitting');
    expect(_enabled('此类型以后不再确认', tester), isFalse, reason: 'remember disabled while submitting');
    expect(_enabled('去权限设置', tester), isFalse, reason: 'settings disabled while submitting');
    // 风险标签与提案文本仍可见。
    expect(find.text('风险：中'), findsOneWidget);
    expect(find.text('标题：健身'), findsOneWidget);

    // 第二次点击是 no-op：调用次数保持为 1。
    await tester.tap(find.text('确认本次'));
    await tester.pump();
    expect(invocations, 1, reason: 'a second tap while submitting must not invoke again');

    completer.complete();
    await tester.pumpAndSettle();
    expect(invocations, 1);
    expect(find.text('处理中'), findsNothing);
  });

  testWidgets('failure shows inline message and re-enables controls', (tester) async {
    final completer = Completer<void>();
    await tester.pumpWidget(wrap(AgentWriteConfirmationCard(
      proposal: proposal(),
      onApprove: () => completer.future,
      onReject: () async {},
      onRemember: () async {},
      onGoToSettings: () async {},
    )));

    await tester.tap(find.text('确认本次'));
    await tester.pump();
    expect(find.text('处理中'), findsOneWidget);

    completer.completeError(StateError('boom'));
    await tester.pumpAndSettle();

    // 不暴露内部异常文本，只有通用失败信息。
    expect(find.text('操作未完成，请重试。'), findsOneWidget);
    expect(find.text('boom'), findsNothing);
    expect(_enabled('确认本次', tester), isTrue, reason: 'controls usable again after failure');
    expect(_enabled('取消', tester), isTrue);
    expect(find.text('处理中'), findsNothing);
  });
}

/// 返回标签为 [label] 的按钮在当前帧是否可点击（其 onPressed != null）。
bool _enabled(String label, WidgetTester tester) {
  final button = tester.widget<ButtonStyleButton>(
    find.ancestor(
      of: find.text(label),
      matching: find.bySubtype<ButtonStyleButton>(),
    ),
  );
  return button.onPressed != null;
}
