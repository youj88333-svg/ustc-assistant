import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/agent_workspace_contract.dart';
import 'package:ustc_assistant_m0/app/agent_workspace_page.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';

void main() {
  testWidgets('opening an older receipt keeps its reading position', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final port = _ApprovalVisibilityPort(
      _view(
        messages: [
          for (var id = 1; id <= 40; id++)
            AgentMessage(
              id: id,
              role: AgentMessageRole.assistant,
              text: '较早的合成对话$id。' * 12,
              status: AgentMessageStatus.complete,
              createdAtUtc: DateTime.utc(2026, 10, 17),
              actions: id == 1
                  ? [
                      _action(
                        id: 'old-receipt',
                        status: AgentActionStatus.committed,
                        title: '旧回执',
                        details: const ['较早回执的完整说明。'],
                        committedCount: 1,
                      ),
                    ]
                  : const [],
            ),
        ],
      ),
    );
    addTearDown(port.dispose);
    await tester.pumpWidget(
      _host(AgentWorkspacePage(controller: port, onSettings: () {})),
    );
    await tester.pumpAndSettle();
    final list = find.byKey(const ValueKey('agent-message-list'));
    final scrollable = find
        .descendant(of: list, matching: find.byType(Scrollable))
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    // History focus/ensureVisible and some input paths do not emit a user
    // scroll notification. The detail toggle itself expresses reading intent.
    position.jumpTo(0);
    await tester.pumpAndSettle();
    final toggle = find.byKey(
      const ValueKey('agent-query-details-toggle-conversation-a:1'),
    );
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(position.extentAfter, greaterThan(500));
    final detail = find.textContaining('较早回执的完整说明。');
    await tester.ensureVisible(detail);
    await tester.pumpAndSettle();
    expect(detail.hitTestable(), findsOneWidget);
    final readingOffset = position.pixels;
    port.replace(port.view);
    await tester.pumpAndSettle();
    expect(position.pixels, closeTo(readingOffset, 1));
    expect(
      find.byKey(const ValueKey('agent-action-approve-old-receipt')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  TestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets(
    'a newly requested phone approval opens and old cards lose their buttons',
    (tester) async {
      tester.view.physicalSize = const Size(360, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final port = _ApprovalVisibilityPort(_view());
      addTearDown(port.dispose);
      await tester.pumpWidget(
        _host(AgentWorkspacePage(controller: port, onSettings: () {})),
      );
      await tester.pumpAndSettle();
      port.replace(
        _view(
          phase: AgentPhase.waitingForApproval,
          pendingAction: _action(
            id: 'new-live',
            status: AgentActionStatus.proposed,
            title: '新方案',
            details: const ['仅处理本次安排。'],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('agent-action-approve-new-live')),
        findsOneWidget,
      );
      port.replace(_view(conversationId: 'different-chat'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('agent-action-approve-new-live')),
        findsNothing,
      );
      expect(port.approvedActionIds, isEmpty);
      await tester.tap(
        find.byKey(const ValueKey('agent-approval-sheet-close')),
      );
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'current approval stays beside the composer on phones with long history',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      for (final size in [const Size(320, 640), const Size(360, 640)]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.view.viewInsets = const FakeViewPadding(bottom: 220);
        tester.platformDispatcher.textScaleFactorTestValue = size.width == 320
            ? 1.0
            : 1.5;

        final action = _action(
          id: 'long-current',
          status: AgentActionStatus.proposed,
          title: '当前待批准的长方案',
          details: [
            for (var index = 0; index < 18; index++)
              '方案明细 $index：仅处理本次明确列出的本地事项，不扩大日期和对象范围。',
          ],
          warning: List.filled(5, '提交前会再次核验当前账号、目标版本与操作许可。').join(),
        );
        final port = _ApprovalVisibilityPort(
          _view(
            phase: AgentPhase.waitingForApproval,
            pendingAction: action,
            messages: [
              for (var index = 0; index < 45; index++)
                AgentMessage(
                  id: index + 1,
                  role: index.isEven
                      ? AgentMessageRole.user
                      : AgentMessageRole.assistant,
                  text: List.filled(40, '较早的对话 $index。').join(),
                  status: AgentMessageStatus.complete,
                  createdAtUtc: DateTime.utc(2026, 10, 17),
                ),
            ],
          ),
        );
        addTearDown(port.dispose);

        await tester.pumpWidget(
          _host(AgentWorkspacePage(controller: port, onSettings: () {})),
        );
        await tester.pumpAndSettle();

        final entry = find.byKey(const ValueKey('agent-current-approval-open'));
        expect(
          tester.getRect(entry).bottom,
          lessThanOrEqualTo(size.height - 220),
        );
        await tester.tap(entry);
        await tester.pumpAndSettle();

        final card = find.byKey(const ValueKey('agent-action-long-current'));
        final approve = find.byKey(
          const ValueKey('agent-action-approve-long-current'),
        );
        final reject = find.byKey(
          const ValueKey('agent-action-reject-long-current'),
        );
        expect(card, findsOneWidget);
        expect(find.text('当前待批准的长方案'), findsOneWidget);
        expect(approve, findsOneWidget);
        expect(reject, findsOneWidget);
        expect(
          find.byKey(const ValueKey('agent-message-list')),
          findsOneWidget,
        );
        final panel = find.byKey(
          const ValueKey('agent-current-approval-panel'),
        );
        final panelRect = tester.getRect(panel);
        final titleRect = tester.getRect(
          find.byKey(const ValueKey('agent-action-title-long-current')),
        );
        final approveRect = tester.getRect(approve);
        expect(panelRect.bottom, lessThanOrEqualTo(size.height - 220));
        expect(panelRect.overlaps(titleRect), isTrue);
        expect(panelRect.overlaps(approveRect), isTrue);
        expect(approveRect.top, greaterThanOrEqualTo(panelRect.top));
        expect(approveRect.bottom, lessThanOrEqualTo(panelRect.bottom));

        await tester.tap(approve);
        await tester.pumpAndSettle();
        expect(port.approvedActionIds, ['long-current']);
        expect(find.text('决定已送出 · 查看方案'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('agent-action-approve-long-current')),
          findsNothing,
        );
        expect(tester.takeException(), isNull, reason: '$size');
      }
    },
  );

  testWidgets(
    'landscape approval remains scrollable above a keyboard with large text',
    (tester) async {
      tester.view.physicalSize = const Size(720, 360);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 220);
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final port = _ApprovalVisibilityPort(
        _view(
          phase: AgentPhase.waitingForApproval,
          pendingAction: _action(
            id: 'landscape',
            status: AgentActionStatus.proposed,
            title: '横屏下需要阅读并确认的本地修改方案',
            details: List.filled(12, '仅修改本次列出的个人安排。'),
          ),
        ),
      );
      addTearDown(port.dispose);
      await tester.pumpWidget(
        _host(AgentWorkspacePage(controller: port, onSettings: () {})),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('agent-current-approval-open')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final approve = find.byKey(
        const ValueKey('agent-action-approve-landscape'),
      );
      await tester.ensureVisible(approve);
      await tester.pumpAndSettle();
      final rect = tester.getRect(approve);
      expect(rect.bottom, lessThanOrEqualTo(140));
      await tester.tap(approve);
      await tester.pumpAndSettle();
      expect(port.approvedActionIds, ['landscape']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'committed actions return to folded history and clear or switching chats drops the live card',
    (tester) async {
      tester.view.physicalSize = const Size(360, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final pending = _action(
        id: 'current',
        status: AgentActionStatus.proposed,
        title: '待批准的修改',
        details: const ['仅创建一条个人任务。'],
      );
      final port = _ApprovalVisibilityPort(
        _view(phase: AgentPhase.waitingForApproval, pendingAction: pending),
      );
      addTearDown(port.dispose);

      await tester.pumpWidget(
        _host(AgentWorkspacePage(controller: port, onSettings: () {})),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('agent-current-approval-open')),
        findsOneWidget,
      );

      final committed = _action(
        id: 'current',
        status: AgentActionStatus.committed,
        title: '待批准的本地变化',
        details: const ['C3 回执记录的结果。'],
        warning: '保存成功不代表Windows已接收或保证投递。',
        committedCount: 1,
      );
      port.replace(
        _view(
          messages: [
            AgentMessage(
              id: 80,
              role: AgentMessageRole.assistant,
              text: '修改已完成。',
              status: AgentMessageStatus.complete,
              createdAtUtc: DateTime.utc(2026, 10, 17),
              actions: [committed],
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('agent-action-current')), findsNothing);
      expect(find.text('本地实际提交 1 项'), findsNothing);

      final detailsToggle = find.byKey(
        const ValueKey('agent-query-details-toggle-conversation-a:80'),
      );
      await tester.ensureVisible(detailsToggle);
      await tester.tap(detailsToggle);
      await tester.pumpAndSettle();
      expect(find.text('本地实际提交 1 项'), findsOneWidget);
      expect(find.text('待批准的本地变化'), findsNothing);
      expect(find.text('本地修改方案'), findsOneWidget);
      expect(find.textContaining('Windows已接收'), findsNothing);
      expect(find.textContaining('系统已接收'), findsOneWidget);
      expect(find.text('这是历史记录，不提供再次批准操作。'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('agent-action-approve-current')),
        findsNothing,
      );

      port.replace(
        _view(
          conversationId: 'conversation-b',
          conversations: [
            AgentConversation(
              id: 'conversation-b',
              title: '另一个对话',
              updatedAtUtc: DateTime.utc(2026, 10, 17),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('agent-action-current')), findsNothing);

      port.replace(
        _view(
          conversationId: 'conversation-b',
          conversations: [
            AgentConversation(
              id: 'conversation-b',
              title: '另一个对话',
              updatedAtUtc: DateTime.utc(2026, 10, 17),
            ),
          ],
          pendingAction: _action(
            id: 'before-clear',
            status: AgentActionStatus.proposed,
            title: '清除前的待批方案',
            details: const ['仅用于核对 clear 收口。'],
          ),
          phase: AgentPhase.waitingForApproval,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('agent-action-before-clear')),
        findsOneWidget,
      );
      port.replace(_view(conversationId: 'conversation-b'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('agent-action-before-clear')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('desktop keeps the current approval card beside the composer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final port = _ApprovalVisibilityPort(
      _view(
        phase: AgentPhase.waitingForApproval,
        pendingAction: _action(
          id: 'desktop-current',
          status: AgentActionStatus.proposed,
          title: '桌面待批准方案',
          details: const ['影响范围：仅一项。'],
        ),
      ),
    );
    addTearDown(port.dispose);

    await tester.pumpWidget(
      _host(AgentWorkspacePage(controller: port, onSettings: () {})),
    );
    await tester.pumpAndSettle();
    final approve = find.byKey(
      const ValueKey('agent-action-approve-desktop-current'),
    );
    expect(
      find.byKey(const ValueKey('agent-action-desktop-current')),
      findsOneWidget,
    );
    expect(approve, findsOneWidget);
    await tester.tap(approve);
    await tester.pumpAndSettle();
    expect(port.approvedActionIds, ['desktop-current']);
    expect(tester.takeException(), isNull);
  });
}

AgentWorkspaceView _view({
  AgentPhase phase = AgentPhase.idle,
  String? conversationId = 'conversation-a',
  List<AgentConversation>? conversations,
  List<AgentMessage> messages = const [],
  AgentActionView? pendingAction,
}) => AgentWorkspaceView(
  phase: phase,
  settings: AgentSettingsSnapshot(
    authority: const AgentAuthority(
      owner: 'synthetic-owner',
      resetEpoch: 1,
      historyEpoch: 1,
      configRevision: 1,
    ),
    keySaved: true,
    consent: true,
    modelId: 'fake-model',
    report: const AgentCapabilityReport(text: true, streaming: true),
  ),
  conversations:
      conversations ??
      [
        AgentConversation(
          id: conversationId ?? 'conversation-a',
          title: '当前对话',
          updatedAtUtc: DateTime.utc(2026, 10, 17),
        ),
      ],
  messages: messages,
  conversationId: conversationId,
  pendingAction: pendingAction,
);

AgentActionView _action({
  required String id,
  required AgentActionStatus status,
  required String title,
  List<String> details = const [],
  String warning = '',
  int committedCount = 0,
}) => AgentActionView(
  id: id,
  kind: AgentActionKind.localPlan,
  status: status,
  title: title,
  details: details,
  warning: warning,
  committedCount: committedCount,
);

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(
    body: SafeArea(
      child: Padding(padding: const EdgeInsets.all(12), child: child),
    ),
  ),
);

final class _ApprovalVisibilityPort extends ChangeNotifier
    implements AgentWorkspacePort, AgentActionWorkspacePort {
  _ApprovalVisibilityPort(this._view);

  AgentWorkspaceView _view;
  @override
  AgentWorkspaceView get view => _view;
  final List<String> approvedActionIds = [];
  final List<String> rejectedActionIds = [];

  void replace(AgentWorkspaceView next) {
    _view = next;
    notifyListeners();
  }

  @override
  Future<void> approveAction(String actionId) async {
    approvedActionIds.add(actionId);
  }

  @override
  Future<void> rejectAction(String actionId) async {
    rejectedActionIds.add(actionId);
  }

  @override
  Future<void> continueSchool() async {}

  @override
  Future<void> refresh() async {}

  @override
  Future<void> loadModels({String key = '', required bool consent}) async {}

  @override
  Future<void> verifyAndSave({
    String key = '',
    required String modelId,
    required bool consent,
  }) async {}

  @override
  Future<void> newConversation() async {}

  @override
  Future<void> selectConversation(String id) async {}

  @override
  Future<void> send(String text, {List<AgentImage> images = const []}) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> deleteKey({required bool confirmed}) async {}

  @override
  Future<void> setModelConsent(bool consent) async {}

  @override
  Future<void> clearHistory({
    String? conversationId,
    required bool confirmed,
  }) async {}

  @override
  String safeValidationSummary() => 'synthetic';
}
