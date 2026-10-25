# 1.0.0公开发布

2026-10-25已在[校内GitLab发布v1.0.0](https://git.ustc.edu.cn/demo233/107_ustc_assistant/-/releases/v1.0.0)，源码修订为`9515e50a95d6988f0d1a438566b5957e0e88d78a`。项目和六份附件的匿名访问、完整下载字节数及SHA-256均已核验；实际发布与检查见[阶段记录](../milestones/open-source-release/records.md)。发布不替代新设备和真实业务验收。

| 使用设备 | 下载 |
|---|---|
| Windows x64 | [完整便携ZIP](https://git.ustc.edu.cn/demo233/107_ustc_assistant/-/releases/v1.0.0/downloads/USTC-Assistant-1.0.0-windows-x64.zip) |
| Android手机、可直接安装APK的鸿蒙 | [ARM64 APK](https://git.ustc.edu.cn/demo233/107_ustc_assistant/-/releases/v1.0.0/downloads/app-arm64-v8a-release.apk) |
| x86_64模拟器 | [x86_64 APK](https://git.ustc.edu.cn/demo233/107_ustc_assistant/-/releases/v1.0.0/downloads/app-x86_64-release.apk) |

## 平台与安装

- Windows x64：完整便携ZIP，解压全部DLL与data后运行`ustc_assistant_m0.exe`。需要Microsoft Edge WebView2 Runtime；依系统情况安装微软官方x64 Visual C++运行库。本版未取得Windows代码签名证书，SHA-256用于完整性核对，不等同发布者数字签名。
- Android ARM64：正式包名`cn.ustcassistant.mobile`，由本项目长期发布密钥签名。原`cn.ustcassistant.mobile.qa`测试版保留，两者独立；不自动搬迁账号配置、聊天、个人安排或密文。可在正式版重新登录并同步学校数据，不要为了安装正式版先清空或卸载测试版。
- Android x86_64：供兼容模拟器使用，与ARM64采用同一正式身份/签名策略，按设备架构选择。
- 可安装Android APK的鸿蒙适用相同APK路线；已有MatePad 11.5″S / HarmonyOS4.2.0反馈属于此前测试版，不能替代本次正式包验核。原生鸿蒙HAP及其他平台不在本次构建范围。

## 开始使用与资料

按首次设置依次配置学校账号、教务/二课同步、模型服务及各项授权；可跳过联网接入，先使用本地日程和任务。模型Key由用户在应用中提供，学校和DeepSeek官方服务分开保存，不自动回退；官方服务独立计费。验证码/学校额外授权仍由本人完成。

Windows继续沿用自己的既有正式资料根与DPAPI用途；Android新正式身份拥有独立私有目录/Keystore。禁止跨设备复制数据库或密文。卸载、清数据或换身份没有自动恢复承诺；本期不新增业务备份/迁移功能。学校数据只读，不执行报名、退选或学校记录修改。

## 校验与说明

发布页附[文件清单](https://git.ustc.edu.cn/demo233/107_ustc_assistant/-/releases/v1.0.0/downloads/release-manifest.json)和[SHA256SUMS.txt](https://git.ustc.edu.cn/demo233/107_ustc_assistant/-/releases/v1.0.0/downloads/SHA256SUMS.txt)。Android证书SHA-256为`8f5022f13297f11ad3049d1da5d9eb61493b48f4745859b48d060dc99d549fa7`；此摘要用于辨认Android签名，文件摘要用于核对下载内容。候选文件中的不可变追溯标记继续保留，实际公开状态以Release页面为准。

已知问题见[统一清单](known-issues.md)，完整来源和通知见随包`LICENSE`、`NOTICE`、`THIRD_PARTY_NOTICES.md`、Flutter通知与语音/SDK许可。

学校资料、模型和图标参考元素的来源与代码许可分别说明，见随包第三方通知。图标按用户选择沿用现有版本。
