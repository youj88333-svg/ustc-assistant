# 重构交接文档（handover）——设计冻结 go ｜ M0 施工待开工

> 产出日期：2026-08（本会话） ｜ 状态：**设计阶段全部完成，go 已由用户重认；
> `rewrite/flutter-native` 分支 + 专属 worktree 已建好，未写任何代码，
> M0 实施交下一 session** ｜ 本文档取代旧快照（旧 handover 止于 `f7dd71c`，
> 曾按用户决定对第 6 层保持不动；现在用户要求重写为最新现状）。
> 本文件是给下一个 session 的接手路径；私有速查见工作区 `temp.md`
> （gitignored，若存在，不在仓库）。

## 1. 一句话状态

USTC 校园助手"整体重构"已完成**设计阶段**（六层阶梯 07–13 全部关闭 + 总体审查
`14-overall-review.md` 整改后通过 + 用户重认 go）。本会话又产出
`15-construction-methodology.md`（施工方法论），并把 M0 从"空骨架"升级为
**Walking Skeleton（fake source 打穿 0–2 层全链路）**。工作区已按铁律建好：
分支 `rewrite/flutter-native` + 专属 worktree，**当前干净、零实现提交**；
下一 session 的任务就是在这条分支上做 M0，不得在 main 写任何重构代码。

## 2. 已交付清单与 gate 状态

| 产出 | 状态 | 关键数字 |
|---|---|---|
| 07 宪法（层 0） | ✅ 关闭（四轮复审） | ADR-000~023（24 条）、D01–D38（D18 取消） |
| 08 目标架构（层 1） | ✅ 关闭 | C0–C5 + P 平台容器；11 场景；L1-01~15 |
| 09 全局契约（层 2） | ✅ 关闭 | CT 65 条矩阵、v8 变更集 7 项（v8=30 表）、错误码表 §2.4、类型词汇表 §2.5、L2-01~22 |
| 10 链路走查（层 3） | ✅ 关闭 | 五链路 + 五管道、边界表 17 行、L3-01~06 |
| 11 组件设计（层 4） | ✅ 关闭 | D-01~D-11 完整转移表 + 待补登记（每块开工前补设计纪律生效）、L4-01~04 |
| 12 横切关注（层 5） | ✅ 关闭 | XC-01~16、L5-01/03/04/06/07/08 |
| 13 风险验收（层 6） | ✅ 关闭（独立审查"整改后通过"+ 用户重认） | R-01~R-20 每条五字段（描述/来源/触发/验证/关闭标准）、gate 6/6 勾选 |
| 14 总体审查 | ✅ 完成 | A/B/C/D 四轮：claim 全绿、13 场景走查、5 透镜红队 7A 全闭环、**go 已由用户重认**；遗留 5 项低优先级（见 §8） |
| 15 施工方法论 | ✅ 生效 | Walking Skeleton/竖切/契约先行/绞杀榕开关/oracle CI/每切 DoD（M0 起必读） |

总体审查中最重要的 7 个 A 级修复（已全部闭环，勿重开）：`inspectUserText→
privacy_rejected` 预检与 icourse 授权入 09 契约；09 §2.5 类型词汇表消灭悬空类型；
D-04 撤销槽失败=整事务回滚；D-06 补 `maintenance_draining × end_maintenance`
abort 行；completeReset 严格清理 v7 备份；迁移备份改 WAL checkpoint + SQLite
在线备份 + integrity_check。

## 3. 工作区现状（接手前必查）

- **main 检出**：`E:\107`，分支 `main`；重构代码冻结（只接受致命 bug 修复与
  设计文档变更）。
- **施工检出**：`E:\107\.worktrees\rewrite\flutter-native`，分支
  `rewrite/flutter-native`，基准 = main 本文件提交（运行 `git log -1` 确认）；
  已 `git status` 验证干净。**M0 的一切代码改动只发生在这个 worktree。**
- 其他 worktree 属于旧分支，**不要动**：`.worktrees/delete-tools-plan`
  （feature/delete-tools）、`.worktrees/flutter-native-jw-v2`、
  `.worktrees/flutter-native-source-roadmap`。
- 永不提交：`.statusline-test/`、`_merge-pending-docs/`（用户私有目录，在 main
  检出区；worktree 中不会出现）。
- 永不修改：用户验收文件（`docs/agent-manual-acceptance-retest-*.md`、
  `_merge-pending-docs/` 内文件）；不得替用户把失败项改成成功。

## 4. 接手阅读顺序（下一 session）

1. 本文件（当前现状与红线）
2. `AGENTS.md`（总纲：六层阶梯/里程碑/四铁律/验证命令；注意 M0 行已更新）
3. `docs/refactor-docs/15-construction-methodology.md`（施工纪律，M0 起必读）
4. `docs/refactor-docs/14-overall-review.md`（go 裁决原文 + §6 遗留清单）
5. `docs/refactor-docs/00-index.md` §0（07–15 导航表）
6. M0 规划直接依据：`08-target-architecture.md`（容器切分/工程布局/依赖方向）、
   `09-contracts.md`（本里程碑涉及的 CT 契约与错误码）
7. `01–06` 模块文档 + main 代码：旧房现状参考（oracle/fixture 资产溯源）

## 5. 下一 session 的任务：M0（Walking Skeleton）

范围以 `15-construction-methodology.md` §3.1 + AGENTS M0 行为准：

```text
SourceChannelRegistry（每源一通道开关，fake 为第一源，默认其余源指向 Python 通道）
  → NativeFakeGateway ──产出── SourceBundle 1.0 字节流（09 契约形态）
  → JobArbiter 雏形（作业生命周期端口）
  → 采集引擎端口（事件顺序/ready 语义以 fake 驱动先串通）
  → normalize → validate → ImportPort（M0 用 throwaway skeleton.db，不建 v7/v8 正式表）
  → 结果查询（导入汇总 + 错误码）
```

- **门禁**：`flutter analyze` / `flutter test` / `flutter build windows --release`
  全绿 **且** fake 源 E2E smoke 契约测试通过。
- **横切项第一周点亮**：Asia/Shanghai 时钟注入、结构化日志、错误码枚举、
  依赖注入/可测试装配（15 §3.1）。
- **先规划后施工**：建议先在 worktree 内产出 M0 实施计划
  （`docs/superpowers/plans/YYYY-MM-DD-m0-walking-skeleton.md`），计划必须逐条
  对照 08/09 论证；可用技能：`writing-plans`、`subagent-driven-development`
  或 `executing-plans`、`test-driven-development`、`verification-before-completion`。
- **契约先行**：先写 09 相关契约的可执行测试，再写实现（15 纪律 3）。
- **禁止**：真实学校访问/真实验收进入自动测试；M0 只用 fake source。
- **施工分支纪律**：短功能分支合入 `rewrite/flutter-native`，每次合入三件套全绿；
  main 只进设计文档。
- **gate 铁律**：自动验证通过 ≠ 里程碑关闭；M0 关闭需用户重认，agent 不得
  自行宣布 gate 关闭。

## 6. 施工纪律速查（详见 15 号文档）

1. 骨架先行：M0 是能走通全链路的 Walking Skeleton，不是空工程。
2. 竖切交付：每条来源一条穿过所有层的完整切片；M2 顺序 = 契约测试 → 引擎在
   loopback 上做完整 → JW 适配器 → oracle 对比 → 真实验收。
3. 契约先行：契约测试在实现之前，CI 常驻。
4. 绞杀榕开关：`NativeXxxGateway/PythonXxxGateway` 并存、同源同刻单通道；
   gate 通过才拨 native；每里程碑打 tag 可回退。
5. oracle 常驻：冻结 fixture 只增不修；Python oracle 对比纳入 CI，差异必须登记。
6. 每切 DoD：功能 + 契约测试 + 时区/隐私/错误码/审计/可观测/账号隔离 +
   三件套全绿 + 风险勾选，横切当切当场勾完（不允许"最后一批补横切"）。

## 7. 决策登记分布地图

| 决策类 | 位置 |
|---|---|
| 红线 / ADR / D01–D38 | 07 §2/§4/§3 |
| 层 1 拍板 | 08 §11 L1-01~15 |
| 层 2 拍板与全部回写 | 09 §13 L2-01~22（L2-22 = 总体审查回写） |
| 层 3/4/5/6 拍板 | 10 §11 L3-01~06 ｜ 11 §8 L4-01~04 ｜ 12 §4 L5-01/03/04/06/07/08 ｜ 13 §5（L6 无新增拍板） |
| 错误码注册表 | 09 §2.4（含 privacy_rejected/consent_required/sync_failed/migration_failed 等） |
| 类型词汇表 | 09 §2.5（SyncSource/SyncOutcome/FirstLoginOutcome/WriteProposal 系列等） |
| v8 schema 变更集 | 09 §7.2（7 项，v8=30 表；冻结后变更须开 ADR） |

## 8. 遗留低优先级（14 §6，不阻塞 M0）

1. campus 三表字段级写/读方细化——M1 实施前补。
2. 09 契约矩阵"所有者"列——下一次文档修订顺手做。
3. CT-C3 快速索引表——下一次文档修订顺手做。
4. 容器内部契约标注为 CT-C0/CT-T 前缀——下一次文档修订顺手做。
5. 11 待补状态机 D-19/D-26/D-17/D-18/D-29/D-30——按"每块开工前补设计"纪律，
   在对应 M1/M2/M5 开工前补完（触发器已登记在 11 §6）。

## 9. 关键提交链（主线）

`e9d64dd`（基线）→ … → `970cb88`（层 5 收口）→ `bd3bec7`（层 5 整改）→
`f7dd71c`（层 5 关闭）→ `5e3c4c4`（08 D22/D23）→ `20fe20f`（13 草案）→
`af1428c`（13 审查整改）→ `e5eac09`（层 6 关闭）→ `80b85e5`（总体审查整改批，
9 文件 +250/−95）→ `e61101c`（总体审查收尾 + 14 报告）→ `1c66c76`（15 施工
方法论 + M0 门禁升级 + 14 go 状态）→ 本文件提交。
完整日志：`git log --oneline`。

## 10. 验证命令（在施工 worktree 内运行）

```powershell
Push-Location E:\107\.worktrees\rewrite\flutter-native
E:\flutter\flutter\bin\flutter.bat analyze
E:\flutter\flutter\bin\flutter.bat test
E:\flutter\flutter\bin\flutter.bat build windows --release
Pop-Location
```

M0 阶段不需要 Python 测试；M1 起涉及 SourceBundle fixture/oracle 时按
`AGENTS.md` 验证节补跑两侧全套。每次提交前必跑 `git diff --check`。
