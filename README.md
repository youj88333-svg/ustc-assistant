# USTC Assistant

面向中国科学技术大学的本地优先校园学习生活助手。仓库包含可运行的 Windows
Flutter 首版，以及教务课程与考试、二课报名中活动、已报名二课日程、评课社区
公开内容和校内公开信息目录五条 Python 只读数据链路。

Windows 首版已接入学校大模型公共服务平台，提供按学校账号隔离的只读校园 Agent：
能读取本地日程、Task 和全部查询型来源，通过可见、可停止的工具调用回答问题，但不
修改本地业务数据、发起同步或执行任何外部写操作。此外已提供账号与同步、七日周课表、
个人日程、Task/PlanBlock、冲突与用户覆盖、提醒、操作历史和设置。当前实现与接手
说明见 `docs/read-only-agent-handoff.md`，架构见 `docs/architecture.md`。

## 安装

```powershell
conda activate ustc_assistant
python -m pip install --no-build-isolation -e .
```

首次使用学校平台时会打开专用 Microsoft Edge 窗口。请在学校官方页面完成登录和验证码；浏览器 Profile 保存在本机，不写入项目目录。

## 命令

```powershell
python -m ustc_assistant collect jw --account-id <local-account-id>
python -m ustc_assistant collect young-enrolment
python -m ustc_assistant collect young-schedule --account-id <local-account-id>
python -m ustc_assistant query icourse --jw-bundle tmp/ustc-jw-import.generated.json
python -m ustc_assistant collect campus
python -m ustc_assistant query campus --text "选课"
python -m ustc_assistant read campus --entry-id <catalog-entry-id>
```

教务采集默认学期由 `config/source-defaults.json` 统一提供：`461 / 2026fall / 2026 秋季学期`。
调试时必须同时提供完整三元组，例如
`python -m ustc_assistant collect jw --account-id <local-account-id> --semester-id 461 --semester-key 2026fall --semester-name "2026 秋季学期"`；不会根据年份或名称推算教务内部学期 ID。
`--account-id` 是 App 本地账号标识，不是教务动态上下文 ID；正式采集命令不提供默认值。

教务联动评课社区会把课程名称作为检索词发送给公开网站 `icourse.club`，但不会发送完整课表、时间、地点、用户 ID 或登录信息。首次使用前应确认这一隐私影响；仅需本地检查课程分组时可增加 `--group-only`，该模式不会联网。

校园公开信息目录只读取教务处和财务处的公开页面，不使用登录状态。通知保留北京时间最近 7 个自然日，办事指南和公开信息每个自然月刷新一次；加 `--force` 可强制刷新全部目录。`query campus` 只搜索本地目录，不联网；`read campus` 按目录条目 ID 按需读取正文并使用 30 天详情缓存，刷新失败时默认可返回带 `stale: true` 的旧缓存。

默认输出分别位于：

- `tmp/ustc-jw-import.generated.json`
- `tmp/ustc-young-enrolment.generated.json`
- `tmp/ustc-young-my-schedule.generated.json`
- `tmp/icourse-public-query.generated.json`
- `tmp/campus-catalog.json`
- `tmp/campus-query.generated.json`
- `tmp/campus-detail.generated.json`
- `tmp/campus-cache/`

运行 `python -m ustc_assistant <command> --help` 查看学期、日期、缓存和手动查询选项。

## Windows App

要求：

- Flutter 3.44.5 / Dart 3.12.2；
- Visual Studio 2022 Build Tools 或 Visual Studio 2022，并安装
  `Desktop development with C++`；
- Conda 环境 `ustc_assistant`；
- Microsoft Edge。

开发运行：

```powershell
cd app
E:\flutter\flutter\bin\flutter.bat run -d windows
```

构建并启动 Release：

```powershell
cd app
E:\flutter\flutter\bin\flutter.bat build windows --release
cd build\windows\x64\runner\Release
.\ustc_assistant_app.exe
```

Release 运行时依赖同目录的 `data/`、`flutter_windows.dll`、`sqlite3.dll` 和插件
DLL，不能只复制单独的 `.exe`。

首次绑定账号或学校会话失效时，App 会在用户确认后启动专用 Edge。验证码和学校
登录仍由用户完成。Python Bridge 由 Flutter 按需启动，直接调用来源 service，
不会解析 CLI 终端文本。

### 只读校园 Agent

聊天页已接入学校 Anthropic 兼容模型服务（`https://api.llm.ustc.edu.cn`，默认模型
`deepseek-v4-flash`）。首次使用前在“设置 → 模型服务”输入学校 API Key，通过最小
文本与 Tool Calling 测试后启用聊天。Key 由 Windows DPAPI 保护，不写入 SQLite 明文
字段、源码、日志或提交。

Agent 提供 15 个只读工具：本地日程（`get_schedule` 等 5 个）、本地任务（`get_tasks`
等 4 个）、本地状态（`get_sync_status`、`get_safe_action_history`）、按需来源
（二课报名中、评课、校园目录/详情 4 个，经 Python Bridge Query Protocol 1.0）。
工具过程默认折叠，可停止和重试。单次请求最多 8 轮模型调用、12 次工具调用。Agent
不能修改本地业务数据、发起同步或执行任何外部写操作。详见
`docs/architecture.md`“只读 Agent 架构”一节。

校内校园网直接访问学校 API；校外由用户自行启动 Panabit iWAN。App 不启动、配置或
管理系统代理、TUN 或 iWAN。真实 Key、完整账号、私人课表和原始模型请求不得写入
验收文档；人工验收清单见 `docs/acceptance/read-only-agent.md`。

## 隐私

- 默认只保存规范化结果；原始响应仅在显式使用 `--save-raw` 时写入 `tmp/private/`。
- 不保存或输出密码、Cookie、Token、CAS ticket、教务上下文 ID 和二课加密请求参数。
- `tmp/`、`temp.md`、缓存和浏览器 Profile 不进入 Git。
- 二课报名和取消报名始终由用户在学校官方页面执行，本项目不会自动提交。

## 开发

```powershell
conda run -n ustc_assistant python -m unittest discover -s tests -v
conda run -n ustc_assistant python -m compileall -q src tests
Push-Location app
E:\flutter\flutter\bin\flutter.bat analyze
E:\flutter\flutter\bin\flutter.bat test
E:\flutter\flutter\bin\flutter.bat build windows --release
Pop-Location
```

Flutter 工程位于 `app/`，使用 Flutter 3.44.5 和 Dart 3.12.2。由于 Flutter
3.44.5 固定的 `meta` 版本与原计划的新生成器不兼容，当前锁定
`drift_dev 2.34.0` 与 `build_runner 2.10.5`；运行时 `drift` 保持 2.34.2。

只读 Agent 修复轮的最近自动验证结果（Python / Flutter 测试计数、静态分析、Windows
Release 构建）在最终验证时记录于 `docs/read-only-agent-handoff.md` 第 7 节；本文件不
硬编码计数与 HEAD 哈希，因为后续提交会改写。自动验证不代替需要学校登录和真实 API Key
的人工验收。

架构和来源契约见 `docs/architecture.md` 与 `docs/data-sources/`。`collect jw`
与 `collect young-schedule` 默认输出
`docs/data-sources/source-bundle-v1.md` 定义的 SourceBundle 1.0，可直接作为
Flutter 导入层的输入。报名中活动、评课和校园公开信息继续使用各自的查询结果契约。

## 当前边界

- 只读 Agent 已接入学校 Anthropic 模型服务，但写工具、每日简报、视觉能力
  （`qwen3.6-chat`）、多会话/多 Agent/MCP、通用 HTTP/任意 URL/文件/Shell/SQL 工具
  仍不在本里程碑范围。引用 chip 当前不可交互（临时引用到来源 URL 的解析为合并后
  工作）。
- 真实人工验收（真实 Key + 校园网/iWAN + 学校登录）尚未执行；自动测试不代替人工
  验收。清单见 `docs/acceptance/read-only-agent.md`。
- Android/iOS 工程脚手架已存在，但移动端登录与来源采集适配器尚未实现；共享 Agent
  核心可复用。
- Windows 首版不是安装包，不捆绑 Python runtime。
- App 关闭后的可靠 Windows 通知投递与取消尚未实现。
- 二课报名和取消报名始终由用户在学校官方页面完成。
