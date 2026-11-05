# iOS 通知与前台运行验证

本目录针对私用 iOS 主应用的系统提醒与前台运行。通知使用 `UNUserNotificationCenter`，复用 C3 两槽期望及事务后对账。60 条待发请求是本应用的保守策略，全部本地期望仍保留；展示最晚已登记时刻、未登记数量和期望范围，避免混淆系统登记与未来覆盖。

`IOSNotificationPolicy.swift` 的独立 Swift 检查验证字段、类型、容量策略、当前发布权与 UTC 日期组件。`ios_i3_notifications_test.dart` 在全新、专用 iOS Simulator 中使用真实系统授权查询和 pending 队列，配合合成本地日程检查登记/改期/取消/容量补位与维护清理。测试先申请仅该 Simulator 的 provisional 授权；拒权与点击另用 Debug 固定注入，不冒称真实通知按钮点击、系统撤权或投递成功。

`ios_i3_workspace_test.dart` 保留同一合成安装，验证三页导航、真实队列回读、窄屏/大字体与前后台复用运行所有权；不发起学校或模型 HTTP。它导出的界面图片只含该 job 自建的合成日程，不能使用正常安装或物理设备替代。晨报的跨 06:00、同日复用和取消，以及每日二课的手动登录退化由共享行为测试验证；iOS 不执行无人值守账密投递。

## 执行

在 macOS 的受控一次性工作区，运行 `bash tools/ios-i3/build.sh`。入口锁定既定 Flutter/Xcode，并运行当前修订的完整 I1/I2 前置检查、原生策略、共享作业、I3 Simulator 和单 Runner 设备 Release/AOT；不接物理设备、Apple 账号、学校或真实模型。Codemagic 的 `ios-i3-notifications` 采用手动、有界免费工作流。

Windows 的包审计优先用 Conda basic310：

```powershell
& 'E:\conda\envs\basic310\python.exe' tools/ios-i3/test_verify_package.py
& 'E:\conda\envs\basic310\python.exe' tools/ios-i3/verify_package.py --ipa '<候选IPA>' --expected-revision '<完整源码SHA>' --report '<新报告路径>'
```

审计检查实际 arm64 Mach-O/AOT、三项修订、固定采集脚本、通知原生接线字符串和无测试入口/传输例外/后台模式/远程通知 entitlement；还保留单目标、无共享组/语音模型/私钥等既有条件。接线字符串只证明产物包含代码，运行以原生/Simulator 记录为准，Apple 签名有效性仍为 `not-verified`。

## 目标手机

同一 Sideloadly 账号及 Bundle ID 覆盖安装，不卸载。用户在应用明确点击后授权通知，核对日程和任务的提醒、前台/后台/正常退出后的实际显示及点击定位。Focus、通知摘要、强退、重启和签名续期分别登记；未打开应用时不会补登记未来容量外的项目，06:00 也不在后台唤醒学校或模型。

系统行为依据：[Apple 本地通知](https://developer.apple.com/documentation/UserNotifications/scheduling-a-notification-locally-from-your-app)、[启动与通知处理](https://developer.apple.com/library/archive/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/SchedulingandHandlingLocalNotifications.html)、[后台运行策略](https://developer.apple.com/documentation/BackgroundTasks/choosing-background-strategies-for-your-app)。工程、实际包和目标手机结果分别记录，不能互相替代。
