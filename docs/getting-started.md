# 开始使用

Windows x64 和 Android ARM64/x86_64 的 1.0.0 安装包已在[校内 GitLab Release](https://git.ustc.edu.cn/demo233/107_ustc_assistant/-/releases/v1.0.0)公开提供；对应的[GitHub Release](https://github.com/youj88333-svg/ustc-assistant/releases/tag/v1.0.0)待发布，完成前请从 GitLab 获取安装包。先按[发布说明](releases/public-1.0.0.md)选择安装包；需要自行构建时使用下文入口。Android 正式版与 QA 应用拥有独立身份和资料目录，不自动搬迁资料。

## 从源码启动 Windows 版本

项目的 `app/pubspec.yaml` 要求 Dart SDK `^3.12.2`，依赖版本记录在 `app/pubspec.lock`。仓库没有固定 Flutter SDK 发行版。请在已安装 Flutter 的 Windows 环境中，从仓库根目录执行：

```powershell
Set-Location app
flutter pub get
flutter run -d windows
```

如果本机已有锁定依赖缓存，也可以使用仓库现有说明中的离线解析命令 `flutter pub get --offline`。Windows 构建使用 Microsoft WebView2；当前工程固定 WebView2 SDK 包 `Microsoft.Web.WebView2 1.0.3967.48`，运行应用的设备还需要 WebView2 Runtime。

## 首次设置

新安装会显示首次设置流程，可以跳过并稍后从“设置 → 首次设置”继续。你可以先创建个人安排和任务，再按需要启用其他能力：

1. **学校来源**：在应用内输入账号和密码；是否保存密码由你选择。你主动开始登录或采集后，应用可在普通系统 WebView 中使用已保存凭据自动认证；验证码和额外授权由你处理。来源只读，不会报名、退选或修改学校记录。
2. **模型服务**：可选择学校模型服务或 DeepSeek 官方服务，并在应用中输入自己有权使用的 Key、选择模型和同意发送。没有配置模型也可使用本地日程和任务。DeepSeek 官方服务可能单独计费。
3. **隐私授权**：私人内容读取、本地操作、评课联网、晨报、系统提醒和每日二课同步分别控制；完成引导不会把它们全部打开。每日二课同步默认关闭，只在你启用且应用运行、前台空闲时工作，退出应用后不会继续采集。

密码、模型 Key、验证码和学校授权只在应用或学校页面中处理，不要放进聊天、Issue、合并请求或日志。应用不会读取浏览器手填的密码或浏览器认证资产。普通 WebView 保留学校页面的正常网络活动；发布候选不增加旧版高级隔离门槛。有关数据处理边界，见[唯一文档导航](README.md)中的产品约束、关键契约和隐私章节。

## 当前平台边界

- **Windows x64**：公开便携 ZIP 已提供，完整解压后运行；Windows 包未代码签名，全新系统和所有设备组合尚未完整验收。
- **Android**：公开正式包名为 `cn.ustcassistant.mobile`，与 `cn.ustcassistant.mobile.qa` 并存，不会自动迁移 QA 资料。继续保留 QA 应用及其资料，不要为安装正式版先卸载或清空它。正式签名材料由维护者本机在源码外管理。
- **鸿蒙设备**：目前仅讨论可直接安装 Android APK 的兼容场景，不提供原生鸿蒙 HAP。MatePad 11.5 S / HarmonyOS 4.2.0 有实际用户反馈，但不能据此推断所有鸿蒙设备均已验证。

查看[开发说明](development.md)了解普通源码构建、正式候选准备命令和各自边界；构建工具会要求干净的已提交修订，候选准备不会自动发布。项目的详细设计与证据索引仍以[docs/README.md](README.md)为准。
