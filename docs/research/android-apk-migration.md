# Android APK迁移评估

调研日期：2026-10-15。用户选择“优先 Android APK，兼顾可安装 APK 的鸿蒙”。本报告依据现行[07](../architecture/07-constitution.md)、[08](../architecture/08-target-architecture.md)、[09](../architecture/09-contracts.md)、[10–12](../architecture/10-runtime.md)、[13 V-07](../quality/13-risks-and-acceptance.md)和[15](../workflow.md)，以及本工作树源码、锁定插件的公开实现与下列官方资料。Windows通过不证明Android能力；本轮未创建Android工程、构建APK、安装SDK、接设备、访问真实学校或读取正式业务资料。

## 结论与边界

建议继续同一Flutter/Dart工程，保留业务核心，新增Android平台实现和手机布局。无需把Agent、数据模型和导入逻辑重写为Kotlin，也不建议另建一套手机后端。真正的迁移工作在平台边界：学校WebView、私有目录与凭据、系统提醒、文件交互、语音和进程生命周期。先证明这些能力，再完成全量UI；“能编译一个APK”不能替代自动登录、采集、资料保留和退出提醒的可用性。

本轮只交付调研与建议实施顺序，尚未批准/开始移动实现；不新增跨设备同步、云后端、手机读取Windows资料或原生鸿蒙分支。手机第一版建议保持同一账号、本地优先、北京时间、五条来源与学校只读；账号、Key及学校会话在手机重新提供/建立。Windows继续维护1.00基线。

## 设备路线

| 设备情况 | 路线与验收边界 |
|---|---|
| 普通Android手机 | 标准Flutter Android APK；先选择一台arm64实机作为开发验收目标，再按已验证矩阵扩展 |
| 能直接运行Android APK的鸿蒙设备 | 先用同一个APK，不增加HMS/GMS依赖；仍需单独测WebView、Keystore、通知权限、省电与文件交互，不能以安装成功代替业务通过 |
| 通过兼容服务运行APK的鸿蒙设备 | 作为单独兼容环境。华为当前说明HarmonyOS 5及以上可通过卓易通/出境易等获取部分应用，分享APK是否可安装取决于实际支持；不再笼统断言所有5及以上都不能安装APK，也不承诺本应用在兼容环境内具备完整后台和隔离能力。来源：[华为安装说明](https://consumer.huawei.com/cn/support/content/zh-cn16061787/) |
| 需要真正原生鸿蒙包 | 是独立HAP/APP路线，不是改APK后缀。涉及鸿蒙Flutter适配发行版或ArkTS及原生能力评估，不纳入这次Android实施建议。来源：[华为应用包术语](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/application-package-glossary) |

本机固定Flutter为3.44.5；本地SDK模板的默认`minSdk=24`、`compileSdk/targetSdk=36`、`NDK=28.2.13676358`已只读核对，锁定`record_android 2.2.0`的Gradle声明也是`minSdk=24/compileSdk=36`，但项目尚无`app/android`，这些不是已经配置好的应用参数。建议先以Android 7/API24为候选构建下限，实际最低可用版本还受插件与WebView能力约束，不能据此承诺所有Android7手机都可同步。当前[Flutter平台表](https://docs.flutter.dev/reference/supported-platforms)已针对更新的3.47，不能无说明地当作本工程锁定版本的验证结果；迁移初期不顺带升级Windows SDK和依赖。

## 哪些代码可以保留

| 现有部分 | 复用程度与具体处理 |
|---|---|
| `core/`模型和规则 | 日程/任务/时间块、来源有效性、冲突、北京时间、提醒两槽、权限和工具契约保留；补充平台能力投影即可，不重新定义业务状态 |
| `data/`事务和迁移 | Drift/SQLite表、schema18增量、导入去重、完整范围内停用/恢复、个人覆盖、审计与回执、受控撤销、知识检索、会话/权限和晨报存储保留。替换数据库打开目录和占用守卫，恢复/故障测试在Android重跑 |
| `agent/` | 固定工具、循环、模型HTTP协议、上下文compact/clear、证据、规划、许可和执行回执可复用。抽离写死的Windows设备文案，注入平台能力；模型可用性/看图/工具续答需手机网络实际验证 |
| `source/` | 身份/分页/日期/稳定键契约、公开HTML解析、只读数据规范化与匿名HTTP可复用。学校响应如何在WebView内取得需新的原生适配；手机网络/TLS/代理另测，不搬桌面7897地址 |
| `jobs/` | 单来源通道、共享租约、停止/排空、采集/导入、晨报、每日二课调度规则和维护协调可保留；进程被杀后的恢复不能依赖Windows退出回调 |
| `app/`与知识资源 | Flutter组件、主题、Markdown、表单与控制器、大部分设置可保留；7份长期材料已由`rootBundle`载入，可随APK提供。日历和输入交互需手机适配 |

核心依据是现有端口分层，尚未给出“复用百分比”：文件可编译不代表行为成立，按行数估算容易掩盖原生能力工作。入口目前在[demo_runtime.dart](../../app/lib/app/demo_runtime.dart)直接装配Windows实现，必须先改为平台工厂/注入；同一业务服务共享，Windows工厂保持原行为。Flutter的[平台通道](https://docs.flutter.dev/platform-integration/platform-channels)支持Dart调用Android原生代码，适合沿用现有固定端口。

## 必须新增或改造的平台部分

### 1. 私有目录、数据库和凭据

[DemoDirectory](../../app/lib/platform/demo_directory.dart)、[数据库打开器](../../app/lib/platform/native_database.dart)使用Windows路径、kernel32句柄和本地DLL；[hook](../../app/hook/build.dart)也只构建Windows目录库。Android使用应用内部持久目录承载SQLite、诊断及受控状态，缓存只存可丢弃资产；按来源划分的浏览器资料由原生WebView管理。替换`p.windows`和USERPROFILE拼接，保留规范化路径、排他/串行写、关闭拒旧结果和未完成维护恢复。即使通常只有一个Activity，也要防重入/独立通知接收器与应用同时写；不为通知随意再启动一个无协调的Dart数据库进程。

[学校](../../app/lib/platform/windows_jw_credential_protector.dart)和[模型](../../app/lib/platform/windows_model_credential_protector.dart)保护器必须替换。建议Android Keystore持有AES-GCM密钥，学校密码与模型Key继续区分用途/关联信息；普通自动同步不额外要求每次生物认证。密钥失效返回需重新提供凭据，不能清空日程；不能解密Windows DPAPI密文。Android硬件支持程度需查询，不能把所有密钥称为硬件保护。[官方Keystore](https://developer.android.com/privacy-and-security/keystore)支持不可导出的密钥及用途限制。

Android默认备份可能包含应用文件，因此首个可安装包前就配置`noBackupFilesDir`/备份排除规则，至少排除凭据、浏览器会话和内部执行状态；是否迁移其他私人资料另行决定，不让默认云备份隐式扩大出站。[Auto Backup说明](https://developer.android.com/identity/data/autobackup)区分云备份和设备迁移，不能只在Dart里控制。

### 2. 学校WebView：最高优先级原型

[观察端口](../../app/lib/platform/native_observation_browser.dart)及[Windows桥](../../app/windows/runner/observation_bridge.cpp)覆盖远多于打开网页：来源分区、重定向/弹窗、固定认证、文档世代、业务身份、受限JS/响应投影、采集分页、取消排空、持久认领与清理。Android需要Kotlin侧等价桥和学校页面宿主；Dart端的C1/C2契约与采集事务保持。可以移植经过审查的固定脚本/投影规则，不能直接编译WebView2/COM代码，也不能给Agent任意JS/URL/点击权限。

首选验证AndroidX WebKit多Profile：运行时检查`WebViewFeature.MULTI_PROFILE`，在页面加载前通过`WebViewCompat.setProfile`给JW、Young及各次受控分区绑定独立Profile。该能力依赖WebView提供方，Android版本足够高也不保证具备。普通`webview_flutter`的全局Cookie清理不能直接满足本项目的一来源一通道与独立删除。[WebViewCompat官方契约](https://developer.android.com/reference/androidx/webkit/WebViewCompat)提供具体功能门禁。

清理是首个原型的硬问题：[ProfileStore.deleteProfile](https://developer.android.com/reference/androidx/webkit/ProfileStore)不允许活WebView关联，且返回成功时部分数据仍可能异步删除。必须证明销毁/排空、许可撤销、不可再复用和清理恢复的可观察语义；不能直接把返回true报作磁盘已清空。如果目标设备缺少多Profile，先评估独立进程/数据目录方案与复杂度，或者明确只禁用学校同步而保留本地功能，不静默共享会话。现行普通WebView边界保留，不借迁移恢复已放弃的全协议封闭门槛。

应用/手机不能自行读取浏览器手填秘密。用户主动保存的凭据仍走固定认证契约；学校真实登录、验证码和额外授权由用户完成。自动原型只用loopback和临时账号；真实站点验证另安排。

### 3. 系统提醒与后台行为

保留C3同事务保存的期望提醒、两槽、默认/覆盖、来源失效过滤、取消和点击后重新定位。替换[WindowsNotifications](../../app/lib/platform/windows_notifications.dart)及Toast/协议激活为Android通知渠道、AlarmManager、BroadcastReceiver和PendingIntent。可先评估成熟的[flutter_local_notifications](https://github.com/MaikuB/flutter_local_notifications/tree/master/flutter_local_notifications)作为端口内调度器，版本在实施时按锁定SDK选择；若无法满足能力/回执/取消契约，再补很薄的Kotlin实现，不把所有业务搬进原生层。

- Android13+需通知运行时许可；首次说明后由用户授权，拒绝仍可用日程。[通知权限](https://developer.android.com/develop/ui/compose/notifications/notification-permission)
- 精确提醒需检查实际精确闹钟能力。候选先采用用户授予的`SCHEDULE_EXACT_ALARM`，不以`USE_EXACT_ALARM`绕过范围/发布要求；未授权显示能力不足，不能把近似投递称为准确提前30分钟。[Android14变化](https://developer.android.com/about/versions/14/changes/schedule-exact-alarms)
- 普通进程退出后的提醒由系统计划执行，不能依赖Dart Timer。重启/更新后从持久期望重建、权限撤销后对账；系统强制停止和厂商省电列为独立验证，不承诺万能保活。插件保存的待提醒记录也不能冒充系统队列的独立核验。[AlarmManager说明](https://developer.android.com/develop/background-work/services/alarms)
- 晨报仍为06:00后第一次打开应用异步生成；每日二课先保留前台可见空闲触发。首个APK不增加定时后台打开学校WebView、常驻服务或推送服务器；WorkManager不是准点提醒的替代。通知后台触发与后台学校同步是两项能力，分开验收。

### 4. 语音、图片、文件和诊断

`record`与`sherpa_onnx`锁定依赖有Android实现，但[模型目录](../../app/lib/platform/speech_model_bundle.dart)和[推理装载](../../app/lib/platform/sense_voice_recognizer.dart)当前依赖EXE旁模型及Windows DLL，必须换成Android `.so`及受控资产路径；默认录音设备Windows通道不适用，Android改为运行时麦克风权限与普通输入。录音状态/30秒限额/光标回填/不自动发送可复用。SenseVoice公开权重约239MB，先实测目标设备内存、时延、发热和安装包体积；不以插件支持证明手机识别质量，不顺带改变为云上传。首个文字链路可先将语音标为未具备，之后再作单独切片；正式移动范围取舍需确认。[上游Flutter示例](https://github.com/k2-fsa/sherpa-onnx/blob/master/flutter-examples/README.md)

锁定`file_selector_android 0.5.2+11`只实现打开/目录选择，`getSaveLocation`未实现，现有安全日志导出需改用SAF创建文档/受控分享。该版本选图原生实现会按返回大小先读入并复制至应用缓存，发生在Dart的10MiB检查之前；移动图片入口应以有界流读取和受控缓存替代，正常/失败/取消均清临时副本。保留PNG/JPEG/WebP、像素/数量/字节限制与去元数据规则，不扩大为任意文件访问。相关代码见[图片入口](../../app/lib/platform/agent_image_picker.dart)、[诊断面板](../../app/lib/app/diagnostics_panel.dart)，插件版本以[lock](../../app/pubspec.lock)为准。

SQLite、Flutter引擎、sherpa和ONNX都有原生库，需逐个确认ABI及16KB页兼容；NDK28的默认对齐不证明已下载的预编译库符合要求。首次产包后检查ZIP/ELF对齐并在16KB环境实际启动。[Android官方16KB指南](https://developer.android.com/guide/practices/page-sizes)

## 手机界面与运行恢复

当前[应用壳](../../app/lib/app/product_app.dart)在760以下已有抽屉布局，[任务页](../../app/lib/app/task_workspace_page.dart)在820以下已有单列，可继续复用。最明显短板是[周日历](../../app/lib/app/calendar_week_view.dart)的62px轴与每列至少124px：建议手机默认日视图、周视图保留横向浏览，日期切换与任务截止栏尽量不用精细拖拽。Agent附件/麦克风/发送行、日期时间选择器、来源登录、审批详情、晨报、设置与错误提示都需320/360dp、软键盘、大字体和安全区验证；维持Agent/日程两个主入口，任务仍在日程内，不增加独立公开资料检索页。

Activity后台、旋转、系统回收、返回手势和冷启动需要单独处理：录音退后台停止、Agent中断事实可恢复、学校旧结果不能越世代提交、维护半程在下次启动恢复。系统可能不调用完整退出清理，重启恢复是必要路径；不能把`dispose()`能执行当作保障。通知点击优先恢复根，再按当前ID/有效性定位，不自动执行旧工具或旧批准。

## 建议实施顺序与完成门槛

以下是研究建议，尚不是已启动的新里程碑。

| 切片 | 先交付什么 | 通过才进入下一步 |
|---|---|---|
| A · 可行性与平台底座 | 选定Android实机及一个APK鸿蒙目标；隔离生成Android宿主；平台工厂、app-private SQLite/日志、Keystore、无真实资料的基本日程/任务 | 签名测试APK冷启动、重启保留、进程回收恢复；能力不可用时应用仍可启动；Windows全套回归不变 |
| B · 学校原生桥原型 | 多Profile准入、JW/Young各独立页面、固定导航、生命周期/清理及loopback采集闭环 | 证明隔离、停止拒旧结果、销毁/清理/恢复；两来源合成契约和完整范围导入。之后由用户完成真实登录/验证码与来源对应验收，不能只展示网页 |
| C · 日常主链路 | 接入真实自动认证/目录/采集和Agent模型/固定工具；手机日历、任务、设置、图片与日志导出 | 教务与Young各完整同步、重复导入不重、历史范围保留；Agent查询/本地修改/停止/权限/回执闭环，未发送多余私人资料 |
| D · 系统提醒与晨报 | 两槽提醒、通知权限/渠道、精确能力、冷启动点击、取消/重建；前台晨报与每日二课 | 普通退出/锁屏/重启/更新、拒绝/撤销权限、来源停用/改期、任务完成/移动和撤销联动；Android与鸿蒙分别记录结果 |
| E · 语音与私有APK交付 | 目标机本地中文短音频、模型加载/体积策略及许可；文件/缓存清理、ABI/16KB、签名升级 | 真人语音/延迟实测、签名安装升级和资料保留、无开发loopback/秘密资产；保留已知问题后再决定移动版本验收 |

建议先产arm64-v8a测试APK；需要模拟器再加x86_64，不默认把多ABI和大语音资产塞入一个包。Flutter可[按ABI构建APK](https://docs.flutter.dev/deployment/android)，后续私有可分发Release需稳定的应用ID、签名密钥和递增版本号；密钥创建/保管按实施阶段处理，不能把Debug签名包当正式升级身份。

最先需要真实证据的是学校WebView隔离/清理、系统退出提醒和目标机的语音开销。没有具体手机型号/Android或鸿蒙完整版本及WebView提供方，本报告不承诺某型号兼容，不给复用百分比或工期。Windows/手机的数据共享也没有因为共用SQLite而自动成立，应另行设计与批准。
