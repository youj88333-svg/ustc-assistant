# Minimal JW Runtime 局部重构设计

日期：2026-08-30
分支：`refactor/webview-minimal`
参考实现：只读 `rewrite/flutter-native`
状态：待主人审核

## 1. 背景与问题

minimal 只保留教务、日程表与本地 Agent。当前原生 WebView2 链路已经具备严格
目标识别、课程/考试采集、SourceBundle 构造与 Windows 自动化验证，但真实验收暴露出
两个结构性问题：

1. 无活动账号时登录与完整重置曾不可达；
2. reset、路由、WebView environment、同步/import、Reminder 与 Agent writer 缺少单一
   所有权边界，逐项补丁容易产生 teardown、UDF 删除与后台写入竞态。

继续给现有页面级 gateway 生命周期打补丁，复杂度已接近重构；整体采用全量分支又会带入
多来源、多租户和 container 框架，不符合 minimal。选择局部重构：移植全量分支的所有权
与端口思想，只重写 JW runtime/reset 闭环，保留 minimal 的功能和数据模型。

## 2. 目标与非目标

### 2.1 目标

- 应用进程内只有一个 `MinimalJwRuntime` 和一个 WebView2 environment owner。
- 登录、同步、取消、重试与 Python fallback 共用一个 job arbiter，不并行、不双写。
- WebView controller、surface、environment release、UDF 与 quarantine 由一个 session admin
  完整拥有。
- 首次登录在身份与完整 bundle 验证前不写入账号或业务数据。
- minimal 永远只有一个账号；重登等价于完整 reset 后重新首次登录。
- 完整 reset 先静默所有 writer，再清库/凭据/UDF；任何物理清理失败都 fail closed。
- 无账号和 reset-failed 状态均有明确、可操作、可恢复的 UI。

### 2.2 非目标

- 不移植全量分支的多来源、多租户、campus/young/icourse 或通用 container 体系。
- 不修改 SourceBundle 1.0 契约或 Drift schema。
- 不删除 Python Bridge fallback；它仍是显式、互斥的兜底通道。
- 不实现 Android/iOS 真实 WebView。
- 自动化验证不替代真实校园网验收。

## 3. 架构边界

### 3.1 `MinimalJwRuntime`

应用 composition root 创建唯一 runtime。它拥有：

- `JobArbiter`；
- `SourceJobGateway`；
- `BrowserSessionAdmin`；
- 稳定的 WebView surface host；
- runtime 状态流与 shutdown Future。

路由、页面和 widget 只借用 runtime，不创建或销毁 environment。页面销毁只能改变 surface
可见性；应用级 shutdown/reset 才能释放 runtime。

### 3.2 `JobArbiter`

arbiter 以同步 check-and-hold 获取唯一 lease，覆盖：

- 首次登录；
- 手动同步；
- 重新开始已取消任务；
- Python Bridge fallback；
- reset maintenance。

lease 只在 terminal settlement 与清理完成后释放。重叠请求返回稳定 `bridge_busy`，不得在
检查与持有之间出现 `await`。

### 3.3 `SourceJobGateway`

UI 唯一调用入口，只暴露：

- `firstLogin`；
- `sync`；
- `cancel`；
- 当前 job/state stream；
- `shutdown`。

gateway 不暴露 controller、UDF path 或 platform 对象。Native 与 Python fallback 在 gateway
内互斥选择，不能同时运行或写库。

### 3.4 `BrowserSessionAdmin`

session admin 唯一负责：

- 由单账号的 opaque token 解析受控 UDF；
- controller 创建与订阅；
- surface attach/detach；
- stop、subscription disposal、controller disposal；
- 等待 WebView2 browser-process/environment release barrier；
- UDF quarantine、有限重试与物理删除。

admin 在 release 成功前始终保留 controller 所有权。创建或释放失败会 quarantine 当前 UDF，
禁止后续登录或物理删除冒充成功。

### 3.5 `MinimalResetCoordinator`

reset coordinator 是 composition root 中的固定依赖集合，不采用动态 participant 注册表。
它显式持有：

- `MinimalJwRuntime`；
- `SyncCoordinator` / import settlement port；
- Agent session quiesce port；
- Reminder reconciler quiesce port；
- Settings/global reset port。

固定依赖使 minimal 的 writer 清单可审计，避免演化成通用 lifecycle framework。

## 4. 首次登录与同步数据流

### 4.1 首次登录

1. UI 挂载 runtime 的稳定 surface。
2. gateway 同步获取 arbiter lease。
3. username/password 只存于 provisional 内存对象；不创建本地账号。
4. session admin 打开唯一 UDF 和 controller。
5. 浏览器执行严格 URL、DOM、document-complete 与 registered-handshake convergence。
6. 密码为空时只填用户名，等待用户在可见 WebView 手动提交；非空时才自动提交。
7. 严格验证 authoritative username 与 expected username。
8. 采集课程与考试；任一来源契约变化时整体失败，不产生部分 bundle。
9. 构造并验证完整 SourceBundle 1.0。
10. 在一个事务中提交账号、受保护凭据、JW 数据、同步记录和必要审计。
11. terminal settlement 后释放 job lease。

任意失败或取消都清零密码字节并丢弃 provisional 对象，不留下半账号、空分区或半导入。

### 4.2 已有会话

会话复用不能仅凭 URL。每次采集前仍执行严格 home convergence、registered handshake 与
expected-account identity proof。冲突映射为稳定 `account_mismatch`，不得继续采集。

### 4.3 取消

取消具有 terminal 优先级：

- 停止接受 collector 成功结果；
- 清理 pending login identity；
- 等待 collector/session/controller settlement；
- 不导入晚到数据；
- cleanup 完成后才释放 lease。

## 5. 完整 Reset 与单账号重登

重登不保留账号分区，等价于完整 reset 后首次登录。固定顺序为：

1. 进入 maintenance，关闭新 job、同步、Agent 写入与 reminder 写入入口；
2. cancel 并等待当前 JW job terminal settlement；
3. detach surface、stop、dispose subscriptions/controller，并等待 environment release；
4. 等待 Sync/import、Agent session、Reminder reconciler quiesce；
5. 在受控事务中清除全部 Drift 表、凭据、历史和撤回槽；
6. 对全部受控 UDF 子项做 containment 校验并逐一删除；锁占用仅进行有限重试；
7. 即使一个 UDF 失败，也继续尝试其余项并保留第一个脱敏错误；
8. 任一 UDF 或 writer 清理失败则进入 `reset_failed`，保持 maintenance，不恢复 writer、
   不创建新 runtime、不进入登录；
9. 重试 reset 复用同一恢复边界，允许数据库已空但 UDF 尚未清完；
10. 全部成功后重新组合 runtime，返回唯一无账号状态。

完整 reset 保留现有双确认。任一确认取消都不写入、不删除，并展示明确取消结果。

## 6. UI 状态机

```text
preparing
  -> unconfigured
  -> login_visible
  -> collecting
  -> configured

configured/unconfigured
  -> reset_confirm_1
  -> reset_confirm_2
  -> resetting
  -> unconfigured

resetting failure
  -> reset_failed
  -> retry_reset
```

- `unconfigured` 始终显示“登录教务”和“清除全部数据”。
- `reset_failed` 只允许显示脱敏错误、重试 reset 或退出应用。
- `reset_failed` 禁止登录、同步和后台 writer 恢复。
- `/sync`、reauth 和普通路由切换不得创建第二个 runtime/environment。
- 页面 await 后必须检查 `mounted`；dispose 后不得访问 controller 或路由 callback。

## 7. 错误、安全与隐私

- 只暴露稳定 error code、脱敏阶段与非负聚合数量。
- 不记录 username、password、Cookie、CAS ticket、URL query、DOM、响应正文或私人课表。
- UDF token 使用账号摘要，不使用账号原文；删除目标必须是 canonical root 的直接受控子项。
- reparse/symlink、root 自身、父目录、未知文件名与 containment 不确定时一律拒绝删除。
- cleanup 尽量执行所有步骤，保留并抛出第一个稳定失败；不得用后续成功覆盖前一步失败。

## 8. 迁移策略

用户已授权后续实施时放弃当前未提交的代理 lifecycle/reset 中间代码，基于提交
`600b3db` 重新实现本设计。实施前必须：

1. 将暂停 diff 保存为审计材料；
2. 精确识别并仅清理代理产生的 lifecycle/reset 未提交文件与 hunks；
3. 严格保留用户原有未提交的 `app/pubspec.yaml`、`app/pubspec.lock`、
   `baseline_head.txt`、`jw-debug.log`；
4. 不重置、覆盖或清理其他用户改动。

迁移分阶段完成：先所有权/runtime，再 session admin，再首次登录事务边界，再 reset，最后
切换 UI composition。每阶段有独立回归与 review，禁止一次性大爆炸替换。

## 9. 验证与验收

### 9.1 自动化

- arbiter 原子 lease 与 terminal release；
- runtime 单实例、页面 push/pop/reopen 不重建 environment；
- strict identity、manual/automatic login、取消后重试；
- session admin detach/stop/dispose/release 顺序；
- UDF containment、quarantine、有限重试与失败后重试；
- reset 期间 active JW、Sync/import、Agent、Reminder writer 的竞态；
- reset 首项 UDF 失败但后续仍尝试；失败后不进入 fresh login；
- Windows 真实 WebView2 loopback；
- 当前 worktree Python oracle 140 项与 compileall；
- 同一终端严格串行 Flutter `analyze -> test -> build windows --release`。

### 9.2 真实校园验收

自动化全绿后，用户在可见窗口亲自输入凭据，执行：

```text
CAS entry
-> identity verified
-> course context/get-data/datum
-> exam table
-> SourceBundle built
-> imported
-> schedule/exams visible
```

只记录脱敏 stage、aggregate count 与稳定 error code。未完成此链路前不得声称真实校园验收
通过；Android/iOS 仍为外部边界。

## 10. 采用的全量分支思想与明确排除项

采用：

- `JobArbiter` 的同步 check-and-hold；
- runtime bundle 的集中 ownership 与逐步 shutdown；
- session admin 保留 controller 直至 native release 成功；
- UDF store 的 opaque token、quarantine、containment 与有限删除重试；
- provisional first-login 在 bundle 完成后才提交。

排除：

- 多来源 channel registry；
- 多租户 Python lifecycle；
- campus/young/icourse；
- 通用 container 分层迁移；
- session snapshot 持久化；
- 与 minimal 目标无关的数据库重构。
