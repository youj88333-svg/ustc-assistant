# 15 施工方法论（Construction Methodology）

> 产出日期：2026-08（本会话） ｜ 状态：**生效**（用户已重认设计 go，M0 按本文档开工）
> ｜ 定位：0–6 层设计之后的**施工纪律文档**。本文不改变 07–13 的任何契约、风险、
> 关闭标准或红线；只规定"怎么写、按什么顺序写、每一块怎样算完成"。
> ｜ 优先级：与 07–13 冲突时，红线与四铁律（07）最高，接口契约（09）次之，
> 本文只调整施工顺序与完成定义（DoD），不改语义。

## 1. 为什么要这份文档：旧房病根诊断

旧房 v2 试做的失败模式有明确记录：**最后一批提交全部在补"导航就绪归属、URL/事件
顺序、ready 握手"等横切问题**。病根不是"逐块实施"本身，而是三个叠加：

1. **横向铺开、集成押后**：共享基础设施被当作单链路附属品硬做，全链路第一次跑通
   发生在里程碑末段，边界时序问题集中爆发，debug 只能跨层猜测。
2. **契约没有机器强制**：接口只写在文档里，生产者和消费者各写各的，合并时才
   发现错位。
3. **横切关注被当作"最后再补"**：时区、事件顺序、错误码、可观测性没有进入每块
   的完成定义，于是堆积成"最后一批补丁"。

对策不是"不许逐块做"（M0–M8 分里程碑是既定路线，必须保留），而是换成成熟的
**骨架先行 + 竖切交付 + 契约护栏 + 绞杀榕开关 + oracle 安全网**。

## 2. 方法论选型与出处

| 方法论 | 解决什么 | 出处 |
|---|---|---|
| Walking Skeleton（Cockburn） | 最早打通一条穿过所有层的细骨架，横切问题第一周暴露 | [Walking Skeleton – Alistair Cockburn](https://web.archive.org/web/20130924061832/http://alistair.cockburn.us/Walking+skeleton) |
| Tracer Bullets（《程序员修炼之道》） | 先校准端到端弹道（时序/握手/反馈），再建重型实现 | [Tracer Bullet](https://www.metaphorex.org/entries/tracer-bullet/) |
| Vertical Slice Architecture | 每个增量是一条穿过所有层的完整功能切片，可运行可定位 | [Vertical Slice Architecture – SSW Rules](https://www.ssw.com.au/rules/vertical-slice-architecture) |
| Strangler Fig + Branch by Abstraction | 新旧并存、按来源逐条接管、任何时刻可拨回旧通道 | [Strangler Fig – AWS](https://docs.aws.amazon.com/prescriptive-guidance/latest/modernization-decomposing-monoliths/strangler-fig.md) ｜ [Strangler Fig with Mobile Apps – Martin Fowler](https://martinfowler.com/articles/strangler-fig-mobile-apps.html) ｜ [Branch by Abstraction – AWS](https://docs.aws.amazon.com/prescriptive-guidance/latest/modernization-decomposing-monoliths/branch-by-abstraction.md) |
| Consumer-Driven Contract Testing | 契约成为 CI 机器强制，生产者/消费者并行开发不背刺 | [CDC Testing – Code with Engineering Playbook](https://raw.githubusercontent.com/Horlando-Leao/code-with-engineering-playbook/main/docs/automated-testing/cdc-testing/README.md) |
| Golden Master / Characterization Tests | 旧房即 oracle，逐字段对比，差异必须登记 | [Characterization test – Wikipedia](https://en.m.wikipedia.org/wiki/Historical_oracle) ｜ [How to test legacy software when modernising – Codurance](https://www.codurance.com/publications/how-to-test-legacy-software-when-modernising) |
| 测试金字塔 + 短分支持续集成 | 快速反馈，集成债不跨夜 | [Testing Pyramid – TestSigma](https://testsigma.com/blog/testing-pyramid/) ｜ [Branching & CI/CD – Microsoft Engineering Playbook](https://microsoft.github.io/code-with-engineering-playbook/agile-development/branching-and-cicd/) |
| Mikado Method | 高风险迁移步步可退，不搞 big-bang | [The Mikado Method – Manning](https://livebook.manning.com/book/the-mikado-method/chapter-2/ch02lev2sec3) |

## 3. 组合后的施工纪律（六条）

### 纪律 1：骨架先行——M0 从"空骨架"升级为"可运行骨架"

M0 不再只是空工程 + CI，而是让一个 **fake source 打穿第 0–2 层定义的全链路**：

```text
SourceChannelRegistry(每源一通道开关, fake 为第一源)
  → NativeFakeGateway ──产出── SourceBundle 1.0 字节流（09 契约形态）
  → JobArbiter 雏形（作业生命周期端口）
  → 采集引擎端口（EnginePort：事件顺序/ready 语义先以 fake 驱动串通）
  → normalize → validate → ImportPort（M0 用 throwaway skeleton.db，不建 v7/v8 正式表）
  → 结果查询（返回导入汇总 + 错误码）
```

- **fake source 是正式测试资产**：与 M2 复用的 loopback fixture 服务器同一路线，
  M0 先落最简版，M2 增厚为完整状态机夹具。
- **开关从 M0 就有**：`source → channel(native|python)` 配置表默认指向 Python
  通道，fake 源指向 native 通道。此后任何来源拨开关都有代码路径可走，
  不靠文档约定。
- **横切项第一周点亮**：Asia/Shanghai 时钟注入、结构化日志、错误码枚举、
  依赖注入/可测试装配，全部进入 M0 骨架而非事后补。
- M0 门禁不变的部分：analyze/test/build 全绿；**新增部分**：fake 源 E2E smoke
  契约测试必须通过（这就是 Walking Skeleton 的"骨架能走"判据）。

### 纪律 2：竖切交付——每里程碑一条完整切片，引擎绝不随链路附属开发

- M2 内部顺序固定为：**契约测试 → 引擎在 loopback 上做完整（状态全集、事件顺序、
  可观测）→ JW 适配器 → oracle 逐字段对比 → 真实教务人工验收**。
  引擎先对 fake 稳定，再插第一条真实适配器；任何横切缺陷在 fake 阶段修掉，
  成本最低。
- M3/M4 每条来源都是一个竖切，各自独立过 gate、独立拨开关；未切的来源继续走
  Python 通道，互不阻塞。
- 禁止"先把某层全部做完再进入下一层"的横向马拉松。

### 纪律 3：契约先行——每个里程碑开工先写可执行契约测试

- 从 09 的 CT 矩阵抽取本里程碑涉及的契约，先写契约测试（生产/消费两侧都对着它
  开发），后写实现；测试不过，该块不算开工完成。
- 契约测试放在 CI 常驻，合并即验证。契约变更走 09 文档 → 契约测试 → 实现的
  顺序，禁止先改实现再改文档。

### 纪律 4：绞杀榕开关——逐源接管、随时可退

- `NativeXxxGateway / PythonXxxGateway` 并存由**配置表 + 运行开关**强制，
  同源同刻单通道（四铁律之一）在 ChannelRegistry 内断言。
- 每条新链路：fixture 全流程 + oracle 对比通过后才允许拨 native；
  拨开关后保留 Python 通道与回拨能力，直到 M7 统一删除。
- 每里程碑打 tag（如 `m0-skeleton`、`m2-jw-native`），回退 = 拨开关 + 回 tag。

### 纪律 5：Golden Master + oracle 常驻 CI

- 冻结 fixture 样本集（R-08）只增不修；Python oracle 对比
  （`compare_jw_bundles.dart` 路线）纳入 CI 常驻，**不是里程碑结束时跑一次**。
- 新旧输出任何差异必须落在登记表：要么是已登记的新房修复，要么是 bug。
- 补充：旧房未覆盖的行为以 07–13 契约为准，不以旧房 bug 为准（oracle 不是宪法）。

### 纪律 6：高风险迁移用 Mikado、日常用短分支

- M1 v7→v8 迁移器、M7 Python 退役：按 Mikado 方法拆分依赖图，每步保持
  analyze/test/build 全绿、可回退。
- `rewrite/flutter-native` 长分支内部：**每个任务短功能分支 + 当日合入**；
  任何合并进长分支前三件套全绿。禁止长任务分支攒成大集成。

## 4. 每切完成定义（DoD）——直接回应"最后一批补横切"

每个竖切（含 M0 骨架）只有同时满足以下全部才算完成，**横切项当切当场勾完**：

- [ ] 功能路径跑通（本切范围全链路）；
- [ ] 本切涉及的 09 契约有契约测试且 CI 通过；
- [ ] 时间：统一 Asia/Shanghai（时钟注入，不裸用本地时区）；
- [ ] 隐私：本切新增文本经 `inspectUserText` 路线或等价预检；隐私拒绝走
  `privacy_rejected` 错误码；
- [ ] 错误：全部失败路径走注册错误码，无裸 `StateError`/吞异常；
- [ ] 审计：本切写操作（如有）审计可追溯；
- [ ] 可观测：本切关键转移有结构化日志（事件顺序/状态转移/耗时）；
- [ ] 账号隔离：本切数据访问带 account 分区语义（骨架期允许用 fake account 占位）；
- [ ] analyze / test / build 全绿；
- [ ] 本切范围内的风险（13 号）勾选或登记新风险，关闭标准不被降级。

## 5. M0 升级前后对照

| 项 | 原 M0（空骨架） | 升级后 M0（Walking Skeleton） |
|---|---|---|
| 内容 | 按 0–2 层建分层空工程、CI | 分层工程 + fake source 打穿 0–2 层全链路 + ChannelRegistry 开关 + CI |
| 数据库 | 无 | throwaway `skeleton.db`（M1 才建 v7/v8 正式 schema，M0 不碰） |
| 测试 | 空测试通过 | fake 源 E2E smoke 契约测试通过 |
| 横切 | 不做 | 时区/日志/错误码/DI 第一周点亮 |
| gate | analyze/test/build | analyze/test/build + smoke E2E 通过（仍受四铁律约束） |

## 6. 禁止事项（反模式清单）

1. 禁止横向马拉松：不得"做完存储层再做引擎层"而不跑端到端。
2. 禁止集成押后：任何一块超过一天未合入 `rewrite/flutter-native` 长分支视为集成债。
3. 禁止横切攒尾：DoD 中任何一项未勾，该切不算完成、不得拨 native 开关。
4. 禁止 fixture 漂移：冻结样本只增不修；修 fixture 必须同 commit 改登记表。
5. 禁止契约单向变更：改接口先改 09 + 契约测试。
6. 禁止在 main 写重构代码：代码只进 `rewrite/flutter-native`；设计文档可进 main。
7. 禁止以自动测试冒充人工验收：学校页面真实验收当场做（07 §2.3-1），
   不攒到最后。

## 7. 与既有文档的关系

- 四铁律、红线、产品不变量：07（不变）。
- 容器切分与技术选型：08（不变）；本文只规定在 08 的工程布局内按竖切施工。
- 接口契约：09（不变）；本文只要求把它们变成 CI 契约测试。
- 链路与状态机：10/11（不变）；11 的"每块开工前补设计"纪律继续适用。
- 风险与验收：13（不变）；每切 DoD 引用其关闭标准，不得降级。
- 总体审查遗留：14 §6 低优先级项按原计划消化，不受本文影响。
