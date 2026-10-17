# Android / APK 鸿蒙 WebView 兼容性调研

调研日期：2026-10-17。范围是手机上的学校登录、教务/二课采集与浏览器资料生命周期，兼顾用户正在使用的 MuMu。依据现行 [07](../architecture/07-constitution.md)、[09 K-02–04](../architecture/09-contracts.md)、[13](../quality/13-risks-and-acceptance.md)、[15](../workflow.md)、已批准的 [Android 计划](../milestones/android-apk/plan.md)及 A0/A2/A7 证据。本报告区分官方能力、项目已有实证、工程推断和待验证方案；建议尚不替代已批准契约。

本切只查阅本工作树及公开官方资料，Sol 集成；Luna/max 调研提供方与厂商资料，Astra 独立复核替代架构。没有修改应用、构建 APK、操作模拟器、访问实际学校、读取正式业务或认证资产。修改范围仅本报告和文档入口；验收为引用核对、文档检查与 Git 差异检查。没有新的手机真人通过结论。

## 结论

普通 Android WebView 能显示网页，与本应用目前能完成学校采集，是不同能力层次。当前问题同时包含旧组件和应用实现选择：我们把较新的隔离脚本世界、文档绑定投递、多 Profile 与可确认清理全部列为学校入口的前置条件，实际设备覆盖不能由“Android 7 以上可安装”推断。

建议保留已经验证的现代系统 WebView 通道，但不把它作为所有手机的唯一长期实现。先验证两条兼容方向：旧系统 WebView 的独立宿主进程/数据目录，以及随应用提供内核的 GeckoView。前者只解决部分隔离与清理问题；后者是完整替代候选，仍有清理完成、分区隔离、文档绑定等关键未知项。没有证据支持现在直接宣布其中任一方案已经满足全部契约。

最大兼容性的目标应当包括完整自动认证和采集，而不是仅能打开网页。兼容方案未完成时也应准确隔离故障、保留本地资料和其他功能；现有恢复待办须真实处理，不能通过换后端或创建新目录抹掉旧失败。当前没有足够资料给出中国手机市场的兼容百分比，也不能承诺所有鸿蒙设备均可运行本 APK。

## 1. 为什么系统版本和手机型号不能代表兼容性

Android 存在三个不同层次：系统框架的 `android.webkit`、设备实际加载的 WebView 提供方，以及应用使用的 AndroidX WebKit 适配库。AndroidX 连接现有引擎，不把 Chromium 内核打包进应用；提高依赖版本不会让旧提供方获得不存在的能力。反过来，较旧 Android 系统也可能通过更新提供方使用新能力，应逐项检测。[Android 官方分层与功能检测说明](https://developer.android.com/develop/ui/views/layout/webapps/jetpack-webkit-overview)

因此需要记录实际提供方包名/版本及功能结果，而不是浏览器名称、User-Agent 或模拟机型。Android 10 及以上的 Chrome 与 WebView 已分离，安装新版 Chrome 不等于本应用换用了新内核；Android 7–9 的历史 Chrome 提供方机制不能推广至现在。[Chromium 官方通道与提供方说明](https://chromium.googlesource.com/chromium/src/+/main/android_webview/docs/prerelease.md)

Google 官方发布记录包含 2026-10-07 的 WebView 156。这说明项目已通过的 149 只是一个测试样本，不是“只能 Android 17 才支持”，也不能把 149 当作精确最低版本。发布不等于每台手机已经安装，灰度、厂商移植及具体能力仍以实际查询为准。[Google 发布记录](https://support.google.com/product-documentation/answer/14343500?hl=zh-sg)

Google 的 Android 分布看板依据 Google Play 活跃设备，并非中国全部手机，更没有发布本项目四项 WebView 能力的装机覆盖。操作系统占比、浏览器份额和本应用学校采集兼容率不能互换。[官方数据口径](https://developer.android.com/about/dashboards)

## 2. 手机市场应按环境分类

下表是测试与分发分类，不是已经完成的厂商认证表。

2024 年及以后国内代表机型、系统版本与证据层次另见 [机型核对](android-webview-domestic-models.md)；该补充不提供逐机型高级能力通过结论。

| 环境 | 能确认的机制 | 对本项目的判断 |
|---|---|---|
| Google Play 更新渠道可用的 Android 手机，包括部分 Pixel、三星和国际版 ROM | 提供方通常有独立更新渠道；最终以系统当前选择的实现为准 | 现代系统通道的优先测试样本，不能按品牌承诺四项能力全有 |
| 小米、OPPO、vivo、荣耀等国内 ROM | 需要核实具体 ROM 选用的提供方、版本、系统商店/OTA 更新路径；本轮未取得逐品牌完整官方版本矩阵 | 必须作为重点目标；不能要求用户具备 Google Play，也不能假设所有国内 ROM 都缺能力 |
| 仍可直接安装 APK 的旧版鸿蒙/EMUI 设备 | 应核实 Android 兼容层、实际提供方及固件；HMS 服务本身不是 APK 运行引擎 | 可复用同一 APK 路线，但学校、Keystore、文件和通知需分别验收 |
| HarmonyOS 5 及以上，通过卓易通等安装/运行部分 APK | 华为明确安装包是否可安装以兼容环境实际支持为准 | 单列兼容环境；安装成功不能证明学校 WebView、加密与后台通知成立 |
| 原生鸿蒙应用 | 使用 ArkWeb 等原生能力，与 AndroidX WebKit 接口不同 | 不属于改 APK 即可支持的范围；以后需要独立平台端口 |
| iPhone / iOS | 官方 WKWebView 提供网页嵌入，WKContentWorld 提供独立脚本环境 | 有成熟网页组件，但当前 APK 不能直接复用为 iOS 应用；平台桥与资料生命周期以后另验 |
| MuMu 等模拟器 | 模拟器自带 Android 镜像与提供方，模拟机型可与真实组件版本无关 | 适合复现和人工体验，不能代替同品牌真实手机，更不能代表整个 Android 市场 |

Google 更新机制见 [Chromium 官方说明](https://chromium.googlesource.com/chromium/src/+/main/android_webview/docs/prerelease.md)。鸿蒙兼容环境的安装范围见 [华为当前用户支持说明](https://consumer.huawei.com/cn/support/content/zh-cn16061787/)。华为对原生 ArkWeb 的说明为当前不支持第三方 WebView 内核；这项说明不直接证明某个 APK 兼容容器能否运行 GeckoView，后者仍须单独实测。[ArkWeb 官方 FAQ，2026-10-14](https://developer.huawei.com/consumer/cn/doc/doccenter-dev-faq/arkweb-kit-faq-0003)

iOS 的网页与脚本隔离接口见 [Apple WKWebView](https://developer.apple.com/documentation/webkit/wkwebview) 和 [WKContentWorld](https://developer.apple.com/documentation/webkit/wkcontentworld)。它们的存在不证明本项目的认证、分区和精确文档契约可直接照搬；iOS 不扩入本轮已批准的 APK 迁移范围。

Android 提供方受 ROM 的允许包与签名等条件约束。普通应用不能随意把一个下载的 WebView APK 变成系统正在使用的实现；调试镜像也不能证明生产手机允许同样替换。因此不把安装第三方 APK、改系统信任或要求 root 作为产品兼容方案。[Chromium 系统集成规则](https://chromium.googlesource.com/chromium/src/+/main/android_webview/docs/aosp-system-integration.md)

旧系统另有更新寿命问题：Chromium 当前说明 Google WebView 不再支持 Android 5–9 的后续版本，旧设备只能取得各自最后支持版本。这是 Google 通道的边界，不应扩写成所有 OEM 内核都完全相同。现有构建下限可暂不改，Android 7–9 的完整学校能力不能先行承诺。[官方旧系统支持范围](https://chromium.googlesource.com/chromium/src/+/main/android_webview/docs/prerelease.md)

## 3. 本项目当前真正要求了什么

工程依赖为 `androidx.webkit:webkit:1.17.1`，锁定 Flutter 的构建下限为 API24。学校正常打开需要以下四项；恢复清理只要求前两项。下面“加入版本”指适配库 API 的版本，**不表示相应 Android 系统版本，也不表示每个设备引擎从该日就支持**。

| 功能标志 | 加入 AndroidX 版本 | 当前用途 |
|---|---|---|
| `MULTI_PROFILE` | 1.9.0 | 教务、二课及不同受控分区的浏览器资料隔离 |
| `DELETE_BROWSING_DATA` | 1.13.0 | 独立资料清理及完成回调，配合关闭与持久恢复 |
| `DOCUMENT_START_SCRIPT` | 1.9.0 | 在页面代码前安装固定脚本 |
| `JS_INJECTION_IN_FRAME_AND_WORLD` | 1.16.0 | 私有脚本世界、frame 策略、固定认证和文档关联调用 |

功能定义与版本见 [WebViewFeature 官方 API](https://developer.android.com/reference/androidx/webkit/WebViewFeature)。其中隔离世界与对应回复代理执行接口在 2026-03-11 的 1.16.0-alpha03 加入，1.16.0 于 2026-05-06 稳定发布。它不是普通网页显示的基础能力，将其作为整个学校入口的硬前提，确实使覆盖面依赖较新的引擎。[AndroidX 发布记录](https://developer.android.com/jetpack/androidx/releases/webkit)

实现位置是 [ObservationBridge.kt](../../app/android/app/src/main/kotlin/cn/ustcassistant/mobile/browser/ObservationBridge.kt) 的 `ensureFeatures`、`install` 和 `ready`。需要明确三件事：

1. `ready` 同时要求页面、私有脚本和 frame 策略准备完成。私有世界并非只用于填密码，教务读取与旧文档拒绝也依赖它。
2. A2 计划提到能力不足时允许手填，但当前没有“缺私有世界→手填→仍能采集”的完整实现。那是尚未实现的回退意图，不能用来解释当前行为或承诺兼容。
3. 上轮预检与诊断修复解决了失败原因被覆盖、新尝试错误进入恢复和日志不可达的问题，没有改变这四项能力要求，也没有给旧引擎补出能力。

单纯关闭自动填密、把脚本改为 `evaluateJavascript`、更换 Flutter WebView 插件，都不能直接证明现行私有上下文与文档绑定契约仍成立。Flutter 官方插件在 Android 也使用平台 WebView，换封装本身不更换设备内核。[Flutter 插件实现说明](https://github.com/flutter/packages/blob/main/packages/webview_flutter/webview_flutter/README.md)

## 4. 已有实证能说明什么

| 本项目环境 | 实际引擎 | 已观察结果 |
|---|---|---|
| 用户 MuMu，Android12/API32 | 110.0.5481.154.1 | 首次来源调用被能力检查拒绝，学校完整通道不可用；后续恢复问题另有修复 |
| 官方 Android14/API34 镜像 | 113.0.5672.136 | 缺多 Profile、独立删除、私有世界，学校通道被拒绝 |
| A0 官方 API35 镜像 | 124.0.6367.219 | 多 Profile 可用，独立删除能力不足 |
| A0 官方 API36 镜像 | 133.0.6943.137 | Profile 隔离、清理回调及冷恢复已验证；不构成完整 A2 私有世界通过 |
| 官方 API37/16KB 镜像 | 149.0.7827.5 | 四项能力及私有世界往返、教务/二课合成链路通过 |

证据归属为 [A0 实验](../milestones/android-apk/records/01-a0-runtime-probes.md)、[A2 原生桥](../milestones/android-apk/records/04-a2-school-bridges.md)、[A7 设备矩阵](../milestones/android-apk/device-matrix.md)及 [MuMu 修复记录](../milestones/android-apk/records/11-mumu-source-and-diagnostics.md)。这些都是特定镜像/实例，不是对应 Android 大版本或手机品牌的普遍结论；没有新增学校真实验收、arm64 手机或鸿蒙通过。

## 5. 扩大覆盖的方案比较

| 路线 | 解决什么 | 仍然解决不了什么 | 建议 |
|---|---|---|---|
| 现代系统 WebView | 沿用现有代码、由系统渠道更新内核 | 不能控制国内 ROM/模拟器的更新速度 | 保留，完善能力诊断和实际版本矩阵 |
| 系统 WebView + 每来源独立宿主进程/目录 | 可绕开对同进程多 Profile 的部分依赖，研究独立排空/清理 | 旧引擎仍没有私有脚本世界；完整清理与崩溃恢复需证明 | 做有边界的生命周期原型，不单独称完整兼容后端 |
| 随包 GeckoView | 内核版本由应用控制，可研究独立脚本和消息桥 | 清理完成、持久分区、frame、文档及真实传输绑定未证明；增加包体和更新责任 | 作为完整兼容候选，优先验证最难的契约 |
| Custom Tabs / 外部浏览器 | 用户浏览、利用外部浏览器登录体验 | 不提供现有受控网页采集、私有 JS 与按来源清理 | 只能算浏览辅助，不能当同步已兼容 |
| AppAuth / 学校正式 OAuth/OIDC | 学校提供正式客户端与授权接口时可简化认证 | 不能凭 AppAuth 替换现有 CAS、两业务站采集和身份核验 | 仅在学校确有授权接口后另评估 |
| 腾讯 X5/TBS | 另一种应用侧网页 SDK 候选 | 本轮未证明与当前隔离、清理完成和文档能力等价；不自动替换系统 WebView | 不作为已成熟可替换的结论，暂不优先引入 |
| 自行维护 Chromium 内核 | 可控制内核实现 | 构建、漏洞更新、ABI、分发和长期维护成本高 | 目前项目规模不优先 |

### 5.1 独立宿主进程/目录

Android 9/API28 起提供 `WebView.setDataDirectorySuffix`，为当前进程设置独立数据/缓存目录后缀。必须在该进程任何 WebKit 初始化前调用，同一目录不能被多个进程同时使用；它不是一个进程内随时切换分区的接口。[官方 API 条件](https://developer.android.com/reference/android/webkit/WebView#setDataDirectorySuffix(java.lang.String))

可研究由主进程持有 C2 租约与 C3 数据，来源宿主仅持固定学校桥；不同分区用随机目录标识，必要时结束宿主后重新创建。若采用此方案，必须证明调用方/作业身份、父进程死亡后的收口、renderer/Worker 终止、目录归属、禁止备份、部分删除及崩溃恢复。不能以 `destroy()`、Cookie 清空、换后缀或一次文件删除成功推断全部旧资料已经清理。

这条路可能降低 Profile/清理 API 的版本依赖，但**不会给旧引擎增加隔离世界或精确旧文档投递**。完整学校兼容还需另一个有证据的实现，不宜花完工期后才发现只解决了两项门槛。

### 5.2 GeckoView

GeckoView 是 Mozilla 提供的应用嵌入引擎，可以固定随应用交付的版本；官方提供稳定/Beta/Nightly 渠道及原生嵌入接口，单个进程只应有一个 GeckoRuntime。它不是本项目即插即用的 AndroidX 实现。[Mozilla 接入与运行时说明](https://firefox-source-docs.mozilla.org/mobile/android/geckoview/consumer/geckoview-quick-start.html)

其 WebExtensions/content script/native messaging 可作为固定受控桥的基础，脚本隔离与页面对象访问语义需按 Gecko 重写和验证，不能直接照搬 Chromium 的 `globalThis`、页面 helper 或回复代理假设。[官方扩展桥](https://firefox-source-docs.mozilla.org/mobile/android/geckoview/consumer/web-extensions.html)、[content script 的 DOM/Xray 语义](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Content_scripts#dom_access)

最需要先验证的是清理：当前 Mozilla-central API 的 `clearDataForSessionContext(contextId)` 返回 `void`，没有清理完成结果；`clearData(flags)` 虽返回完成结果，却作用于整个 runtime 的资料，若两来源共享 runtime 不能随意清空。官方还要求先关闭相应 session，以免资料重新积累。本轮引用的是当前开发分支文档，不能当作锁定稳定版和设备已通过。[StorageController API](https://mozilla.github.io/geckoview/javadoc/mozilla-central/org/mozilla/geckoview/StorageController.html)

本轮未核得稳定公开 API 对“每来源独立持久 profile 路径”的完整保证；不能仅凭存在 `contextId` 或通用启动参数就宣布分区隔离、独立完成清理及冷恢复成立。原型须先解决这些问题，再投入教务/二课整条迁移；未能证明时及时停止，不默认降低 K-02。

若通过，业务端仍可复用 C1 固定数据契约、C2 作业和 C3 事务、Agent 工具与 Flutter 页面；主要重做的是 P 原生桥、会话账本、脚本与生命周期。还要验 arm64、16KB 页、内存/包体、稳定版更新、所有额外网络行为及 APK 鸿蒙兼容环境。不能只凭 Firefox 能打开学校页面就认定自动采集成立。

### 5.3 为什么外部浏览器和传统注入不是直接替代

Custom Tabs 使用浏览器能力并可共享浏览器登录状态；官方对需要注入网页 JavaScript 的场景仍区分为 WebView 用途。它适合提供用户主动打开链接的体验，不是现有 C1 页面采集端口。[Chrome 官方 Custom Tabs 说明](https://developer.chrome.com/docs/android/custom-tabs)

AppAuth-Android 面向 OAuth2/OIDC 客户端授权。本项目实际学校链路是已经核验的 CAS 与教务/二课业务站；没有正式客户端注册、重定向和数据 API 证据时，不能从“支持 OAuth 的成熟库”推导出可替换学校协议。[AppAuth 官方项目](https://github.com/openid/AppAuth-Android)

传统页面世界注入能实现许多常见自动化，但不等于当前批准的私有上下文与精确文档契约。若以后选择改变信任模型、仅保留手动认证或接受不同会话保留语义，应写明具体影响并单独裁决；本轮研究不把这些取舍伪装成等价技术替换。X5 的公开 SDK 文档也不能单凭“能打开网页/清缓存”证明全部条件。[TBS SDK 官方 API](https://x5.tencent.com/docs/tbsapi/reference/com/tencent/smtt/sdk/QbSdk.html)

## 6. 对本项目的推荐推进顺序

后续状态：用户于2026-10-17要求重新评估高级能力限制，优先普通系统WebView并保留自动登录/采集。新的推荐已写入[待批准的A7修订计划](../milestones/android-apk/plan.md#a7普通系统webview兼容修订待批准)及[边界提案](../decisions/android-system-webview-compatibility.md)，不再以GeckoView原型作为下一步首选。下文保留原研究时点的建议及其所依据的强契约；批准前不把新取舍记为现行规范或已有实现。

### 先把兼容目标说清楚

建议把普通 Android 10 及以上、包括无 Google Play 的国内 ROM，作为下一轮完整学校能力的重点覆盖目标；这是研究建议，不是已经验证的最低可用承诺。现有 API24 构建下限暂不因这份报告改变，较旧系统保留可成立的功能，但完整学校支持单独登记。APK 鸿蒙按实际容器和提供方单列，原生 ArkWeb 不混入 Android 通过率。

兼容状态应区分基础应用、学校浏览、学校受控读取、固定自动认证和资料恢复/清理。能力不足不应让新尝试创建无法回收的资产，也不能让 Agent 把“缺组件”“未登录”和“没有课程”混为一谈。只有整条路径有实现与测试时才展示“可手动继续采集”。现有 pending 恢复可能约束启动，不能无视它宣称全部本地功能必然可用。

### 再做两个小而完整的原型

1. **目录/进程原型**：只验证旧系统组件下的来源隔离、关闭排空、持久认领、完整清理和崩溃恢复，明确不以此验收旧引擎完整采集。
2. **完整候选原型**：锁定 GeckoView 稳定版，优先证明独立清理完成及另一来源保留；随后证明无秘密 bootstrap、固定秘密单次投递、同 URL 新文档/BFCache/历史拒旧、frame 规则、Young 真实传输绑定和固定响应投影。通过这些才迁移完整业务链。

两项原型允许按结果调整优先级；研究阶段不承诺必定保留两个正式后端。若无法满足现行契约，要把失败点和可选取舍交回设计，而非继续堆条件或暗中放宽。

### 后端切换与资料保留一起设计

若引入第二种后端，每个分区必须记住所属后端及必要版本，作业开始时固定使用一个实现，不能两条采集并跑后接受先返回的结果。原系统后端的待清理/未知分区继续走原归属恢复，不能因为 Gecko 可用就跳过。禁止复制认证 Cookie、浏览器 token 或手填秘密来搬迁会话；本地日程、备注、任务、加密凭据和已提交回执按原承诺保留。

这会修改 A2 的具体平台映射和测试矩阵，若牵涉隔离、安全或会话保留取舍，需要先修订设计并取得批准。本报告没有把候选架构登记为已批准决定，也没有更改 APK。

## 7. 建议的兼容性验收矩阵

| 维度 | 应覆盖的样本 | 需要验证的重点 |
|---|---|---|
| 系统版本 | 当前构建下限附近、Android9/10、主流中间版本、新稳定版 | 安装与功能分开，不以一台新系统推断旧系统 |
| 提供方 | 已知旧 110/113、部分能力 124/133、现代已验 149 及更新稳定渠道 | 四项检测只是起点，还要验证往返和故障行为；这些编号不是预设兼容阈值 |
| 厂商分发 | 一个 Google 更新渠道样本，以及国内 ROM 的多个不同提供方家族 | 实际组件、升级路径、renderer 退出和更新后的冷恢复 |
| 鸿蒙 | 一种直接 APK 环境；一种新版 APK 兼容容器 | ABI、WebView/Gecko、Keystore、文件、通知及后台恢复分别记录 |
| CPU/页大小 | arm64 实机、x86_64 模拟器、16KB 环境 | 内核及原生库能启动，不将模拟翻译等同实机 |
| 学校行为 | 教务与二课各自的完整链路 | 复杂重定向、人工挑战、身份、分页/范围、取消/重启、同 URL 拒旧 |
| 资料维护 | 单来源删除、异常退出、旧后端 pending、APK 覆盖升级 | 另一来源与正式日程不丢失，不误报清理成功，不通过卸载逃避恢复 |

测试必须包含旧版本和更新后的回归。三星官方记录过特定应用在 WebView M139 及更新版本下发生滚动异常，说明“更新了”也不能替代应用级验证；其针对该故障的临时卸载更新建议，不应扩写为本项目的普遍降级方案。[三星支持案例](https://www.samsung.com/us/support/troubleshoot/TSG10010053/)

诊断建议只增加本机安全摘要：系统 API、ABI/页大小、实际提供方包名/版本、适配库/后端版本、逐项能力、受控合成探针和固定失败码。用户主动导出即可；不采集 IMEI、账号、学校 URL/响应、Cookie、完整应用清单或自动上传。正式覆盖率必须从有代表性的实际样本计算，不用模拟器通过项或浏览器份额代替。

## 8. 尚不能得出的结论

- 不能给某个手机品牌整体盖“支持/不支持”章；同品牌不同 ROM、地区、维护状态可能不同，本轮没有完整官方逐型号矩阵。
- 不能认定所有 Android14 设备缺能力、Android17 才可用，或把149当精确最低内核；现有证据只对应具体提供方实例。
- 不能认定更新 Chrome、换 Flutter 插件、允许手填或移除一个功能判断就能恢复完整采集。
- 不能认定 GeckoView 已满足 K-02–04，或承诺它在新版鸿蒙容器中可用；也没有证明等价旧版完整通道技术上绝不可能，只是本轮尚未证实。
- A7 仍保留真人、真实学校/模型、目标手机/鸿蒙及厂商策略验收；本报告不关闭这些项目，不改写之前失败。
