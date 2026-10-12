# M2.3 多段登录兼容性与真实自动化记录

> 保留发生时的规格、失败、修复和检查；旧“待验/未关闭”不是当前状态。当前范围见 [任务单](../plan.md)，最终结论见 [验收](../acceptance.md)。正文只迁移链接，保留当时叙述。

#### M2.3 登录阶段 busy 与手动跳转观测（2026-10-11）

用户验证共享密码自动活动查询后报告登录完成似乎持续跳转，最终摘要为 idle/activities、committed=false、failure=busy、failureStage=login、automation=none、credentialSaved=true，二课计数零。保留为本版真实失败；摘要不能证明本次密码曾成功投递，也不能唯一确定实际跳转链或 busy 入口，不覆盖前版 stale 失败及 477/13 组本机检查。

用户要求简单 Python 脚本，由本人登录捕获完整重定向，并提示专用 `ustc_assistant` Conda 环境。根核实 `E:/conda/envs/ustc_assistant/python.exe` 已安装 Playwright 1.61；按最新偏好使用此环境，不安装依赖、不改全局代理。手动实验为独立普通 Edge 非持久上下文，固定 Young 入口，可固定 JW 入口对照，默认本机 7897 代理。只观察主/子 frame 文档请求的 HTTP 多跳、页内路由及弹窗；不读取 DOM、请求/响应头体、Cookie/Storage/其它认证资产，不自动填表或执行学校业务写。导航网址移除账号、参数值、fragment 和动态路径，未知字段匿名；重复跳转保留顺序与帧关系。脱敏结果仅写忽略的 tmp，不导出登录资料；普通 Edge 结果是链路线索，不直接证明产品 WebView 或身份契约通过。

设计依据继续从 docs/README.md 导航当前 07–15、共享凭据用户授权和 M2 任务验收。Sol / max 负责诊断、固定端口与有界等待修复及实际检查；Astra / high 只读定位；Luna / max 限定 Python 工具与合成测试或 C2 反例，互不重叠。允许修改本切来源协调器的导航前置等待/明确拒绝语义、相关测试、独立诊断文件及当前记录；不改变凭据出口、读取后文档拒旧、来源身份/完整性、事务、分区许可或清理范围。

静态复核发现：原生 `AdvanceLogin` 可先于 Dart ready 事件返回 businessReady，C2 随即在准备循环外调用导航，Dart 前置拒绝 busy 直接终止；原生导航前 busy 又被折叠为 sourceFailed。修复把导航准入纳入有界准备等待，只有明确未发出导航的 busy 才保留会话并等待，成功发出一次后不重复 Navigate；超时/未知失败仍排空，取消仍拒旧。另发现 `/login/` 中间门户过早归类与重新导航可能打断多段链的控制流风险，真实是否命中待手动链路确认，不凭推测修改门户契约。合成验证应覆盖 ready 迟到、导航前 busy、准备取消/超时、导航确认丢失及读取后导航，学校真实工具只由用户本人登录。

根实际验证独立工具：八项 Python 合成回归通过；实际无界面系统 Edge 只访问 loopback，完整关联 302→303→307→308→200，九次文档请求、四次 frame 导航，iframe/弹窗/同文档路由均观测到，合成秘密未进入摘要。初稿用同步 API 加终端 input 会停止事件派发，已在启动前改为异步派发/关闭页面自动保存；未知路径匿名 ID、popup 无 frame 的请求保留、记录上限和关闭回调也经根修复/检查。未安装依赖或读已有 Edge 资料。根以隐藏 Python helper 启动独立可见 Edge，PID 40664；用户已完成登录、两个目标页面并关闭窗口，安全结果写入忽略的 tmp。

本次真实手动结果为 17 事件、6 个 HTTP 文档请求、同一 page/主 frame，failure=null、truncated=false；未观察到子框架或弹窗。必要链路：Young `/login/` 200 → passport `/login` 302 → id `/cas/login` 200 → 人工 CAS POST 302 → Young `/login/sc-wisdom-group-learning/` 回调根 200 → 约 2.8 秒后自然 SPA 子路径 → 用户选择 SignUp、mySchedule。另有一次人工 CAS POST 200，只记录方法/状态，不推断原因或改变单次自动投递规则；参数只记名称，值未读取/输出。全部观察 origin 均在已有 Young 白名单，当前没有扩白名单依据。

依据此实证，根修正 native `AdvanceLogin`：Young 门户和 namespace 根含/不含尾斜杠继续 waiting；只有精确 Young origin 下、长度严格大于 namespace 前缀的子路径才准入业务准备，先保留现有 LoginBaseContext，不解释 ticket。学校自然 SPA 路由只是固定准备入口，仍需 Dart ready、固定目标/helper、前后身份和完整读取；不会替代 C1/C3 许可。Astra / high 只读复核同意最小方案，要求延迟门户/回调不被打断和根停留超时反例；Luna / max 限定独立 loopback 夹具与原生回归，根实际运行。该修复在同一任务内增加原生门户判定/夹具文件，不扩大产品范围。

根已有最终 Dart 检查：analyze 零问题，482 本地测试通过、1 个既有平台反例跳过。新增五项覆盖 ready 迟到、明确 native busy 无新事件后的重试、导航前返回 CAS、准备超时保留 JW 事实/共享密码及确认丢失不重发。初次相关回归因 fake 未发初始 navigating 导致文档世代不一致两项失败；修正 fake 后一个初始导航计数断言仍旧，根纠正并通过完整回归，生产守卫未放宽。Astra 指出的导航前清 ready 造成永久等待、认证 origin ready=false 的回退遗漏均已修复。当前这些是源码/本机证据；新原生多段回归与正式 Release 替换仍在推进，上一版 477/13 组记录不冒充本轮重跑，产品真实自动化和完整 M2 尚未关闭。

#### M2.3 原生回归与真实自动化验收（2026-10-11）

随后根完成延迟门户/回调夹具集成与最终构建。本切最终 analyze 零问题、482 项本地测试通过（1 个既有平台反例跳过），两套 Windows 原生共 7 组通过；原记录中“仍在推进”保留为当时状态，不把上一版五套 13 组计入本轮重跑。

| 根代理实际最终检查 | 结果与范围 |
|---|---|
| `flutter test integration_test/jw_authentication_flow_test.dart -d windows --no-pub` | 4 组通过；固定 CAS 单次投递、精确表单/文档与租约、refresh/route/其他 origin/节点变化/关闭撤销、用户名同步处理器引起变化时停止密码投递 |
| `flutter test integration_test/young_automation_flow_test.dart -d windows --no-pub` | 3 组通过；保存密码后关闭重开、清二课分区后再认证、延迟 SPA/helper，以及新增门户 → Passport/CAS → namespace 根回调 → 自然业务子路由。新夹具要求 bootstrap 完成前不发固定业务导航；两次自动查询均单次认证、完整分页，保留 JW 事实和同一受保护凭据 |
| `flutter build windows --release --no-pub --target=lib/main.dart` | 通过，33.0 秒；最后构建目标为正式应用，产物仍为 `app/build/windows/x64/runner/Release/ustc_assistant_m0.exe` |
| 文档保留与一致性 | 17 份当前文档、221 处本地链接、77 处锚点、07–15 九份历史正文与 01–06 保留、`git diff --check` 通过；本表为真人结果登记前的检查，登记后再核对 |

自动测试仅访问 loopback、合成业务响应、临时库及自建分区，没有访问真实学校或读取正式库/凭据/浏览器资产。构建前及启动前按确切 Release 路径确认零匹配进程，随后以 CLI 正常可见启动同一正式应用；唯一进程 PID 28376，主窗口句柄 9505596、标题 USTC Assistant。没有 Computer Use、前台输入或实际窗口画面检查，进程/句柄不替代用户验收。

用户在修复版密码留空执行活动查询与此前有活动的日期范围同步，返回两份 `young-import-v1`：

| 真实操作 | 提交与失败 | 完整读取/规范化 | 本地事实与分区 |
|---|---|---|---|
| 报名活动只读查询 | committed=true，failure=null，identityFailure=null | 58 条活动、6 页；未导入日程 | localEvents=0，importCount=0，queryCount=1；accountBound/credentialSaved/profileRetained=true，profileReused=false |
| 活动关联日程同步 | committed=true，failure=null，identityFailure=null | 31 天、31 页，2 条来源日程 → 2 条本地日程；排除/重复均为 0 | localEvents=2，importCount=1，queryCount=1；accountBound/credentialSaved/profileRetained/profileReused=true |

随后用户明确确认 **“两项全程自动，显示正确”**：无需在学校窗口补密码或点击继续，导入日程名称、日期和北京时间正确。这是产品自身独立分区与正式身份/许可/事务链路的真实成功证据；不是把手动 Edge 调研或合成测试记为产品真人通过。终态 `automation=none` 只表示进度已结束，全程自动由用户的明确反馈证明；profileReused 不推导永久免登录。旧 stale/busy 失败、此前候选 68 条/7 页及原检查保留，不同作业的活动列表数量不冒充同一快照。

**当前结论**：M2 两个能力的真实自动查询、首次日程导入及日程显示已通过；完整 M2 仍待以下最终人工连续性清单，不提前关闭。用户无需逐次贴摘要，异常时反馈对应步骤及当次闭合摘要即可：

1. 查询活动并展开必要信息，核对名称、地点、活动时间与独立报名时段；正常退出重启后，同范围再次同步仍为 2 条二课日程，已有 JW 日程与学期目录保留。
2. 隐藏一条二课日程、再次同步仍隐藏、恢复显示；另在二课作业完成前取消，确认旧数据保留并可再次同步。
3. 清除二课登录资料后，两个来源的日程、共享学校密码及 JW 目录保留；留空密码再次同步可自动完成。

当前只收到二课 localEvents=2、importCount=1、queryCount=1；JW 最近真人计数仍为 418 条、累计回执 5、目录 81，不推断新的 JW 计数或三项检查已完成。M0/M1 关闭及 JW 非空考试后补保持；真实未观察的响应/撤回/未关联样本与完整 V 项继续分别登记，不因本次日常自动化通过被记为真实通过。本次新增真人结果登记只修改文档，不重复运行已经通过的 SDK 检查。
