# Android / APK鸿蒙1.00私有交付

2026-10-25沿用现有QA身份交付，不公开发布。用户MatePad 11.5″S / HarmonyOS 4.2.0直接安装APK，已反馈日常使用总体无大问题，并确认原后台返回目录占用故障未再出现；[用户验收](../milestones/android-apk/acceptance.md)保存原话与适用范围。

## 下载本机安装包

交付目录为本工作树下`app/build/private-releases/android-1.00-qa2024-441a68b/`，在E盘，不包含用户资料或签名私钥。

| 使用环境 | 文件 | 版本码 | 大小 |
|---|---|---:|---:|
| ARM64 Android手机、可直接安装APK的鸿蒙（含当前MatePad） | [ARM64安装包](../../app/build/private-releases/android-1.00-qa2024-441a68b/USTC-Assistant-Android-QA2024-arm64-v8a.apk) | 2024 | 281727148 bytes |
| MuMu x86_64模拟器 | [MuMu安装包](../../app/build/private-releases/android-1.00-qa2024-441a68b/USTC-Assistant-Android-QA4024-x86_64.apk) | 4024 | 293625010 bytes |

这两个文件沿用[记录23](../milestones/android-apk/records/23-onboarding-and-brand.md)的已验证构建，没有另造一个未经测试的“最终版”。各设备只安装对应的一个APK；手机不能安装x86_64包。体积主要来自随包本地语音模型，不是用户数据。Windows1.00及独立Windows暂存目录保留，未被本次移动交付覆盖。

## 安装与开始使用

已有QA应用请直接覆盖安装；包名、签名及资料目录保持，聊天、日程、备注、密码和设置按原增量升级规则保留。已经安装QA2024的MatePad无需为了本次文件整理再安装一次。遇到签名、架构或降级提示先停止并保留提示，不通过卸载或清数据绕过。

新安装按学校账号、同步教务/二课、模型Key、逐项授权四页设置，可跳过或稍后继续。已有用户从“设置 → 首次设置”进入，不强制重做；填写学校账号本身不代表已验证登录，真实同步和模型验证需主动启动，学校挑战由用户处理。提醒、晨报、每日二课、评课联网、私人读取及本地操作沿用各自许可，不因安装/完成引导全部开启。

仅在应用内输入学校密码和模型Key。出现问题可从“设置”标题旁“导出日志”，或“数据与隐私 → 导出最近日志”主动保存安全诊断，反馈设备版本、现象及该文件即可；不用发送密码、Key、学校页面原文或业务明细。导出日志不等于业务备份。

正常同签名升级保留资料；卸载、清应用数据、切换独立正式身份不承诺恢复。本版schema20不支持直接降级读取，也不支持Windows与手机之间复制数据库或密文。正式Release签名和跨身份迁移本轮没有实施。

## 身份与校验

| 项目 | 值 |
|---|---|
| 应用包名 | `cn.ustcassistant.mobile.qa` |
| 产品版本 / 构建版本 | `1.00` / `1.0.0-qa-a8-setup` |
| 构建种类 | 私有QA / Debug，普通入口`lib/main.dart`；不是正式Release |
| 源码修订 | `441a68b99ea713eb891b269dc0210a1c41b63f77` |
| 数据库 / 工具 / 提示词 | schema20 / agent-tools-v7 / persona-v15 |
| 签名证书SHA-256 | `16d3f9867f0a15d4d4ffc877bdd9ec240e92a3fddf6a0a66da857e2888846036` |
| ARM64 APK SHA-256 | `6d50e1fe566d29ec40e4c33e3922f17af3872501d41ca03a352d0150d7fa31b7` |
| x86_64 APK SHA-256 | `6863b9f77f28ee3f3f2b82d199e42442e4cfb13ffd46069c9825b590d3f115fe` |

交付目录的`manifest.json`记录身份、源码及各文件大小/哈希，`SHA256SUMS.txt`还覆盖manifest本身；可用PowerShell的`Get-FileHash -Algorithm SHA256`核对。`licenses/`附带APK内相同的Flutter依赖通知、语音组件许可和模型许可。主清单不包含用户日志、私钥、数据库、浏览器资产或缓存。

工程检查以[记录23](../milestones/android-apk/records/23-onboarding-and-brand.md)为准，交付复制/签名/许可/清单检查以[记录24](../milestones/android-apk/records/24-private-handoff.md)为准；这次仅整理文件和文档，不将上轮1654项共享测试写成本轮重跑。使用前可查看[已知问题和保留项](android-private-1.00-known-issues.md)，详细环境见[设备矩阵](../milestones/android-apk/device-matrix.md)。
