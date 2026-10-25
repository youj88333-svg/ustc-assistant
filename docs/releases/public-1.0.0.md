# 1.0.0公开发布候选

当前为准备中的本地候选，不代表GitLab已公开或安装包已上传。实际源码、安装包身份、哈希、检查和最后发布确认以[阶段记录](../milestones/open-source-release/records.md)为准；最终入口计划为[校内GitLab Releases](https://git.ustc.edu.cn/demo233/107_ustc_assistant/-/releases)。

## 平台与安装

- Windows x64：完整便携ZIP，解压全部DLL与data后运行`ustc_assistant_m0.exe`。需要Microsoft Edge WebView2 Runtime；依系统情况安装微软官方x64 Visual C++运行库。候选未取得Windows代码签名证书，SHA-256用于完整性核对，不等同发布者数字签名。
- Android ARM64：正式包名`cn.ustcassistant.mobile`，由本项目长期发布密钥签名。原`cn.ustcassistant.mobile.qa`测试版保留，两者独立；不自动搬迁账号配置、聊天、个人安排或密文。可在正式版重新登录并同步学校数据，不要为了安装正式版先清空或卸载测试版。
- Android x86_64：供兼容模拟器使用的独立ABI候选，与ARM64采用同一正式身份/签名策略，按设备架构选择。
- 可安装Android APK的鸿蒙适用相同APK路线；已有MatePad 11.5″S / HarmonyOS4.2.0反馈属于此前测试版，不能替代本次正式包验核。原生鸿蒙HAP及其他平台不在本次构建范围。

## 开始使用与资料

按首次设置依次配置学校账号、教务/二课同步、模型服务及各项授权；可跳过联网接入，先使用本地日程和任务。模型Key由用户在应用中提供，学校和DeepSeek官方服务分开保存，不自动回退；官方服务独立计费。验证码/学校额外授权仍由本人完成。

Windows继续沿用自己的既有正式资料根与DPAPI用途；Android新正式身份拥有独立私有目录/Keystore。禁止跨设备复制数据库或密文。卸载、清数据或换身份没有自动恢复承诺；本期不新增业务备份/迁移功能。学校数据只读，不执行报名、退选或学校记录修改。

## 校验与说明

发布候选应附版本/源码修订、ABI/包名/版本码、Android证书SHA-256、逐项manifest及`SHA256SUMS.txt`；以实际生成清单为准，不将此前私有包摘要冒充本次结果。已知问题见[统一清单](known-issues.md)，完整来源和通知见随包`LICENSE`、`NOTICE`、`THIRD_PARTY_NOTICES.md`、Flutter通知与语音/SDK许可。

学校资料、模型和图标参考元素的来源与代码许可分别说明，见随包第三方通知。图标按用户选择沿用现有版本；候选包的实际公开状态以GitLab Release为准。
