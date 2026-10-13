# M5.2 只读工具与主动图片

实施日期：2026-10-13。依据 [07–12](../../../architecture/07-constitution.md)、[13](../../../quality/13-risks-and-acceptance.md)、[14](../../../reviews/14-overall-review.md)、[15 工作流](../../../workflow.md)和 [总方案 §16](../plan.md#16-m52-施工规格含图片输入修订)。依赖为用户的真实 toolReady，图片为用户追加的主动输入范围；原话和安全摘要见 [验收页](../acceptance.md)。本记录不关闭 M5.1/M5.2/M5 或完整 V 项。

## 交付与边界

Sol / max 持有共享契约、C3 账本/迁移/复验、C4 循环与模型图片出口、控制器和组合根。Luna / max 分别承担固定只读适配和合成测试、引用/进度/图片 UI 与原生选择器，以及互不重叠的账本/迁移合成检查。Astra / high 一次只读复核停止、恢复和交付边界；根修复并实际执行检查，不以代理声明代替验核。

固定 12 个函数按人类问题开放：日程/事件/冲突、任务/块、知识检索/正文、评课课程/学期/点评、校园栏目/文章。参数封闭，不接 URL、SQL、文件路径或批准。使用同一日程投影与公开端口，教室优先、教师、北京时间、来源缺失和任务/块独立状态保留；私人备注、任务正文和考试备注留在本地。Young 明示活动关联依据及 registration_verified=false。

每轮独立随机引用，跨轮、过期、未签发、改意图或已失效引用拒绝。C3 对运行票据、日程 context/revision、确切公开/知识结果复验；交付模型前、异步 Key 交接后及输出交付都再验。工具正文标为不可信，注入不能改注册表或扩大权限。显式只查公开资料时排除本地读；普通聊天不附业务定义。清业务、知识、权限或界面世代变化不能把旧卡片变成当前证据。

公开网络使用专门 PublicQueryCoordinator，与手工入口共享租约与同一库；取消仅排空自己的作业。评课第三方同意不由模型开启；知识未载入与零命中分开，不自动载入。财务在线关键词/FAQ 仍 unavailable。课程学期按 5 项分页，点评经同一端口的 2400 字符切片及游标继续；单个结果/出处最多 10000 UTF-8 字节，不截掉含义后伪称完整。

C4 完整原生回合执行，最多 8 次模型请求、16 次工具、180 秒，文本/定义/参数/结果最多 26000 UTF-8 字节。完整 tool-call/result 配对不拆开；同参数无进展重复结束，坏参数只允许一次修正。存储/权限/清理失效立即结束，不再请求模型；普通不可用按固定结果说明。系统明确当前北京时间、本地读取不等于学校采集时间及未知适用性。模型私有推理和整页中间结果不落库。

C3 schema 11→12 增量添加有界出处、步骤和图片数量，同一 ticket/事务保存。原有 Key、来源、目录、日程、任务、备注/隐藏、Undo、知识和界面设置保留；整体历史预算包含新字段。历史卡只用于查看，后续上下文不把旧业务答案或图片描述重放为当前事实；未完成运行重启中断，无自动网络重放。

C5 展示实际查询步骤、失败/覆盖、编号出处和可展开片段。正文未知引用标记为未验证，普通模型链接不获得读取权限。仅已核验出处可复制；不执行 HTML 或自动请求 Markdown 图片。

原生选图使用固定版本 file_selector 1.1.0，仅用户点击“附图”选择 PNG/JPEG/WebP。原文件单张 10 MiB、1600 万像素，拒绝多帧，去元数据并缩至长边 1536，规范 PNG 单张 3 MiB/合计 6 MiB、最多 3 张。预览/移除及迟到选择复验当前输入；取消、切换/清历史或卸载清理未发送图片。文件名/路径不交给模型，不读取浏览器或自动截图。

规范图片只进入本轮 user content/data URL，同一固定模型网关，不用 Files API。统计与历史只有附件数量；图片缓冲尽力擦除，不承诺平台内部图像缓存和不可变编码字符串全部抹除。含图 400/415/422 明确 imageRejected，不静默丢图重发。学校视觉能力未由已有 toolReady 证明；协议参考 [网关契约](../../../reference/sources/model-gateway.md)及 [OpenAI 图像输入](https://developers.openai.com/api/docs/guides/images-vision)。

## 失败与修复

- SDK 默认沙箱仍有 resolvedExecutable 空值/无输出问题，终止自己的检查后以单次提权执行本机 SDK 正常启动；不改全局代理、SDK、TLS 或信任。
- 第一轮定向检查修正新增测试缺失的 PNG 编码导入、合成 SSE 的 UTF-8 Content-Type、未来版本 sentinel 预期，以及纯 fixture 的时间格式与覆盖语义；生产迁移不吞碰撞或降版本。静态检查补齐跨接口显式类型与导入。
- UI 测试的等待被进行中动画占用、弹出菜单未开始动画、同文案匹配及按钮出屏分别处理；使用有界等待、真实可见控件和明确定位，保留发送/停止/卸载/引用断言，不关掉产品进度来使测试通过。
- Astra 指出专门公开协调器的 recovery 不能靠普通 cancel 收口、关键失败后仍可能继续模型，以及自然“明天有哪些课”未开放本地读。根分别使用 retryRecovery、关键失败立即终结、补人类日期/课程主题选择，并新增恢复、零新增出站和自然语句反例。
- 新票据刚签发后的只读会话创建失败也必须落入 finally；退出部分依赖已关闭时不得复活。根把准入放入受控区，保存停止后的真实取消状态，保持 recovery 和所有权，禁止用已关闭依赖新发送。
- 首轮 Windows Agent 检查 1 组通过、3 组失败：停止前等待 held stream 的动画直到预算届满、失败退出视图未刷新持久取消事实及合成时间格式。根修正有界等待与关闭失败后的事实刷新，随后 4 组通过；未把早期失败覆盖为通过。
- 既有 M0 原生批次第二组曾持续无输出，根停止本轮测试；临时阶段定位的单组复跑完整通过，未复现产品故障。移除定位标记后整套两组重新通过；不补造确定根因或把初次停滞记为通过。
- 正式程序首次被根误用后台参数启动，窗口未显示。核对本轮精确 PID、规范路径及无可见窗口后，结束这个根自建且未交互的进程，以正常窗口方式重启；已确认 USTC Assistant 标题/主窗口存在。未读取正式记录，窗口元数据不替代真人界面或问答验收。

## 根检查

所有自动请求和库均为合成、loopback 或 nonce TEMP；Windows DPAPI 仅保护合成 Key，不访问学校、正式业务、实际 Key 或浏览器资产。SDK 命令从 app/ 执行，日志在忽略的 build/，临时定位代码已移除。

| 检查 | 当前实际结果 |
|---|---|
| 定向适配/运行/UI | 根 m52-adapter-runtime-ui-ready.log 55 项通过；后续范围/Young/出处修订纳入最终全套 |
| `flutter analyze --no-pub` | 根 exit 0，无问题，m52-analyze-delivery.log |
| `flutter test --no-pub --reporter expanded` | 根 exit 0，849 项通过、1 项跳过；跳过仅 Windows 上的非 Windows 保护不可用分支，m52-unit-delivery.log |
| Windows Agent | 根 exit 0，最终 4 组通过，m52-windows-agent-delivery.log |
| 既有相关 Windows | 前七套 exit 0；M0 最终两组 exit 0，m52-windows-m0-delivery.log；明细见下表 |
| 默认 Release | 根 `flutter build windows --release --no-pub --target=lib/main.dart` exit 0，63.2 秒，m52-release-delivery.log；无诊断、回环或临时 M3 编译标志 |
| 文档与 diff | 根 tools/check-docs.ps1 与 git diff --check 通过，覆盖现行本地链接、标题锚点及冻结档案清单 |

每套命令为 `flutter test integration_test/<套件>.dart -d windows --no-pub --reporter expanded`：

| 套件 | 通过组数 |
|---|---:|
| settings_maintenance_flow_test | 3 |
| calendar_workspace_flow_test | 4 |
| app_shell_flow_test | 1 |
| public_knowledge_flow_test | 1 |
| jw_sync_flow_test | 7 |
| young_sync_flow_test | 2 |
| young_automation_flow_test | 3 |
| m0_flow_test（最终整套复跑） | 2 |

M0–M4 相关套件共 23 组，含新增 Agent 共 27 组。新增 Agent 4 组包括：真实默认 DPAPI 的合成配置/held stream 停止及重开；清业务保留 Agent 与 reset 删除/激活重试；失败退出保留所有权、持久取消、拒绝旧运行与重试；C4/C3 的日程和随包知识端口、出处 Widget、原生 PNG 编解码/主动选择注入、历史仅计数及重启零自动请求。原生注入不是真人操作系统文件对话框或真实视觉验收。工程本地提交 3c5c757，文档另行提交，不推送。

## 真实核对与接续

真实 toolReady 已满足工具依赖；普通聊天/停止、少量日程/资料问答、主动选图和所选模型的实际视觉质量待用户核对。保留现有 Key 和所有业务资料启动默认 Release，不读取正式记录来替用户判断回答。只需少量已知问题及非敏感图片，工程矩阵不再要求用户重复。

本切只读与图片交付不表示本地批准写/规划/学校刷新已启用，后续按 M5.3/M5.4 接续。M1 非空考试、Young 未观察样本、财务在线搜索/FAQ、政策现行性及完整 V 项继续保留。
