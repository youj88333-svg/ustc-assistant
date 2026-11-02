# iOS I2 教务与二课桥

学校桥遵循[来源与分区契约](../../docs/architecture/09-contracts.md)，此目录提供
独立的教务/二课入口及合成集成检查。当前学校桥需要 iOS27+；它采用手动登录与固定
只读采集，不向网页投递应用保存的密码。

设备包审计将两份固定 reader 与源码的 Git LF 字节比较，同时核对 manifest 中的实际
资源哈希；Windows 工作副本的 CRLF 只在源码比较端规范化，安装包资源不做改写或宽松匹配。

## 验收入口

`app/lib/ios_i2_entry.dart` 通过 `RuntimeBootstrap.open` 和
`IOSRuntimePlatformFactory` 打开现行运行时，显示“教务”和“二课”两个标签，复用
`JwSyncPanel`、`YoungSyncPanel` 的产品模式。出现学校登录、验证码或额外授权时，用户在
学校窗口手动完成，返回应用后继续当前同步。密码字段可留空；流程不要求模型 Key，
不读取学校窗口中手填的秘密。

入口未增加提醒、每日自动同步、Agent、图片或语音功能。iOS 语音和 Widget 按已批准
决定取消；此入口不改变其他平台的实现。

## 登录失败与诊断

普通网页加载失败先撤销旧文档资格，手动登录窗口保留，并显示“页面未能加载，请重试”。
原生“重试”只 GET 固定来源入口，不重放登录 POST；失败后返回应用再继续，可重新打开
同一受控窗口。后台和 WebContent 终止仍撤销工作；有业务读取在途时文档失效仍由 C1 收口。

右上角“复制诊断”只在点击时调用无参数 `platform_v1/i2BrowserDiagnostics`。
`ios-i2-browser-diagnostics-v2` 保留原 11 项：kind、source、state、lastEvent、failureStage、
errorDomain、errorCode、cleanupStage、cleanupFailure、cleanupErrorDomain、cleanupErrorCode。
另有 policyAction、policyTarget 两项闭合分类，总计13键，独立保留最近策略拒绝，不会被
之后的 navigating/ready 覆盖。它们只表达跳转/弹窗/权限等类型与 registered/campus/
external/localFixture/otherScheme 范围，不含实际主机或URL。Dart仍严格兼容11键v1。
阶段/来源/错误域为闭合词表，数字码限 ±100000 或 null，不包含 URL、查询参数、账号、
密码、Cookie、网页内容或 NSError.userInfo/描述。Dart 检查全部键和类型并重建后才复制。
首个加载失败与清理失败分开保留；app 类码 1–10 对应 invalidSnapshot、unsafeDirectory、
storageFailed、cleanupPending、staleResult、busy、closed、sourceFailed、unsupportedPlatform、ownershipLost。

学校 suite 还使用两个 loopback origin，实际经过手动 CAS 表单 POST、认证 callback 屏障、
返回应用及 coordinator 继续后导入；故障注入覆盖取消、旧 WKNavigation、当前加载失败、
窗口重显和固定 GET 重试。注入测试不能证明目标手机原故障的 NSError 或具体成因。

重复同步检查不假定会话 Cookie 在全部 WK 视图关闭后仍然有效。它先要求复用同一已认领
profile；如再次要求手动登录，还必须观察合成服务器因缺少认证 marker 的固定重定向，
再经过真实合成表单和 callback，返回应用由 coordinator 完成重复导入。两条路径都检查
原行 ID、数量和无保存密码，并记录实际是否再次登录；不延长 Cookie 时效或放宽事务断言。

## 手动网页兼容与权限分离

主页面允许无userinfo、默认443的规范校内HTTPS主机；子frame保留普通HTTPS和
about:blank/srcdoc浏览。固定 `allows`/业务origin、reader、身份/schema及C3事务没有扩展。
导航only认证页可显示但ready=false、inspect/event不回传其未登记origin，加载完后
advance=manualRequired，不能据此读业务。JW不改其他认证origin的History原型。

主frame明确GET链接的`_blank`可转入同一view；POST、脚本新窗和通用opener不支持。
网页alert/confirm用带来源域名的系统提示交给用户；返回/重试/关闭取消当前提示，消息
不进入诊断。文本prompt和设备/文件权限仍拒绝，TLS与页面已有策略保留。

`ios_i2_auth_compatibility_test.dart`在新鲜Simulator中使用三个loopback来源，验证
导航only无读出权限、拒绝后诊断保留、重试可再登录且提交后的POST计数不增加、GET新窗
和POST新窗的不同结果、实际WK alert/confirm显示及完成核心、返回取消与排空。原生浅/深色
弹层有截图；合成调用共用完成函数不等于真人触屏点击验收。Debug仅可显式增加受控loopback
导航origin，Release拒绝该参数；自动过程不访问学校或真实认证资料。

## 集成检查范围

`app/integration_test/ios_i2_school_test.dart` 仅在 iOS Debug Simulator 运行。测试先打开并
关闭真实 iOS `RuntimeBootstrap`，再用固定 loopback 目标创建 iOS 目录、Drift 数据库、JW /
Young 注册表和原生 `NativeObservationBrowser`。教务与二课业务分别使用现有合成 fixture，
学号固定为 `TEST0001`，测试不访问学校、模型服务或实际认证资料。Dart `HttpClient` 只允许
直接访问 `127.0.0.1`；其他目标被导向本机未开放端口，WKWebView 的 fixture 目标也必须是
固定 loopback origin。

自动检查覆盖：

- 教务课程目录、课程/考试采集、重复导入与用户隐藏覆盖保留；暂停中的 loopback 读取被
  取消后不提交新结果。
- 二课活动只读查询、固定日期区间日历事务导入、重复导入与用户隐藏覆盖保留；身份不匹配
  不替换已有日历数据。
- 同一 loopback origin 下两个 JW UUID store 的标记隔离、正常关闭/重开保留，以及通过
  注册表删除临时候选 B 后已认领 A 仍保留标记；再由正式 coordinator 清除该来源登录资料。
- JW 同文档 history、真实下一文档拒旧，Young 同 URL push/replace 保留固定业务准备能力；用户关闭排空；临时
  observation 正常关闭删除 WebKit store，正式 profile 普通关闭保留。

原生 `i2Fixture` 只接受 `writeSyntheticMarker`、`checkSyntheticMarker`、
`checkNoSyntheticMarker` 三个固定操作；标记固定且仅用于检测当前 WK store 中的 cookies、
localStorage、IndexedDB 与 CacheStorage。`i2StoreExists` 只接受固定 profile 结构和来源，
仅返回 store 是否存在，不读取 WebKit 私有文件。调试宿主暂存已经核验的 UUID 关联，
使 Dart 移除 profile 元数据后仍能通过官方枚举核对实际删除；这不授予打开/认领权限。
生产构建不提供这些调试方法。

集成检查重建 RuntimeBootstrap、注册表和浏览器对象，但没有杀进程或重新启动应用；结果不
代表真正的跨进程恢复，也不代表目标 iPhone、学校认证或真实业务验收。请在全新、仅用于
测试的 Simulator 上运行，因为检查会向应用的本地数据库写入合成 `TEST0001` 记录。

`app/integration_test/ios_i2_persistence_test.dart` 提供真正分成两个 Flutter 测试进程的
合成持久性检查。`write` 阶段在本地数据库无账号绑定、无已提交许可的全新 Simulator 上，
由注册表创建 JW UUID profile，启动只绑定 `127.0.0.1` 的固定 JW fixture，在 WK store 写入
固定标记，并在应用 demo owner 下保存严格校验的合成 handoff（profile 名称、loopback
端口，路径从当前系统容器重新构造）。应用进程结束后，不卸载应用；在同一个 Simulator 上用独立 Flutter 测试进程运行
`read` 阶段，重建注册表和原生浏览器，重新绑定原端口并打开同一 profile，验证 cookies、
localStorage、IndexedDB、CacheStorage 标记仍在，再由注册表 recovery-only 清理 profile 和
handoff。它不访问学校、模型服务、真实账号记录或秘密；失败不会跳过。该检查只允许 Debug
iOS Simulator，不能用真机、已绑定账号的安装或包含其他 JW profile 的 Simulator。

跨进程检查命令必须在同一台全新 Simulator 上按顺序分两次执行，并在两次之间仅终止应用
进程、保留安装和应用数据：

```bash
cd app
flutter test --no-uninstall integration_test/ios_i2_persistence_test.dart -d <simulator-id> --dart-define=USTC_I2_PERSISTENCE_PHASE=write
# 终止应用进程；不要卸载应用或清除 Simulator 数据
flutter test --no-uninstall integration_test/ios_i2_persistence_test.dart -d <simulator-id> --dart-define=USTC_I2_PERSISTENCE_PHASE=read
```

`--no-uninstall` 是必需参数：Flutter 测试默认在结束时卸载应用，单纯不手动卸载并不能保留数据。
这组检查与单进程学校业务 suite 分开；必须在同一安装上完成 write/read 两阶段，
单独运行其中一阶段不能证明跨进程保留。专用构建流程将两阶段都作为设备包生成门槛。

## 原生导航与失败恢复

`app/integration_test/ios_i2_boundaries_test.dart` 只在 Debug iOS Simulator 上运行。
它使用独立 loopback 页面和临时 demo profile，实际触发主页面、子 frame、弹窗、
外部协议与附件下载的原生决策，同时核对同源重定向、缺失目录失败后的幂等排空和重新打开、
JW 会话拒绝 Young 固定操作。清理失败会使检查失败，不访问真实学校或认证资料。
发生多重错误时保留首个操作失败，仍尝试各层清理，并输出不含页面内容的固定阶段标签。

```bash
cd app
flutter test integration_test/ios_i2_boundaries_test.dart -d <simulator-id>
```

## 运行

在 Windows 工作区可运行 Dart 格式与静态分析：

```powershell
cd app
dart format --output=none --set-exit-if-changed lib/ios_i2_entry.dart integration_test/ios_i2_school_test.dart integration_test/ios_i2_persistence_test.dart test/platform/ios_i2_screen_test.dart
flutter analyze --no-pub
```

Widget 检查可在工程支持的 Flutter 环境运行：

```powershell
cd app
flutter test test/platform/ios_i2_screen_test.dart --no-pub
```

iOS 集成检查需要 macOS、Xcode 和已启动的 iOS Simulator：

```bash
cd app
flutter run --target=lib/ios_i2_entry.dart -d <simulator-id>
flutter test integration_test/ios_i2_school_test.dart -d <simulator-id>
```

Windows 静态检查不等同于 macOS/Xcode 编译或 iOS Simulator 执行；没有实际运行的命令不得
登记为通过。
