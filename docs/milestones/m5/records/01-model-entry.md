# M5.1 模型入口与最短对话

实施日期：2026-10-13。依据 [07–12](../../../architecture/07-constitution.md)、[13](../../../quality/13-risks-and-acceptance.md)、[14](../../../reviews/14-overall-review.md)、[15 工作流](../../../workflow.md)及 [总方案 §15](../plan.md#15-m51-施工规格)。[总方案已批准](../acceptance.md)，M5.1 的真实能力和体验尚未验收，本记录不关闭 M5 或完整 V 项。

## 交付与边界

Sol / max 持有共享契约、C3 迁移/事务、C4 运行、C5 控制器、Runtime 与维护集成。三个 Luna / max 分别交付固定模型传输、页面/设置与合成检查；互不修改共享 store 或组合根。Astra / high 针对停止、配置保护和跨层维护做一次只读复核，根处理两项明确竞态；模型声明通过不替代下面的根检查。

生产模型入口仅为学校 `GET /v1/models` 与 `POST /v1/chat/completions`，固定 HTTPS 主机，不跟重定向、不读取 Cookie 或浏览器资产。短期 Key 租约单次消费，二进制缓冲尽力清零；Dart/HTTP 所需的不可变字符串无法可靠擦除，不声称完整内存抹除。传输有连接/读取/整体超时、SSE/正文/工具参数限额，工具参数完整终结前不交付。

网关实现参考 [学校 API 指南](https://llm.ustc.edu.cn/guide/api-usage/)、[兼容协议](https://llm.ustc.edu.cn/guide/protocol/)和 [模型目录说明](https://llm.ustc.edu.cn/guide/models/)。兼容性仍按实际 Key/model 验核；不把文档里的 OpenAI 兼容声明当 toolReady。SSE 的 `usage:null` 按 [OpenAI 流式契约](https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events)视为未提供计数，只有实际对象才解析；新增合成 frame 覆盖此正常情况。

C3 增量 schema 10→11 添加独立模型配置、会话/消息、运行、历史清理意图和最小审计。Key 用独立类型/用途复用 Windows DPAPI CurrentUser；保护先成功，保存事务才复验 authority 并替换。保护或 SQL 失败保留旧配置，已有教务/二课、知识、个人/任务、备注/隐藏、目录和 Undo 不重建。

authority 包括 reset/history/config/request 世代；C3 保存回复和配置均复验。停止持久推进 requestEpoch，排空模型后收口；开始清历史先写持久意图，删除前排空，重启只恢复清理与中断事实。清业务保留 Key、配置和历史，reset 一并删除；原 M4.4 维护租约与 busy-before-intent 保持。退出先撤销/排空模型，依赖排空成功后永久关闭；退出失败保留目录所有权，不继续旧 run。

C5 默认 Agent 接实际对话端口，设置新增 Agent 区，支持模型目录/合成验核、受保护 Key、流式发送/停止、会话与历史清理。已保存模型的联网同意可撤销/恢复，关闭时不删除 Key/历史，但禁止新发送。输入与回复检查可识别秘密；此检测不承诺发现所有秘密。Markdown 不自动请求图片、不打开模型给出的链接或执行 HTML。

本切没有业务工具注册。只有用户主动运行能力验核时可发送固定 `echo_probe` 合成函数：文本/流式成功仅 chatOnly；工具调用参数校验和不可预知 proof 的结果续答均成功才 toolReady。目录、Key 和能力以配置事务保存；真实工具接入仍按 M5.2 依赖。

## 失败与修复

- SDK 在默认沙箱内无输出停滞；终止该检查进程后以单次提权运行同一离线命令正常启动。不修改全局 SDK、代理或系统策略，不把工具启动失败记成源码错误。
- 初轮静态检查发现 Markdown builder 的 const 父构造不成立、未用变量/导入和大括号提示；页面确认 await 后增加直接 mounted/端口守卫。新增卸载反例确保不会弹旧确认或调用旧端口。
- 合成保护器的 typed 和 unexpected 异常都归一为 protectionFailed；保护失败、SQL checkpoint 失败分别验证旧配置/审计不变。
- 全量 unit 首轮 14 条旧版本迁移测试失败：合成副本从当前版本回造旧版时残留新 Agent 表。只更新 nonce/TEMP fixture helper 及当前成功目标版本 11；保留失败旧版本、碰撞、原始事实和序列回滚断言，不在生产迁移吞表碰撞。
- Astra 确认“beginRun 返回 ticket 前停止”会遗留 active run，以及“保护异步暂停期间停止”仍可能提交配置。根增加 C3 requestEpoch 裁决、保留迟到 ticket 并再次收口，在 Key 交接后、网络注册前复验；候选 Key 超时调用同一停止路径。新增暂停 beginRun/protect/lease 的真实 C3 合成反例，要求旧配置保留、零新出站且后续可再发送。
- Windows 新装配首轮 1 项通过、2 项失败：测试漏选模型、漏设置 held stream，预期关闭异常未在 runAsync 内捕获。随后又修正桌面返回控件的定位，以及输入后缺失按钮更新帧的等待；显式复验 route.canPop/isCurrent、可见返回控件及发送按钮启用，不用程序直接 pop 掩盖产品路径。保留故障、所有权和实际停止断言，最终根三组通过；不把早期失败改写为通过。

## 根检查

所有自动请求和数据库均为合成、loopback 或 nonce TEMP，Windows DPAPI 只保护合成 Key；不访问真实学校、不读正式业务或浏览器认证资产。命令在 `app/`，SDK 为本机 `E:/flutter/flutter/bin/flutter.bat`。

| 检查 | 当前实际结果 |
|---|---|
| 定向 unit：网关、C4/C3/文本、页面及旧迁移 | 根 `m51-focused-root.log` 114 项通过；最后权限/取消/网关/页面目标 47 项通过，均纳入最终全套 |
| `flutter analyze --no-pub` | 根 exit 0，无问题，`m51-analyze-accepted.log` |
| `flutter test --no-pub` | 根 exit 0，795 项通过、1 项跳过；Windows 上跳过“非 Windows 保护机制不可用”分支，`m51-unit-accepted.log` |
| Windows `agent_model_flow_test.dart` | 根 exit 0，3 组通过，`m51-windows-agent-ready.log`；实际默认 DPAPI 仅保护合成 Key |
| 既有相关 Windows | 根 8 套 exit 0，共 23 组通过；明细见下表 |
| 默认 Release | 根 `flutter build windows --release --no-pub --target=lib/main.dart` exit 0，32.8 秒；无诊断/临时 M3 编译标志，`m51-release-accepted.log` |
| 文档与 diff | 根 `tools/check-docs.ps1` exit 0：97 份 Markdown、702 个本地链接、冻结档案清单通过；`git diff --check` 通过 |

每套 Windows 命令为 `flutter test integration_test/<套件>.dart -d windows --no-pub`，按依赖顺序执行，全部为根实际结果：

| 套件 | 通过组数 |
|---|---:|
| settings_maintenance_flow_test | 3 |
| calendar_workspace_flow_test（含任务/时间块/Undo） | 4 |
| app_shell_flow_test | 1 |
| public_knowledge_flow_test | 1 |
| jw_sync_flow_test | 7 |
| young_sync_flow_test | 2 |
| young_automation_flow_test | 3 |
| m0_flow_test | 2 |

含本切 3 组共 26 组。构建日志只保留在忽略的 `app/build/`，不会进入工程提交。早期 SDK/测试失败与修复保留于上节，不推断真实学校请求、费用或成功率。工程本地提交 `15dc270`；文档另行提交，不推送。

## 真实核验与后续

用户需在新版“设置 → Agent”主动提供 Key、选择目录里的模型并执行合成验核，再复制 `agent-model-validation-v1` 安全能力摘要；只需核对真实流式对话与停止。Key 不通过聊天发送，学校额外授权仍由用户处理。

没有这份实证时，M5.1 只能记工程完成，不能关闭或启用 M5.2 业务工具。M1 非空考试、Young 未观察样本、财务搜索/FAQ 与政策现行性继续按既有登记保留。
