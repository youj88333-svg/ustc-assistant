# 10 本分支运行链路

## 本分支当前规则

2026-10-09 按 [09 K-01–K-06](09-contracts.md)修订。以下定义必要的运行顺序和失败出口；本地 M0、M1 已执行的自动与真实人工检查分别记录于 [15](15-construction-methodology.md)，其余能力仍待验收，不继承旧链路的关闭状态。

### 启动与首登

本地基础 M0 使用明确标注“合成演示”的独立装配、目录和本地上下文，直接验证合成采集与事务链路，不进入真实首登、不创建正式账号或学校会话许可。真实来源注册保持 unavailable，不用合成 verifier 放行生产来源。以下首登与维护顺序在对应真实能力切片启用前实现并验收；本地 M0 仍执行目录排他、版本守卫、取消/提交裁决及必要恢复。

同一应用数据目录仅允许一个活动进程。C5 在开库、迁移和分区调和前先经 P 取得该目录排他所有权，并持有至资源收口和退出；第二实例只激活现有实例或退出，不进入业务链路。取得所有权后打开数据及维护状态；有已确认但未完成的 reset 时先恢复删除流程。随后读取 C3 已提交认领许可，P 调和所有登记分区与 provisional 私有资产：先处理 deletePending，仅凭匹配具体 partition、attempt、owner、未撤销且属于当前 resetEpoch 的有效许可认领或保留 claimed；无许可候选回收，claimed 缺许可、许可撤销或不匹配则持久隔离/标记 deletePending，排空并真清理。即使在 C3 撤销成功、P 标记删除前退出，也不得凭 P 的 claimed 标志或账号存在复用；必要清理完成前不恢复正常启动。失败进入恢复页，提供重试与退出，不开放来源、Agent 或正常写操作。需要迁移时先只读清点实际输入元数据，确认映射后从一致受控副本转换、验收发布，再调和并开放业务。启动还按 C3 持久业务及期望提醒对账平台通知，未完成项明确保留待办。

首登顺序：

1. C5 收集用户输入 → C2 原子取得全局租约；busy 时尚未 stage，不创建临时分区。
2. C3 在内存 stage 并预分配本地账号 ID；C2/C1 经 P 原子登记 purpose=initial、attempt、partition、owner 后创建 provisional 分区。
3. C1 开启可见认证交互；需要用户操作时暂停同一作业。用户确认后经 C2 申请一次性凭据租约，验证码由用户操作。
4. 登录后按原作业目标打开业务文档，执行该来源有效身份契约、获取学期及业务数据；每次提取关联当前文档。身份不通过不得交付。
5. C1 在仍有效的业务文档中核验并封存不可变内部采集产物，绑定身份判定、规范化数据、来源契约、分区和原作业，随后只做收口。正常关闭不废除该产物；C2 校验原作业戳，C3 单事务复验账号、维护状态、generation、epoch 和完整性，提交账号、身份绑定、配置、业务快照、必要凭据密文及保护元数据、具体分区认领许可与审计。P 负责凭据保护和按需解密，密文随 C3 SQL 事务存储；浏览器手填的秘密不反读。
6. 提交后由 C5/C2 经 P 凭有效许可认领分区与必要私有资产，成功且必要收口完成后开放主界面；账号提交成功而认领或资源收口失败进入恢复页，不重做业务事务。

在步骤 5 提交前，作业失败、用户取消、校验失败和事务回滚均销毁 staged 上下文、撤销租约，closeAndDrain 后回收本次 provisional 分区及私有调试资产。清理失败保留 P 的待删除登记并进入恢复页。进程崩溃的内存上下文失效，持久归属与清理待办在下次启动调和；不会因无数据库账号而跳过分区清理。

### 教务日常自动采集（2026-10-10）

空闲时可从上次成功保存的目录提前选学期；用户提供新密码（可选择本机保存）或使用已有加密凭据 → 全局租约和当前作业，捕获本次选择 → 固定可见认证流程 → 单次投递/学校按钮提交 → 等待复杂重定向 → 固定课表入口 → 新目录 → 复验开始前选定项，未指定则沿用上次成功学期，首次按北京时间月份匹配唯一当前标签 → 每次复验只读接口、本人路线和前后身份 → 封存、排空、原子导入/凭据保存/学期目录及成功学期保存与认领。月份规则为 2–6 月当年春、7 月当年夏、8–12 月当年秋、1 月上一年秋，仅匹配实际目录 ID。过期会话将业务入口送回认证站点时接续同一作业；认证页面与业务页面的 ready 不混用。提交后 AJAX 响应尚未完成不能当作失败而再次发密码。

挑战、额外授权或结构不明时进入 manualRequired，保持作业与租约；用户在学校窗口完成后点击“登录完成，继续采集”。新密码和新目录仅在成功导入后保存，取消或失败不替换旧事实。指定/成功学期缺失，或首次当前标签缺失/不唯一时才进入 choosingSemester；不会默换为最新学期。缓存不代替最新目录或来源核验。启动仅升级本地库和恢复资产，不自行访问学校。具体实证与当前未完成项见 [15 接续任务](15-construction-methodology.md#m1-业务契约验证与采集接续任务2026-10-10)。

### 二课日常自动查询与日程同步（2026-10-11）

已有账号直接核对同一本机学校身份；未绑定时先输入预期学号。空闲时选择日程日期范围（最多 62 天，首次北京时间当月，后续上次成功范围），或直接查询活动；可提供新密码并选择保存，留空使用共享学校加密密码。C2 取得全局租约并建立 Young 作业/分区后，复用固定认证驱动：等待精确 CAS 表单、申请一次性租约、单次投递与提交，等待重定向，再打开本次固定业务目标。无需正常登录后再次点击继续，也无需进入学校页手动翻页或选择日期。

固定业务准备只等待主文档、最终 SPA 路径与登记 helper 就绪，并要求短暂稳定；过期授权重回认证时接续原作业。准备完成后 C1 从前后业务身份和全部活动页或逐日全部日历页构造封存产物，排空后经 C3 提交。活动查询的业务列表只在内存交付，不导入日程；日程先验证全部行与完整性，再排除未关联活动的行，保留本地身份和覆盖。新密码与成功查询/导入回执同事务保存；失败、取消或回滚保留旧密码、教务事实和既有二课日程。

Young 门户 `/login/` 和 namespace 根回调页都保留给学校自己的跳转/票据处理；等待自然进入 namespace 子路由，再等当前文档 ready，才发出一次固定活动或日程导航。不得在门户完成加载时抢先打开深链接，也不以固定睡眠代替这段状态转换。明确未导航的 busy 可以有界等待；已发出导航后的未知确认失败不重发。真实手动观测与产品原生合成回归分别记录于 [15 登录接续](15-construction-methodology.md#m23-登录阶段-busy-与手动跳转观测2026-10-11)。

无保存密码、学校挑战、结构不明或额外授权时才 manualRequired；用户完成学校操作后继续同一作业，已投递的密码不自动重发。读取开始后的导航、路由或 context 变化仍拒绝本次产物，不以准备阶段的等待规则容忍过期读取。收口完成后的失败显示闭合失败阶段及原因，不能继续显示正在关闭；收口未完成仍保持恢复与互斥。清 Young 登录资料保留共享密码/JW 资产，删除共享密码明确影响两来源；启动和清理不自行访问学校。检查与真实待验见 [15 同一任务](15-construction-methodology.md#m23-真实失败与自动认证接续2026-10-11)。

### 浏览器装配与兼容性故障

真实观测及产品来源采用 07 DR-ADR-09 的普通 WebView 装配：打开页面前设置顶层/frame 导航、弹窗、下载、权限申请与外部协议控制，登记固定采集操作并建立文档关联。保留分区隔离、凭据保护和排空真清理；来源特定常规请求规则只在可靠且兼容性已验证时采用。装配不主动注入 CAL、不安装全协议防护扩展、不一律禁用 Worker、不以 JS 替换 WebRTC，并尊重页面已有策略。页面正常后台网络活动无需证明全部封闭，不因这类未知流量阻止登录观测或判来源 unavailable；保留控制及身份/响应契约仍须验收。

不在启动、首登、同步或发布前运行 CAL 资格门禁，也不等待补丁运行时。原实验失败留档，不记为修复通过。若实际页面发生渲染进程故障，则立即使相关文档/操作失效，终止未完成采集，按既有取消/提交及收口规则处理；未提交产物不得补报成功，已提交事实保留，排空或清理失败进入恢复。只在实际发生时定位兼容性问题，不删除或放宽来源原有安全策略来绕过。

### 同步与查询

普通同步经 C2 取得作业戳，C1 打开正式分区并独立核验来源身份；健康探测只决定是否需要登录。C1 在活文档中封存完整快照后收口，C3 消费封存产物而非重新要求已关闭文档仍存活，在提交事务内检查账号、维护状态、原 generation/epoch、完整性、幂等和引用。业务及期望提醒由 C3 持久事务提交，平台通知在事务外协调，失败记录待重试；C2 收尾业务结果并等待 C1 资源收口后才释放租约和发布 idle。

二课报名、评课与校园信息走 C2 查询入口，不加入同步来源集合。身份来源按 K-01 核验，公开来源不申请学校密码。结果须完成封闭字段、应用主动请求的出站和不可信输入检查后才入 Agent 对话；不以页面所有后台网络封闭作为结果交付条件。需要缓存落库的来源结果同样由 C3 事务复验原作业戳。来源查询与模型推理是两种运行状态，不合并为共享状态机。

完整快照内未返回的旧记录更新来源观察状态并保留业务；窗口外不改成缺失；不完整响应零导入。课表、Agent、提醒与冲突读取同一投影，来源缺失不自动退出；用户明确隐藏经本地业务事务提交。

### 暂停、恢复与取消

| 场景 | 顺序与结果 |
|---|---|
| 等待登录/验证码 | 保持同一 jobId、全局租约和原业务目标；等待用户，不自动绕过核验 |
| 用户请求恢复 | C2 校验仍为当前暂停作业并串行受理；按需申请凭据 → 恢复 → 重新打开原业务目标 → 文档及身份核验 → 继续执行 |
| 重复恢复/过期句柄 | 不重复填表或创建第二个作业；稳定拒绝或返回已受理状态 |
| 用户取消 | 由 C3 事务先后裁决：取消先受理则使原 generation 失效、撤销未消费凭据，未提交产物拒绝；提交先发生则保持 committed，只停止仍可停止的后续动作，必要认领、收口及恢复继续。迟到回调不能追加写库或入对话 |
| 资源收口失败 | 保持禁复用与协调恢复状态；重试收口或退出，不发布 idle |
| identity_unverified / identity_evidence_conflict | 正式分区关闭本次句柄、不交付并保留资产；下次作业重新核验；initial/recovery 的未提交候选均按 K-02 回收 |
| account_mismatch | 持久隔离受影响分区 → 终止占用 → 真清理；失败保留待办与明确 UI 状态 |

跨重启普通作业及确认卡的恢复方式尚待相关设计确认；进程退出后的内存句柄不能被继续调用。不论普通恢复方案如何选择，已确认的 reset 删除意图和分区清理待办必须跨重启保留。

C2 向 C5 交付的结果同时包含提交事实和后续待办；恢复或重试待办不等于重新导入。

| 结果 | C5 展示与下一步 |
|---|---|
| 等待用户 | 未提交，展示原暂停目标并由用户确认继续 |
| 未导入失败/取消 | 未提交，展示稳定原因；必要收口或候选清理完成后才可重新发起 |
| 已导入但提醒待处理 | committed，显示导入成功及提醒待办，按期望提醒重试平台协调 |
| 已提交但认领/资源待恢复 | committed，进入恢复页，只重试必要认领与收口 |
| 提交后取消 | committed，保留已提交结果与许可，说明已停止的可停止动作及剩余必要待办 |
| 清理未完成 | 保持维护/恢复状态，显示未完成范围，提供重试与退出，不报清理成功 |

C5 分别负责首登凭据用途、继续原暂停目标、维护删除范围三类应用确认。验证码与学校授权由学校认证页面负责；应用确认不能替代程序身份核验或把未知身份改判匹配。

### 重新认证与维护

重新认证在创建学校作业前由 C3 校验输入仍属既有本地身份；失败为 identity_mismatch，既有账号、业务、凭据和分区保持。通过预检后走相同来源身份规则。已有账号无可用正式分区时，先完成既有 deletePending，再经 C2 创建 purpose=recovery 的 provisional 候选，登记新的 attempt、partition 和既有 owner；不因账号存在就认领。只有真实身份匹配且原戳有效，C3 才在重认证事务中更新必要凭据及绑定具体 partition/attempt/owner/resetEpoch 的认领许可，既有身份和业务不变；失败不替换旧凭据，收口并回收候选。提交成功后的认领失败按许可恢复，未知证据不触发正式分区串号清理。

删凭据先撤销未消费租约并停止可能消费它的作业，再由 C3 事务删除受保护凭据；保留正式账号与会话。清会话先拒新作业、使旧结果失效并排空占用，撤销对应认领许可，再清理本应用登记的对应分区。清业务数据先建立写屏障、等待已进入事务及 Agent/来源收口，再提交用户确认范围的清理；操作失败可重试，安全收尾后才解除维护状态。维护期间停止提醒调度，处理在途发布及已登记通知后才能完成，失败保持待办；恢复按 C3 事实对账，不承诺未经证明的 exactly-once，具体平台能力和参数仍按 V-08 验证。

单独清 Agent 历史时，C3/C4 入口先拒绝新的相关运行，使旧流、摘要、查询和确认失效并排空；迟到写及新增请求复验当前会话世代与授权。清业务数据后按用户选择保留的历史仅作历史，旧批准及业务引用失效，不能继续授权或定位写入。完整模型与工具状态在 V-06 对应设计触发时补齐。

完全重置先持久 reset 意图和 epoch、阻止新写并撤销认领许可，随后收口所有来源和 Agent、停止提醒调度并处理在途及登记通知、清理本应用会话和用户确认的私有资产，最后提交业务及确认范围内凭据删除。跨步骤失败维持屏障；启动重放未完成阶段，不把文件未删除记为 reset 成功，不删除旧工程或系统浏览器资产。

## 历史设计资料

下文旧序列图、失败特例、五来源路径和关闭记录保留原文。真实路径仅提供观测线索；当前实现须按上方及 09 重定义身份、导航、分区和响应契约。

# 10 运行时链路走查（六层阶梯 · 第 3 层）

> 产出日期：2026-08-14 ｜ 状态：**第 3 层已关闭（2026-08-14 用户重认；2026-08-15 用户批准 L3-06 严格文件清理回写；2026-08-23 Task 17 回写 L3-07；2026-08-25/27 M2 真实验收回写 L3-08~10）**
> ｜ 依据：`09-contracts.md`（CT-C0-01~CT-T-04 共 65 条冻结签名，L2-01~26）、
> `08-target-architecture.md` §7 五链路容器级走查、`07-constitution.md`
> （ADR-000~023 + 修订注）、01–06 模块文档（main 代码为准）

## 1. 本层目标与 gate

- 目标：把第 2 层冻结的 CT 签名**装配成可执行的运行时序列图**——三条主要 E2E
  （同步 / Agent 查询 / completeReset）+ 两条账号生命周期子链路（首次登录 / 账号
  维护）+ 五条数据链路（jw / young-schedule / young-enrolment / icourse / campus）
  的 fetch→normalize→validate→deliver 管道；**每条消息标注 CT 编号与关键参数，
  每个分支出口标注终态 / 稳定错误码 / 暂停态**。
- 与第 1 层的区别：08 §7 是"容器名能否走通"；本层是"CT 签名能否走通"——消息必须
  引用 09 中真实存在的契约，不得发明新接口（发现缺口即回写第 2 层，本层首轮审查
  已回写 L2-15/L2-16/L2-17）。
- **gate：① 五条链路 + 五条管道全部走通无死胡同（每个 await/事件/错误都有去向）；
  ② 每条数据链路 fetch→normalize→validate→deliver 四工位闭合；③ 并发/迟到/取消/
  崩溃四类边界情形逐条有去向（§9 扫描表）；④ 本层引用的每个 CT 编号在 09 §11
  矩阵中存在。**

## 2. 运行时基元（并发模型与作业生命周期）

### 2.1 执行模型

- 单 isolate 事件循环承载 C0–C5 纯 Dart 部分；平台会话/进程在 P（CT-P-01~08）。
- **C2 单线程持有**：全局来源作业租约（CT-C2-01）、凭据租约流转（CT-C2-03）——
  同一租约的 `takePassword()`/`revoke()` 串行化由 C2 单线程持有机械保证。
- 事件流唯一方向：C1 → C2 →（转播）→ C4/C5（CT-C1-01 `SourceJobHandle.events`）；
  事件内只含安全计数，凭据/原始数据永不进流。
- 当前作业可见性：C2 注册 ordinary/query/first-login/reauth 的同一
  `SourceJobHandle` 后发布 `currentJob`；C5 可晚订阅并重放该 handle，needs_user_login
  期间可调用其 `resume/cancel`。C2 在 terminal settlement、资源清理及流关闭后发布
  `null`；仅仍持有该 handle 的 owner 可发布 `null`，旧作业 cleanup 不得清掉随后
  发布的新 handle，live-first+snapshot 不漏不重。C5 不读取 C1/P/JobArbiter。
- 时间：进程内一律 epoch ms（`BeijingClock`，CT-C0-01）；线协议 ISO 例外只存在于
  信封边界（SourceBundle/QueryResult 的 C1 产出与 C3 解码两处，09 §2.1）。

### 2.2 通用作业生命周期（同步类）

```
[C5/C4] ──入口（sync / submitQuery / firstLoginSync / reauthenticate，CT-C2-01）──► [C2]
  1. JobArbiter 原子取全局来源作业租约（A-3 整改：同步 check-and-hold，
     检查与持有之间无 await；isBusy() 仅为提示性预检）── 占用 → 抛 busy
  2. [仅同步/重认证] SourceStateService.startSyncRun(stamp, trigger)（CT-C3-21）
     → 返回 runId；[首登] 不写 run（账号行尚不存在，见 §6）
  3. 通道路由（已安装全集上的当前映射，CT-C2-02）
  4. C1/Python startCollection(spec) → JobEventStream（CT-C1-02/CT-C1-01）；终态事件先可见，
     stream `done` 等待 C1 session/凭据/active-record/NativeJobGate cleanup barrier
     Native WebView 作业只有在权威账号证据核验成功后才调用
     `confirmAuthenticated(ref)`（CT-P-02）；该调用不含身份或浏览器资产，P 仅据此在
     close 时保存不透明快照，禁止按 `/home` URL 猜测登录成功
  5. 事件转播（sequence 连续；八相位 + sequence/safeCount/终态载荷全集见
     11 D-07 / 12 XC-06）
  6. 终态接收：C2 校验 SourceJobHandle.stamp（CT-C0-03）
     ├─ 迟到 → stale_lease（不交接 C3/C4）
     └─ 正常 → 交接（见各链路）
  7. [仅同步/重认证] SourceStateService.finishSyncRun(runId, stamp, state,
     resultCode, importBatchId)（CT-C3-21）
  8. 终态释放全局租约（任何终态/异常路径都必须释放——try/finally 语义）
```

**取消与 generation（A-4/L2-17 整改）**：用户直接取消或 C2 通用取消 → 取消请求被接受的时刻先
`bumpSourceGeneration(source, cancel)`（CT-C3-21）→ C1 协作式终止（CT-C1-02）→
`cancelled` 终态 → finishSyncRun(cancelled)。**计数规则**：同一维护操作对同一来源
只递增一次、取根操作 reason；reset/clearBusinessData 内部触发的取消不再以 cancel
重复递增；deleteCredentials/clearSession 对活跃作业的取消没有独立根 reason，按 C2
通用取消以 cancel 对每个受影响来源递增一次（09 CT-C3-21 注）。

**sync_runs 终态映射（A-5 整改）**：

| 作业终态 | run state | result_code |
|---|---|---|
| complete + 导入成功/重放 | success | imported / replayed |
| cancelled | cancelled | cancelled |
| failed（采集/校验/导入） | failed | collection_failed / 对应 9 错误码 / sync_failed |
| 迟到拒绝 stale_lease | failed | stale_lease |
| needs_user_login 暂停期间 | **running**（不置任何暂停终态；确认后同一 run 继续，CT-C2-06） | — |
| 需要用户动作的失败（如 reauthentication_required） | needs_user_action | reauthentication_required |

### 2.3 租约戳组装与传播

- C2 组装：jobId/accountId/source/channelKind + `currentSourceGeneration`（CT-C3-21
  读取）+ `currentResetEpoch`（CT-C3-05 读取）；首登用 ProvisionalAuthContext 的
  预分配值（§6）。
- 传播纪律：`SourceJobHandle.stamp` 显式携带，任何 C3 写事务不得靠 jobId 反查或
  调用方上下文猜测（09 §2.3，L2-14）。

### 2.4 启动期来源配置调和与路由开放顺序（M3 触发；spec §3.4）

- 启动顺序冻结：**C3 启动初始化完成 → 已知来源配置调和 → C2 路由开放**。
- 已知来源配置调和（09 CT-C3-03/19 缺口修正，私有 C3 实现）：对每个已有账号幂等
  补齐五个冻结来源（`ustc_jw`/`ustc_young_my_schedule`/`ustc_young_enrolment`/
  `icourse`/`campus`）的 `source_configs` 行——仅插入缺失行、不覆盖既有
  `enabled/configJson/lastSuccessAt/retryAfter/sourceGeneration`、不新增表、v8=30 表。
  无账号时零写入。此调和使 C2 在任何普通同步/查询前都能读到目标来源配置与
  generation，"读配置"不偷偷产生写入。
- 首登的 `commitFirstLogin` 在既有单事务内创建全部五来源行（JW 写完整学期三元组、
  其余默认），不依赖本启动调和（§6）。

## 3. 主链路 ①：同步（手动/自动）序列图

参与者：C5（同步页/启动编排）、C2（SyncCoordinator + SourceJobGateway）、
C3（SourceStateService / ImportService）、C1（JobExecutor + 适配器）、P（WebView）。

```
C5                 C2                      C3                     C1/P
 │ sync(src,trig)（CT-C2-01）                                        │
 ├─────────────────►│                       │                      │
 │  0. 活动账号前置：无活动账号 → no_account（skip）                 │
 │  1. [automatic] freshness/retryAfter 预检（CT-C2-07）            │
 │      新鲜或退避窗口内 → fresh_or_backoff（skip，非错误）          │
 │     [manual] 绕过退避（CT-C2-07；CT-C2-08 只用于 campus/icourse） │
 │  2. JobArbiter 原子取全局租约（同步，无 await）→ 占用则 busy      │
 │  3. startSyncRun(stamp, trigger)（CT-C3-21）→ 返回 runId          │
 │                  ├──────────────────────►│ 写 sync_runs(running)│
 │  4. 通道路由 + 组装 spec（含无密码凭据租约：StoredAccountSubject → │
 │     expectedUsername；Jw/YoungSchedule CollectionRequest；         │
 │     spec.credentialLease 启动时只带 expectedUsername，09 §5.2）    │
 │                  ├── startCollection(spec)（CT-C1-02）──►        │
 │                  │◄── JobEvent 流（CT-C1-01）──┤                 │
 │  5. 转播事件（starting→checking_session→…）                      │
 │     checking_session 期间：probeSession → 会话健康（CT-P-02）    │
 │  ┌─ 分支 A：会话过期 ────────────────────────────────────────┐  │
 │  │ 6a. needsUserLogin（暂停态，流不断、租约保持；run 保持      │  │
 │  │     running，CT-C2-06）                                    │  │
 │  │ 7a. C5 弹确认卡 → 用户确认                                  │  │
 │  │ 8a. C2 resumeInteractive(jobId)（CT-C2-01）                 │  │
 │  │ 9a. C2 向 C3 requestCredentialLease(StoredAccountSubject,   │  │
 │  │     includePassword: true)（CT-C2-03）                      │  │
 │  │10a. resumeLogin(jobId, lease)（CT-C1-02）                   │  │
 │  │     → C1 takePassword() 取即失效                            │  │
 │  │11a. 同一作业、同一流、sequence 连续（ADR-005）              │  │
 │  └────────────────────────────────────────────────────────────┘  │
 │  ┌─ 分支 B：用户取消 ────────────────────────────────────────┐  │
 │  │ 12b. cancel(jobId)（CT-C1-02）被接受时刻：                  │  │
 │  │      bumpSourceGeneration(source, cancel)（CT-C3-21）       │  │
 │  │ 13b. C1 协作式终止 → cancelled 终态                         │  │
 │  │ 14b. finishSyncRun(runId, stamp, cancelled, 'cancelled')    │  │
 │  └────────────────────────────────────────────────────────────┘  │
 │  ┌─ 分支 C：正常完成 ────────────────────────────────────────┐  │
 │    15c. CollectionCompleted{bundleBytes, verifiedUsername?}     │
 │    16c. C2 校验 handle.stamp 仍属当前 generation/resetEpoch     │
 │         迟到 → stale_lease（不交接；finishSyncRun(failed,       │
 │         'stale_lease')）                                        │
 │    17c. C2 → C3 importBundle(bytes, stamp)（CT-C3-02）          │
 │                  ├──────────────────────►│ 事务内复验 stamp     │
 │                  │                       │ 解码→语义校验(9 码)   │
 │                  │                       │ →幂等→单事务落库     │
 │                  │                       │ →事务外提醒协调      │
 │                  │                       │ （失败降级为 pending）│
 │                  │◄──────────────────────┤ ImportResult{status,  │
 │                  │                       │  importBatchId,      │
 │                  │                       │  reminderReconcil-   │
 │                  │                       │  iationPending}      │
 │    18c. finishSyncRun(runId, stamp, success, status=='replayed' │
 │         ?'replayed':'imported', importBatchId)（CT-C3-21）      │
 │    19c. 若 pending → 记 retryable_failure 审计（后续触发重协调）│
 │  └────────────────────────────────────────────────────────────┘  │
 │ 20. 终态释放全局租约 → 事件 → C5 页面 drift 流自动刷新            │
```

死胡同核对（本链路）：no_account / busy / fresh_or_backoff / reauthentication_required
（凭据缺失）/ cancelled / collection_failed / stale_lease / 9 个 bundle 错误码全部
有稳定出口；提醒协调在 **importBundle 内部**（A-5 整改：C2 在 finishSyncRun 之前
收到 pending 标记）；needs_user_login 期间 run 保持 running；needs_user_action 终态
仅用于"需要用户动作"的失败账本。

## 4. 主链路 ②：Agent 查询序列图（外部 + campus + 本地）

```
C4(工具)          C2                        C3                    C1/P
 │ submitQuery(request)（CT-C2-01；A-1 整改：C4 唯一查询入口，      │
 │   不组装 spec/租约戳——C2 内部组装 SourceJobSpec）                 │
 ├───────────────►│ 1. JobArbiter 原子取全局租约（占用 → busy）      │
 │                │ 2. 通道路由 + 组装 spec（CT-C1-02）              │
 │                ├── runQuery(spec)（CT-C1-02）──────────►         │
 │                │◄── JobEvent 流（CT-C1-01）──┤                    │
 │ 3. 转播（SourceJobHandle{stamp, events, cancel, resume}）         │
 │  ┌─ young_enrolment 需要登录态 ─────────────────────────────┐    │
 │  │ 4a. needsUserLogin → C4 转确认卡 → resume → 凭据租约      │    │
 │  │     （仅 young_enrolment 可接受凭据；icourse/campus 从不） │    │
 │  └───────────────────────────────────────────────────────────┘   │
 │ 4b. QueryCompleted{result, verifiedUsername?,                   │
 │     attachmentRegistrations}（CT-C1-01；始终非 null；仅          │
 │     campus_detail 可非空，其余查询为空列表）                     │
 │ 5b. C2 校验 handle.stamp → 迟到 stale_lease（不进对话）          │
 │ 6b. C2 → C4 交接经安全校验的 QueryResult（CT-C1-04 封闭字段集）  │
 │ 7b. C4：信封校验 → OutboundPrivacyFilter 净化 → 入对话           │
 │                                                                  │
 │ campus 目录分支（campus_search 工具）：                           │
 │ 8. C4 → C3 目录服务判 freshness（CT-C3-07；语义 CT-C2-08：       │
 │    30min/6h）                                                    │
 │  ├─ 无需刷新 → C3 本地搜索（CT-C3-07）→ 入对话                   │
 │  └─ 需刷新 → 9. C4 → C2 submitQuery(CampusSearchQueryRequest)    │
 │       10. C1/P 抓取规范化 → C2 按 stamp 校验交还 C4               │
 │       11. C4 → C3 commitCatalogSource(stamp, result,             │
 │           attachmentRegistrations=[])（CT-C3-22）                 │
 │       12. C3 事务内复验 stamp → upsert entries/state/            │
 │           attachment_cache → 13. C3 本地搜索 → 入对话            │
 │  刷新失败且目录缺失 → catalog_unavailable（明确报错，不带部分数据）│
 │ campus_detail 工具：同外部查询路径（C4 → C2 submitQuery          │
 │   → C1/P 详情读取 → QueryCompleted{result, attachmentRegistrations}│
 │   → 14a. C4 → C3 commitCatalogSource(stamp, result,               │
 │           attachmentRegistrations)（CT-C3-22；登记附件缓存索引——  │
 │           否则下次读取永远 miss，自审补链）                        │
 │   → 15a. C4 入对话；附件命中缓存经 C3 Catalog 服务（CT-C3-07）     │
 │   读 campus_attachment_cache 索引定位 P 文件（A-2 整改：           │
 │   不再误引 CT-C3-20——那只是 clearCache）                          │
 │                                                                  │
 │ 本地读写（C4 工具 → C3 服务）：                                   │
 │ 14. 读：AgentLocalDataGateway（CT-C4-04）→ C3 六子域服务         │
 │ 15. 写：proposeWrite(view, expectedResetEpoch)（CT-C4-05）       │
 │     → 审批门（CT-C3-18 永久语义）→ resolveAndCommit(...,         │
 │     expectedResetEpoch) → 事务内比对 reset_epoch → 业务+审计     │
 │     +确认日志同事务；过期 → stale_lease                          │
```

死胡同核对：busy / stale_lease / result_validation_failed / query_failed /
catalog_unavailable / needs_user_login（恢复或取消）全部有出口；C4 不直连 C1
（全部经 C2，submitQuery 入口）。

## 5. 主链路 ③：completeReset 序列图（durable finalization + 启动恢复）

```
C5(协调器)      C2                        C3                    C4
 │ 0. 清单预览 + 双确认（CT-C5-01）                                │
 │ 1. C3 beginReset()（CT-C3-05）：reset_pending=1、resetEpoch++、│
 │    ├───────────────────────────►│ 写屏障（除 finalization 拒绝新写）│
 │ 2. C2：revoke 全部未消费凭据租约（CT-C2-03，A-7 整改）           │
 │     → 终止可能消费凭据的作业 → cancelAll（CT-C2-01）→ 等待终态  │
 │     （内部取消不重复 bump——根 reason=reset，09 CT-C3-21 注）    │
 │     → 拒绝新来源作业（稳定出口 = maintenance_in_progress）        │
 │ 3. C2 经 SourceStateService 以 reset 原因逐来源 bumpGeneration   │
 │    （CT-C3-21；SourceGenerationReason.reset）                    │
 │ 4. C4 拒新 run/工具/审批（CT-C4-03）；取消模型流/工具/确认；     │
 │    等待写终态                                                   │
 │ 5. C2 按已安装通道全集幂等 clearSession（CT-C2-02 全集语义）     │
 │    ├─ Native：C1/P WebView 分区真删除（CT-P-02）                 │
 │    └─ Python：P 租户适配器 profile 清理（CT-T-02）               │
 │ 5.1 C3 markResetSessionsCleared()（CT-C3-05）：持久              │
 │     reset_pending=2；从此启动恢复可跳过会话重放                  │
 │ 5.5 C3 clearCache 私有实现（CT-C3-20 范围：campus 三表+附件/详情 │
 │     磁盘缓存+icourse 24h 缓存）；文件先删、三表后删，任一失败保持 │
 │     pending=2 + 写屏障，不得继续 finalization                    │
 │ 5.6 P FileStoragePort.clearDebugAssets(accountId)（幂等；清      │
 │     debug/raw/<accountId>/）；失败同样保持 pending=2，不得删账号   │
 │ 6. C3 finalizeReset()（CT-C3-05）：单事务删 action_logs+undo_slot│
 │    +local_accounts（其余 FK CASCADE）→ 清 reset_pending → 广播空账号│
 │ 7. C5 回 /sync 首登态；C2/C4 于空账号态重新开放                  │
 │                                                                  │
 │ 失败分支（08 §7.3 表 + reset_pending 三值编码 0/1/2；09 §2.4 L2-18）：   │
 │   beginReset 未提交失败 → 原状（0）+ `write_commit_failed`               │
 │   C2/C4 取消失败 → 保持 pending（1）+ 写屏障，可重试                    │
 │   会话清理失败 → 保持 pending（1），不得绕过后删库                      │
 │   markResetSessionsCleared 失败 → 保持 pending（1），安全重放会话清理   │
 │   会话清除后先持久 pending=2；cache/debug 清理或删库失败均保持 2，      │
 │     下次启动重试两项私有资产清理，全部成功后才 finalization             │
 │   上述 pending=1/2 失败的对外稳定出口统一为 `reset_incomplete`           │
 │   finalizeReset 重复执行 → 幂等                                         │
 │                                                                         │
 │ 启动恢复（CT-C5-02 强制门）：                                           │
 │   C5 启动 → resetState()（三值编码映射）→ 非 0 即先于正常路由/           │
 │   自动同步/Agent 恢复重置；pending=1 先重新幂等清会话（安全重放），      │
 │   pending=2 跳过会话但重放 cache/debug 清理；全部成功后才               │
 │   finalization；恢复失败保持写屏障 + 专用恢复界面                       │
```

死胡同核对：beginReset 未提交失败回到原状并允许重新发起；其余失败分支以“可重试的
持久状态 + 明确下一步”结尾。所有完成事件/导入/Agent 写携带 resetEpoch，过期即拒
（stale_lease）——删除后不重建数据。

## 6. 子链路 ④：首次登录序列图（commitFirstLogin 单事务）

```
C5(表单)        C2                     C3                     C1/P
 │ firstLoginSync(FirstLoginRequest{username,password,savePassword}) │
 │   （CT-C2-01）                                                     │
 ├──────────────►│ 1. JobArbiter 原子取全局租约 → 占用则 busy        │
 │               │    （A-3 整改：先取租约后 stage，busy 时无需       │
 │               │     创建/销毁 provisional）                        │
 │               │ 2. stageFirstLogin(...)（CT-C3-03）               │
 │               ├──────────────────────►│ 仅内存：预分配            │
 │               │◄──────────────────────┤ prospectiveAccountId、    │
 │               │  ProvisionalAuthContext{handle, prospectiveAccountId,│
 │               │  expectedUsername, initialSourceGeneration=0,    │
 │               │  initialResetEpoch=0}；不插任何行、不落盘不落日志 │
 │ 3. C2 以 ProvisionalSubject 申请租约（includePassword:false）     │
 │    （CT-C2-03）→ 组装 LeaseStamp（prospectiveAccountId, gen=0）   │
 │ 4. startCollection(spec)（CAS 交互登录 D03，CT-C1-02；            │
 │    spec.semester=null ——首登无持久选择：登录后抓学期列表 +        │
 │    月份规则默认，ADR-009）                                        │
 │  ┌─ needs_user_login → C5 确认 → 同一 ProvisionalSubject 重申请  │
 │  │   含密码租约 → resumeLogin（CT-C1-02）→ C1 takePassword()     │
 │  └─ 成功：CollectionCompleted{bundleBytes, verifiedUsername,     │
 │         selectedSemester}（CT-C1-01；C1 实际选中完整三元组，A-6）│
 │ 5. C2 校验 stamp + verifiedUsername + selectedSemester 非空       │
 │ 6. C3 commitFirstLogin(handle, bundleBytes, verifiedUsername,    │
 │    selectedSemester, stamp)（CT-C3-03）                           │
 │               ├──────────────────────►│ 单事务：                  │
 │               │                       │  ① handle 校验 stamp      │
 │               │                       │     (accountId==预分配、  │
 │               │                       │      jobId/gen/epoch 一致)│
 │               │                       │  ② 解码校验（9 错误码）   │
 │               │                       │  ③ 创建预分配 accountId  │
 │               │                       │  ④ 建 source_configs     │
 │               │                       │     （当前 generation +   │
 │               │                       │      写入 selectedSemester│
 │               │                       │      完整三元组，CT-C3-15）│
 │               │                       │  ⑤ 私有事务内导入核心    │
 │               │                       │  ⑥ 凭据密文 + 内部计算    │
 │               │                       │     identityDigest（sha256│
 │               │                       │     (utf8(verifiedUsername.│
 │               │                       │     trim()))               │
 │               │                       │     09 §7.4 唯一生产者）  │
 │               │                       │  ⑦ 置活动 + 审计 +       │
 │               │                       │     记 first_login 终态  │
 │               │                       │     （CT-C3-21 私有实现） │
 │ 7. 广播 activeAccountChanged → C5；P                             │
 │    reconcileProvisionalDebugAssets(activeAccountId)（CT-P-05）： │
 │    匹配 prospectiveAccountId 的目录改标正式账号，其余 provisional │
 │    目录物理删除 → C5 进主界面                                    │
 │    reconcile 失败 → 账号事务不回滚，但停留启动维护页并幂等重试    │
 │                                                                  │
 │ 失败路径：stage 后作业失败/用户取消、任一守卫失败                  │
 │   （stale_lease/身份错误）或事务回滚 →                            │
 │   cancelFirstLogin(handle)（CT-C3-03）→ CT-P-05                  │
 │   clearDebugAssets(prospectiveAccountId) → 无活动账号、           │
 │   无凭据行、无来源业务数据；handle 一次性消费，临时明文尽力零化； │
 │   全局租约随终态释放（§2.2-8）                                    │
 │   debug 清除失败 → CT-C5-02 启动维护页调用 reconcile(null) 重试   │
```

死胡同核对：首登不写 sync_runs（账号行存在前无 run 行；first_login 终态在
commitFirstLogin 事务内补记，CT-C3-21）；provisional **认证上下文**不落任何持久
介质；debug 构建可写的 provisional 调试资产不含 handle/凭据，失败/取消立即清理，
崩溃后由 CT-C5-02 启动门调用 CT-P-05 reconcile（无活动账号即全部删除）；
selectedSemester/identityDigest 两条来源链闭合（C1 返回三元组 / C3 内部计算 digest）。

## 7. 子链路 ⑤：账号维护序列图（四种操作）

### 7.1 重新认证（identityDigest 不可变）

```
C5 → C2 reauthenticate(ReauthRequest{accountId,username,password,savePassword})
     （CT-C2-01）
  → 1. JobArbiter 原子取全局租约 → busy 则直接返回（未 stage，无 handle 可销毁）
  → 2. C3 stageReauthentication(...)（CT-C3-04）
      ① 校验输入 username 的 digest == 现有 identityDigest（不符即拒绝）
      ② 返回 ProvisionalAuthContext（prospectiveAccountId=既有 accountId，
         initialGeneration/ResetEpoch=当前库值快照）
  → 3. startSyncRun(stamp, reauthentication)（trigger 语义 CT-C2-05；
      持久状态端口 CT-C3-21）→ runId
  → 4. C2 以 ProvisionalSubject 申请租约 → 启动统一来源作业（CAS）
  → 5. 完成返回 verifiedUsername + 原 LeaseStamp
  → 6. C3 commitReauthentication(accountId, verifiedUsername, handle, stamp)
     （CT-C3-04）
      ① 事务内复验 stamp 的 accountId/jobId/sourceGeneration/resetEpoch 与当前库值
      ② 再次校验 digest == 原 identityDigest（内部计算，09 §7.4）
      匹配 → 仅更新凭据密文与元数据；identityDigest 保持不变
             → finishSyncRun(runId, stamp, success, 'reauthenticated')
      不匹配 → identity_mismatch；先 discardProvisionalAuth(handle)（CT-C3-04）；
              库内身份/凭据/业务数据不变；C2 持久 quarantine 本次会话分区
              → 清除（CT-P-02）
              清除失败 → 标记跨重启保留、禁复用、报 UI
             → finishSyncRun(failed, 'identity_mismatch')
  ── 失败/取消出口（A-7 整改）：
      busy（取租约前）→ 直接返回 busy，无 provisional 残留
      stage 后作业失败/用户取消 → discardProvisionalAuth(handle)（CT-C3-04）
        → finishSyncRun(failed/cancelled, 对应码)
      身份失败两码分工（M3 回写）：`identity_mismatch`（输入的账号不是本机账号，C3 digest
        拒绝：stage 前与提交事务内两处；identityDigest/凭据/业务数据不变）与
        `account_mismatch`（登录后 C1 权威证据确证签入的是另一个账号）
        → discardProvisionalAuth + finishSyncRun(failed, 该码) + 该会话分区先持久
        quarantine 再清除（C2 对两码同路径处理，既有行为；**native 作业自身的分区策略**只由
        `account_mismatch` 触发，见 07 ADR-003 M3 修订）
        **按来源限定（Task 17 修正）**：本节重新认证链路的来源硬编码为 JW
        （`sync_coordinator.dart:766`/`:794` 固定 `ustc_jw` + `JwCollectionRequest`，
        `account_lifecycle_service.dart:65` 同），故此处 `account_mismatch` 的语义按 JW
        实现读取：**任何未核验证据**（含“没有可用权威”）都报此码
        （`jw_identity_verifier.dart:28`/`:53`）；“确证另一个账号”这一更强语义**只对
        Young 成立**（Young 仅正向不匹配报 `account_mismatch`，无法核验报非破坏性
        `identity_unverified`）。JW 行为不改（M2 已验收）
```

### 7.2 删除凭据（先撤销租约）

```
C5 确认 → AccountMaintenanceCoordinator（CT-C5-01）
  → C2 beginMaintenance(deleteCredentials)（CT-C2-04）
      ① revoke 全部未消费凭据租约（CT-C2-03）
      ② 对每个受影响来源在接受取消时先 bumpSourceGeneration(source, cancel)
         （CT-C3-21）→ 取消并等待可能消费凭据的作业终态
  → C3 deleteCredentials（CT-C3-07 Identity 写服务；删密文，保留账号与浏览器会话）
  → C2 endMaintenance（CT-C2-04）
  门关闭期间新请求 → maintenance_in_progress（稳定拒绝）
  取消/等待旧作业或删除凭据失败 → maintenance_failed；保持维护门，重试或显式 abort 后才释放
```

### 7.3 清会话（全通道幂等）

```
C5 确认 → C2 beginMaintenance(clearSession)（CT-C2-04）
      ① 对每个活跃来源在接受取消时先 bumpSourceGeneration(source, cancel)
         （CT-C3-21）→ 停止并等待该账号全部来源作业终态
      ② 遍历【已安装通道全集】（CT-C2-02）：每通道 clearSession(accountId) 幂等
         Native 经 C1/P；Python 经 P 租户适配器（CT-T-02）
      ③ 任一失败 → 该通道分区保持隔离状态、重试；不因路由切换遗漏已注销通道
  → endMaintenance（CT-C2-04）
  门关闭期间新请求 → maintenance_in_progress
  取消/等待或任一通道清理失败 → maintenance_failed；隔离标记与维护门保持到重试/abort
```

### 7.4 清业务数据（维护写屏障 + generation 递增）

```
C5 确认 → AccountMaintenanceCoordinator（CT-C5-01）
  → C3 beginBusinessDataClear()（CT-C3-06）：拒新业务写 + 等待已进入写事务终态
  → C2 beginMaintenance(clearBusinessData)（CT-C2-04）：拒新来源作业
    （maintenance_in_progress）、取消并等待旧作业（内部取消不重复 bump）；
    经 SourceStateService 以 clearBusinessData 原因逐来源 bumpGeneration
    （CT-C3-21）
  → C4 拒新 run/工具/审批并等待所有可写执行终态
  → C3 commitBusinessDataClear()（CT-C3-06）：单事务清 15 张业务表 + undo_slot
    （保留账号/凭据/设置/权限策略/Agent 历史/审计；campus 三表归 clearCache
      CT-C3-20）
  → 解除屏障与维护门（任何取消/等待失败 → abortBusinessDataClear，不开始清理）
    取消/等待/提交失败的对外稳定出口 = maintenance_failed；abort 完成后才重新开放
```

## 8. 五条数据链路管道（fetch→normalize→validate→deliver）

每条链路四工位闭合核对：工位缺一个即死胡同。产物与消费者按 09 §5.3/§5.4/§7.3。

### 8.1 jw（WebView 交互 + SourceBundle）

```
fetch:   probeSession（CT-C1-02；底层经 CT-P-02 probe）→（过期）CAS 可见登录（白名单填表/权威账号证据核验/
         验证码交人工）→ 登录后抓学期列表（ADR-009）→ 选中学期 → 课程页 + 考试页
normalize: DOM/接口解析 → 规范化 datum（course_series / calendar_events /
         schedule_relations 外部身份）
validate: SourceBundle 构造 + validate（16MB/深度 64/敏感键 11 类/时间 +08:00/
         计数/引用完整性）——9 个错误码（CT-C1-03）
deliver:  CollectionCompleted{bundleBytes, verifiedUsername?, selectedSemester?}
         （CT-C1-01）→ C2 stamp 校验 → C3 importBundle（CT-C3-02）
异常出口: needs_user_login（恢复/取消）| account_mismatch（权威证据缺失/冲突或旁证冲突；
         JW 侧未按 M3 修订拆分，M2 已验收）| collection_failed | stale_lease
         | 9 个 bundle 错误码
```

### 8.2 young-schedule（WebView 登录态 + SourceBundle）

```
fetch:   probeSession（CT-C1-02；底层经 CT-P-02 probe）→（过期）needs_user_login 暂停-恢复
         → 北京时间滚动窗口逐日切片查询（窗口由 C2 按 BeijingClock 计算，
         YoungScheduleCollectionRequest.queryDates，CT-C1-02）
normalize: 已报名日程记录 → calendar_events（second_class 外部身份）；跨日/重复响应
         相同外部 ID 合并，相同 ID 内容冲突 → collection_failed（spec §7.3）
validate: SourceBundle（CT-C1-03；scope=日期窗口完整性；空日=有效空快照）
deliver:  CollectionCompleted{bundleBytes}（CT-C1-01）→ C2 stamp 复验 → C3 importBundle
         （CT-C3-02）→ finishSyncRun
异常出口: needs_user_login（暂停-恢复/取消）| 身份三分（Task 17b）：identity_unverified（无可用权威，
         非破坏性）/ identity_evidence_conflict（权威匹配但旁证冲突，非破坏性）/
         account_mismatch（权威确证另一账号，唯一触发 Young 分区 quarantine + 物理清理）
         | collection_failed（页面/API/完整性/ID 冲突）| stale_lease（迟到/切换）
         | cancelled（用户取消）| 9 个 bundle 错误码（C3 解码/语义）| 空快照（合法终态）
         | no_account/busy/maintenance_in_progress（作业创建前）
```

- **登录恢复导航归属（M3-0 观测，spec §4.2/§4.3）**：Young CAS 成功后默认落地页是
  `/login/sc-wisdom-group-learning/dataAnalysis`，**不是** schedule 或 enrolment 目标页；
  登录完成必须**重新打开原作业请求的目标页**（schedule → `.../personalInformation`），
  不得把登录完成误当业务采集完成。非密导航图与零阻断观测证据见
  `13-risks-and-acceptance.md` §M3-0（2026-09-09 冻结；M3 Task 18 真实站点 gate 保持
  开放）。C1 组件级状态机见 11 §5.15（D-12）。

### 8.3 young-enrolment（WebView 查询侧 + QueryResult）

```
fetch:    runQuery(YoungEnrolmentQueryRequest)（CT-C1-02）→ 报名中活动列表
          （分页采集；reportedTotal 与总页数首页冻结，后续页必须一致；total=0/pages=0
          为有效完整空结果）
normalize: NORMALIZED_FIELDS → YoungActivity 封闭字段集（CT-C1-04）
         descriptionText/requirementsText 有界纯文本转换；imagePath/私有字段丢弃
validate: QueryResult 1.0 canonical 校验（封闭集 fail-closed；references=[]；
         queryType=young_enrolment；activityCount/reportedTotal 一致；CT-C0-05）
deliver:  QueryCompleted{result, attachmentRegistrations=[]}（CT-C1-01）→ C2 校验
         stamp/事件/QueryResult → C4 工具（不入库、不落 C3、不应用 12h freshness、
         不使用 CT-C3-22 附件登记）
异常出口: needs_user_login（唯一可接受凭据的查询类型）| 身份三分（Task 17b）：identity_unverified
         （无可用权威，非破坏性）/ identity_evidence_conflict（权威匹配但旁证冲突，非破坏性）/
         account_mismatch（权威确证另一账号，唯一触发分区清理）
         | query_failed（页面/API/请求失败）| result_validation_failed（字段/计数/隐私失败）
         | stale_lease（迟到/切换）| cancelled（用户取消）
         | no_account/busy/maintenance_in_progress（作业创建前）
```

- **查询来源负要求（D-30，spec §8.1）**：`young_enrolment` 是查询来源，**零 `sync` 调用、
  零 `sync_runs` 行**——只经 `submitQuery`（CT-C2-01），永不经 `syncAll`/`sync` 启动，不写
  C3 业务数据。当前骨架遍历 `SyncSource.values` 的行为不是目标契约（09 syncAll 成员冻结）。
- **登录恢复导航归属**：enrolment 登录完成后必须重新打开目标页 `.../myproject`
  （非默认落地页 dataAnalysis；详见 §8.2 M3-0 注与 `13-risks-and-acceptance.md` §M3-0）。
  C1 组件级状态机见 11 §5.16（D-13）。

### 8.4 icourse（HTTP 公开 + QueryResult）

```
fetch:    HttpSourceClient 搜索公开页（课程/教师关键词，24h 磁盘缓存 TTL，
         网络失败降级 stale 缓存）
normalize: 排名 + 关系强度（relationStrength）+ 代表性证据
         selectedEvidence→evidence；**reviews 不进 canonical**（CT-C1-04，L2-14）
validate: canonical 校验（封闭集；siteAiSummary 只留 text；teacherLinks 只留 label）
deliver:  QueryCompleted{result, attachmentRegistrations=[]}（CT-C1-01）→ C2 →
         C4 工具（评课联动只发送必需检索词，红线 2.1-2）
异常出口: query_failed | result_validation_failed | stale_lease | stale 缓存降级
```

### 8.5 campus（HTTP 公开 + QueryResult + 目录 upsert）

```
fetch:    目录刷新（五个目录键、分页、7 天窗口过滤；30min 节流/6h 过期/失败降级
         旧目录，CT-C2-08）｜ 详情读取（content + 附件受控下载：大小/MIME 白名单，
         批≤3、链接≤1 层）｜ 附件内容转换（CT-C1-05；文件/decoder 在 P）
normalize: CatalogEntry 封闭字段集（id 精确算法 = 'campus_'+sha256 前 24 位，
          09 §7.2；canonicalize_url 规则）；campus_detail 封闭集；
          附件登记载荷（cache_key/sizeBytes/…，不进信封）
validate: canonical 校验（CT-C1-04；URL ∈ references；raw HTML 拒绝；
         无 localPath/sha256）
deliver:  campus_search → QueryCompleted{result, attachmentRegistrations=[]} → C2
          校验 stamp → C4 → C3 commitCatalogSource（原 stamp + result + 空列表，
          CT-C3-22）→ upsert → 本地搜索入对话
          campus_detail → QueryCompleted{result, attachmentRegistrations}
          （CT-C1-01 载荷载体）→ C2 校验 stamp → C4 → C3
          commitCatalogSource（原 stamp + result + 原登记列表，CT-C3-22）→ C4 入对话
          （附件命中缓存经 C3 Catalog 服务 CT-C3-07 定位 P 文件）
异常出口: catalog_unavailable（目录缺失且刷新失败）| result_validation_failed
         | stale_lease | 降级旧目录（合法）
```

## 9. 边界情形与死胡同扫描（每行"去向"非空即无死胡同）

| # | 情形 | 触发 | 去向 |
|---|---|---|---|
| 1 | 同步中再触发同步/查询 | 全局租约占用 | 原子取得失败 → `busy`（CT-C2-01）；UI 呈现"同步进行中" |
| 2 | 暂停态挂起时用户关 App | needs_user_login + 进程退出 | 跨重启作废（ADR-022）；UI 提示"上次待确认操作已失效" |
| 3 | 通道切换后旧作业迟到 | generation 已递增 | C2/C3 校验失败 → `stale_lease`，不导入/不更新目录/不进对话 |
| 4 | reset 后 Agent 迟到写 | resetEpoch 已递增 | 写屏障 + expectedResetEpoch 比对 → `stale_lease` |
| 5 | 作业取消（暂停态） | cancel(jobId) | 接受时刻 bump(cancel)（CT-C3-21）→ 立即终态 `cancelled` → finishSyncRun(cancelled) |
| 6 | 作业取消（采集中） | 协作式检查点 | 同上：bump(cancel) 先于终态；迟到结果 stale_lease |
| 7 | App 崩溃残留 running | 下次启动 | `recoverInterruptedRuns` → `interrupted/app_restarted`（CT-C3-21） |
| 8 | reset 中途崩溃/私有文件清理失败 | reset_pending=1/2 | 启动强制门恢复；=1 重新幂等清会话并标记 2，=2 重放 cache/debug 清理；全部成功后才 finalization（CT-C5-02）；对外稳定出口 `reset_incomplete` |
| 9 | 身份核验失败分区 | digest 不匹配 | 持久 quarantine → 清除；失败跨重启禁复用（CT-P-02） |
| 10 | 维护门期间新请求 / 维护本体失败 | beginMaintenance 后 | 新请求稳定拒绝 `maintenance_in_progress`；已取得门后的排空/执行失败返回 `maintenance_failed`，保持门/写屏障到重试或 abort |
| 11 | 删除凭据时有未消费租约 | 用户点删除 | 先 revoke；对受影响来源 bump(cancel) 后终止并等待作业，再删密文（§7.2） |
| 12 | 凭据租约二次取值 | takePassword 后 | 返回 null（原子取即失效，CT-C2-03） |
| 13 | 提醒协调失败 | importBundle 事务外协调 | `reminderReconciliationPending` 返回给 C2 → 审计 + 后续重协调 |
| 14 | 目录刷新失败且无旧目录 | 离线首次使用 | `catalog_unavailable`，联网后重试 |
| 15 | 学期目录抓取失败 / 月份目标缺失 | 新学期待发布 | 抓取、解析失败或无启用学期 → `collection_failed`；有效目录缺月份目标 → 最近已结束，其次最早未来；持久选择不存在/冲突 → `collection_failed`，不静默切换（ADR-009 / D-23） |
| 16 | Python 通道进程退出 | 租户健康探测（CT-P-07） | 当前作业终态 `failed`（query_failed/collection_failed）+ C2 记账；重启策略细节归 M2-M6（CT-T-01） |
| 17 | 首登 provisional 调试资产失去认领 | 首登失败/取消或 App 崩溃 | 显式失败/取消：cancelFirstLogin 后 clearDebugAssets(prospectiveAccountId)；崩溃：启动时 reconcileProvisionalDebugAssets(String? activeAccountId)，匹配正式账号则提升、其余物理删除（CT-P-05/CT-C5-02） |

## 10. 开放问题移交（本层不解决，标注承接层）

| 开放问题 | 来源 | 承接层 |
|---|---|---|
| 作业级错误 transient/fatal 分类与有限重试（重试最终失败=上述稳定错误码） | 08 §10 | 第 4 层（作业状态机） |
| syncAll 遇 needs_user_login 的恢复语义形态（逐源挂起 vs 整批挂起） | 08 §10 | 第 4 层 |
| 五适配器 normalize 段逐字段实现规则（封闭集已冻结，解析细节） | 09 §5.4 | M2–M4 |
| 学期 fallback 选择算法（当前出口已定=collection_failed） | ADR-009 | M2 |
| PythonChannel 转换映射的完备性验证（legacy 键全量覆盖） | 09 §5.4 | M2–M4 oracle 对拍 |
| Python 租户重启策略（当前出口已定=作业 failed） | 09 CT-T-01 | M2–M6 |

> 走查指针（总体审查 S7）：v7→v8 迁移与备份回退不属于五链路序列图范围，
> 承接见 09 CT-C3-01 + 11 D-01（M1 迁移状态机），本层不重复绘制。

## 11. 本层拍板记录（L3 决策）

| 编号 | 决策 | 内容 | 状态 |
|---|---|---|---|
| L3-01 | 走查回写 09 §5.2 | `JwCollectionRequest.semester` 改 nullable：null=首登无持久选择（登录后抓列表+月份规则默认，ADR-009），非 null=持久选择 | ✅ 已回写 |
| L3-02 | 首轮独立审查整改（2026-08-14，8A/3B） | A-1 submitQuery 入口 / A-2 附件载荷载体（QueryCompleted.attachmentRegistrations）/ A-3 原子取租约 / A-4 取消 bump(cancel) 与计数规则 / A-5 暂停保持 running + 提醒协调顺序 + 终态映射 / A-6 selectedSemester 返回链 + identityDigest 内部计算 / A-7 discardProvisionalAuth + completeReset revoke 顺序 / A-8 补码补号补 CT 标注；B-1 L2-01~16 / B-2 takePassword 绑定 / B-3 trigger 分支 | ✅ 已落地（回写 09 L2-16） |
| L3-03 | 整改后复审修订（2026-08-14，4A/3B） | QueryRequest/AttachmentCacheRegistration 类型闭合；C4 唯一 submitQuery；附件列表非 null、campus 两分支均 CT-C3-22；stage 前 busy 无 handle；identity_mismatch 销毁；08 首登/reset 顺序；维护取消 reason；digest 操作数与 gate CT 清单对齐 | ✅ 已落地（回写 09 L2-17；2026-08-14 用户重认，gate 关闭） |
| L3-04 | 第 4 层整改复审回写（2026-08-14） | reset 失败码分工：beginReset 未提交/pending=0 → write_commit_failed，pending=1/2 → reset_incomplete；非 reset 维护本体失败 → maintenance_failed，新请求拒绝仍为 maintenance_in_progress | ✅ 已同步（回写 09 L2-18/19） |
| L3-05 | 第 5 层独立审查回写（2026-08-14，A-2/A-4） | completeReset 补步骤 5.5（clearCache 私有实现：campus+icourse）与 5.6（clearDebugAssets 幂等清 debug/）；本行当时未闭合失败恢复，现行语义以 L3-06 为准 | ✅ 已同步（回写 09 L2-20） |
| L3-06 | 第 5 层整改复审用户收口（2026-08-15） | 修订 L3-05：会话清除后先持久 pending=2；cache/debug 任一失败阻断 finalization 并跨重启重试。首登 provisional 调试资产成功提升归属、失败/取消清除、崩溃由启动门调和 | ✅ 已同步（回写 07 ADR-023 / 09 L2-21 / 11 L4-04） |
| L3-07 | Task 17 owner approval（2026-08-23） | C2 currentJob/currentJobHandle 在四类作业注册后发布同一 SourceJobHandle，晚订阅可重放并可 resume/cancel，terminal settlement/cleanup 后仅由同一 handle owner 发布 null；连续作业 live-first+snapshot 不漏不重，旧 cleanup 不覆盖新 handle。C1 terminal event 即时、stream done 作为 session/credential/active-record/NativeJobGate cleanup barrier | ✅ 已同步（回写 09 L2-23 / 11 L4-06） |
| L3-08 | M2 真实验收账号证据修订（2026-08-25，用户批准） | CAS 跨 origin 导致 storage 不可作为必需证据；fetch 现改为同源账号载荷权威匹配 + DOM/storage 可选冲突旁证，缺权威或任一冲突均 account_mismatch | ✅ 已同步（回写 07 ADR-003 / 09 L2-24 / 11 L4-07） |
| L3-09 | M2 真实验收学期默认修订（2026-08-25，用户批准） | 无持久选择时月份目标键存在且启用即选，不要求覆盖当天；仅缺失/禁用才回退最近已结束、最早未来 | ✅ 已同步（回写 07 ADR-009 / 09 L2-25 / 11 L4-08） |
| L3-10 | M2 冷启动会话快照修订（2026-08-27，用户批准继续修复） | 真实登录可直接到受保护课程页而不产生 `/home` 观测；权威身份核验成功后 C1 调 CT-P-02 `confirmAuthenticated(ref)`，P 才可在 close 保存不透明快照；失败/取消且未核验成功不得保存 | ✅ 已同步（回写 09 L2-26 / 11 L4-09） |
| L3-11 | M3 Young 运行时回写（2026-09-09，Task 2） | ① §2.4 冻结启动顺序 C3 init→已知来源调和→C2 路由开放（spec §3.4，09 CT-C3-03/19 缺口修正）；② §8.2/§8.3 补齐 Young 双链路全部稳定出口（pause/cancel/stale/identity/validation/transport）与登录恢复导航归属（CAS 默认落地 dataAnalysis，须重新打开目标页；M3-0 证据见 13 §M3-0）；③ §8.3 冻结查询来源负要求（D-30：零 sync 调用/零 sync_runs 行）；④ D-12/D-13 组件状态机见 11 §5.15/§5.16 | ✅ 已同步（回写 09 L2-27 / 11 L4-10） |
| L3-12 | M3 身份失败分类回写（2026-09-15，Task 17b） | §8.2/§8.3 的 Young 异常出口把单一 `account_mismatch` 拆为三分：`identity_unverified`（无可用权威）与 `identity_evidence_conflict`（权威匹配但旁证冲突）都是**非破坏性**终态（终止作业、不交付、保留分区、仅作业级隔离），仅 `account_mismatch`（权威确证另一账号）触发分区 quarantine + 物理清理；§8.1 的 JW 侧保持原样（M2 已验收）。C1 清理分支开关 `job.identityMismatch` 只因 `account_mismatch` 为真 | ✅ 已同步（回写 07 ADR-003 / 09 L2-28 / 11 L4-11） |

## 12. 第 3 层 gate 检查表

- [x] ① 五条链路（§3/§4/§5/§6/§7）序列图走通，每条消息标注 CT 编号、每分支有去向
- [x] ② 五条数据管道（§8）fetch→normalize→validate→deliver 四工位闭合
- [x] ③ §9 边界情形 17 行去向非空且为当前出口（不借"归第 4 层"逃逸）
- [x] ④ 本层引用的 CT 编号（CT-C0-01/03/05、CT-C1-01~05、CT-C2-01~08、
      CT-C3-02~07/15/18/20/21/22、CT-C4-03/04/05、CT-C5-01/02、CT-P-02/05/07、
      CT-T-01/02）全部在 09 §11 矩阵中存在
- [x] ⑤ ADR-000~023 与 L2-01~26 决策在本层消息中全部可溯源（原子取租约/取消递增/
      takePassword/selectedSemester 返回链/discardProvisionalAuth/全通道清会话/
      封闭 QueryResult）
- [x] ⑥ 与 08 §7 容器级走查一致（无容器越权调用：C4 不直连 C1、C1 不依赖 C3、
      写库唯一 C3、C2 核心无 dart:io）
- [x] 开放问题移交（§10）逐项有承接层，且每项已给出"当前出口"
- [x] **gate 关闭（2026-08-14 用户重认；2026-08-15 回写重验；2026-08-23 Task 17、2026-08-25/27 M2 真实验收回写重验）**：首轮 8A/3B +
  复审 4A/3B 全部闭环，09 回写 L2-15~26；L3-06 的严格文件清理、provisional
  调和、Task 17 的 current-job/cleanup barrier 顺序、L3-08 身份证据出口与 L3-09
  学期默认顺序无死胡同 → 第 4 层 `11-component-designs.md`
