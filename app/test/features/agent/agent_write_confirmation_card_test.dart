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
      onApprove: () => approved = true,
      onReject: () => rejected = true,
      onRemember: () {},
      onGoToSettings: () {},
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
      onApprove: () {},
      onReject: () {},
      onRemember: () {},
      onGoToSettings: () {},
    )));
    expect(find.text('此类型以后不再确认'), findsNothing);
  });

  testWidgets('shows a risk badge label', (tester) async {
    await tester.pumpWidget(wrap(AgentWriteConfirmationCard(
      proposal: proposal(risk: RiskLevel.high),
      onApprove: () {},
      onReject: () {},
      onRemember: () {},
      onGoToSettings: () {},
    )));
    // 风险徽标：卡片把风险标签渲染为单个「风险：高」文本（见 _riskStyle 的 label）。
    // 用精确匹配 `find.text('风险：高')`，而非 `find.text('高')`（后者做整串匹配，命中 0 个）。
    expect(find.text('风险：高'), findsOneWidget);
  });
}
