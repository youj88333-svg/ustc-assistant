# M0 实施与检查记录

> 保留发生时的规格、失败、修复和检查；旧“待验/未关闭”不是当前状态。当前范围见 [任务单](plan.md)，最终结论见 [验收](acceptance.md)。正文只迁移链接，保留当时叙述。

#### M0 实际交付与主代理检查（2026-10-09）

装配源码在 [app/lib](../../../app/lib)，运行说明在 [app/README](../../../app/README.md)。最终 Release 位于 `app/build/windows/x64/runner/Release/ustc_assistant_m0.exe`，需保留同目录 DLL、`data/` 与原生资源。默认独立目录为 `%TEMP%\ustc_assistant_m0_demo_v1`；未创建正式用户数据库或浏览器分区，未读取/改写旧工程资产，未访问学校或模型服务，未推送或提交。

主代理在 `app/` 用 `E:\flutter\flutter\bin\flutter.bat` 执行：

| 实际命令 | 最终结果与证据范围 |
|---|---|
| `doctor -v` | Windows、Visual Studio、Windows SDK 与既有代理可用；Android/Chrome 提示与本切无关 |
| `pub get --offline` | 成功，固定依赖并生成新 lockfile；原生 hook 随首次 test/build 完成 |
| `analyze --no-pub` | exit 0；全工程无问题 |
| `test --no-pub` | exit 0；43 项通过，包含下述真实进程测试；不是沿用实验或旧工程结果 |
| `test integration_test/m0_flow_test.dart -d windows --no-pub` | exit 0；真实 Windows Debug 窗口一条用户链路通过：正常采集、重放、不完整/存储失败、取消、收口重试、已提交待办、关闭组合根再重开、旧作业失效和待办重试 |
| `build windows --no-pub` | exit 0；Release 可执行目录已生成 |

契约和主代理复核确认：C1 不依赖 C3/平台/Flutter，C2 映射封存产物到 C3；目录能力先于数据库打开，组合根以 coordinator → controller.dispose → store.close → directory.release 顺序关闭；单来源只有 SyntheticSource，五条真实来源与 Agent 明确尚未接入。C3 的记录/回执/安全计数审计/汇总待办同事务提交；身份/版本/epoch/维护复验位于事务内。完整空快照保留 localId 并标缺失，再次观察清除缺失；取消先受理零导入，提交先完成返回 alreadyCommitted，不伪报无修改。

`transaction_recovery_test.dart` 在随机隔离目录构建包含 sqlite3 hook 资产的 Dart CLI 助手：一次在首条 SQL 写入后强制终止、一次在 commit 返回后终止；重开实际文件分别断言全部零提交、全部已持久，并重放回执及重试 pending。`platform_ownership_test.dart` 的实际第二进程、强杀退出重取、大小写/点别名、祖先/目标 junction、rename 固定、DB/WAL/SHM 异常类型和持有权失效通过。界面测试另覆盖 1280×800、800×600 无溢出及乱序读取保护。测试关闭所有资源并校验绝对目标在其随机临时根下后清理，不删除默认演示数据。

实施中保留的失败及修复：普通 sandbox 中 Flutter/Dart 因 SDK 缓存锁或 resolvedExecutable 异常未执行成功，切换本任务允许的 SDK 缓存访问后恢复；Dart `compile exe` 在非 ASCII TEMP 路径读取中间 dill 失败，改用仅编译子进程的 ASCII 临时目录后可编译，但该单 exe 未绑定 sqlite3 原生资产，首次进程恢复测试两例均失败。随后改用 `dart build cli` bundle，在相同两例重跑及最终全套中通过，生产 Flutter hook 仍按常规构建。本次不修改全局 TEMP、PATH 或 7897 代理。另修正收口失败后即时重试被异步 `_work` 清空延迟拒绝的问题，保留无 sleep 的公开行为回归；C1/C3 长度上限统一，重启时补明确的持久待办状态文案。上述失败不是人工验收记录，未改写为先前已通过。

独立 Sol / high 针对提交事实、取消/恢复和排空退出作只读集成复核，未发现新的可确认 M0 缺陷；主代理仍独立跑上述全套。**实施交付时尚未执行**：用户人工启动/采集/取消/恢复、真实窗口关闭后再启动的体验验收；随后用户确认另记如下。native `CloseHandle` 失败注入仍未执行，失败分支静态保持未释放并返回 ownershipLost。Windows 自动集成直接装配 M0App，不能代替实际窗口关闭回调证据；用户的窗口行为确认也不新增内部 `onExitRequested` 跟踪证据。M0 排他针对合作应用实例，不承诺同用户恶意程序持续替换子文件的防御。上述局限保留，不以新增安全框架扩大本切。

交付时提供的本地人工检查入口：运行 Release，依次体验正常/取消/收口失败重试/待办失败，关闭窗口并重开后检查待办和记录保留、第二实例被拒绝。确认到来前只记“实现及自动验收完成”，不记用户通过或 M0 正式关闭；真实来源、浏览器/凭据、完整数据/Task/Agent/提醒与整体冻结仍按各自切片验证。

最终文档检查通过：15 个当前有效区/入口、148 个本地链接及 15 个锚点无错误，07–15 九份历史正文与 HEAD 的换行归一内容相同，01–06 无差异；`git diff --check` 通过。用户此前未提交的设计修订和前置验证记录保留。

## 工作流临时试验

此前一次临时快照导入试验中，Sol 定规格、Luna 实现、Sol 复核，9 组独立验收首次全部通过，无需实现返工；临时目录和两个实验文件已清理。该结果支持边界明确的小任务采用此分工，尚不能证明整个 M0 的额度收益或正式验证通过。
