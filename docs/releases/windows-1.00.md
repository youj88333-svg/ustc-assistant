# USTC Assistant 1.00 · Windows 私有交付

工程版本`1.0.0+1`，Windows x64。用户于2026-10-15认可此版本基线；目前仅准备本地完整目录和ZIP，尚未公开发布、上传、提供安装器或代码签名。已知问题单独列在同包`windows-1.00-known-issues.md`。

## 启动

1. 将ZIP完整解压到可长期保留的目录，保留全部DLL和`data`，不要直接从压缩包运行或只复制EXE。
2. 安装Microsoft Edge WebView2 Runtime。面向Windows 10/11 x64；具体系统构建、运行库及全新机器兼容性仍需实际验证。遇缺少`VCRUNTIME`/`MSVCP`的系统提示，可从微软官方安装x64 Visual C++ Redistributable；不要从非官方站点单独下载DLL。
3. 启动`ustc_assistant_m0.exe`。此文件名为兼容旧版保留，应用显示名为USTC Assistant，设置→关于可查看版本。
4. 同一Windows用户同时只运行一个实例。已有版本请正常退出后启动新包；不要让两个版本同时打开同一份资料。

[WebView2官方](https://developer.microsoft.com/microsoft-edge/webview2/) · [Visual C++运行库官方](https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist)

## 已有用户与首次使用

资料仍在`%USERPROFILE%\.ustc-assistant\local_v1`，移动解压目录不会主动清除日程、任务、聊天、设置或保存的密码。版本升级沿用schema18和现有通知身份，无额外资料迁移操作。请勿删除该资料目录、在运行中手工复制数据库、用旧程序覆盖新格式，或把其中的资料当作交付文件分享。此包没有新增业务备份/回退或跨设备同步功能。

首次使用可先创建个人安排和任务；教务/二课在设置→来源接入。学校密码、验证码和额外授权仅在应用/学校窗口操作，别发给开发者。Agent在设置→Agent主动提供学校模型Key并授权；未配置不影响本地日程。教务与二课使用同一份本机加密学校凭据；学校来源只读，不报名、退选或修改学校记录。

日程支持教学节次、日/周视图、来源课程/考试/二课、个人安排、出勤计划、备注、冲突和任务时间块；Agent可按许可查询、规划及修改本地资料。晨报为每天06:00后首次使用的异步摘要；提醒需要应用内开关和Windows系统通知均允许。每日二课自动同步默认关闭，仅在已启用且应用可见空闲时运行，退出后不会采集。晨报、提醒、来源读取和模型质量的实际限制见已知问题。

## 遇到错误

在设置→数据与隐私的诊断区导出最近日志，连同版本、发生时间、操作步骤和错误提示反馈。安全日志保留有界阶段/错误/计数，不包含对话正文、密码、Key、原始学校响应或录音；仍请先检查自行添加的截图和描述，避免分享私人资料。启动失败界面可导出当次安全错误。无需发送数据库或浏览器目录。

`manifest.json`记录源码提交、版本及逐文件SHA-256；ZIP的摘要在交付目录旁提供。摘要用于核对文件完整性，不等于发布者数字签名。构建资产、许可与文档一起交付，不包含用户资料或测试助手。

## 第三方声明

Flutter及Dart依赖声明在`data/flutter_assets/NOTICES.Z`；静态链接的WebView2加载器声明在`data/licenses/webview2`，对应固定SDK 1.0.3967.48。语音目录`data/speech/sensevoice`保留模型来源`NOTICE.txt`、原始`LICENSE`、FunASR模型许可、record、sherpa-onnx和ONNX Runtime许可；模型权重使用FunASR Model Open Source License Agreement 1.1，代码依赖各用其声明的许可，不能把权重统称为Apache或MIT。保留所有随包声明。本次私有交付不为项目源码另设开源许可。
