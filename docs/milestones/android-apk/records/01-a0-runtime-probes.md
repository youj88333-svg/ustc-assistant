# A0 重启后的原生运行验证

日期：2026-10-16。前次构建及软件模拟失败保留在[记录00](00-a0-platform-probes.md)，本记录承接用户“已重启”，依据[已批准计划](../plan.md)的A0、07/09/12、13和15执行；没有访问真实学校、模型、业务库或认证资产。

## 结果与放行范围

WHPX现已报告`installed and usable`，两个独立AVD实际启动。根完成如下原生运行核验；A0的模拟器准入通过，允许推进A1及合成桥接。实机、鸿蒙、学校登录及完整手机版仍未验收。

| 环境 | 实际提供方 | 浏览器 | 密钥与退出通知 |
|---|---|---|---|
| API35、Google APIs x86_64、镜像修订9 | WebView `124.0.6367.219` | `MULTI_PROFILE=true`、`DELETE_BROWSING_DATA=false`；按能力门禁拒绝，未放宽清理要求 | 4项instrumentation、Keystore、进程退出后OS提醒与取消通过 |
| API36、Google APIs x86_64、镜像修订7 | WebView `133.0.6943.137` | 两Profile的Cookie/localStorage隔离、清理回调、另一Profile保留、冷进程删除及跨进程资料恢复全部通过 | 同4项instrumentation、Keystore、进程退出后OS提醒与取消通过 |

Keystore验证包含往返、不同用途拒绝、nonce不重复、删除密钥后拒绝；两个模拟器均报告`hardwareBacked=false`，没有将软件保护记为硬件保护。通知使用本QA包的真实AlarmManager、非导出Receiver及系统活动通知；先确认进程已不在，再等15秒计划触发。取消后等待同样窗口，Receiver计数为0且系统无活动通知。这里没有用系统“强制停止”测试退出提醒，也没有证明目标手机的锁屏、省电、重启或厂商行为。

浏览器仅加载保留域的内联合成页面，不发HTTP。已加载Profile先按Profile清理并等待回调；其名称的物理删除留在冷进程完成。没有将Android版本号、API存在或单次回调等同于清理/持久化证明。

## 本轮失败及修正

1. Windows PowerShell把转发函数中的adb `-w/-W/-e`解析为公共参数。改为基本函数逐项转发，随后实际instrumentation成功。
2. API35旧提供方缺少按Profile清理API。这是正确拒绝结果；根采用Google官方API36镜像补充可行环境，未用镜像站WebView APK、绕过签名或削弱TLS。[AndroidX能力查询](https://developer.android.com/develop/ui/views/layout/webapps/jetpack-webkit-overview)与[清理接口](https://developer.android.com/reference/androidx/webkit/WebStorageCompat)仍以实际feature probe为准。
3. 首次官方大镜像下载在Java网络读取处长期无进展；根只停止了本轮明确识别的SDK下载进程。公开小段/有界GET复验可用，随后SDK Manager重试成功；临时下载片段已删除。未改全局代理/系统信任。
4. QA Activity在进程死亡后会收到Android恢复的原始任务Intent，导致旧Keystore命令重放、通知报告错型/超时。`singleTop/onNewIntent`不足以解决旧任务恢复；修正为持久递增指令序号、唯一操作ID与结果关联，旧序号不执行。该登记仅属于Debug合成宿主，不是生产业务账本。
5. API36异步WebView启动较慢，报告文件尚未出现时，PowerShell将原生命令stderr提升为终止异常。轮询对“文件尚未写好”保留有界等待，只在匹配当前操作ID及固定kind的成功报告后通过；并保存退出投递/取消两份独立报告。没有用吞掉最终失败的方式放行。

## 根执行与产物

根实际运行`tools/android-a0.ps1 -Action Build`，完成Debug x86_64分包、AndroidTest、Release Manifest合并与lint；本轮没有修改共享Dart/Windows源，未重复或冒记上轮1435项Dart及Windows结果。两份脚本语法与diff检查通过。

在严格核对AVD名、emulator标记、独立5038端口及`.qa`包后安装两份APK，仅为QA授予通知/精确提醒测试许可。实际命令：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/android-a0.ps1 -Action Test -ApiLevel 35 -TestScope Notifications
powershell -NoProfile -ExecutionPolicy Bypass -File tools/android-a0.ps1 -Action Test -ApiLevel 36
```

API36总摘要为`android-a0-run-v1/success=true`，Profile隔离/清理/重启、Keystore、退出投递和取消全部true；`realDevice=false`、`schoolVerified=false`。API35单独摘要明确`webviewTested=false`，不能代替浏览器门禁。报告位于`app/build/android-a0/reports/ustc_android_a0_api35`和`ustc_android_a0_api36`，属于本地生成物，不入Git。

| 生成物 | 字节数 | SHA-256 |
|---|---:|---|
| `app/build/app/outputs/flutter-apk/app-x86_64-debug.apk` | 124874753 | `fcb9be1d7a02ffdd393dec25738862bcf0fee747180144e9af920b5d3650a5dd` |
| `app/build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk` | 20174 | `ec861398d1bb50bfd7506b29f6cb2d5db4ee3181da69a51239a79ce630ed87ff` |

工程检查点`da4a046`，仅本地提交、未推送。SDK、系统镜像、AVD、缓存和临时资料仍在E盘，原C盘资料没有迁移或删除；WHPX系统组件由Windows管理。Windows1.00源/私有包、正式数据及通知身份未变。

## 后续

A1按计划建立平台工厂、同一私有根所有权下的独立子目录、SQLite/诊断、Keystore封套和无来源配置的本地日程/任务启动。A0的模拟器结论不关闭实机能力门禁，也不启用目标手机上的真实学校作业。
