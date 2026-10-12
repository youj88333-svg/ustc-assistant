# Young 二课来源契约

本文是本分支 Young 当前来源字段、读取范围和规范化语义的唯一详细参考。通用身份、作业、分区、事务与安全规则见 [09 关键契约](../../architecture/09-contracts.md)；M2 真人验收、用户批准范围和关闭状态见 [M2 验收记录](../../milestones/m2/acceptance.md)。

## 能力与当前状态

M2 已正式验收关闭，范围是报名活动只读查询与个人日历中活动关联日程的同步。日历中没有活动关联的行不导入。验收不证明本人独立报名成功、取消状态、未关联样本或来源撤回语义；这些仍按验收记录保留为未知。

本契约区分两项作业：

- `activities`：只读查询活动列表并在应用内展示；活动列表自身不写入本地日程。
- `calendar`：读取用户选定日期范围内的个人日历，先验证全部行和完整覆盖，再仅导入带非空活动 `itemId` 关联的日程。

候选观测只提供设计输入，不单独授予生产读取或事务许可。当前正式作业使用应用拥有的 WebView、固定读取器及 C3 封存/提交链。

## 固定入口与登录过渡

初始入口为 `https://young.ustc.edu.cn/login/`。当前允许来源 origin 固定为：

- `https://young.ustc.edu.cn`
- `https://passport.ustc.edu.cn`
- `https://ucas.ustc.edu.cn`
- `https://id.ustc.edu.cn`
- `https://analytics.ustc.edu.cn`

固定业务页为报名活动 `/login/sc-wisdom-group-learning/myproject/SignUp` 和个人日程 `/login/sc-wisdom-group-learning/personalInformation/mySchedule`。`/login/` 门户以及 `/login/sc-wisdom-group-learning[/]` 回调根只表示登录过渡；等待学校自然进入同一来源下的业务 namespace 子路由后，再准备固定目标页。不得读取或解释回调票据，也不能把页面 ready 当作身份或导入许可。

产品主动读取仅接受已登记主文档内固定 GET helper 和三个固定路径；原生响应关联只接受同一来源下 `/login/wisdom-group-learning-bg/` 业务请求：

| 路径 | 参数与用途 |
|---|---|
| `/paramdesign/scMyInfo/info` | 读取当前业务账号的最小 profile 投影 |
| `/personal/scCalendar/getPageUserList` | 固定字段、日期 `now`、`pageNo`、`pageSize=10`，读取个人日历页 |
| `/mobile/item/enrolmentList` | 固定字段、`pageNo`、`pageSize=10`，读取报名活动页 |

活动页固定字段为 `id,,action`；日历页固定字段为 `id,,number,title,place,startTime,endTime`。产品主动读取不使用其它 URL、方法、参数或页面，也不接受账号选择器。页面自行产生的常规后台请求按通用来源与浏览器规则处理，本契约不把它们当作产品读取或关闭它们。

登录前后可使用经授权共享的加密学校密码事实；Young 仍有自己的服务端身份比对、Young 作业许可和隔离浏览器分区。它不读取或复用 JW Cookie/页面会话；同一密码不能替代 Young 的当前身份或分区认领。认证表单提交只能由本次单次投递驱动；人工挑战由用户接续，手填秘密不读取。

准备阶段若 Dart `ready` 尚未到达，或原生固定导航明确在尚未发出 `Navigate` 时以 `busy` 拒绝，可在限定准备预算内等待。导航一旦发出或确认结果未知，不能重放；未知确认按失败关闭和排空。读取开始后，主文档、会话、执行 context、登记脚本、操作与步骤必须持续匹配。

## 身份与响应关联

固定 profile 成功响应需包含 `success=true`、`code=200` 及 `result.username`。用户名只是服务端业务字段；身份判定要求同一作业读取前后的 profile 一致，并与 C3 持有的预期本地账号匹配。UI 自报账号、页面名称、API 可达或某一条日历 `userId` 都不替代该判定。

每个请求必须属于当前 Young 会话、主文档、作业和严格递增步骤；实际编译脚本、登记的 scriptId 与执行 context 必须一致，响应要关联到本次发出的固定 GET。页面跳转、route/context 更换、迟到或跨步骤响应、传输失败、超时及读取器失效均使整个采集产物不可交付。业务原文和账号值不进入 UI、常规进度、日志或审计。

C3 只绑定一个本地账号，Young 和 JW 分别与同一预期账号比对；独立的是来源核验依据和许可，不是两个本地账号。Young 的 `initial/recovery` 或已认领分区只服务 Young；分区状态不证明服务端身份，也不授予其它来源许可。

## 响应字段、分页与时间

profile 只保留 `username`。分页响应只接受成功 envelope 中的 `result.records` 与 `result.total`；每页最多 10 行，总数为 0–10000。活动行字段为：

| 字段 | 语义 |
|---|---|
| `id` | 活动的不透明字符串标识，也是该查询中的稳定唯一键 |
| `itemName` | 活动名称 |
| `st`、`et` | 活动开始和结束 |
| `applySt`、`applyEt` | 可空报名起止，与活动时间分开解释 |
| `placeInfo` | 可空活动地点 |

活动开始必须早于结束；若报名起止同时存在，结束不能早于开始。活动 ID 在完整列表中唯一。活动列表只作查询结果，不作为用户已报名的个人事实，也不持久化为日程。

日历行的必需字段为 `id`、`title`、`place`、`startTime`、`endTime`；`itemId` 可缺省、空或 null。`id` 是日程外部稳定键；非空 `itemId` 只表示页面记录关联到一个活动，不证明用户独立报名成功或仍处于报名状态。开始须早于结束。

活动和日历时间均须为严格的 `YYYY-MM-DD HH:mm:ss` 本地墙上时间，按北京时间 UTC+8 解析并以 UTC 存储，不使用机器本地时区，不猜测无时区秒级值。日期覆盖按北京时间自然日计算。

活动列表按 `total` 从第 1 页顺序读取，固定页大小 10；日历对每个所选日期分别从第 1 页读取。各自一次查询内 `total` 必须稳定，页号连续且页长恰为剩余量与 10 的较小值；每个查询内 `id` 唯一且最终记录数必须精确等于 `total`。`total=0` 只有一张合法空首屏；空页、短中间页、超页、重复 ID 或少于声明总数均不是完成快照。不同作业的总量可以变化。

## 日期范围与关联规范化

日历范围为用户开始作业前选择的 1–62 个连续北京时间日期，首尾均包含。首次默认当前北京时间月份；之后默认上次成功范围，用户可在开始前修改。每个日期都必须完成自己的分页查询。行必须与其请求日期实际相交；跨日重复 `id` 的关联、标题、地点、起止时刻必须完全一致，否则整次作业失败。

系统先验证返回的全部行、分页和跨日一致性，然后才按 `itemId` 过滤。未关联行仍计入读取完整性，不进入导入事件；同一关联日程跨日返回且内容完全一致时只保留一条。缺少 `itemId` 只解释为“未观察到活动关联”，不解释为报名失败、取消或来源删除。

日历本地稳定键是响应中的 `id`；同一范围只接受逐字段完全一致的重复跨日实例。不会按标题、时间、活动名称或数组顺序生成替代键。活动查询的稳定键为活动 `id`，只用于完整性和结果展示。

任何身份不匹配、页面或脚本关联失效、字段缺失/类型错误、时间无效、total 变化、分页缺页/重复、日历行不与请求日期相交、跨日同 ID 内容冲突或采集/封存阶段取消，都拒绝整份产物。不会把未观测、请求失败、部分覆盖或空数组解释成“没有日程”，也不允许部分提交。事务提交先后仍按通用事务规则裁决。

## 本地提交与保留语义

`activities` 成功后仅向应用查询视图提供结果；不插入、更新或删除本地日程。账号/Young 分区认领、作业回执、审计以及本次新共享密码事实由 C3 在成功事务中处理。

`calendar` 只提交完整范围内已验证且具非空 `itemId` 的唯一日程。更新按 `id` upsert，保留本地事件标识和用户隐藏覆盖；完整范围内不再出现的旧项记录为范围内缺失，不清除范围外事实；范围外的日程不会因本次查询被改写。日历范围、业务事件、回执、审计、Young 分区许可以及本次更新的共享凭据同一事务提交。事务失败保留旧业务事实，取消与提交先后按通用事务规则裁决。

## 明确保留的未知项

- 真实未关联日历行样本未观察；产品已按用户批准规则验证全部行后排除未关联项。
- `itemId` 关联不证明本人报名成功、取消或撤回状态；这些业务语义仍未观察。
- 学校来源对日程撤回/缺失的完整含义未被独立证实；本地仅按完整所选日期范围记录观察状态。
- M2 的关闭仅覆盖上述正式范围，不把剩余未知项改写为真实通过。

静态实现依据：[固定 origin 与入口](../../../app/lib/source/observation_contract.dart)、[固定 Young 页面和登录过渡](../../../app/windows/runner/observation_bridge.cpp)、[受控 API 读取器](../../../app/windows/runner/young_business_reader.cpp)、[业务字段与分页契约](../../../app/lib/source/young_business_contract.dart)、[采集封存与范围规则](../../../app/lib/source/young_collection_contract.dart)、[身份关联与作业协调](../../../app/lib/jobs/observation_coordinator.dart)、[正式同步协调器](../../../app/lib/jobs/young_sync_coordinator.dart)、[共享认证驱动](../../../app/lib/jobs/school_authentication_driver.dart)、[本地事务存储](../../../app/lib/data/young_store_extension.dart)。
