# USTC Assistant Flutter App

`app/` 是 USTC Assistant 的共享 Flutter 应用。当前真实运行和验收目标是 Windows；
Android/iOS 仅有平台脚手架，后续将复用这里的数据库、导入、业务模型和共享 Agent
核心，并替换来源采集适配器。

## 已实现

- Drift/SQLite 本地账号分区与 SourceBundle 1.0 原子导入；
- `CredentialProtector`（Windows DPAPI）保护的学校账号和可选密码；
- 教务同步：目标通道为原生 WebView2 采集器（`lib/features/sync/native/`，接入中），
  Python localhost Bridge 保留为 fallback；
- 七日周课表、重叠展开、人工冲突关系和来源事件用户覆盖；
- 单次、全天、跨日和基础重复个人日程；
- Task、PlanBlock、截止风险、结束后确认和单步撤回；
- Reminder 持久化、App 内状态和 App 运行期间的 Windows 通知；
- 账号、操作历史、设置、官方网页和完全重置；
- 本地 Agent（见下文）。

## Agent

聊天页已接入学校 Anthropic 兼容模型服务
（`https://api.llm.ustc.edu.cn`，默认模型 `deepseek-v4-flash`，SSE 流式，
`tool_use`/`tool_result` 循环）。共享 Agent 核心位于 `lib/features/agent/`：

- `domain/` 与 `application/`：平台无关的会话运行时、工具注册表、上下文构建、
  确定性隐私过滤、15 个本地只读工具（含 4 个管理态只读）与 20 个受控写/生命周期
  工具（11 写 + 9 生命周期/清除/撤回）。无外部按需来源工具。
- `data/`：`DriftChatRepository`、`AnthropicLlmProvider`（`package:http`）、
  `ProtectedAgentSecretStore`（DPAPI）。
- `presentation/`：聊天页、工具运行条、安全 Markdown、设置页和首次配置面板。

API Key 由 DPAPI 保护，每调用临时传入，不持久化为字段、不写入日志或异常。工具向
模型只返回临时引用，不返回数据库主键。单次请求最多 8 轮模型调用、12 次工具调用。
Agent 不能修改本地业务数据（未经审批门）、发起同步或执行任何外部写操作。本地
日程/任务工具返回数据时会话生成去重的本地导航动作，聊天页渲染为可点击 `ActionChip`
经 GoRouter 跳转。写工具与删除/生命周期工具全部经审批门按风险分级确认（聊天内联
确认卡）；权限变更永远需用户亲手确认。组合级集成测试见
`test/integration/agent_composition_flow_test.dart` 与
`test/features/agent/agent_delete_tools_test.dart`（真实路由 + 注入式组合）。

学校 API Host 固定为 `https://api.llm.ustc.edu.cn`，不在 App 内提供 Host 配置项；探针
仅返回脱敏的成功/失败与错误码，不存储或显示"最近连接测试时间"。

## 运行

```powershell
E:\flutter\flutter\bin\flutter.bat pub get
E:\flutter\flutter\bin\flutter.bat run -d windows
```

使用 Python fallback 同步时依赖仓库根目录的 Python 包和 Conda 环境
`ustc_assistant`。解释器无法自动定位时，可在 App 设置中填写该环境的 `python.exe`。

## 验证

```powershell
E:\flutter\flutter\bin\flutter.bat analyze
E:\flutter\flutter\bin\flutter.bat test
E:\flutter\flutter\bin\flutter.bat build windows --release
```

Release 位于 `build/windows/x64/runner/Release/`。运行和复制时必须保留整个
Release 目录，不能只保留 `ustc_assistant_app.exe`。

产品边界和当前交接状态分别见：

- `../docs/plan-webview-minimal.md`（本分支总路线）
- `../docs/plan-webview-minimal-m7-webview2.md`（原生 WebView2 接入计划）
- `../docs/m6-external-machine-handoff.md`（M6 交接手册）
- `../docs/acceptance/read-only-agent.md`（Agent 人工验收清单，minimal 注记版）
