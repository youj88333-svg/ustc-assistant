# USTC Assistant

USTC Assistant 是一款面向校内学习生活的本地优先助手。它把 Agent、日程和任务放在同一个应用里：Agent 是默认首页，任务位于日程页，设置用于管理账号、模型和授权。

## 功能

- 查看教务课程与考试、二课活动关联日程，管理个人安排、任务、时间块、冲突、提醒与撤销。
- 通过用户主动启用的来源采集更新日程；教务与二课操作只读，不报名、退选或修改学校记录。二课活动关联日程不代表本人报名状态已验证。
- 在 Agent 中查询本地日程、任务和已收录的校园公开资料，查看结果出处；按当前授权准备本地修改方案，由用户确认后提交。
- 可选使用学校模型服务或 DeepSeek 官方服务。应用内也提供用户主动触发的中文语音输入；晨报、提醒和每日二课同步分别管理授权。

## 平台现状

| 平台 | 当前情况 |
|---|---|
| Windows x64 | 1.0.0 便携 ZIP 已公开发布，完整解压后运行。Windows 包未代码签名，目标机型和全新系统覆盖仍有限。 |
| Android APK | 1.0.0 ARM64 与 x86_64 正式 APK 已公开发布，采用长期发布签名。正式身份为 `cn.ustcassistant.mobile`，与 QA 包 `cn.ustcassistant.mobile.qa` 并存且不自动迁移数据。多厂商设备和完整逐项验收仍有保留项。 |
| 鸿蒙设备 | 仅指可直接安装 Android APK 的场景。MatePad 11.5 S / HarmonyOS 4.2.0 有用户实际使用反馈；这不代表原生鸿蒙 HAP 支持，也不代表所有设备已验收。 |

## 下载 1.0.0

安装包已在 [GitHub Release](https://github.com/youj88333-svg/ustc-assistant/releases/tag/v1.0.0) 和[校内 GitLab Release](https://git.ustc.edu.cn/demo233/107_ustc_assistant/-/releases/v1.0.0)发布，两处提供相同版本的文件：

| 使用设备 | GitHub 下载 | 校内 GitLab 下载 |
|---|---|---|
| Windows x64 | [便携 ZIP](https://github.com/youj88333-svg/ustc-assistant/releases/download/v1.0.0/USTC-Assistant-1.0.0-windows-x64.zip) | [便携 ZIP](https://git.ustc.edu.cn/demo233/107_ustc_assistant/-/releases/v1.0.0/downloads/USTC-Assistant-1.0.0-windows-x64.zip) |
| Android 手机、可直接安装 APK 的鸿蒙 | [ARM64 APK](https://github.com/youj88333-svg/ustc-assistant/releases/download/v1.0.0/app-arm64-v8a-release.apk) | [ARM64 APK](https://git.ustc.edu.cn/demo233/107_ustc_assistant/-/releases/v1.0.0/downloads/app-arm64-v8a-release.apk) |
| x86_64 模拟器 | [x86_64 APK](https://github.com/youj88333-svg/ustc-assistant/releases/download/v1.0.0/app-x86_64-release.apk) | [x86_64 APK](https://git.ustc.edu.cn/demo233/107_ustc_assistant/-/releases/v1.0.0/downloads/app-x86_64-release.apk) |

安装步骤、签名及资料保留边界见[发布说明](docs/releases/public-1.0.0.md)，限制见[已知问题](docs/releases/known-issues.md)，文件摘要见[SHA256SUMS.txt](https://github.com/youj88333-svg/ustc-assistant/releases/download/v1.0.0/SHA256SUMS.txt)。源码构建入口见[开始使用](docs/getting-started.md)，构建命令见[开发说明](docs/development.md#正式候选构建)，完整导航见[docs/README.md](docs/README.md)。

## 隐私与模型配置

日程、任务、偏好和应用历史保存在本机。学校密码和模型 Key 只有在你主动输入并选择保存后才供应用按需使用，由 Windows DPAPI 或 Android Keystore 保护；这不表示整个业务数据库已加密。用户主动启用教务或二课采集后，已保存的学校凭据可用于普通 WebView 中的自动认证；来源保持只读，应用不读取浏览器已有的手填秘密或认证资产。

模型服务是可选项，需要你在应用中选择服务、输入自己的 Key 并同意发送。使用模型时，当前请求所需的对话内容以及主动选择附加的图片会发往所选服务；学校密码不会发送给模型。DeepSeek 官方账户可能单独计费。私人备注和任务正文须另行授权后才会按当前任务有界读取。学校页面及其依赖脚本在普通 WebView 中运行，可能产生页面自身的常规网络活动。不要把密码、Key、学校页面原文或数据库贴到公开问题中。

## 贡献与许可

请先阅读[贡献指南](CONTRIBUTING.md)和[开发说明](docs/development.md)。发现安全问题时按[安全报告说明](SECURITY.md)处理，不要公开贴出漏洞细节。

项目原创代码采用 [Apache License 2.0](LICENSE)；该许可不自动覆盖第三方依赖、语音模型权重、图标和来源材料，各自许可与归属以对应声明为准。
