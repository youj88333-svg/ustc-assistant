# A2 学校原生桥与合成链路

日期：2026-10-16。依据[迁移计划 A2](../plan.md#a2原生桥与合成验收契约)、07/09 K-01–K-06、10–13、15及当前 JW/Young 来源契约。只使用独立 QA、合成身份、loopback 页面和临时私有目录，不访问真实学校、模型、正式业务记录或浏览器认证资产。实机及真实来源验收仍待设备与用户授权。

## 实现与边界

Sol 实现并集成原生宿主、文档世代、秘密投递与关闭排空；Luna/max 分别承担固定 URI 策略、Profile 账本、独立集成及传输测试。Young 传输的关键实现由独立 Sol/max 承接，Astra 对隔离目标、真实响应及清理时序按具体问题只读复核。根执行工具链与模拟器检查，代理的静态判断不作为通过证据。

- Android 接入既有 `ustc_assistant/observation_v1`，只接受固定方法与字段，注册在普通 Flutter 宿主。复用现有 C1 校验、C2 租约/封存及 C3 事务，schema18不变；没有添加第二份学校 HTTP 客户端或业务数据库。
- C3 登记路径映射 AndroidX 独立 Profile；辅助账本只保存来源、不含账号的登记相对路径、派生Profile名、generation及清理状态。普通正式分区保留，观察资料或恢复清理先持久撤销，销毁所有主/子 WebView，再调用 SDK 清除，回调成功才记已清。已加载 Profile 的物理容器删除受 SDK 限制，在后续冷进程首次使用桥时处理；逻辑撤销与 SDK 已清不冒充容器物理删除。未知资料不擅自清理。进程级宿主和已加载名集合跨Flutter引擎保留，清理回调未完成前不允许新引擎复用。
- AndroidX WebKit 固定为 `1.17.1`。正常来源使用前要求 Profile、独立清理、DOCUMENT_START 与 `JS_INJECTION_IN_FRAME_AND_WORLD` 的实际提供方支持；缺少时返回不可用，不在 page world 填密码。只做分区恢复时不要求认证脚本能力，以免提供方降级妨碍本地清理。
- 固定认证脚本运行在私有执行世界，先无秘密准备表单，再通过同一文档的 `JavaScriptReplyProxy` 单次投递。同步历史失效另用私有世界捕获的 Navigation API 与原生 entry 身份检查；同 URL 替换也必须停止后续填密。教务固定投影迁移为 Android 随包资产，保留身份前后核验、学期、完整性、教师/地点与去重；Android 额外传入同步文档有效性守卫，没有改写 Windows 脚本。
- Young 在 DOCUMENT_START 捕获真实 fetch/XHR 原语，只关联固定 helper 调用因果链中的一个实际 GET 实例；Promise 自报值始终忽略。来源 WebView 使用 SDK 的 LOAD_NO_CACHE，固定读取遇 ServiceWorker 控制则拒绝；不把保留分区中的旧 HTTP 缓存当作当前业务身份。先验证原始 JSON 的重复键、大小/深度/节点边界，再提取白名单。背景同 URL 请求、伪 helper、迟到响应不能代入；无法关联的异步方式失败关闭。页面世界的投影通过闭包内捕获的消息出口回原生，reply capability不放到全局参数或返回值中。
- XHR 的原生 API 只暴露最终 `responseURL`，无法证明中间链始终同源或没有重定向；固定初始请求和最终完整 URL、真实响应实例仍须匹配。fetch 另检查 `redirected=false`。这是与 Windows CDP 的明确观测差异，不以 helper 结果代替服务端身份，也不读取认证 header/存储或重放请求。09 的导航逐跳控制及公开 HTTP 重定向规则不被改写为普遍 XHR 零重定向承诺。
- 顶层/框架导航、弹窗、下载、权限、外部协议与 TLS 继续有单独控制。弹窗只作受控地址交接，不成为第二个采集窗口；其 POST 不重放。原生工具栏只显示 origin，允许返回应用和关闭；主文档/历史变化、renderer 退出、取消或宿主离开撤销操作。Debug 仅对 127.0.0.1 放行明文，生产 Manifest 不带这个配置。
- frame控制另用浏览器原生CSP执行：独立无秘密世界在每个文档开始时安装仅`frame-src`精确来源及`object-src 'none'`，不设置default/connect/img/script限制，不全局禁用Worker。临时head只用于同步安装，随后移除自建节点，保留页面正常解析；删meta不撤销已应用策略。SVG/XML不以普通meta插入成功冒充生效，非HTML同步stop并报告不可用。frame策略与认证ready只保存候选proxy，在本代主文档完成后分别重证；主文档、历史和可信恢复事件重新关联，迟到消息不能直接授予能力。
- Young页面可见的消息入口只接受字符串、有界JSON及匹配的reply/call，ArrayBuffer、坏JSON和伪能力均忽略；不读取其字节内容。QA日志只含固定阶段/失败码，无参数、URL、原始响应或秘密；生产不启用该调试标签。

## 实际提供方与准入

| 独立环境 | 已实际观察 | 本轮用途 |
|---|---|---|
| API36，WebView133 | Profile/清理可用，私有执行世界不可用 | 保留A0/A1本地能力证据；不据此启用完整学校认证 |
| API37.0，WebView145 | 私有执行世界仍不可用 | 采集明确拒绝；最终恢复清理与排空反例通过 |
| 官方API37.2/google_apis_ps16k rev6，WebView149.0.7827.5 | 四项运行时门槛均支持，私有世界往返成立 | 完整A2合成桥接和16KB镜像上的运行证据；不是目标手机已兼容的结论 |

依赖固定`androidx.webkit:webkit:1.17.1`，实际能力逐项查询；不按Android版本号或依赖版本推断。官方镜像仅用于补验，不替换或删除旧AVD，不安装第三方提供方APK，不开放调试端口或修改系统信任。

## 已暴露的失败与修复

1. AndroidX `executeJavaScript` 的接收器参数即使为空也必须显式传入，初次 AndroidTest 编译失败后修正，没有用编译通过冒充运行支持。
2. 官方 API36 WebView133及 API37.0 WebView145均报告隔离世界能力为 false。两次均保留原生提供方报告，正常认证继续拒绝；更新 AndroidX 本身不能补出运行时实现。
3. 实际应用 UID 下，Android Context 的 `/data/user/0` 路径带系统别名。Profile 账本初版逐祖先拒绝，4项测试失败；只规范化可信 Context 根后再检查，调用方路径仍严格拒绝别名/链接。修正后来源策略/账本10项通过。
4. 静态复核发现 strict 函数裸调用导致 `this` 丢失；调用改为明确的全局对象成员方式。清数据前必须销毁写入者，包括临时 popup，原先仅 stopLoading 的顺序已修正。
5. 私有认证的 href、document及 history.length 无法独自发现同 URL 的同步 replaceState。增加原生 Navigation 对象/entry 守卫，并加入输入事件改变历史的专门反例；实际提供方验证结果与能力报告分别保存。
6. 旧提供方拒绝读取后的恢复检查，初版测试误用命名参数，之后又未先创建固定父目录；分别保留编译/路径失败。修正测试后，实际 Flutter→原生的不可用拒绝、恢复清理及排空通过，未放宽目录规则。
7. WebView149实际运行时，空的`executeJavaScript`接收器触发提供方崩溃；虽然API允许可空，全部调用仍改为显式非空接收器。原崩溃和修订后的隔离/旧proxy反例分别保留。
8. 初版iframe反例实际到达拒绝地址1次；请求头缺少用于分类的`Sec-Fetch-Dest`，不能把缺头或非主帧等同普通资源。改用上述仅限嵌入文档的原生策略；7组实际反例通过，正常第三方fetch/图片/脚本也通过。历史恢复探针初次在新上下文建立前求值超时，改为等待真实页面完成；实际走reload/back路径，`bfcacheHit=false`，不宣称测到BFCache命中。
9. Young认证namespace根回调被误认为业务页，SPA去票据/安装helper时又触发stale。根回调现等待，只有真正子路由才业务就绪；未发出导航的前置检查遇当前session世代变化返回busy供既有有界重试，已发动作/关闭/换session仍拒绝。另修复快速免CAS时页面尚未就绪就返回businessReady的问题。
10. 新增取消反例暴露的是测试预期：首次取消不会保存尚未提交的账号/密码，重试需重新给候选；C3可能已完成额外清理session，不能再用旧session的单槽排空查询代替作业回执。检查改为租约释放、许可为空、零导入与可重新成功提交；没有改变产品保留规则。
11. 最终旧提供方复验曾在Dart编译阶段主机OOM，尚未执行测试；两台模拟器同时保留造成内存压力。改为每次只运行一台后通过，未修改系统内存/代理设置，失败报告保留。

## 根检查与当前证据

本轮完成原生桥与合成工程验证，可推进独立A3；目标手机和真实学校未验收，A2不作真人关闭。检查只使用QA/临时资料；同一反例重跑不叠加计数。

| 检查 | 已实际观察 |
|---|---|
| Dart | 最终analyze无问题；全套1446通过、1项平台跳过。新Android集成不冒计为普通单测数；后续只改Android桥/资产/集成，未改共享业务 |
| Android原生 | 当前提供方全套35项通过，含来源策略6、账本4、真实Young传输5、私有提供方3、frame策略7及既有基础/Keystore检查。API37.0此前来源策略/账本/传输15项通过，属于相应局部证据 |
| 当前提供方完整集成 | 最终6组通过、gate-only组1项有意跳过：固定导航/下载与ArrayBuffer/坏JSON/伪能力消息、取消及窗口关闭、JW自动认证与教师/地点/非空合成考试/去重/跨学期保留、Young共享凭据与复杂跳转/分页/日历、身份不符与不完整拒绝、旧路由回包拒绝及安全重试；限定QA标签另确认非字符串分支实际到达 |
| 缺能力与恢复 | 最终WebView145 gate-only集成1项通过、其余6项有意跳过；不加载缺少门槛的学校页面，已登记分区仍可只清理并排空 |
| Profile实际运行 | WebView149两个合成Profile隔离、单独清理不影响另一份、SDK清理回调、冷进程删除与重启后合成存储恢复均通过。测试只读自建标记，不读取认证资产 |
| Windows | 独立 Flutter 进程运行教务认证4、二课自动认证3、应用壳1，共8组通过；只用临时/loopback，Debug通知测试身份。没有替换1.00 Release |
| 构建 | 最终普通QA x86_64、AndroidTest、生产Release Manifest及lint通过；检查包名、入口、ABI与备份排除。没有构建/签名生产Release APK，不能据Manifest检查宣布A8已完成 |

报告位于 `app/build/android-a2/reports/`；早期失败保留。官方新镜像经既有7897进程代理下载至E盘；大文件单连接及部分range停滞，改用有界并行分段，只接受官方仓库公布的完整长度和SHA-1匹配后安装。原始SDK/AVD不删除，不改全局代理、TLS或系统信任。下载、缓存、AVD和临时资产均不入Git。

运行入口仍是 `tools/android-a0.ps1`，A2通过 `-IntegrationSuite A2 -ApiLevel 37 -CurrentProvider`选择；旧提供方用`-ApiLevel 37 -UnsupportedSourceOnly`，只运行拒绝与恢复反例，不能作为完整链路通过。普通QA包用`-Action Build`重建；保持`--no-uninstall`和版本码4001，不靠卸载重装伪装保留成功。

## 本地检查点与产物

工程提交：`e5c8bf15ca8662429d85c2014d43e1d7379b5ab7`。文档另行提交，未推送。普通QA入口为`cn.ustcassistant.mobile.MainActivity`，应用ID为`cn.ustcassistant.mobile.qa`，版本`1.0.0-qa-a2`/4001，仅x86_64。APK位于`app/build/android-a2/artifacts/USTC-Assistant-Android-A2-QA-x86_64.apk`，125049541字节，SHA-256：`298d8b0469570a8b53f8a4c3c604db6d30a6a7d9010fe83b71f92d1878b4a15c`。同目录外部manifest关联源码与报告；包内未另注入构建revision，不把外部关联冒称包内日志已有该字段。

最终报告为`analyze-final.txt`、`dart-tests-first.txt`、`native-all-final-messages.txt`、`integration-final-messages.txt`、`message-rejection-final.json`、`gate-old-final-retry.txt`、`profile-current/`、`build-final-messages.txt`及`windows/`；先前失败/局部通过继续保留。所有产物、SDK、Gradle/Pub缓存、AVD与临时脚本继续E盘，构建目录不入Git。Windows标签仍为`e9746b9013df2aafa2f04cdb5d740ecb4c75f5e9`，已交付ZIP的SHA-256仍为`76af4056e026743d8966a212a5288a2a6234423774560f611a168ddea0417e96`。

目标手机的Profile隔离/清理、运行时四项能力、真实JW/Young身份与自动链路仍待用户设备；真实非空考试继续后补。HTTP Link预取不是本轮frame门禁的零流量承诺，未经测试的真实挑战/弹窗/后台场景不补记通过；权限和TLS保留原生拒绝实现，实际系统/学校交互在A7分别核验。Android系统提醒、手机文件/界面、模型与语音整合仍按A3–A6推进。

主要API依据：[文档开始与世界](https://developer.android.com/reference/androidx/webkit/WebViewCompat)、[绑定文档的proxy](https://developer.android.com/reference/androidx/webkit/JavaScriptReplyProxy)、[Profile限制](https://developer.android.com/reference/androidx/webkit/ProfileStore)、[独立清理](https://developer.android.com/reference/androidx/webkit/WebStorageCompat)、[CSP meta及继承](https://www.w3.org/TR/CSP3/)、[消息类型](https://developer.android.com/reference/androidx/webkit/WebMessageCompat)。这些说明不替代上述实际检查。
