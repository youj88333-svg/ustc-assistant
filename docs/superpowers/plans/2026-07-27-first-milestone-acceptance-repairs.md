# Windows 首版验收问题修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **状态更新（2026-07-28）：** Task 1-10 的代码、自动测试、静态分析和 Release
> 构建已经完成。本文复选框是历史实施步骤，不是实时进度；修复后的完整人工复测仍
> 待用户执行，当前结论见 `docs/project-status.md`。

**Goal:** 修复 Windows 首版第一轮人工验收发现的数据可见性、顺序同步、日程详情、Task/PlanBlock、重新认证和完全重置问题。

**Architecture:** 继续以 Drift/SQLite 为业务事实来源，通过 repository/service 补齐有效数据查询与稳定错误契约，通过 GoRouter 将现有详情组件接入应用。同步由 `SyncCoordinator` 严格串行编排，页面只负责用户交互决策；来源数据、用户覆盖和人工冲突关系继续分层保存。

**Tech Stack:** Flutter 3、Dart 3.12、Drift 2.34、GoRouter 17、Windows DPAPI、现有 Python localhost Bridge、`flutter_test`、Python `unittest`

## Global Constraints

- 工作目录为隔离工作树 `E:\107\.worktrees\first-windows-milestone`，分支为 `feature/first-windows-milestone`。
- Flutter 命令在 `app/` 中执行；如 `flutter` 不在 PATH，使用 `E:\flutter\flutter\bin\flutter.bat`。
- Python 使用 Conda 环境 `ustc_assistant`，最低 Python 3.10。
- 时间统一使用 `Asia/Shanghai`；当前教务测试学期为 `semesterId=421`、`2026spring`、`2026 春季学期`。
- 不修改 SourceBundle 1.0 契约，不让 Flutter 兼容 legacy 来源格式。
- 来源同步不得覆盖 `UserOverlay`，不得物理删除仅因完整快照缺失或滚动窗口变化的历史来源记录。
- 二课只同步已报名日程；报名和取消报名仍由用户在官方页面执行。
- 不保存明文密码，不记录 Cookie、Token、完整学号或浏览器 Profile 内容。
- 自动测试不得访问学校网站，不得操作真实用户数据库或真实凭据。
- 保留用户对 `docs/acceptance/windows-first-milestone.md` 的未提交验收记录，不重写、不还原。
- 每个任务先写失败测试，再做最小实现，通过聚焦测试后独立提交。

---

### Task 1: 按 SourceRecord presence 过滤有效日程

**Files:**
- Modify: `app/lib/features/schedule/application/effective_event_repository.dart`
- Modify: `app/test/features/schedule/schedule_projection_test.dart`
- Modify: `app/test/features/import/import_service_test.dart`

**Interfaces:**
- Consumes: `source_records.local_entity_id -> calendar_events.id` 和 `source_records.presence`
- Produces: `EffectiveEventRepository.watchDisplayEvents()` 只返回当前可见的来源事件；个人事件不要求存在 `SourceRecord`

- [ ] **Step 1: 写完整快照缺失事件的失败测试**

在 `schedule_projection_test.dart` 增加内存数据库测试，插入四个事件：

```dart
// importedMissing: source=ustc_jw, presence=missing_within_scope
// importedObserved: source=ustc_jw, presence=observed
// importedOutside: source=ustc_young_schedule, presence=outside_scope
// personal: source=user, no SourceRecord
final visible = await EffectiveEventRepository(
  database,
  accountId: accountId,
).watchDisplayEvents().first;

expect(visible.map((event) => event.id), containsAll([
  'importedObserved',
  'importedOutside',
  'personal',
]));
expect(visible.map((event) => event.id), isNot(contains('importedMissing')));
```

在 `import_service_test.dart` 扩展现有 `missing_within_scope` 测试：为旧事件创建
`UserOverlay`，导入新完整快照后断言旧 `CalendarEvent` 和覆盖仍存在。

- [ ] **Step 2: 运行聚焦测试并确认失败**

Run:

```powershell
E:\flutter\flutter\bin\flutter.bat test test/features/schedule/schedule_projection_test.dart test/features/import/import_service_test.dart
```

Expected: `importedMissing` 仍出现在 `watchDisplayEvents()`，新断言失败。

- [ ] **Step 3: 在有效事件查询中加入来源存在性条件**

修改 `watchDisplayEvents()` SQL：

```sql
WHERE e.account_id = ?
  AND e.deleted_at IS NULL
  AND e.status NOT IN ('cancelled', 'hidden', 'skipped')
  AND (
    e.source = 'user'
    OR EXISTS (
      SELECT 1
      FROM source_records sr
      WHERE sr.account_id = e.account_id
        AND sr.local_entity_id = e.id
        AND sr.presence <> 'missing_within_scope'
    )
  )
```

把 `database.sourceRecords` 加入 `readsFrom`。不要在导入时删除事件，也不要将
`outside_scope` 当作缺失。

- [ ] **Step 4: 运行聚焦测试并确认通过**

Run:

```powershell
E:\flutter\flutter\bin\flutter.bat test test/features/schedule/schedule_projection_test.dart test/features/import/import_service_test.dart
```

Expected: 全部通过，旧事件和覆盖仍在数据库中，但范围内缺失事件不参与显示。

- [ ] **Step 5: 提交**

```powershell
git add app/lib/features/schedule/application/effective_event_repository.dart app/test/features/schedule/schedule_projection_test.dart app/test/features/import/import_service_test.dart
git commit -m "fix: hide source events missing from complete snapshots"
```

---

### Task 2: 建立凭据存在性与原账号重新认证契约

**Files:**
- Modify: `app/lib/core/database/tables/account_tables.dart`
- Modify: `app/lib/core/database/app_database.dart`
- Generate: `app/lib/core/database/app_database.g.dart`
- Modify: `app/lib/features/accounts/application/account_service.dart`
- Modify: `app/test/core/database/migration_test.dart`
- Modify: `app/test/features/accounts/account_service_test.dart`

**Interfaces:**
- Produces: `AccountSummary.hasCredentials`
- Produces: `AccountService.hasCredentials(String accountId) -> Future<bool>`
- Produces: `AccountService.stageReauthentication({required String accountId, required String username, String? password, bool savePassword = false}) -> Future<ProvisionalAccount>`
- Keeps: `confirmSuccessfulLogin({required String verifiedUsername}) -> Future<String>`，重新认证成功时返回原 `accountId`

- [ ] **Step 1: 写凭据状态与重新认证失败测试**

在 `account_service_test.dart` 增加：

```dart
test('credential deletion preserves account and requires reauthentication', () async {
  final id = await service.persistVerifiedAccount(
    username: 'PB00000000',
    password: 'secret',
    savePassword: true,
  );
  await service.deleteCredentials(id);

  expect(await service.activeAccount(), isNotNull);
  expect(await service.hasCredentials(id), isFalse);
  expect((await service.summaries()).single.hasCredentials, isFalse);
  expect(
    () => service.usernameForSync(id),
    throwsA(
      isA<AccountVerificationError>().having(
        (error) => error.code,
        'code',
        'credentials_not_found',
      ),
    ),
  );
});
```

再增加原账号重新认证测试：

```dart
final provisional = await service.stageReauthentication(
  accountId: id,
  username: 'PB00000000',
  password: 'new-secret',
  savePassword: true,
);
expect(provisional.accountId, id);
expect(
  await service.confirmSuccessfulLogin(verifiedUsername: 'PB00000000'),
  id,
);
expect(await service.hasCredentials(id), isTrue);
expect(await database.select(database.localAccounts).get(), hasLength(1));
```

并验证与本地身份摘要不一致的用户名触发 `identity_mismatch`，账号和业务行数不变。

- [ ] **Step 2: 运行测试并确认失败**

Run:

```powershell
E:\flutter\flutter\bin\flutter.bat test test/features/accounts/account_service_test.dart
```

Expected: `hasCredentials`、`stageReauthentication`、`identityDigest` 或
`AccountSummary.hasCredentials` 尚不存在。

- [ ] **Step 3: 增加不可还原的账号身份摘要**

给 `LocalAccounts` 增加 nullable 字段：

```dart
TextColumn get identityDigest => text().nullable()();
```

将数据库 `schemaVersion` 提升到 `2`，并在 `onUpgrade` 中执行：

```dart
if (from < 2) {
  await migrator.addColumn(localAccounts, localAccounts.identityDigest);
}
```

摘要统一由以下函数产生：

```dart
String _identityDigest(String username) =>
    sha256.convert(utf8.encode(username.trim())).toString();
```

`confirmSuccessfulLogin` 每次成功都写入摘要。`deleteCredentials` 在删除
`CredentialAccount` 前解密现有 username，确保摘要已写入；随后清零临时明文字节并删除
整条凭据。摘要只用于本地分区一致性判断，不能用于登录，也不能还原完整学号。

更新 `migration_test.dart`：从 schema 1 打开数据库后升级到 schema 2，断言旧账号仍在且
新列为 null；下一次正常认证或删除凭据前会补齐摘要。

- [ ] **Step 4: 生成 Drift 代码**

Run:

```powershell
E:\flutter\flutter\bin\dart.bat run build_runner build --delete-conflicting-outputs
```

Expected: `app_database.g.dart` 与 schema 2 表定义一致，无冲突输出。

- [ ] **Step 5: 实现凭据状态和固定账号重新认证**

给 `AccountSummary` 增加必填布尔字段：

```dart
final bool hasCredentials;
```

`summaries()` 使用 `credentialAccounts` 是否有该账号行设置 `hasCredentials`；
`hasSavedPassword` 仍只表示是否保存密码。

实现：

```dart
Future<bool> hasCredentials(String accountId) async =>
    await (database.select(database.credentialAccounts)
          ..where((row) => row.accountId.equals(accountId)))
        .getSingleOrNull() !=
    null;

Future<ProvisionalAccount> stageReauthentication({
  required String accountId,
  required String username,
  String? password,
  bool savePassword = false,
}) async {
  final account = await (database.select(database.localAccounts)
        ..where((row) => row.id.equals(accountId)))
      .getSingleOrNull();
  if (account == null) {
    throw const AccountVerificationError('account_not_found');
  }
  final normalized = username.trim();
  if (account.identityDigest == null) {
    throw const AccountVerificationError('account_identity_missing');
  }
  if (!_constantTimeEquals(
    account.identityDigest!,
    _identityDigest(normalized),
  )) {
    throw const AccountVerificationError('identity_mismatch');
  }
  return stageLogin(
    username: normalized,
    password: password,
    savePassword: savePassword,
    provisional: ProvisionalAccount(accountId),
  );
}
```

给 `_StagedLogin` 增加 `fixedAccountId`，重新认证时设为原账号 ID。
`confirmSuccessfulLogin` 在该字段存在时不得调用 `accountIdFor` 改绑其他分区，必须再次
比较 verified username 的摘要并写回固定 ID。不得从 `maskedHint` 反推账号。
`_credential()` 在无记录时稳定抛出
`AccountVerificationError('credentials_not_found')`。

- [ ] **Step 6: 运行账号与迁移测试**

Run:

```powershell
E:\flutter\flutter\bin\flutter.bat test test/core/database/migration_test.dart test/features/accounts/account_service_test.dart
```

Expected: 全部通过；重新认证不创建第二个 `LocalAccount`。

- [ ] **Step 7: 提交**

```powershell
git add app/lib/core/database/tables/account_tables.dart app/lib/core/database/app_database.dart app/lib/core/database/app_database.g.dart app/lib/features/accounts/application/account_service.dart app/test/core/database/migration_test.dart app/test/features/accounts/account_service_test.dart
git commit -m "feat: support same-account reauthentication"
```

---

### Task 3: 严格串行执行全部同步并返回稳定错误

**Files:**
- Modify: `app/lib/features/sync/domain/sync_state.dart`
- Modify: `app/lib/features/sync/application/sync_coordinator.dart`
- Modify: `app/test/features/sync/sync_coordinator_test.dart`

**Interfaces:**
- Produces: `typedef SyncActionResolver = Future<bool> Function(SyncNeedsUserAction action)`
- Changes: `syncAll({required SyncTrigger trigger, String? accountId, required SyncActionResolver resolveUserAction})`
- Produces: `reauthenticate(SyncSource source, {required String accountId, required String username, String? password, bool savePassword = false, BridgeSemesterCapability? semesterOverride}) -> Future<SyncOutcome>`
- Produces: `SyncFailed(source, code: 'reauthentication_required')` when credentials are absent
- Keeps: `resumeInteractive(jobId, userConfirmed: bool)`

- [ ] **Step 1: 写串行同步失败测试**

构造两个来源都返回 `SyncNeedsUserAction` 的 fake Bridge，记录调用顺序：

```dart
final order = <String>[];
final outcomes = await coordinator.syncAll(
  trigger: SyncTrigger.manual,
  resolveUserAction: (action) async {
    order.add('resolve:${action.source.storage}');
    return true;
  },
);

expect(order, [
  'start:ustc_jw',
  'resolve:ustc_jw',
  'resume:ustc_jw',
  'start:ustc_young_schedule',
  'resolve:ustc_young_schedule',
  'resume:ustc_young_schedule',
]);
expect(outcomes, everyElement(isA<SyncSucceeded>()));
```

增加取消测试：resolver 对 JW 返回 `false`，断言 JW 为 `SyncCancelled`，Young 仍启动。
增加无凭据测试：删除 credential 后 `sync()` 不调用 `bridgeFactory`，返回
`SyncFailed(code: 'reauthentication_required')`。

增加重新认证测试：

```dart
final outcome = await coordinator.reauthenticate(
  SyncSource.jw,
  accountId: accountId,
  username: 'PB00000000',
  password: 'new-secret',
  savePassword: true,
);
```

恢复交互登录后断言 outcome 成功、账号数量仍为 1、凭据重新建立；输入其他学号时断言
`SyncFailed(code: 'identity_mismatch')` 且 Bridge 未启动。

- [ ] **Step 2: 运行聚焦测试并确认失败**

Run:

```powershell
E:\flutter\flutter\bin\flutter.bat test test/features/sync/sync_coordinator_test.dart
```

Expected: `syncAll` 在 resolver 介入前启动下一来源，或新签名尚不存在。

- [ ] **Step 3: 实现错误映射**

在 `sync()` 中先调用 `accounts.hasCredentials(account.id)`：

```dart
if (!await accounts.hasCredentials(account.id)) {
  await recordFailure(
    source,
    account.id,
    code: 'reauthentication_required',
  );
  return SyncFailed(source, code: 'reauthentication_required');
}
```

将 `AccountVerificationError`、Bridge busy 和账号不一致映射到稳定 code；保留最后的
通用 `sync_failed`，但不要再吞掉已知错误。

- [ ] **Step 4: 实现严格串行 `syncAll`**

```dart
typedef SyncActionResolver =
    Future<bool> Function(SyncNeedsUserAction action);

Future<List<SyncOutcome>> syncAll({
  required SyncTrigger trigger,
  String? accountId,
  required SyncActionResolver resolveUserAction,
}) async {
  final outcomes = <SyncOutcome>[];
  for (final source in SyncSource.values) {
    var outcome = await sync(
      source,
      trigger: trigger,
      accountId: accountId,
    );
    if (outcome is SyncNeedsUserAction) {
      final confirmed = await resolveUserAction(outcome);
      outcome = await resumeInteractive(
        outcome.jobId,
        userConfirmed: confirmed,
      );
    }
    outcomes.add(outcome);
  }
  return outcomes;
}
```

确保 resolver 返回前不会开始下一来源；取消当前来源后 Bridge job 必须终止。

- [ ] **Step 5: 实现固定账号重新认证采集**

新增：

```dart
Future<SyncOutcome> reauthenticate(
  SyncSource source, {
  required String accountId,
  required String username,
  String? password,
  bool savePassword = false,
  BridgeSemesterCapability? semesterOverride,
}) async
```

方法先调用 Task 2 的 `accounts.stageReauthentication(...)`，再复用 `firstLoginSync` 的
Bridge start 和 `_consume` 流程；`_PausedSync.provisional` 必须保留固定
`ProvisionalAccount(accountId)`，以便成功时 `confirmSuccessfulLogin` 补回凭据，取消或
失败时 `cancelFirstLogin` 清除内存中的用户名和密码。不得先创建新账号。

- [ ] **Step 6: 运行同步协调器测试**

Run:

```powershell
E:\flutter\flutter\bin\flutter.bat test test/features/sync/sync_coordinator_test.dart
```

Expected: 顺序、恢复、取消、无凭据和既有单来源用例全部通过。

- [ ] **Step 7: 提交**

```powershell
git add app/lib/features/sync/domain/sync_state.dart app/lib/features/sync/application/sync_coordinator.dart app/test/features/sync/sync_coordinator_test.dart
git commit -m "fix: serialize multi-source sync interactions"
```

---

### Task 4: 接通重新认证页面和逐来源同步结果

**Files:**
- Modify: `app/lib/features/accounts/presentation/accounts_page.dart`
- Modify: `app/lib/features/sync/presentation/sync_page.dart`
- Modify: `app/lib/app/router.dart`
- Modify: `app/test/features/accounts/accounts_page_test.dart`
- Modify: `app/test/features/sync/sync_page_test.dart`
- Modify: `app/test/app/app_shell_test.dart`

**Interfaces:**
- Consumes: `AccountSummary.hasCredentials`
- Consumes: Task 2 `stageReauthentication`
- Consumes: Task 3 `syncAll(... resolveUserAction:)`
- Produces route: `/accounts/:accountId/reauthenticate`
- Produces: `SyncPageLoader(database:, reminderReconciler:, reauthenticateAccountId:)`

- [ ] **Step 1: 写账号页状态和路由失败测试**

在 `accounts_page_test.dart` 删除凭据后重新 pump，断言：

```dart
expect(find.text('需要重新登录'), findsOneWidget);
expect(find.byKey(Key('reauthenticate-$id')), findsOneWidget);
```

点击按钮，验证 `onLoginAgain(id)` 收到原账号 ID。

在 `app_shell_test.dart` 使用内存数据库打开
`/accounts/$id/reauthenticate`，断言出现固定本地账号提示、完整学校账号输入框、密码
框、保存密码开关和“重新登录”按钮。输入与身份摘要不一致的账号时不启动 Bridge。

- [ ] **Step 2: 写同步页严格顺序与结果测试**

在 `sync_page_test.dart` 增加两个来源依次待登录的 fake coordinator 流程，断言第二个
来源在第一个登录对话框完成前没有启动。再断言：

```dart
expect(find.textContaining('教务系统：同步成功'), findsOneWidget);
expect(find.textContaining('二课平台：已取消'), findsOneWidget);
```

无凭据返回 `reauthentication_required` 时，断言显示“请先重新登录”按钮并导航到固定
账号重新认证路由。

- [ ] **Step 3: 运行 Widget 测试并确认失败**

Run:

```powershell
E:\flutter\flutter\bin\flutter.bat test test/features/accounts/accounts_page_test.dart test/features/sync/sync_page_test.dart test/app/app_shell_test.dart
```

Expected: 重新认证路由和逐来源顺序结果尚未实现。

- [ ] **Step 4: 修改账号页**

`_AccountPanel` 根据 `hasCredentials` 显示：

```dart
Text(account.hasCredentials ? '凭据已保存' : '需要重新登录')
```

把原“重新登录”按钮 key 固定为 `reauthenticate-$accountId`。删除凭据成功后立即
`reload()`，业务数据不变。

- [ ] **Step 5: 修改 SyncPage**

手动“全部同步”调用：

```dart
final outcomes = await widget.coordinator.syncAll(
  trigger: SyncTrigger.manual,
  resolveUserAction: (action) => _confirmInteractiveLogin(action),
);
```

启动自动同步传入 resolver：

```dart
resolveUserAction: (_) async => false
```

`_confirmInteractiveLogin` 只返回用户选择；恢复由 coordinator 在同一来源状态机中执行。
每个 outcome 进入页面状态列表并按 source 展示，不用最后一个结果覆盖前一个。

为重新认证模式增加固定 `reauthenticateAccountId`。提交时调用：

```dart
widget.coordinator.reauthenticate(
  SyncSource.jw,
  accountId: widget.reauthenticateAccountId!,
  username: usernameController.text.trim(),
  password: passwordController.text.isEmpty
      ? null
      : passwordController.text,
  savePassword: savePassword,
)
```

该方法先校验本地身份摘要，再使用已有采集/恢复路径验证网站身份。页面同时显示
`maskedHint`，说明数据将重新绑定到该本地账号。

- [ ] **Step 6: 添加 GoRouter 路由**

```dart
GoRoute(
  path: '/accounts/:accountId/reauthenticate',
  builder: (context, state) => SyncPageLoader(
    database: database,
    reminderReconciler: reminderReconciler,
    reauthenticateAccountId: state.pathParameters['accountId'],
  ),
),
```

账号页 `onLoginAgain` 改为：

```dart
context.push('/accounts/$accountId/reauthenticate');
```

- [ ] **Step 7: 运行 Widget 测试**

Run:

```powershell
E:\flutter\flutter\bin\flutter.bat test test/features/accounts/accounts_page_test.dart test/features/sync/sync_page_test.dart test/app/app_shell_test.dart
```

Expected: 状态、顺序、固定账号重新认证和导航全部通过。

- [ ] **Step 8: 提交**

```powershell
git add app/lib/features/accounts/presentation/accounts_page.dart app/lib/features/sync/presentation/sync_page.dart app/lib/app/router.dart app/test/features/accounts/accounts_page_test.dart app/test/features/sync/sync_page_test.dart app/test/app/app_shell_test.dart
git commit -m "feat: add explicit account reauthentication flow"
```

---

### Task 5: 接通日程详情路由并移除空白区域创建

**Files:**
- Create: `app/lib/features/schedule/presentation/event_detail_loader.dart`
- Modify: `app/lib/features/schedule/presentation/schedule_page.dart`
- Modify: `app/lib/features/schedule/presentation/week_timetable.dart`
- Modify: `app/lib/app/router.dart`
- Modify: `app/test/features/schedule/schedule_page_test.dart`
- Modify: `app/test/features/schedule/week_timetable_test.dart`
- Modify: `app/test/app/app_shell_test.dart`
- Modify: `app/test/accessibility/milestone_accessibility_test.dart`
- Modify: `app/test/goldens/responsive_golden_test.dart`

**Interfaces:**
- Produces route: `/events/:eventId`
- Produces: `EventDetailLoader(database:, eventId:)`
- Changes: `SchedulePage(database:, onEventSelected:, clock:)`
- Removes: `WeekTimetable.onEmptyRangeCreate` 和 `onEmptyAllDayCreate`

- [ ] **Step 1: 写点击日程进入详情的失败测试**

在 `schedule_page_test.dart` 创建 active account 和单个个人事件，向
`SchedulePage` 注入：

```dart
String? selectedId;
SchedulePage(
  database: database,
  onEventSelected: (id) => selectedId = id,
)
```

点击事件后断言 `selectedId == eventId`。在 `app_shell_test.dart` 打开
`/events/$eventId`，断言显示 `EventDetailPage` 中的标题、时间和来源。

- [ ] **Step 2: 写空白区域不再创建的失败测试**

更新 `week_timetable_test.dart`，长按无事件时间格和全天栏后断言没有创建回调，也没有
弹出创建页面。删除测试辅助构造器中的两个空白创建参数。

- [ ] **Step 3: 运行聚焦测试并确认失败**

Run:

```powershell
E:\flutter\flutter\bin\flutter.bat test test/features/schedule/schedule_page_test.dart test/features/schedule/week_timetable_test.dart test/app/app_shell_test.dart
```

Expected: `SchedulePage` 尚无 `onEventSelected`，详情路由尚不存在。

- [ ] **Step 4: 简化 WeekTimetable**

删除：

```dart
final void Function(DateTime day, int minute)? onEmptyRangeCreate;
final ValueChanged<DateTime>? onEmptyAllDayCreate;
```

以及 `_TimedGrid`、全天栏中的 `onLongPressStart`/`onLongPress` 创建逻辑。保留事件点击、
Task 点击、滚动和重叠展开。

- [ ] **Step 5: 接通 SchedulePage 回调**

`SchedulePage` 增加：

```dart
final ValueChanged<String>? onEventSelected;
final ValueChanged<String>? onTaskSelected;
```

事件回调传递 `event.id`，Task 回调传递 `task.id`。删除
`CalendarEventPrefill` 和 `onCreateCalendarEvent` 在周课表中的依赖；全局新增按钮不变。

- [ ] **Step 6: 创建事件详情加载器和路由**

`EventDetailLoader`：

```dart
class EventDetailLoader extends StatelessWidget {
  const EventDetailLoader({
    required this.database,
    required this.eventId,
    super.key,
  });

  final AppDatabase database;
  final String eventId;
}
```

加载 active account 后调用
`EffectiveEventRepository(database, accountId: account.id).byId(eventId)`。
加载中显示进度；`StateError('calendar event not found')` 显示“记录已不存在”和返回按钮。

路由：

```dart
GoRoute(
  path: '/events/:eventId',
  builder: (context, state) => EventDetailLoader(
    database: database,
    eventId: state.pathParameters['eventId']!,
  ),
),
```

`SchedulePage` 使用 `context.push('/events/$eventId')`。

- [ ] **Step 7: 修正所有编译调用点并运行测试**

更新 accessibility/golden 测试中 `WeekTimetable` 构造参数，不重新生成 golden，除非
像素差异确实来自移除空白长按语义。

Run:

```powershell
E:\flutter\flutter\bin\flutter.bat test test/features/schedule/schedule_page_test.dart test/features/schedule/week_timetable_test.dart test/app/app_shell_test.dart test/accessibility/milestone_accessibility_test.dart
```

Expected: 全部通过。

- [ ] **Step 8: 提交**

```powershell
git add app/lib/features/schedule/presentation/event_detail_loader.dart app/lib/features/schedule/presentation/schedule_page.dart app/lib/features/schedule/presentation/week_timetable.dart app/lib/app/router.dart app/test/features/schedule/schedule_page_test.dart app/test/features/schedule/week_timetable_test.dart app/test/app/app_shell_test.dart app/test/accessibility/milestone_accessibility_test.dart app/test/goldens/responsive_golden_test.dart
git commit -m "feat: open schedule event details"
```

---

### Task 6: 接通日程偏好、冲突、主事件、隐藏和个人事件操作

**Files:**
- Create: `app/lib/features/schedule/presentation/event_preferences_sheet.dart`
- Create: `app/lib/features/schedule/presentation/conflict_management_page.dart`
- Modify: `app/lib/features/schedule/application/effective_event_repository.dart`
- Modify: `app/lib/features/schedule/presentation/event_detail_loader.dart`
- Modify: `app/lib/features/schedule/presentation/event_detail_page.dart`
- Modify: `app/lib/features/schedule/presentation/overlap_expansion.dart`
- Modify: `app/lib/features/schedule/presentation/conflict_editor.dart`
- Modify: `app/lib/features/schedule/presentation/week_timetable.dart`
- Modify: `app/lib/app/router.dart`
- Modify: `app/test/features/schedule/overlay_conflict_test.dart`
- Modify: `app/test/features/schedule/week_timetable_test.dart`
- Create: `app/test/features/schedule/event_detail_flow_test.dart`
- Modify: `app/test/features/history/history_test.dart`

**Interfaces:**
- Produces: `EffectiveEventRepository.overlappingRecords(String eventId) -> Future<List<EffectiveEventRecord>>`
- Produces: `EventPreferencesSheet(event:, onSave:)`
- Produces route: `/events/:eventId/conflicts`
- Consumes: `OverlayService.setEventOverlay`、`setForegroundPreference`
- Consumes: `ConflictService.classify`
- Consumes: `CalendarEventService.edit`、`softDelete`

- [ ] **Step 1: 写事件详情操作失败测试**

在 `event_detail_flow_test.dart` 使用内存数据库和测试 Router，覆盖：

```dart
// 学校来源事件
expect(find.byKey(const Key('hide-source-event')), findsOneWidget);
expect(find.byKey(const Key('delete-personal-event')), findsNothing);

// 个人事件
expect(find.byKey(const Key('edit-personal-event')), findsOneWidget);
expect(find.byKey(const Key('delete-personal-event')), findsOneWidget);
```

保存出勤、听讲、备注、颜色后重新加载详情，断言 `EffectiveEventRecord` 读取覆盖值。
隐藏学校事件后断言周课表不显示，但 `CalendarEvent` 和 `UserOverlay` 仍存在。
删除个人事件后断言 `deletedAt != null`，并可由管理页面恢复。

- [ ] **Step 2: 写冲突与主事件失败测试**

创建三个重叠事件，点击组后断言 `OverlapExpansion` 同时显示三项。选择一项进入详情，
再进入冲突页：

```dart
expect(find.byType(ConflictEditor), findsOneWidget);
await tester.tap(find.byKey(const Key('foreground-event-b')));
await tester.tap(find.byKey(const Key('save-conflicts')));
```

断言：

- 选定事件的 `foregroundPriority` 高于同组其他事件；
- `ConflictService` 保存的 pair 为 `conflict` 或 `nonConflict`；
- `confirmed conflict` 与 foreground priority 互不改写；
- `EventBlock` 对冲突显示红色圆圈感叹号。

- [ ] **Step 3: 运行聚焦测试并确认失败**

Run:

```powershell
E:\flutter\flutter\bin\flutter.bat test test/features/schedule/event_detail_flow_test.dart test/features/schedule/overlay_conflict_test.dart test/features/schedule/week_timetable_test.dart
```

Expected: 偏好 sheet、冲突路由和详情操作尚未接通。

- [ ] **Step 4: 实现重叠记录查询**

`overlappingRecords(eventId)` 先用 `byId(eventId)` 读取目标，再查询同账号、未删除、时间
区间相交的事件 ID：

```sql
candidate.start_at < target.end_at
AND candidate.end_at > target.start_at
```

全天事件按日期区间相交判断。返回值再通过 `byId` 生成有效记录，并应用 Task 1 的
presence 规则；不把 `missing_within_scope` 事件加入冲突处理。

- [ ] **Step 5: 实现偏好编辑 Sheet**

`EventPreferencesSheet` 使用 Dropdown、文本框和颜色 swatch 编辑：

```dart
OverlayMutation(
  attendancePolicy: selectedAttendance,
  attendanceNote: attendanceNote,
  listeningMode: selectedListening,
  listeningNote: listeningNote,
  color: selectedColor,
  userNotes: userNotes,
)
```

保存调用 `OverlayService.setEventOverlay(event.source.id, mutation)`。隐藏使用单独确认后：

```dart
OverlayMutation(hidden: true)
```

详情加载器保存成功后重新加载，而不是依赖旧对象。

- [ ] **Step 6: 接通个人事件编辑和删除**

个人事件编辑打开已有 `CalendarEventForm(initialEvent: ...)`，提交
`CalendarEventService.edit(eventId, submission.event, ...)`。删除经确认后调用
`softDelete(eventId)` 并 `context.pop()`。学校来源详情不呈现删除按钮。

- [ ] **Step 7: 实现冲突管理页**

`ConflictManagementPage` 接收同组 `EffectiveEventRecord`，为所有事件对构造
`ConflictPairDraft`，调用：

```dart
  ConflictService.classifyPair(
  left,
  right,
  state,
  scope: scope,
  reason: reason,
)
```

页面顶部使用 Radio/ListTile 选择一个前景主事件。保存时给选中事件 priority `100`，
其余同组事件 priority `0`。该操作不调用 `classify`，两类数据分别保存。

- [ ] **Step 8: 接通路由与渲染**

增加 `/events/:eventId/conflicts`。详情页仅在 `overlappingRecords` 至少两项时显示
“处理重叠日程”。`OverlapExpansion` 继续保持第一次展开、第二次选择的行为。

`WeekTimetable` 排序时 foreground priority 优先；主事件 opacity 保持轻微透明，
背景事件弱化。冲突图标使用现有 `Icons.error_outline`，红色圆圈语义标签为
“已确认冲突”。

- [ ] **Step 9: 验证操作历史**

扩展 `history_test.dart`，断言隐藏来源事件、删除个人事件、更新覆盖和冲突分类都产生
不含标题、地点或账号明文的安全摘要。

Run:

```powershell
E:\flutter\flutter\bin\flutter.bat test test/features/schedule/event_detail_flow_test.dart test/features/schedule/overlay_conflict_test.dart test/features/schedule/week_timetable_test.dart test/features/history/history_test.dart
```

Expected: 全部通过。

- [ ] **Step 10: 提交**

```powershell
git add app/lib/features/schedule app/lib/app/router.dart app/test/features/schedule app/test/features/history/history_test.dart
git commit -m "feat: manage event preferences and conflicts"
```

---

### Task 7: 将 Task 截止时间改为北京时间日期时间选择器

**Files:**
- Modify: `app/lib/features/tasks/presentation/task_form.dart`
- Modify: `app/test/features/tasks/task_ui_test.dart`

**Interfaces:**
- Keeps: `TaskFormSubmission.deadlineAt`
- Produces keys: `task-deadline-date`、`task-deadline-time`、`clear-task-deadline`
- Removes: 自由文本 `task-deadline` 解析和 `_validateDeadline`

- [ ] **Step 1: 写日期时间选择失败测试**

向 `TaskForm` 注入可控初始时间：

```dart
TaskForm(
  initialNow: DateTime(2026, 7, 27, 10),
  onSubmit: (value) async => submitted = value,
)
```

点击日期按钮选择 `2026-07-30`，点击时间按钮选择 `18:45`，提交后断言：

```dart
expect(submitted!.deadlineAt, DateTime(2026, 7, 30, 18, 45));
```

再测试清除按钮后 `deadlineAt == null`。使用 tester 对 `showDatePicker` 和
`showTimePicker` 的标准控件完成选择，不直接调用私有方法。

- [ ] **Step 2: 运行测试并确认失败**

Run:

```powershell
E:\flutter\flutter\bin\flutter.bat test test/features/tasks/task_ui_test.dart
```

Expected: 仍显示手工文本输入，日期/时间 key 不存在。

- [ ] **Step 3: 实现选择器**

`_TaskFormState` 使用：

```dart
DateTime? deadlineAt;

Future<void> _pickDeadlineDate() async {
  final base = deadlineAt ?? widget.initialNow;
  final date = await showDatePicker(
    context: context,
    initialDate: base,
    firstDate: DateTime(base.year - 1),
    lastDate: DateTime(base.year + 10),
  );
  if (date == null) return;
  final time = deadlineAt == null
      ? const TimeOfDay(hour: 23, minute: 59)
      : TimeOfDay.fromDateTime(deadlineAt!);
  setState(() {
    deadlineAt = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
  });
}
```

时间按钮在未选日期时先采用 `initialNow` 日期。UI 使用两个 ListTile/icon button，
显示完整北京时间；清除使用 `Icons.clear` 和 tooltip。

- [ ] **Step 4: 运行 Task UI 测试**

Run:

```powershell
E:\flutter\flutter\bin\flutter.bat test test/features/tasks/task_ui_test.dart
```

Expected: 标题校验、预计分钟校验和新日期时间用例全部通过。

- [ ] **Step 5: 提交**

```powershell
git add app/lib/features/tasks/presentation/task_form.dart app/test/features/tasks/task_ui_test.dart
git commit -m "feat: pick task deadlines with date and time controls"
```

---

### Task 8: 接通 Task 详情、PlanBlock 和单步撤回

**Files:**
- Create: `app/lib/features/tasks/presentation/task_detail_loader.dart`
- Modify: `app/lib/features/tasks/presentation/task_detail_page.dart`
- Modify: `app/lib/features/tasks/presentation/plan_block_editor.dart`
- Modify: `app/lib/features/schedule/presentation/schedule_page.dart`
- Modify: `app/lib/app/router.dart`
- Modify: `app/test/features/tasks/task_ui_test.dart`
- Modify: `app/test/features/tasks/plan_block_undo_test.dart`
- Create: `app/test/features/tasks/task_detail_flow_test.dart`
- Modify: `app/test/integration/first_milestone_flow_test.dart`

**Interfaces:**
- Produces route: `/tasks/:taskId`
- Produces: `TaskDetailLoader(database:, taskId:)`
- Consumes: `TaskLifecycleService.byId/complete/cancel/reopen/restore`
- Consumes: `PlanBlockService.create/byId/markDone/markSkipped/reschedule/cancel`
- Consumes: `UndoService.canUndo/undo`

- [ ] **Step 1: 写 Task 点击路由失败测试**

在 `task_detail_flow_test.dart` 创建有截止和无截止 Task，分别从周课表截止带和 Task
中心点击，断言路由到 `/tasks/:taskId`，详情显示标题、状态、截止风险和备注。

目标 Task 被软删除后直接打开路由，断言显示“记录已不存在”和返回按钮。

- [ ] **Step 2: 写 PlanBlock 链路失败测试**

在同一测试中：

```dart
await tester.tap(find.byKey(const Key('schedule-task')));
expect(find.byType(PlanBlockEditor), findsOneWidget);
```

选择开始、结束并保存，断言数据库新增 `PlanBlock` 且 `taskId` 正确。重新打开详情，断言
显示该 block；编辑、删除后数据库状态与现有生命周期规则一致。

再为结束后的 accepted block 验证“已执行”“已跳过”“重新安排”三条路径。

- [ ] **Step 3: 写单步撤回失败测试**

创建 block 后断言详情页出现 `task-detail-undo`。点击一次恢复创建前状态；第二次按钮
不可用。完成 Task 并选择取消未来 block 后撤回，断言 Task 和受影响 block 一并恢复。

- [ ] **Step 4: 运行聚焦测试并确认失败**

Run:

```powershell
E:\flutter\flutter\bin\flutter.bat test test/features/tasks/task_detail_flow_test.dart test/features/tasks/plan_block_undo_test.dart test/features/tasks/task_ui_test.dart
```

Expected: Task 路由、PlanBlock 入口或详情撤回尚未接通。

- [ ] **Step 5: 创建 TaskDetailLoader**

加载 active account，并创建共享实例：

```dart
final undo = UndoService(database: database, accountId: account.id);
final blocks = PlanBlockService(
  database: database,
  accountId: account.id,
  undoRecorder: undo,
);
final tasks = TaskLifecycleService(
  database: database,
  accountId: account.id,
  undoRecorder: undo,
  planBlocks: blocks,
);
```

读取 `tasks.byId(taskId)`、该 Task 的 PlanBlock 列表、`planImpact`、`projectTask` 和
`undo.canUndo()`，装配 `TaskDetailPage`。每次 mutation 完成后重新加载。

- [ ] **Step 6: 扩展 TaskDetailPage**

页面增加：

- Task 状态操作：完成、取消、重新打开、受阻/解除受阻；
- PlanBlock 列表及编辑、删除、复核操作；
- key 为 `schedule-task` 的安排时间按钮；
- key 为 `task-detail-undo` 的单步撤回按钮；
- 北京时间格式化的 deadline 和 PlanBlock 时间；
- 已删除目标的明确空状态。

保留现有完成 Task 时“未来 PlanBlock 保留/取消”两阶段确认。

- [ ] **Step 7: 接入 PlanBlockEditor**

创建模式：

```dart
PlanBlockEditor(
  onSubmit: (draft) => blocks.create(
    taskId: task.id,
    title: draft.title,
    startAt: draft.startAt,
    endAt: draft.endAt,
  ),
)
```

编辑模式用现有 block 初始化，提交调用 `move`/`resize`；删除调用 `cancel`。复核重排
调用 `reschedule` 并使用用户新选时间。不要新增执行中状态、完成百分比或实际时长。

- [ ] **Step 8: 接通 SchedulePage 和 GoRouter**

周课表 `onTaskSelected` 和 Task 中心 `onTaskSelected` 都调用：

```dart
context.push('/tasks/$taskId');
```

新增：

```dart
GoRoute(
  path: '/tasks/:taskId',
  builder: (context, state) => TaskDetailLoader(
    database: database,
    taskId: state.pathParameters['taskId']!,
  ),
),
```

- [ ] **Step 9: 运行 Task 与集成测试**

Run:

```powershell
E:\flutter\flutter\bin\flutter.bat test test/features/tasks/task_detail_flow_test.dart test/features/tasks/plan_block_undo_test.dart test/features/tasks/task_ui_test.dart test/integration/first_milestone_flow_test.dart
```

Expected: 详情、PlanBlock、状态操作和单步撤回全部通过。

- [ ] **Step 10: 提交**

```powershell
git add app/lib/features/tasks app/lib/features/schedule/presentation/schedule_page.dart app/lib/app/router.dart app/test/features/tasks app/test/integration/first_milestone_flow_test.dart
git commit -m "feat: connect task details and planning blocks"
```

---

### Task 9: 让完全重置清除账号边界并返回首次登录

**Files:**
- Modify: `app/lib/features/settings/application/settings_service.dart`
- Modify: `app/lib/features/settings/presentation/settings_page.dart`
- Modify: `app/lib/app/router.dart`
- Modify: `app/test/features/settings/settings_test.dart`
- Create: `app/test/features/settings/complete_reset_flow_test.dart`

**Interfaces:**
- Changes: `SettingsService.completeReset(...) -> Future<void>` 清除当前账号及账号级数据
- Produces: `SettingsPage.onCompleteReset`
- Produces: 完全重置成功后 `context.go('/sync')`，`SyncPageLoader` 因无账号显示首次登录

- [ ] **Step 1: 写完整清理失败测试**

在 `settings_test.dart` 为当前账号插入课程、SourceRecord、Overlay、Task、PlanBlock、
Reminder、SourceConfig、ActionLog、UndoSlot 和 Credential。调用：

```dart
await settings.completeReset(
  firstConfirmation: true,
  secondConfirmation: true,
);
```

断言当前账号和上述账号级记录全部为空，`browserClears == 1`。若存在不属于账号的应用级
设置，断言只保留明确允许的安装级设置；Python path 和学期 override 按设计清除。

增加失败保护测试：第二次确认 false 时所有行保持不变。

- [ ] **Step 2: 写重置后导航失败测试**

`complete_reset_flow_test.dart` 使用内存数据库打开设置页，完成两次确认，断言：

```dart
expect(router.routeInformationProvider.value.uri.path, '/sync');
expect(find.byKey(const Key('first-login-username')), findsOneWidget);
```

连续点击期间按钮 disabled，service 只调用一次。

- [ ] **Step 3: 运行聚焦测试并确认失败**

Run:

```powershell
E:\flutter\flutter\bin\flutter.bat test test/features/settings/settings_test.dart test/features/settings/complete_reset_flow_test.dart
```

Expected: `LocalAccount` 尚未删除，或重置后仍停留在设置页。

- [ ] **Step 4: 实现事务性账号清理**

`completeReset` 在确认后按外键依赖顺序、同一 Drift transaction 清理当前
`accountId` 的所有数据库记录，最后删除 `local_accounts`。优先依赖数据库外键级联；
没有级联的表显式按 `accountId` 删除。数据库事务成功后再：

```dart
await accounts.clearDedicatedBrowserSession();
```

凭据删除包含在账号清理中；浏览器清理失败时数据库已明确完成，UI 显示“本地数据已
清除，但浏览器会话清理失败”，不得恢复一个部分删除的账号。

- [ ] **Step 5: 接通导航**

`SettingsPage` 增加：

```dart
final VoidCallback? onCompleteReset;
```

`_completeReset` 成功后仅调用一次该回调。Router 的 `_SettingsLoader` 传入：

```dart
onCompleteReset: () => context.go('/sync')
```

Sync loader 查询不到 active account 时显示现有首次登录表单。

- [ ] **Step 6: 运行设置测试**

Run:

```powershell
E:\flutter\flutter\bin\flutter.bat test test/features/settings/settings_test.dart test/features/settings/complete_reset_flow_test.dart
```

Expected: 完整清理、双确认、防重复和首次登录导航全部通过。

- [ ] **Step 7: 提交**

```powershell
git add app/lib/features/settings app/lib/app/router.dart app/test/features/settings
git commit -m "fix: return to first login after complete reset"
```

---

### Task 10: 全量回归、Release 构建与人工复测准备

**Files:**
- Modify only if tests reveal a directly related regression:
  - `app/test/integration/first_milestone_flow_test.dart`
  - `app/test/accessibility/milestone_accessibility_test.dart`
  - `app/test/goldens/responsive_golden_test.dart`
- Read without overwriting user results:
  - `docs/acceptance/windows-first-milestone.md`

**Interfaces:**
- Consumes: Tasks 1-9 的全部公开行为
- Produces: 可供人工复测的 Windows Release 可执行文件

- [ ] **Step 1: 运行 Python 全量测试**

Run from repository root:

```powershell
conda run -n ustc_assistant python -m unittest discover -s tests -v
conda run -n ustc_assistant python -m compileall -q src tests
```

Expected: 所有 Python 测试通过，compileall 无输出、退出码 0。

- [ ] **Step 2: 运行 Flutter 全量测试**

Run from `app/`:

```powershell
E:\flutter\flutter\bin\flutter.bat test
```

Expected: 全部通过。若 golden 因本次可见 UI 修复产生预期差异，先人工检查生成图片没有
文字溢出、控件重叠或周末缺失，再仅更新对应 golden。

- [ ] **Step 3: 运行静态分析**

Run:

```powershell
E:\flutter\flutter\bin\flutter.bat analyze
```

Expected: `No issues found!`

- [ ] **Step 4: 构建 Windows Release**

Run:

```powershell
E:\flutter\flutter\bin\flutter.bat build windows --release
```

Expected: 生成
`app/build/windows/x64/runner/Release/ustc_assistant_app.exe`。

- [ ] **Step 5: 检查仓库状态和敏感文件**

Run from repository root:

```powershell
git status --short
git diff --check
git diff --name-only HEAD
```

Expected:

- `tmp/`、`temp.md`、浏览器 Profile、SQLite、凭据和原始响应没有进入 Git；
- 用户的 `docs/acceptance/windows-first-milestone.md` 修改仍保留且未被重写；
- 没有无关生成文件或依赖锁文件漂移。

- [ ] **Step 6: 向用户报告自动验证并请求人工复测**

按验收文档只复测原失败项：8、13、18、19、20、21、22、24、25、26、36、39，以及
此前未完成的 14、15。真实学校页面需要用户登录时立即同步说明当前来源和等待动作。

不要代替用户填写“完成：”结果；由用户实际操作后记录。

- [ ] **Step 7: 在人工复测通过后提交必要的测试文档变更**

只有用户明确确认复测结果并允许提交时，才执行：

```powershell
git add docs/acceptance/windows-first-milestone.md
git commit -m "docs: record Windows milestone repair acceptance"
```

如果用户尚未完成复测，本任务停在自动验证和 Release 构建完成状态，不伪造验收结论。
