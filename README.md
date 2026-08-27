# USTC Assistant（minimal 分支）

面向中国科学技术大学的本地优先校园学习生活助手。本分支为整体重构的**最小实现**：
只保留教务（JW）+ 日程表 + Agent（本地只读 / 受控写 / 生命周期）。二课（young）、
评课（icourse）、校园公开目录（campus）的用户功能与外部 Agent 来源工具已随 M1 删除。

- 教务采集：目标通道为 Flutter 原生 WebView2（进行中，见
  `docs/plan-webview-minimal-m7-webview2.md`）；当前仍可通过 Python Bridge 兜底。
- Agent：接入学校 Anthropic 兼容模型服务（`https://api.llm.ustc.edu.cn`，
  默认模型 `deepseek-v4-flash`），只读工具 15 个（本地）+ 受控写/生命周期工具 20 个，
  无外部按需来源工具。

## 安装

```powershell
conda activate ustc_assistant
python -m pip install --no-build-isolation -e .
```

Python 仅用于 Bridge fallback 与 oracle；Flutter App 会按需启动它。

## 命令（Python CLI）

```powershell
python -m ustc_assistant collect jw --account-id <local-account-id>
python -m ustc_assistant config generate-flutter-defaults
```

教务采集默认学期由 `config/source-defaults.json` 统一提供：`461 / 2026fall / 2026 秋季学期`。
调试时必须同时提供完整三元组，例如
`python -m ustc_assistant collect jw --account-id <local-account-id> --semester-id 461 --semester-key 2026fall --semester-name "2026 秋季学期"`；
不会根据年份或名称推算教务内部学期 ID。`--account-id` 是 App 本地账号标识，
不是教务动态上下文 ID。

Flutter 端 `app/lib/core/config/generated_source_defaults.dart` 中的默认教务学期常量由
同一份 JSON 生成，切勿手改。修改了 `config/source-defaults.json` 后必须重新生成并提交
生成文件：

```powershell
conda run -n ustc_assistant python -m ustc_assistant config generate-flutter-defaults
```

默认输出：`tmp/ustc-jw-import.generated.json`。

运行 `python -m ustc_assistant <command> --help` 查看选项。

## Windows App

要求：

- Flutter 3.44.5 / Dart 3.12.2；
- Visual Studio 2022（含 `Desktop development with C++`）；
- （使用 Python fallback 时才需要）Conda 环境 `ustc_assistant`。

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

Release 运行时依赖同目录的 `data/`、`flutter_windows.dll`、`sqlite3.dll` 和插件 DLL，
不能只复制单独的 `.exe`。

### Agent

聊天页已接入学校 Anthropic 兼容模型服务。首次使用前在“设置 → 模型服务”输入学校
API Key，通过最小文本与 Tool Calling 测试后启用聊天。Key 由 `CredentialProtector`
（Windows DPAPI）保护，不写入 SQLite 明文字段、源码、日志或提交。

Agent 提供 15 个本地只读工具 + 20 个受控写/生命周期工具（11 写 + 9 生命周期/清除/撤回），
全部经审批门按风险分级确认；无任何外部按需来源工具。Agent 不能发起同步或执行任何外部
写操作。真实人工验收清单见 `docs/acceptance/read-only-agent.md`（minimal 注记版）。

校内校园网直接访问学校 API；校外由用户自行启动 Panabit iWAN。App 不启动、配置或
管理系统代理、TUN 或 iWAN。真实 Key、完整账号、私人课表和原始模型请求不得写入
验收文档。

## 隐私

- 默认只保存规范化结果；原始响应仅在显式使用 `--save-raw` 时写入 `tmp/private/`。
- 不保存或输出密码、Cookie、Token、CAS ticket、教务上下文 ID 等会话材料。
- `tmp/`、`temp.md`、缓存和浏览器 Profile 不进入 Git。

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

- Flutter 工程位于 `app/`，使用 Flutter 3.44.5 / Dart 3.12.2；锁定 `drift_dev 2.34.0`
  与 `build_runner 2.10.5`。
- 静态验证快照见 `docs/m6-refactor-final-verification.md`（analyze 0 error；
  test 1360 pass / 7 fail 基线）；7 项基线失败处置见 `docs/m6-external-machine-handoff.md` §6。
- 来源契约见 `docs/data-sources/`。

## 当前边界

- 原生 WebView2 采集在接入中（M7）；`JwWebViewAdapter` 由 stub 转真实实现，本机可编译，
  真实校园账号/校园网人工验收仍外置。
- 不做 C++ 会话持久化：重启后重新登录（已知边界）。
- Android/iOS 真实 WebView 与构建仍留外部机器（M5 静态接口 + stub）。
- Python Bridge 未删除，保留为 fallback（`kUsePythonBridgeFallback`）。
