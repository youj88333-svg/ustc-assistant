# 07 宪法与决策日志（六层阶梯 · 第 0 层）

> 产出日期：2026-08-12 ｜ 状态：**第 0 层已关闭（2026-08-14，第四轮复审收口后重认）** ｜ 依据：AGENTS.md「整体重构与正式版路线」、
> `docs/refactor-docs/00–06`（以 main 代码为准）

## 1. 本层目标与 gate

- 目标：把"跨阶段不可变红线"与"全部待决策项"收敛进本文件；决策按单向门（不可逆，
  设计期拍板）/双向门（可逆，实施期拍板）分类。
- **gate：红线清单无遗漏；决策登记表覆盖 01–06 §8 全部开放决策与 §10 架构级存疑；
  单向门逐项拍板并落 ADR；双向门确认延期合理。**
- **红线判定元规则（第三轮整改修订，2026-08-12）**：一条红线必须同时满足
  (a) 违反它 = 产品失去存在意义或产生安全危害；
  (b) **不依赖可替换实现细节**——红线只保留实现无关语义；具体介质（SQLite）、语言特性
  （Dart String 零化限制）、路径形式（tmp/private）、回环地址值（127.0.0.1）、CLI flag、
  表名、包名、驱动名、参数值等一律移入 §2.5 移交登记并承接至第 2/5 层；
  (c) 能用来验收任意里程碑。
  架构端口名（CredentialProtector）、产品概念名（PlanBlock/Agent/completeReset）属于
  对外契约，允许出现在红线正文。

## 2. 红线清单（跨阶段不变，目标架构必须满足）

### 2.1 安全红线（五原则，2026-08-12 已确认；AGENTS.md「强制安全规则」自此指向本节）

1. **凭据与密钥边界（三类资产，三类边界；ADR-019，第三轮整改修订）**：
   ① 应用显式凭据（密码/API Key）：仅以受保护形式持久化（经 `CredentialProtector`），
   即用即取、永不落日志/审计/工具 payload/非目标出站；
   ② **浏览器会话资产保持不透明**：浏览器运行时维护的全部认证状态——包括但不限于
   Cookie、LocalStorage、SessionStorage、IndexedDB、缓存、Service Worker 状态、认证
   header、WebAuthn/平台凭据引用——只存在于受控隔离会话分区（引擎独占生命周期、按账号
   隔离、真删除语义，ADR-002）；**应用代码不读取其明文**，仅经不透明会话管理端口操作，
   来源适配器只能获得规范化页面业务数据；
   ③ 临时明文（内存中解密密码）：最短存活 + 尽力零化 + 永不落日志（不承诺运行时可绝对
   清除，采 Bitwarden 式诚实措辞）。模型 Key 只用于学校 LLM 网关。
2. **出站最小化与授权**：出站请求只携带完成该查询所必需的最少字段，未经显式允许
   默认拒绝（fail-closed）；评课联动只发送必需检索词（课程名、教师名或其组合），
   首次联网前告知并授权；不得发送完整课表、时间、地点、学号、姓名、用户 ID、
   登录信息等可拼出个人画像的上下文。
3. **本地资产与调试边界**：调试资产（原始响应、缓存、私有笔记、浏览器会话分区）不进入
   版本控制和正式发布；原始数据仅在显式要求时保存到私有目录；本地调试服务仅允许本机
   回环且不得出现在发布构建。
4. **不可信输入防御**：外部页面与公开点评文本视为不可信数据，不得当作 Agent 指令。
5. **用户主权**：二课报名/取消永远由用户执行；写操作风险分级 + 用户确认 + 审计
   （只存安全摘要，不存 id/ref/原文）；权限变更永远由用户亲手确认；来源刷新不得
   覆盖 `UserOverlay`；用户可随时完全清除本地数据（凭据、会话、Agent 历史）。

降级为实施细则（可调，不属红线）：校园目录"每批详情 ≤3、链接 ≤1 层"（"先目录
后 entryId、禁任意 URL"保留在原则 2 的 fail-closed 精神下）；附件受控下载与内容转换
归 C1、平台实现归 P（第三轮整改明确容器归属）。

### 2.2 产品不变量（无技术名词；实现细节见 §2.5 移交登记；2026-08-12 已确认）

1. **本地优先**：业务数据与核心能力在本地运行；云同步为远期可选项，不默认上传。
2. **学校数据承诺**：学校来源的记录不因滚动窗口变化而丢失；应用不物理删除学校
   课程/考试/二课数据，仅在用户明确同意后本地隐藏。
   > 解释注（2026-08-14，用户拍板，L2 审查整改 A-10）：本条约束**应用自动行为**
   > （同步、滚动窗口、导入流水线）；用户亲手确认的破坏性维护
   > （clearBusinessData / completeReset）属于 2.1 原则 5 用户主权的"可随时
   > 完全清除本地数据"，不受本条限制。任何应用自动路径仍禁止物理删除学校数据。
3. **冲突语义**：时间重叠不自动等于冲突；冲突关系允许用户解释、调整。
4. **用户确认语义**：规划性内容永不自动执行或自动完成——PlanBlock 结束由用户确认
   已执行/跳过/重排；个人事件完成确认不发送系统通知，待确认事件由用户在应用内确认
   （当前入口为 Agent 聊天）。
5. **Agent 权力边界**：Agent 对学校/外部系统只读，永不自动发起外部写操作；写能力
   只作用于本地业务数据（本地写规则见 2.1 原则 5）。
6. **单账号模型**：产品定位于个人单用户使用，任意时刻至多一个学校账号；不提供
   多账号并存与切换，更换账号 = 完全重置回初始状态（清库 + 清会话，completeReset）。
7. **数据资产连续性**：用户已有本地数据必须能无损迁移到新架构，且迁移可回退。
8. **三端目标**：最终产品运行于 Windows/Android/iOS；先完成 Windows 正式版，移动端
   之后实现；三端共享平台无关核心，平台差异仅经适配器边界替换。
9. **出勤与听讲语义**：课程出勤支持必去/可以赌/不去及自由备注；听讲模式独立记录。

### 2.3 过程红线（2026-08-12 已确认）

1. 自动测试不得访问学校网站；涉及学校页面的改动必须真实登录人工验收；不得把自动测试通过写成人工验收通过。
2. 用户验收文件（`_merge-pending-docs/` 等未跟踪用户文件）不得修改、不得替用户改结论。
3. 旧房（main + Python 五链路 + CLI）在 M7 前保持可运行、可回退；不得提前删除现有 service/测试/真实故障回归样例。
4. 每里程碑 analyze/test/build 全绿才算完成。
5. 真实故障回归样例必须迁移进新房对应测试，不得因重构整理而丢失。

### 2.4 旧房专属约束（新架构废止或重述，不构成红线；2026-08-12 已确认）

| 旧约束 | 新架构处置 |
|---|---|
| App 经本机临时 Python Bridge 调用来源能力 | 废止（M7），由原生采集引擎取代 |
| "各来源只共享浏览器生命周期、存储和 CLI 编排" | 重述为"共享采集引擎（会话/导航/事件/可观测），来源保留独立 DOM/接口/解析规则" |
| `pythonPath` 设置、`PythonLocator` | 废止（M7） |
| CLI（`python -m ustc_assistant`）去留 | D13 决定 |
| 未打包 Windows 首版不保证关 App 后提醒可靠触发 | 转 backlog：MSIX 决策（D28） |
| `clearDedicatedBrowserSession` 现状为 no-op（01§10-1） | 目标态必须真实实现（会话数据分区清理），作为 D02 的一部分 |

### 2.5 降级移交登记（原红线中绑定技术产物的条款在此移交，后续层逐项消化，不得丢失；2026-08-12 已确认）

| 移交项 | 原位置 | 新宿主 |
|---|---|---|
| SourceBundle 1.0 envelope/manifest/digest 幂等/9 错误码语义（L2-07 修正）；canonical schema 与 Draft-7 副本双方言同步 | 原 2.3-1 | `09-contracts.md` §SourceBundle（第 2 层）+ D06 的 ADR |
| v7 基线 27 表数据字典与 schemaVersion 迁移线（v7 为起点、v8+ 仅正式迁移；v8 后表数为基线 27 + 变更净增减，不再混称"27 表"） | 原 2.3-2 | `09-contracts.md` §schema 迁移线 + D10 的 ADR（"数据资产连续性"不变量留在 2.2-7） |
| 账号隔离实现机制（accountId 分区、凭据级联删除） | 原 2.3-3 | `09-contracts.md` §账号隔离机制（"账号隔离"不变量留在 2.2-6） |
| 北京时间 Asia/Shanghai 为唯一业务时区 | 原 2.3-4 | D14 的 ADR + `12-cross-cutting.md`（第 5 层） |
| 认证回环/Query Protocol 1.0 语义延续（暂停-恢复同一作业、安全计数、凭据边界） | 原 2.3-5 | D01/D03/D05/D15 的 ADR（§3 已覆盖） |
| 学校来源按稳定外部身份 upsert | 原 2.2-2 | `09-contracts.md` §数据模型（第 2 层） |
| 冲突判定序（显式关系 > 系列规则 > 时间重叠派生） | 原 2.2-3 | `09-contracts.md` §冲突投影 + `11-component-designs.md` |
| 重复系列稳定身份 + 单次例外；物化上限（366 天/1000 次） | 原 2.2-4 | `09-contracts.md` §重复系列；上限为实施期参数 |
| 提醒默认偏移（定时 15min / 全天不提醒） | 原 2.2-5 | 双向门 D33：第 2 层 09-contracts 冻结默认值（定时 15min / 全天不提醒），M5 只做 UI |
| Task 只持久化四态、派生状态查询计算 | 原 2.2-6 | `09-contracts.md` §数据模型 |
| SourceBundle 只用于 JW+二课完整快照；报名/评课/校园走独立查询结果 | 原 2.2-8 | `09-contracts.md` §SourceBundle 范围 |
| SourceBundle 信封细节（无主键/身份/覆盖/冲突判断；一 Bundle 一账号一来源一范围一事务） | 原 2.2-9 | `09-contracts.md` §SourceBundle 1.0 |
| Agent 写提交"业务+审计+确认日志"同事务；Agent 写入不占撤回槽 | 原 2.2-10 | `09-contracts.md` §事务边界 + `11-component-designs.md` §审批门 |
| 个人事件支持单次/全天/跨日/基础重复系列 | AGENTS.md 产品约束（孤儿规则，审查 A-8） | `09-contracts.md` §个人事件模型 |
| PlanBlock 不记录完成百分比/实际执行分钟/自动剩余工时 | AGENTS.md 产品约束（孤儿规则，审查 A-8） | `09-contracts.md` §任务与计划块模型 |
| 校园目录"每批详情 ≤3、链接 ≤1 层"；附件受控下载与内容转换归 C1、平台实现归 P | AGENTS.md 安全细则（孤儿细则，审查 A-8；第三轮整改明确归属） | `09-contracts.md` §Agent 工具安全细则 + `12-cross-cutting.md` §附件管道 |
| 本地事实来源介质 SQLite（具体介质选型） | 红线 2.1 元规则迁出（第三轮） | `09-contracts.md` §数据库 |
| Dart String 不可变致"绝对零化"不可承诺（语言特性限制） | 红线 2.1-1 ③（第三轮） | `12-cross-cutting.md` §安全实现约束 |
| `--save-raw` 落盘形式与 tmp/private 具体目录 | 红线 2.1 原则 3（第三轮） | `12-cross-cutting.md` §调试资产 |
| 本地调试服务仅绑 127.0.0.1 的具体地址值 | 红线 2.1 原则 3（第三轮） | `12-cross-cutting.md` §调试服务边界 |

## 3. 决策登记表

分类规则：**单向门** = 改动成本高或影响第 1–2 层结构，必须设计期拍板，拍板即落 ADR；
**双向门** = 可逆/局部，实施期按里程碑拍板，不阻塞第 1–2 层。

### A 组：采集引擎（单向门，第 1 层容器切分的前置）

| ID | 决策 | 出处 | 推荐倾向 | 状态 |
|---|---|---|---|---|
| D01 | 引擎形态与统一适配器接口：WebView 驱动（jw/young 依赖登录态与页面交互）vs 原生 HTTP（icourse/campus 公开）；五链路统一 fetch→normalize→validate→deliver 管道 | 02§8-1、02§9 建议1 | 双形态、统一接口：WebView 引擎子层 + HTTP 客户端子层，适配器统一管道 | ✅ ADR-001 |
| D02 | 登录会话承载：WebView 专用数据分区（持久化，对应 Edge profile 语义）、会话健康探测时机、会话真实清理 | 01§8-1/8-4、01§9 建议1、01§10-1 | 按账号独立持久化数据分区；收集前探测 + `/health` 级主动探测；清理=真删分区 | ✅ ADR-002 |
| D03 | CAS 交互登录原生化：白名单 origin 填表、账号三层核验、`needs_user_login` 暂停-恢复交互模型（用户确认后取密码） | 01§8-2、02§8-2、06§8-2 | 语义照搬现状：可见窗口交互登录、确认后才解密取密码、恢复同一作业 | ✅ ADR-003 |
| D04 | 并发互斥模型：卡槽租约（采集×查询同钥匙互斥）、全局单活跃门、一源一通道、落库守卫；单账号模型下换账号=完全重置 | 02§8-4、01§10-5/6 | 卡槽租约 + 全局门 + 重置终止作业 + 落库守卫 + 来源级互斥 | ✅ ADR-004 |
| D05 | 进度与暂停-恢复语义：作业进度/安全计数/取消在进程内的表达（替代 HTTP 轮询） | 02§8-2、06§8-1 | 进程内事件流（`Stream<JobEvent>`），保留 sequence/safeCount/terminal 语义 | ✅ ADR-005 |
| D30 | 教务学期选择能力：main 上目标学期写死（`461/2026fall`），v2 分支已验证"从教务页面源文件抓取学期列表"；是否纳入目标态及抓取途径 | 开发规则（学期硬编码）、`feature/flutter-native-jw-v2` 分支实现 | 纳入目标态：登录后从教务页面源文件抓取学期列表，设置页可选，持久化三元组；默认学期按月份规则（2–6 春季 / 7 夏季 / 8–12 秋季 / 1 月=上一年秋季），从列表匹配选取，禁止推算 | ✅ ADR-009 |

### B 组：契约与数据（单向门，第 2 层全局契约的前置）

| ID | 决策 | 出处 | 推荐倾向 | 状态 |
|---|---|---|---|---|
| D06 | SourceBundle 生产端宿主：原生 Dart 采集器直接产出 vs 打包 Python 继续产出 | 03§8-1 | 原生 Dart 直接产出（从零重写隐含）；Python 仅作 oracle | ✅ ADR-006 |
| D07 | campus 目录存储归属：并入 SQLite vs 保留 JSON 文件（原子写+节流+降级语义不变） | 02§8-3 | 并入 SQLite（与本地事实来源统一），保留 30min 节流/6h 过期/降级旧目录语义 | ✅ ADR-007 |
| D08 | 同步状态机三表（source_records/sync_runs/import_batches）在无 Bridge 下是否简化（trigger/retry 语义） | 03§8-3 | 保留三表与 presence 语义；trigger 枚举与 retryAfter 按 D12 微调 | ✅ ADR-008 |
| D09 | 撤销模型：单槽保留 vs 多槽；`expires_at` 与 `clearAtStartup` 语义落地（03§10-3） | 03§8-4、05§8-3 | 单槽保留（现状），启动清槽语义显式化，多槽转 backlog | ✅ ADR-010 |
| D10 | schema v8 变更集边界：action_logs 索引（03§9 建议2）、agent 三处 prompt 版本不一致（06§10-2）等 | 03§9、06§10-2 | 允许，仅经正式迁移；变更清单在第 2 层冻结 | ✅ ADR-011 |
| D11 | 既有 Python 侧本地数据迁移：CLI tmp/ 产物是否并入 Flutter 库 | 03§8-2 | 不迁移（tmp/ 非正式数据）；正式数据仅存在于 Flutter SQLite v7 | ✅ ADR-012 |

### C 组：同步与壳层（单向门中的小型项）

| ID | 决策 | 出处 | 推荐倾向 | 状态 |
|---|---|---|---|---|
| D12 | freshness/backoff 常量合并与归属（两套 12h：`automaticSyncInterval` 无消费方）；自动同步是否成真开关 | 04§8-1、04§10-1 | 合并为同步模块单一常量；真开关转双向门 backlog | ✅ ADR-013 |
| D13 | CLI 去留：M7 删除 vs 降级为调试工具 | 02§8-1 | M7 删除；调试能力由新房 fixture/oracle 测试基建承担 | ✅ ADR-014 |
| D14 | 时区模型：epoch ms + Asia/Shanghai 显式语义保留 vs 引入时区库 | 05§8-5 | 保留现状并显式化（唯一业务时区）；跨时区需求出现前不引入 | ✅ ADR-015 |

### D 组：harness（单向门，M6 与查询网关缝合的前置）

| ID | 决策 | 出处 | 推荐倾向 | 状态 |
|---|---|---|---|---|
| D15 | QuerySourceGateway 消费侧形态：旧房 HTTP 双轮询通道 bug 多、接近不可用，需重设计（参考 MCP Tasks/elicitation + OpenHands 事件流）；Query Result 1.0 envelope 去留 | 06§8-1、用户实测反馈 | 重设计：进程内 QueryJob 对象 + 事件流 + MCP 式取消/elicitation 暂停恢复；envelope 保留作安全载体 | ✅ ADR-016 |
| D16 | Agent 本地数据网关/写网关背后的数据层形态：保留现有 Drift 服务层 vs 统一仓库层 | 06§8-3 | 保留现有服务层（M1 重建后形态不变），不引入新仓库抽象 | ✅ ADR-017 |
| D17 | Agent 六子结构是否拆包/抽共享库 | 06§8-4 | 保持 feature 内聚合；M6 后再评估拆包 | ✅ ADR-018 |

### E 组：双向门（延期，实施期按里程碑拍板，不阻塞第 1–2 层；延期安排 2026-08-12 已确认）

| ID | 决策 | 出处 | 建议拍板时机 |
|---|---|---|---|
| D18 | ~~多账号会话并行度~~ | 01§8-3 | 已取消（单账号模型，见 ADR-004） |
| D19 | 密码自动填充与"仅确认后读取已存密码"的信任边界呈现 | 01§8-2 | M5 |
| D20 | 页面状态管理框架（维持"服务构造 + 局部 setState" vs Riverpod/Bloc） | 05§8-1 | M5 |
| D21 | DI 容器（维持路由工厂手工装配 vs 引入 provider 等） | 04§8-6 | M5 |
| D22 | 深色模式/跟随系统 | 04§8-4 | M8/backlog |
| D23 | 路由/分支状态持久化 | 04§8-5 | M8/backlog |
| D24 | WeekTimetable 抽独立组件/包 | 05§8-2 | M5 |
| D25 | 任务带/全天带"最多 3 条 +N"折叠策略 | 05§8-6 | M5 |
| D26 | 冲突/重复规则数据云端同步 | 05§8-4 | 远期 |
| D27 | MCP 等外部工具协议 | 06§8-5 | 远期 |
| D28 | MSIX 打包与关 App 后提醒可靠性 | 产品约束、04§10 | M8 |
| D29 | 移动端（Android/iOS）采集适配实现排期 | 红线 2.2-8、AGENTS.md 目标 | Windows 正式版后（M8 之后） |
| D31 | 自动同步真开关（设置页当前为纯展示文本，无真开关） | 04§8-3、04§10-1、ADR-013 | M5 评估 |
| D32 | 批量删除/清理工具形态：`create_task` 可 32 突发批量建，但 Agent 无删任务工具且禁止 batch/delete-all——"用户明确要求的批量删除"缺口。第 2 层冻结批量删除的确认/额度/审计/撤销契约（单对象工具 + 现有 8×12 为基线；禁止无预览 delete-all；可预告"用户批准的复合操作 + 每对象 mutation ledger"，不在第 1 层拍具体数量上限）；M6 定工具暴露形态 | 用户反馈 2026-08-12；第三轮整改 | ✅ 契约面已拍板（2026-08-14 L2-05：上限 32【基线】+ 预览确认 + 每对象 ledger + 单槽整包撤销；上限与防死循环职责分离）；工具暴露形态 M6 定 |
| D33 | 提醒默认偏移参数：第 2 层 09-contracts 冻结（定时事件默认提前 15 分钟、全天事件默认不提醒）；M5 只做 UI 不再拍默认值 | 原 2.2-5、§2.5；第三轮整改 | ✅ 已拍板（2026-08-14 L2-01：09-contracts CT-C3-14 全表冻结，含 exam/second_class/task/plan_block 特例） |
| D34 | `agent_permission_policies.expires_at` 处置：**✅ 已拍板（2026-08-14，第 2 层 L2-02）——v8 删除该列**（代码核实为死列：恒 NULL、决议 `resolve` 从不读）；"此类型以后不再确认"=永久记住（ask_first_time + firstConfirmedAt），无过期概念；将来如需"限时记住"作新功能开新决策 | 03§10-3；第三轮整改；用户拍板 | 已拍板（`09-contracts.md` §7.7 CT-C3-18） |
| D35 | 单账号模型下 `sourceConfigs` 主键形态（`'$accountId:$source'` 是否简化） | 04§8.3 | ✅ 已拍板（2026-08-14 L2-03：保留复合字符串 id + UNIQUE(account_id, source)，零迁移） |
| D36 | `account_mismatch` 后的 UI 恢复引导（旧房统一显示"重新登录失败"） | 01§9 建议4、01§10-9 | M5 |
| D37 | `sync_runs.trigger` 枚举与 retry 契约（ADR-008 移交给 D12，ADR-013 未定细节） | ADR-008/013 | ✅ 已拍板（2026-08-14 L2-04：trigger 扩 4 值 + state 6 值 + retry 契约，09-contracts CT-C2-05~07） |
| D38 | completeReset 数据代价缓解：备份/导出入口或清单预览（单账号模型下重置销毁个人日程/Task/Agent 历史） | 审查 D-1 | M5/M8 |

## 4. ADR 日志

模板（每条 ADR 四要素）：

```markdown
### ADR-NNN：标题
- 状态：已采纳 / 待采纳 / 已取代
- 上下文：为什么现在必须决定
- 选项：A / B / C（含利弊一句话）
- 决策：选 X
- 后果：正面 + 负面 + 缓解措施
```

### ADR-000：整体重构采用"从零重写 + 六层阶梯设计先行 + 旧房/新房并存"

- 状态：**已采纳**（2026-08-12 商定，已随 AGENTS.md 提交 3e8f043）
- 上下文：模块分立导致 `feature/flutter-native-jw-v2` 迁移 debug 困难（横切引擎问题在单链路反复打补丁）；决定强化整体性。
- 选项：A 修补式继续迁移；B 逐模块渐进重构；C 从零重写 + 设计先行。
- 决策：C，配套六层阶梯（每层有 gate）、M0–M8 里程碑、并存三边界（代码/运行时/数据）与四铁律。
- 后果：正面——引擎共享层一次设计、整体性有机械保障；负面——设计周期长、有分析瘫痪风险；
  缓解——双向门延期（E 组）、第 4 层组件设计按里程碑补、v2 测试基建作为抢救资产直接复用。

> 后续 ADR：每个单向门（D01–D17）拍板时，在本节按顺序追加 ADR-001…，并在 §3 登记表
> 状态列标注 ADR 编号。双向门拍板不必落 ADR，仅在登记表更新状态。

### ADR-001：采集引擎采用"双形态 + 统一 SourceAdapter 管道"

- 状态：**已采纳**（2026-08-12，用户拍板）
- 上下文：五链路分属两类来源——登录态页面交互型（jw/young 日程/young 报名）与公开
  HTTP 型（icourse/campus）；`feature/flutter-native-jw-v2` 证明共享基础设施缺失导致
  WebView 横切问题在单链路反复修补。
- 选项：A 双形态 + 统一管道（WebView 引擎子层 + HTTP 客户端子层，全部适配器实现同一
  fetch→normalize→validate→deliver 管道）；B 全部 WebView；C 全部原生 HTTP 逆向接口；
  D 每链路独立实现。
- 决策：A。
- 后果：正面——共享引擎一次设计（会话/导航/就绪/可观测），三端仅替换 WebView 边界，
  python-oracle 对比挂在 validate 工位，v2 测试基建直接复用；负面——WebView2 与
  Playwright 能力差异需引擎接管 user-data-folder 生命周期（并入 D02 设计）；统一的是
  管道框架而非来源差异，各来源 normalize 段保留独立 DOM/接口/解析规则。

### ADR-002：登录会话承载采用"每账号独立持久化数据分区 + 收集前健康探测 + 真实清理"

- 状态：**已采纳**（2026-08-12，用户拍板）
- 上下文：Python 侧 Edge 持久 profile 提供跨重启存活的学校登录会话；旧房"清除浏览器
  会话"实际是 no-op（01§10-1）；v2 分支的 user-data-folder 生命周期逻辑散落在各来源
  适配器中反复出 bug。
- 选项：A 每账号独立持久化数据分区（引擎独占生命周期）+ 收集前探测 + 清会话=真删卡槽；
  B 共享 cookie 容器；C 不持久化、每次重登。
- 决策：A，附加条款——卡槽生命周期（开/锁/关/崩溃脏状态恢复）归引擎独占，来源适配器
  不得私自管理；启动/定期探测留双向门（实施期）。
- 后果：正面——会话跨重启存活、账号隔离、清理语义真实（借鉴 Auth0 "logout must be
  real"）；负面——WebView2 UserDataFolder 与 Playwright profile 行为差异（锁文件、
  目录占用、关闭时序）需引擎处理；三端将来替换卡槽实现时必须保持"清理=物理删除、
  探测=返回会话健康状态"的跨平台契约。

### ADR-003：CAS 交互登录语义照搬现状，验证码场景明确不自动化

- 状态：**已采纳**（2026-08-12，用户拍板）
- 上下文：旧房 CAS 流程（白名单填表、三层核验、needs_user_login 暂停-恢复）已真实
  跑通（01§3）；01§10-3/4 存疑：三层核验存在盲区、验证码场景无自动化覆盖。
- 选项：A 语义照搬 + 验证码交用户手动；B 引入验证码自动识别；C 重设计登录交互。
- 决策：A。填表仅白名单 origin、按钮异常静默回退人工；三层核验缺一即 AccountMismatch
  （明确失败优于假装成功）；暂停-恢复同一作业、用户确认后才解密取密码；验证码不自动化。
- 后果：正面——复用已验证交互模型，密码信任边界与用户主权红线一致；负面——依赖学校
  页面结构，改版可能三层证据全失，以明确失败兜底；验证码场景列入 M2 真实人工验收清单。

### ADR-004：单账号模型 + 卡槽租约互斥（并发与账号模型）

- 状态：**已采纳**（2026-08-12，用户拍板）
- 上下文：产品定位于个人单用户；旧房"采集/查询两本锁互不锁"并发未验证（01§10-6）、
  "切账号不取消作业"可能串号（01§10-5）；D02 已定卡槽归引擎独占。
- 选项：A 单账号模型 + 卡槽租约（同卡槽采集×查询互斥）+ 全局单活跃门 + 重置终止
  作业 + 落库守卫 + 一源一通道；B 维持旧房两本锁；C 允许多账号并行。
- 决策：A。换账号唯一路径 = completeReset（清库+清会话，重置前终止全部作业）；
  租约随作业生命周期（needs_user_login 暂停期间保持持有，终态释放）；导入事务校验
  活动账号与作业一致；来源级互斥（原生/Python 物理二选一）**权威位置在 C2 通道注册表
  （Native/Python 共同闸门，审查 C-3 修订 2026-08-12），C1 JobGate 卡槽租约仅管
  Native 侧会话资源互斥**。
- **第三/四轮整改修订（2026-08-12/14）**：C2 为**全部来源作业唯一仲裁者**（JobArbiter），
  C4 不再直连 C1；所有作业携带租约戳 {jobId, accountId, source, channelKind,
  sourceGeneration, resetEpoch}；sourceGeneration 递增原因全集 = **通道切换、取消、
  completeReset、clearBusinessData** 四类，C3 导入/写入前校验租约戳仍属当前账号与
  当前 generation/resetEpoch，迟到结果返回
  稳定错误、不得写库。并存期 Python 进程与认证回环传输只经 P 提供的
  `PythonProcessPort`/`LoopbackBridgeTransportPort` 注入 C2；C2 核心不直接持有 `dart:io`
  或 HTTP 客户端，M7 随 Python 租户删除两端口。参考 Kubernetes Lease + resourceVersion
  的单一协调者/holder/generation/迟到拒绝模式（不引入依赖）。
- 后果：正面——消灭多账号并行整类问题（D18 取消）、消除旧房并发雷与串号雷；负面——
  同步进行时 Agent 查二课被拒（busy 语义延续；旧房码 bridge_busy/bridge_query_busy
  随 Bridge 废止，L2-08），确定性优先于并行度；
  宪法 2.2-6 由"账号隔离"修订为"单账号模型"。
- **L2 审查整改修订（2026-08-14）**：sourceGeneration 权威归 **C3 同步状态服务**
  （落 `source_configs.source_generation`，09 v8 #7），C2 经 C3 递增后组装入租约戳，
  C3 导入/写入事务内与库内值比对——消灭"预检-提交"之间的 TOCTOU（09 §2.3/§7.3）。
- **L2 复审收口修订（2026-08-14，用户批准）**：租约戳须由 C2 经
  `SourceJobHandle.stamp` 显式交接，不得靠 jobId 或调用方上下文猜测；C2 在终态交接前
  校验，C3 对 normal 导入、首登提交、重新认证提交、campus 目录提交四类来源派生写
  均在事务内复验。C3 以 `SourceStateService` 暴露 generation 原子递增与 sync run
  账本，C2 不直接写 `source_configs`/`sync_runs`（09 CT-C3-21）。

### ADR-005：作业进度采用进程内事件流（safeCount + 八相位照搬 + 热流可重放）

- 状态：**已采纳**（2026-08-12，用户拍板）
- 上下文：旧房跨进程依赖 HTTP 长轮询传作业进度（01§4.1）；新架构纯 Dart 同进程，
  传话筒可拆但进度语义必须保留；"凭据与原始数据从不进事件流"的旧房规矩延续（01§4.3）。
- 选项：A 进程内 `Stream<JobEvent>`（sequence/phase/safeCount + terminal result/error）；
  B 回调；C Future 一次性返回。
- 决策：A。**八相位**全集照搬（starting→checking_session→waiting_for_user→collecting→
  needs_user_login|complete|cancelled|failed，共 8 个）；safeCount 仅安全计数；needs_user_login
  恢复同一作业同一流、序号连续；取消协作式；热流支持重放最近事件。
- 后果：正面——UI/Agent 多订阅方同流，隐私边界由"流内只含安全计数"机械保证；负面——
  热流语义需处理迟到订阅（重放最近事件），v2 分支事件顺序类 bug 一半源于此，列入引擎测试清单。

### ADR-006：SourceBundle 生产端由原生 Dart 产出，Python 仅作 oracle

- 状态：**已采纳**（2026-08-12，用户拍板）
- 上下文：ADR-000 已定 M7 Python 退役；旧房 SourceBundle 生产在 Python 侧
  （jw/young-schedule 的 build_*_source_bundle）；SourceBundle 1.0 语义为契约红线
  （已移交 09-contracts）。
- 选项：A 原生 Dart 生产器 + 校验器（等价重写，Python 仅作测试 oracle）；B 打包
  Python 可执行继续生产。
- 决策：A。验收标准=同一批货 Python/Dart 装箱逐字段对比一致（`compare_jw_bundles` +
  python-oracle fixture 复用）；digest/时间戳/错误码语义等价为 M2 的 gate。
- 后果：正面——M7 退役可执行、移动端可携带（三端红线）；负面——等价性验证必须严格
  （digest 等细节易"看着像实则不等"），oracle 对比是 M2 gate 而非口头承诺。

### ADR-007：campus 目录条目并入 SQLite，附件缓存仍留磁盘

- 状态：**已采纳**（2026-08-12，用户拍板）
- 上下文：旧房 CatalogStore 为库外 JSON 文件（临时文件+原子替换，02§3.4）；30min
  节流/6h 过期/降级旧目录语义需保留；红线 2.2-1（本地事实来源唯一）与 2.2-7（数据
  资产连续性）要求单数据家。
- 选项：A 目录条目并入 SQLite（节流/过期/降级语义原样保留；附件缓存仍留磁盘）；B 保留
  库外 JSON 文件。
- 决策：A。schema v8 变更集新增目录相关表（与 D10 联动，迁移线测试覆盖）。目录条目
  身份精确复用旧房算法：`'campus_' + sha256(utf8('$source\0$canonicalUrl'))` 的小写
  十六进制前 24 位（URL 先 canonicalize）；观察时间只用 `first_observed_at` /
  `last_observed_at`，不增设语义重叠的 `updated_at`。
- 后果：正面——备份/迁移/completeReset 一体不遗漏，Agent 访问路径统一；负面——v8
  新增表的迁移线测试责任增大（D10 承接）。

### ADR-008：同步状态机三表保留、语义照搬，trigger/retry 参数归 D12

- 状态：**已采纳**（2026-08-12，用户拍板）
- 上下文：三表（source_records/sync_runs/import_batches）是业务账本而非 Bridge 附属——
  幂等（bundleId/digest）、快照对齐（presence 三态）、可恢复性（interrupted 恢复）；
  红线 2.2-2 学校数据承诺依赖 presence 语义；App 被杀场景在新房依然存在。
- 选项：A 三表保留、语义照搬，trigger/retry 参数归 D12 微调；B 激进简化（并表/删表）；
  C 原封不动。
- 决策：A。
- 后果：正面——账本职责原样保留，M1 重建时与"完整快照对齐"导入流水线一并重建；
  负面——将来若需要按来源差异化触发/重试策略，单点配置需再演进（当前无此需求）；
  参数类调整（trigger 枚举、retryAfter）走 D12→D37。

### ADR-009：教务学期选择能力纳入目标态，默认学期按月-学期规则从抓取列表选取

- 状态：**已采纳**（2026-08-12，用户拍板）
- 上下文：main 上目标学期写死（461/2026fall）；v2 分支已验证"从教务页面源文件抓取
  学期列表"的途径；用户决定默认学期改为月份规则而非写死。
- 选项：A 抓取列表 + 设置页选择 + 默认按月份规则；B 写死 + 手抄；C 只抓默认不做选择。
- 决策：A。默认学期规则：**2–6 月默认当年春季、7 月默认当年夏季、8–12 月默认当年
  秋季、1 月默认上一年秋季**（审查 A-5 修正）；学期 ID 只从抓取列表中匹配选取，
  绝不硬编码、绝不按年份推算；列表缺失/未发布新学期的回退策略（最近可用学期/上次
  持久化选择；列表并存时优先匹配包含当前日期的学期）细节归第 4 层/M2。
- 后果：正面——学期切换刚需落地，无需手抄学期代码；负面——月份规则与列表匹配的边界
  情形（新学期待发布、列表抓取失败）需 fallback 设计，列入 M2 真实验收清单；AGENTS.md
  开发规则中 461/2026fall 仅为旧房现状默认，新房按本规则。

### ADR-010：撤销保持单槽 + 启动清槽，expires_at 列随 v8 删除，多槽转 backlog

- 状态：**已采纳**（2026-08-12，用户拍板）
- 上下文：单槽"一步撤回"是已验收产品承诺；undo_slot.expires_at 只写不读、
  clearAtStartup 生产无调用方（03§10-3、05§10-1）；Agent 侧有 undo_last_action
  工具作为额外撤回通道。
- 选项：A 单槽保留 + 启动清槽 + expires_at 随 v8 删除 + 多槽转 backlog；B 升级多槽。
- 决策：A。撤回定位为会话内即时动作，跨会话不恢复；App 启动清空槽；expires_at 列
  删除；Agent 写入仍不占槽（NoopUndoRecorder 语义照搬）。
- 后果：正面——消除死列与悬案语义，行为显式化；负面——跨会话不可撤回（关 App 后
  撤销按钮消失，有意取舍）；schema v8 迁移项 +1（D10 承接）。

### ADR-011：schema v8 变更走"migration-only + 迁移测试 + 清单第 2 层冻结"

- 状态：**已采纳**（2026-08-12，用户拍板）
- 上下文：ADR-007（目录表族）与 ADR-010（删 expires_at）已预定 v8 加表与删列，v8
  变更必然发生；候选四项：目录表族、删 expires_at、action_logs 索引（03§9 建议2）、
  prompt 版本统一（06§10-2）；红线 2.2-7 数据资产连续性。
- 选项：A 允许变更但 migration-only + 迁移测试 + 清单第 2 层冻结；B v7 完全不动
  （已被 ADR-007/010 排除）；C 自由改表。
- 决策：A。每条变更配"旧库建→插数据→迁移→校验"四步测试（03§9 建议1 的 Room 模式）；
  最终清单在 `09-contracts.md` 冻结，冻结后新增变更须开 ADR 修正。
- 后果：正面——数据资产连续性有机械保障；负面——琐碎变更（索引、版本常量）也要走
  全套迁移测试，纪律成本换确定性。
- **L2 审查整改修订（2026-08-14）**：清单在 09 §7.2 最终冻结为七项，其中审查整改增补
  **#7 `source_configs.source_generation`（加列）** 并修订 #6（reset_pending 三值
  编码 0/1/2，见 09 §7.4）——按本 ADR 修正流程记录，冻结后一切新增变更均照此办理。

### ADR-012：Python tmp/ 产物不迁移，唯一数据资产为 Flutter v7 库

- 状态：**已采纳**（2026-08-12，用户拍板）
- 上下文：Python CLI 的 tmp/ 产物（规范化 JSON、campus-catalog.json、icourse 24h
  缓存）是调试草稿（红线 2.1 原则 3 定性）；用户正式资产仅存在于 Flutter SQLite v7。
- 选项：A 不迁移，v7→v8 迁移器为唯一搬家路径，tmp/ 数据新房首次使用时自动重建；
  B 迁移 tmp/ 产物。
- 决策：A。campus 目录按 ADR-007 的 6h 过期逻辑首次查询自动刷新重建；icourse 缓存
  按 24h TTL 自动重建；离线时目录缺失走明确报错语义（catalog_unavailable 照搬）。
- 后果：正面——事实来源不被调试产物污染，迁移入口唯一；负面——离线首用时 campus
  目录缺失（catalog_unavailable 明确报错，需联网后重试），重建期间校园查询不可用。

### ADR-013：freshness/backoff 合并为同步模块单一常量，自动同步真开关转 backlog

- 状态：**已采纳**（2026-08-12，用户拍板）
- 上下文：两套 12h 常量并存——`SettingsService.automaticSyncInterval` 全库无消费方，
  `SyncCoordinator.freshness` 实际生效，设置页文案对应后者（04§10-1）；自动同步在
  设置页为纯展示文本。
- 选项：A 合并为同步模块单一常量、删除死常量；B 双常量 + 注释；C 顺带做真开关。
- 决策：A。freshness/backoff 归同步配置单点，设置页文案从该单点读取；自动同步真开关
  记 E 组 D31（backlog，M5 评估）。
- 后果：正面——改同步策略只动一处；负面——按来源差异化 freshness 不再可能
  （当前无此需求，将来需要时再演进）。

### ADR-014：CLI 随 M7 一并删除，调试能力由新房 Dart 工具/测试基建承接

- 状态：**已采纳**（2026-08-12，用户拍板）
- 上下文：`python -m ustc_assistant` 是旧房离线调试入口；M7 gate 要求新房无 Python
  依赖，保留 CLI = Python 环境永驻，与 gate 直接矛盾。
- 选项：A M7 随 Python 一并删除，调试能力由新房测试基建承接；B 保留降级为调试工具；
  C 保留但重写为 Dart。
- 决策：A。M7 前 CLI 照常可用（过程红线 2.3-3）；新房调试由 v2 抢救的 fixture 服务器、
  python-oracle 对比工具（Dart）与 `app/tool/` 目录承接；将来无 UI 数据修复需求用
  Dart 工具实现，不复活 Python。
- 后果：正面——M7 gate 可关闭、无 Python 环境残留；负面——极小的调试习惯迁移成本；
  CLI 承载的真实验收历史保留在文档，代码删记录不删。

### ADR-015：时间语义铁律——存储 epoch ms，业务时区唯一 Asia/Shanghai

- 状态：**已采纳**（2026-08-12，用户拍板）
- 上下文：现状 DateTime 本地语义与显式北京时格式化并存（05§8.3-5），机器系统时区
  不同可能解释出不同"星期几"；用户群体在中国，跨时区为伪需求。
- 选项：A epoch ms 存储 + Asia/Shanghai 唯一业务时区显式化；B 引入时区库跟随系统；
  C 存北京时间文本。
- 决策：A。铁律一：存储/传输一律 epoch 毫秒（UTC 语义）；铁律二："今天/明天/星期几/
  第几周/几点"的一切解释只按 Asia/Shanghai。`core/time` 收敛为唯一时间工具箱，各模块
  不得自行拼装时区语义（M1 落地）；不引入时区库、不做跟随系统时区。
- 后果：正面——与现状数据兼容（无需迁移），消灭并存混用的隐患；负面——Dart 无命名
  时区库，Asia/Shanghai 以**固定 UTC+8 偏移**实现（不处理历史夏令时语义）；跨时区
  需求真出现时再开新决策。
- **L2 审查整改修订（2026-08-14）**：铁律一增加**线协议兼容例外**——已发布的
  SourceBundle 1.0 / QueryResult 1.0 信封内时间字段（collectedAt/generatedAt 及
  bundle 数据时间字段）维持发布时的 +08:00 ISO-8601 线格式（改线格式等于改已发布
  契约、破坏 Python oracle 对拍）；C1 产出/C3 解码边界完成换算，进程内存与数据库
  一律 epoch ms（09 §2.1）。

### ADR-016：外部查询消费侧重设计——进程内 QueryJob + 事件流（参考 MCP/OpenHands）

- 状态：**已采纳**（2026-08-12，用户拍板）
- 上下文：旧房 QuerySourceGateway 为跨进程 HTTP 双轮询 + 独立恢复端点，状态散落三处、
  时序 bug 高发，用户实测接近不可用；参考 MCP Tasks（ProgressToken / CancelledNotification /
  Elicitation，[modelcontextprotocol.io](https://modelcontextprotocol.io/extensions/tasks/overview)）
  与 OpenHands 事件流架构（[docs.openhands.dev](https://docs.openhands.dev/sdk/arch/events)）。
- 选项：A 重设计——进程内 QueryJob 对象 + D05 事件流，取消/登录恢复模型化为作业暂停态；
  B 接口冻结换实现（已被实测否定）；C 引入完整 MCP 协议栈（过度设计）。
- 决策：A。submit 返回 QueryHandle{events, cancel, resumeLogin}；needs_user_login = 暂停态
  等用户输入（elicitation 模型），同对象恢复；无轮询、无独立恢复端点；QueryResult 1.0
  envelope 保留为出站安全校验载体（references 白名单/敏感键拒绝语义照搬）。重设计范围：
  domain/query_source.dart 契约 + 4 个外部只读工具适配（M6）；AgentSessionService 推理循环不动。
- 后果：正面——根除轮询时序 bug 面，状态机可单元测试（fixture 注入替代 HTTP 时序模拟）；
  负面——契约重写 + 4 个工具适配，工作量计入 M6。
- **第三轮整改修订（2026-08-12）**：QueryJob 不再由 C4 直连 C1 创建，改由 **C2 统一
  仲裁网关（SourceJobGateway）**创建/持有/收尾；C4 经 C2 提交查询、获得经安全校验的
  QueryResult。ADR-004 的租约戳与迟到拒绝语义适用于查询作业。
- **L2 复审收口修订（2026-08-14，用户批准）**：目标态只保留一个 canonical
  QueryResult 1.0，不设 Python/Native 双版本；M2–M6 PythonChannel 在 C2 边界逐字段
  转换 legacy 结果，转换后仍按封闭字段集 fail-closed。iCourse 只暴露确定性
  `selectedEvidence→evidence`，完整 `reviews` 不进入 canonical 信封；其余逐类型字段与
  legacy 映射见 09 CT-C1-04。

### ADR-017：Agent 数据面保持"聚合根级服务 + 应用层门面"，不引入统一仓库层

- 状态：**已采纳**（2026-08-12，用户拍板）
- 上下文：M03 服务层与 AgentLocalDataGateway 现状已合 DDD/六边形模式（聚合根级服务 +
  应用层跨聚合门面，参考 [clean_architecture_linter 指南](https://github.com/ittae/clean_architecture_linter/blob/main/doc/CLEAN_ARCHITECTURE_GUIDE.md)
  与 [StackOverflow 六边形仓库层次讨论](https://stackoverflow.com/questions/77726069/on-which-layer-is-the-data-warehousing-interface-placed-in-the-hexagonal-archite/77729401#77729401)）；
  数据层形态与是否原生化无关。
- 选项：A 保留服务层形态（M1 原样重建、借单账号模型删多账号分支），Agent 门面定位为
  应用层跨聚合编排；B 统一仓库层（违反"仓库按聚合根分"共识）；C 服务搬进 Agent。
- 决策：A。AgentLocalDataGateway/AgentWriteGateway 属应用层编排与端口适配，不是仓库；
  不引入新抽象层。
- 后果：正面——符合 DDD 共识、避免纯增层；负面——服务层若在 M1 重建中膨胀，"形态
  不变"纪律可能掩盖设计债（以子域划分 + 09 契约冻结对抗）；重建纪律：形态不变≠代码
  复制，接口语义与旧房一致，旧房测试迁移作回归基线。

### ADR-018：Agent 保持 feature 内聚合，用 subpackage lint 机械守护平台无关边界

- 状态：**已采纳**（2026-08-12，用户拍板）
- 上下文：拆包收益场景为"多消费者共享同一核心"，本项目单 App 三端共用一个 Flutter
  工程、不满足（参考 [AppFlowy 项目结构](https://deepwiki.com/AppFlowy-IO/AppFlowy/1.2-project-structure-and-technology-stack)
  与 [Melos 多包适用讨论](https://github.com/invertase/melos/discussions/299)）；Dart
  官方默认单 package 内目录分层（[dart-lang 模块结构](https://github.com/dart-lang/language/blob/46411cb4a9ec4cf3d2f0c9f756c51171ccac7e94/resources/bazel/module-structure.md)）。
- 选项：A 保持聚合 + subpackage_lint 机械守边界 + 拆包触发器=出现第二个真实消费者；
  B 现在就拆独立包；C 合并。
- 决策：A。M6 重建时 domain/application 保持零平台依赖（forbid dart:io/DPAPI/Win32），
  用 [subpackage_lint](https://pub.dev/documentation/subpackage_lint/1.1.0+2/index.html)
  禁止跨边界 import；将来拆包走 Melos/workspace，纯 Dart 边界即切割线。
- 后果：正面——约 1% 成本取得拆包 90% 收益（边界机械守护）；负面——lint 仅守护 import
  边界、无法守护运行时能力误用；规则维护与误报豁免需持续成本。

### ADR-019：凭据红线按三类资产修订（审查 A-1）

- 状态：**已采纳**（2026-08-12，用户拍板）
- 上下文：红线原条文要求 Cookie/Token 也"经 CredentialProtector 密文落库"，与浏览器
  会话资产由 WebView 运行时写入 profile 的事实矛盾；Dart 不可变 String 无法保证绝对
  零化（参考 [Bitwarden Memory Hardening](https://contributing.bitwarden.com/architecture/deep-dives/memory-hardening/)）。
- 选项：A 三类资产三类边界（显式凭据密文 / 浏览器会话资产受控分区 / 临时明文尽力零化）；
  B 维持一刀切原文；C 放弃持久化 WebView profile。
- 决策：A。§2.1-1 按三类资产修订；浏览器会话资产约束并入 ADR-002 的卡槽语义；零化
  承诺改为"尽力零化 + 永不落日志"。
- **第三/四轮整改修订（2026-08-12/14）**：浏览器会话资产范围扩大为"浏览器运行时维护的全部
  认证状态"（Cookie/LocalStorage/SessionStorage/IndexedDB/缓存/Service Worker/认证
  header/WebAuthn 引用）；会话端口拆分为 **BrowserAutomationPort**（navigate/wait/click/
  fill/受控提取脚本）与 **BrowserSessionAdminPort**（open/probe/close/clearPartition →
  不透明 SessionPartitionRef，另提供持久 quarantine 标记，清理成功前跨重启禁止复用），
  **不公开 cookies/storage/认证 header 或任何敏感明文取值**；
  evaluate 仅允许登记提取脚本、返回值经 schema 与敏感键检查，禁止读 document.cookie/
  各 Storage/IndexedDB/认证 header；Native 与 Python 通道满足同一会话资产契约。用户执行
  "清会话"或 completeReset 时，必须清除该账号在**全部已注册 Native/Python 通道**中的
  会话分区，而非只清当前选中通道；身份核验失败后，受影响分区必须隔离并清除，不能继续复用。
- 后果：正面——红线与实现事实一致、可机械验收；负面——放弃"绝对零化"表述（诚实化）；
  清会话需遍历全部已注册通道，任一分区清理失败都必须保留隔离状态并增加恢复成本。

### ADR-020：凭据经 C2 一次性租约注入 C1，C1 不依赖 C3

- 状态：**已采纳**（2026-08-12，用户拍板）
- 上下文：C1 交互登录需要 username/password，凭据仓库在 C3；C1 禁止依赖 C3（08 依赖
  铁律）；"凭据经 C0 端口流动"表述错误——CredentialProtector 只是加解密能力，不是凭据
  仓库（审查 C-2）。
- 选项：A C2 一次性租约（启动作业前向 C3 申请，作为作业参数注入 C1，读取一次即失效）；
  B C0 级 Identity 端口（污染 C0 纯工具定位，给 C1 开常驻读凭据口）；C C1 回调 C2 取凭据
  （回调穿透作业状态机，时序复杂）。
- 决策：A。租约含 expectedUsername；密码仅在 needs_user_login 恢复时按需附带（用户确认
  后才申请，红线 2.1）；恢复同一作业重新申请租约；C1 读取一次即失效、用后尽力零化。
- **第三轮整改修订（2026-08-12）**：凭据恢复路径闭合——C4/C5 请求恢复 → C2 验证作业
  处于 needs_user_login → C2 在用户确认后向 C3 申请一次性凭据租约 → 注入同一个 C1/Python
  作业 → 一次读取即失效；同步与查询**不得各自实现凭据旁路**。
- 后果：正面——依赖铁律不破、凭据存活面最小；负面——C2 增加租约申请/失效状态
  （签名由 09-contracts 冻结）。
- **L2 复审收口修订（2026-08-14，用户批准）**：租约主体显式建模为
  `CredentialSubject = StoredAccountSubject | ProvisionalSubject`。首登/重认证 staged
  凭据以不透明 `ProvisionalHandle` 申请租约；首登只在 C3 内存预分配 accountId，不提前
  写 local_accounts/source_configs。两类主体共用 `takePassword()` 取即失效与 revoke
  语义（09 §6.3）。

### ADR-021：目标态移除文件导入路径（L1-02 补记，审查 D-2 要求补 ADR 四要素）

- 状态：**已采纳**（2026-08-12，用户拍板于 L1-02）
- 上下文：旧房有 file-origin 导入（ImportOrigin.file）；L1-02 在容器层拍板移除但未走
  ADR 流程（审查 D-2）。
- 选项：A 移除（目标态仅"采集→导入"单一路径）；B 保留文件导入。
- 决策：A。M1 不含 file-origin 测试；M5 无文件导入入口；旧房 file-origin 能力随旧房退役。
- 后果：正面——导入面唯一、ImportService 契约简化；负面——丢失"分享课表包"入口与一条
  现成测试通道；将来如需恢复，走"来源适配器 + 文件抓取"正规化，不复活 origin 分支。

### ADR-022：恢复语义从简（L1-08 补记，审查 D-2 要求补 ADR 四要素）

- 状态：**已采纳**（2026-08-12，用户拍板于 L1-08）
- 上下文：跨重启残留两类（running 中断 / waiting_user 确认卡悬挂）；恢复重机制价值低
  （单机单账号产品）。
- 选项：A 跨重启一律中断作废（确认卡作废 + 审计、暂停查询不恢复）；B 持久化确认卡 +
  跨进程恢复（重机制）。
- 决策：A。schema 零增量。
- **第三轮整改修订（2026-08-12）**：本 ADR 只覆盖普通作业（running/waiting_user）的
  跨重启作废；**reset_pending 不属于此范围**——它是用户已确认的数据删除意图，为满足
  用户主权与隐私必须跨重启保留直到完成或明确失败（见 ADR-023）。
- 后果：正面——消灭悬挂态雷区、状态机大幅简化；负面——关 App 前挂起的确认卡失效、
  用户需重新发起；UI 需提示"上次待确认操作已失效"。

### ADR-023：账号生命周期一致性——首次登录单事务提交 + 重新认证身份不变 + 维护操作隔离/可恢复终结

- 状态：**已采纳**（2026-08-12 用户拍板，2026-08-14 用户授权第四轮复审收口）
- 上下文：旧房首登实际顺序是"确认并激活账号→导入"（01§3 流程 A），导入失败会留下
  已激活账号/凭据但没有完整业务快照的跨事务窗口；第二轮目标稿又曾误写成"导入→确认"，
  与活动账号导入守卫冲突。重新认证曾表述为"更新 identityDigest"（身份可变）；
  completeReset 伪原子回滚无法覆盖跨数据库/浏览器分区的失败；普通清业务数据/清会话若
  不先隔离进行中作业，也会被迟到写入或未清通道破坏。参考 SQLite 单库原子事务、Kubernetes Finalizer
  （terminating→禁新工作→清理依赖→完成删除）、Temporal Saga（集中协调 + 幂等步骤 +
  可重试前向恢复，不宣称全部回滚）。
- 选项：A 账号生命周期统一收口（commitFirstLogin 单事务 / identityDigest 重新认证不可变 /
  completeReset durable finalization / 其他破坏性维护统一隔离门）；B 维持旧房顺序 + 文档化
  窗口；C 每次操作各自编排且不共享隔离语义。
- 决策：A。
  ① 首次登录：C3 `commitFirstLogin` 单事务完成"绑定/创建账号 + 导入 SourceBundle +
  凭据密文 + identityDigest + 置活动 + 审计"，任一失败整体回滚；ImportService 跨容器
  公共入口仅支持 normal，首登由 commitFirstLogin 复用 C3 私有事务内导入核心；两者分别
  校验 activeAccountId 或 provisional/verifiedUsername/jobId/generation。首登 provisional
  上下文只存在进程内存，以不透明句柄引用，
  不得写数据库/文件/日志；凭据仅经一次性租约交给当前作业，使用后尽力零化，
  作业失败或进程退出即丢弃。
  ② 重新认证：identityDigest **不可变**——仅首次建立或显式 schema 迁移可写；重新认证
  前后校验 digest 一致，只更新凭据密文与元数据；不匹配返回 account_mismatch/
  identity_mismatch。若不匹配发生在浏览器认证之后，数据库身份/凭据/业务数据保持不变，
  但受影响会话分区必须先写入持久 quarantine 标记，再由 C2 清除；清除失败时标记跨重启
  保留并向 UI 报告，禁止复用。
  ③ completeReset：CompleteResetCoordinator（C5）编排 durable finalization——beginReset
  （持久 reset_pending + resetEpoch++ + 写屏障）→ C2 拒新作业/取消并等待全部 Native/
  Python 作业终态 → C4 拒新 run/工具/审批并等待 → C2 按通道幂等清会话 → C3 finalizeReset
  单事务删除 + 清 reset_pending + 广播空账号 → C5 回首登；所有完成事件/导入/Agent 写入
  携带 resetEpoch，过期即拒；启动检测 reset_pending 是**强制启动门**，恢复失败时保持写屏障
  并进入专用恢复界面，禁止正常路由/自动同步/Agent，不得按 best-effort 忽略。
  ④ 其他账号维护：删除凭据先由 C2 撤销未消费凭据租约并终止可能消费凭据的作业；清会话
  清除全部已注册 Native/Python 通道分区；clearBusinessData 由 C5 维护协调器先调用 C3
  `beginBusinessDataClear` 建立写屏障并等待已进入的本地写事务终态，再持有 C2/C4
  维护独占权，拒绝新作业/新写、取消并等待旧作业，递增相关 sourceGeneration 后由 C3
  单事务清理；提交或回滚后才解除屏障和维护门，防止本地并发写或迟到结果重建数据。
- **L2 复审收口修订（2026-08-14，用户批准）**：`stageFirstLogin` 返回仅内存的
  `ProvisionalAuthContext{handle, prospectiveAccountId, expectedUsername, initialSourceGeneration,
  initialResetEpoch}`；`commitFirstLogin` 接收并事务内复验原 `LeaseStamp` 后才创建预分配
  accountId。`commitReauthentication` 同样接收 stamp 并事务内复验，identityDigest
  不可变规则不变。
- 后果：正面——账号生命周期的提交、认证、重置与清理竞态统一闭合，用户主权（重置可完成）与隐私（会话真清）
  有机械保障；负面——① C3 事务接口比旧房复杂；② ImportService 需拆出不对外暴露的
  事务内核心供 normal/首登两条入口复用；③ completeReset 需少量持久维护状态；④ C2/C4 需维护独占门，P 需承载
  并存期进程/回环适配；⑤ 组合级故障注入测试成本增加。
  缓解：全部负面计入 M1/M5 工作量与测试清单，不推迟到第 2 层之外。

## 5. 第 0 层 gate 检查表

- [x] 红线清单编制（§2：安全五原则 / 产品不变量 / 过程 / 旧房专属 + 移交登记）——§2.1–§2.5 已确认（2026-08-12）；§2.1-1/原则 3 经第三轮整改修订为实现无关语义（ADR-019 修订 + 元规则）
- [x] 决策登记表覆盖 01–06 §8 全部开放决策与 §10 架构级存疑（D01–D38，含出处；D33–D38 为审查补漏）
- [x] 单向门 D01–D17 逐项拍板并落 ADR——A 组（ADR-001~005）+ D30（ADR-009）；B 组（ADR-006~008、010~012）；C 组（ADR-013~015）；D 组（ADR-016~018）全部完成
- [x] 双向门 D18–D38 延期合理性确认——已确认（2026-08-12）；D18 已取消（ADR-004 单账号模型）；D32 为 2026-08-12 后补；D33–D38 为审查补漏（2026-08-12）
- [x] ADR-000 已固化（已随 AGENTS.md 提交）
- [x] **第 0 层 gate 关闭（第四轮复审收口后重认，2026-08-14）**：红线自洽（元规则迁出 4 项入 §2.5，共 20 项）+ ADR-000~023 一致 + D01–D38 归类闭合 + 第三轮修订（ADR-004/016/019/020/022 修订 + ADR-023 新增）+ 第四轮收口（旧房首登上下文纠正、身份不匹配会话隔离、全通道清会话、账号维护独占、Python 并存适配边界）→ 进入第 1 层
