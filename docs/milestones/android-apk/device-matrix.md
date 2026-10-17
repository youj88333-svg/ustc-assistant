# Android设备能力矩阵

本表区分可重复的合成/模拟器结果与真人、实机结果；阶段任务见[计划](plan.md)，操作说明见[人工测试说明](manual-validation.md)，最新预检/诊断回归见[记录11](records/11-mumu-source-and-diagnostics.md)。没有记录的能力保持待验，不能用安装成功推定学校登录或后台通知可靠。

| 环境 | 当前证据与能力边界 | 未验证项 |
|---|---|---|
| 官方API34，Android14，x86_64，4KB页 | A7原生67通过/9提供方跳过；本地底座/升级保留、Agent/公开能力、手机界面/文件合成、提醒/通知到日程任务详情及本地ASR通过。WebView113.0.5672.136缺多Profile/独立删除/私有世界；学校获取与恢复清理正确拒绝，完整采集不可用，见[A7记录](records/10-a7-emulator-validation.md) | 真实手机/学校/模型、麦克风、厂商省电与触摸体验 |
| 官方API36，x86_64 | A1–A6底座、事务/密钥、Agent、日历任务、文件、提醒及本地ASR合成证据分别见各记录；旧提供方缺私有脚本世界，学校采集不可用 | 不补记本轮重复执行；同上实机项 |
| 官方Android17/API37，镜像37.2 google_apis_ps16k，x86_64，16KB页 | 当前提供方WebView149.0.7827.5；原生76通过/0跳过，多Profile/独立删除/私有世界成立，合成学校6组通过/1旧提供方分支跳过；包内本地ASR及普通入口冷启动通过。模拟10%电量/省电、深度休眠和强停重开通过，见[A7记录](records/10-a7-emulator-validation.md) | 开发兼容样本，不是arm64实机、稳定版目标手机或正式Release/16KB交付结论 |
| 本机MuMu宿主5.30.1.3586，Android12/API32 | 用户已安装启动，反馈学校入口无反应并进入恢复态；只读实际提供方为`com.android.webview` 110.0.5481.154.1，ABI含x86_64。固定诊断确认先`unsupportedPlatform`后`staleResult`，学校桥当前不可用，见[首轮修复](records/11-mumu-source-and-diagnostics.md)。DocumentsUI可解析日志保存动作，但未代用户保存 | 新版覆盖、实际导出与受支持提供方上的恢复/真实学校；模型、麦克风、通知和其余真人体验未验收 |
| arm64 Android目标手机 | 尚无设备；优先正式目标 | 全部目标机条件及A8正式ABI/签名/升级 |
| 可安装APK的鸿蒙或兼容服务 | 无目标设备；实际型号/系统/兼容层需单独登记 | 不因Android模拟器通过记为鸿蒙通过 |

Android14及以后新安装应用通常需用户单独允许精确提醒；拒绝时使用可延迟的系统调度，并保留本地功能。[Android官方说明](https://developer.android.com/about/versions/14/changes/schedule-exact-alarms) 系统“强行停止”与普通离开应用不同，测试结果按系统版本记录；重新打开时恢复仍有效的未来提醒，已过期的提醒不补发。不能承诺强停期间收到提醒，也不能承诺应用运行在已关闭的模拟器里仍投递。

MuMu本身可[安装本地APK](https://www.mumuplayer.com/help/win/developers-essentials-manual.html)。本轮只读系统和已审计固定诊断标签，不自动安装/升级其应用或Android/WebView、不更改代理或ADB设置、不替换现有实例。更新应用不会让旧提供方获得缺失能力；未核验MuMu专用WebView升级途径，不建议安装来源不明组件。
