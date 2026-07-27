# USTC Assistant Flutter App

`app/` 是 USTC Assistant 的共享 Flutter 应用。当前真实运行和验收目标是 Windows；
Android/iOS 仅有平台脚手架，后续将复用这里的数据库、导入和业务模型，并替换来源
采集适配器。

## 已实现

- Drift/SQLite 本地账号分区与 SourceBundle 1.0 原子导入；
- Windows DPAPI 保护的学校账号和可选密码；
- Python localhost Bridge 同步教务课程、考试和已报名二课日程；
- 七日周课表、重叠展开、人工冲突关系和来源事件用户覆盖；
- 单次、全天、跨日和基础重复个人日程；
- Task、PlanBlock、截止风险、结束后确认和单步撤回；
- Reminder 持久化、App 内状态和 App 运行期间的 Windows 通知；
- 账号、操作历史、设置、官方网页和完全重置。

聊天页目前只是禁用外壳，不包含 LLM、每日简报或 Agent 工具调用。

## 运行

```powershell
E:\flutter\flutter\bin\flutter.bat pub get
E:\flutter\flutter\bin\flutter.bat run -d windows
```

App 同步依赖仓库根目录的 Python 包和 Conda 环境 `ustc_assistant`。解释器无法自动
定位时，可在 App 设置中填写该环境的 `python.exe`。

## 验证

```powershell
E:\flutter\flutter\bin\flutter.bat analyze
E:\flutter\flutter\bin\flutter.bat test
E:\flutter\flutter\bin\flutter.bat build windows --release
```

Release 位于 `build/windows/x64/runner/Release/`。运行和复制时必须保留整个
Release 目录，不能只保留 `ustc_assistant_app.exe`。

产品边界和当前交接状态分别见：

- `../docs/superpowers/specs/2026-07-26-first-windows-milestone-closure-design.md`
- `../docs/project-status.md`
