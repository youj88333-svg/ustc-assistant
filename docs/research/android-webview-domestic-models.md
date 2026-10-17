# 2024 年及以后国内手机的 WebView 与系统版本

调研日期：2026-10-17。用户要求继续核对小米、OPPO、vivo、荣耀和鸿蒙的具体机型。依据 [07](../architecture/07-constitution.md)、[09 K-02–04](../architecture/09-contracts.md)、[13](../quality/13-risks-and-acceptance.md)、[15](../workflow.md)、已批准 [APK 计划](../milestones/android-apk/plan.md)及 [兼容性总报告](android-webview-compatibility.md)。本文件维护型号/系统的公开证据，总报告维护架构候选与取舍，二者不复制任务单。

范围仅为国行代表机型和公开官方资料，不穷尽全部 SKU。Sol 核对、集成；Luna/max 分别调研小米/OPPO、vivo/荣耀、华为。没有修改应用、构建/安装包、操作手机或学校、读取正式业务或认证资产。验收为来源核对、文档检查和差异检查；本轮没有新增设备运行通过结论，不改变安全、资料保留或里程碑状态。

## 判断口径

本轮可以更明确地判断：**已核对的 HyperOS、ColorOS、OriginOS、MagicOS 代表机型属于支持普通 Android WebView 的平台；鸿蒙必须按系统代际与 APK 运行环境另分。** 普通支持不等于本应用的学校通道已通过。

| 证据层次 | 能确认什么 | 不能确认什么 |
|---|---|---|
| 官方产品参数、发布稿、企业设备表 | 国行型号、系统名称、明确列示的 Android 基线、发布/上市资料 | 该用户手机目前的 OTA 版本、WebView 提供方与引擎版本 |
| OEM 开发文档、Android 平台要求 | 厂商系统存在原生 WebView 开发/运行机制，可作为基础支持判断 | 某个 SKU 的高级接口全部可用，或学校链路正常 |
| 设备上的功能检测及行为验证 | 特定固件/提供方上的实际能力 | 本轮未执行，不将公开资料记为设备通过 |

Android14 CDD 的手机要求 2.2.3 `[3.4.1/H-0-1]` 明确要求完整实现 `android.webkit.Webview` API；3.4.1 规定对应 Chromium 实现。该规范为 Android 平台基础判断提供依据，但不等于我们已经核验每台国行设备的 CDD 合规或实际组件状态，更不包含本项目四项 AndroidX 扩展保证。[AOSP 官方规范](https://source.android.com/docs/compatibility/14/android-14-cdd?hl=en)

以下“支持”均为正常原厂系统的**平台级判断**，不是安装本 APK 的实测结果。首发系统、参数页列示系统、企业 SDK 兼容栈、OTA 升级计划分开；没有证据的 Android 基线留空，不用海外 ROM 或系统数字顺推。

## 小米 / REDMI

小米官方的 [WebView 适配指导](https://dev.mi.com/xiaomihyperos/documentation/detail?pId=2045)直接说明应用 WebView 的设置、窗口变化与页面适配，展示 `WebSettings` 接口。这是普通原生 WebView 的直接厂商证据，比“小米手机可以打开浏览器”更具体；不是逐型号引擎版本清单。

| 代表机型 | 已核公开时间 | 国内系统证据 | 普通 WebView |
|---|---|---|---|
| Xiaomi 15 / 15 Pro | 2024-10-29 商城新品开售 | 小米澎湃 OS 2；本轮未核准国内首发 Android 基线 | 支持，HyperOS 开发接口级证据 |
| REDMI K80 | 2024-11 在中国大陆推出 | 小米澎湃 OS 2；Android 基线未核 | 支持，同上 |
| Xiaomi 15 Ultra | 2025-02 国内发布 | 小米澎湃 OS 2；Android 基线未核 | 支持，同上 |
| Xiaomi 17 / 17 Pro / 17 Pro Max | 2025-09 发布，官方首月统计从 9-25 起 | 内置小米澎湃 OS 3；Android 基线未核 | 支持，同上 |

型号来源：15 的 [国内商城说明](https://www.mi.com/article/detail/a58b2a65ac38.html)、[15 商品主体](https://www.mi.com/shop/buy/detail?product_id=20618)与 [15 Pro 产品页](https://www.mi.com/prod/xiaomi-15-pro)；K80 的 [2024 年报](https://ir.mi.com/static-files/ad1290a8-475f-4375-8281-a86f8bb79f67)；15 Ultra 的 [官方业绩材料](https://ir.mi.com/static-files/c9c6f155-70d2-4031-9f4d-79b14193bbd4)与 [产品页](https://www.mi.com/prod/xiaomi-15-ultra)；17 系列的 [2025 年第三季度材料，第 4 页](https://ir.mi.com/static-files/1e19fb17-dc12-4803-8426-376008c467a9)。这些足以核对相应机型与 OS，不将其扩写成所有机主目前仍停留在首发系统。

另有 [MiCT 官方说明](https://dev.mi.com/xiaomihyperos/documentation/detail?pId=1985)：通过小米浏览器提供应用内网页能力，面向中国大陆、符合条件的 HyperOS/MIUI 设备。它属于浏览器承载的另一种接入方式，文档排除部分折叠屏/Pad 的条件只针对该服务，不能据此判断折叠手机缺普通 WebView。MiCT 和快应用的 `webview` 也不能证明本项目当前原生桥的高级能力。

## OPPO / 一加国内 ColorOS

ColorOS 官方在 [ColorOS15 介绍](https://www.coloros.com/article/A00000066/)中明确描述系统级滑动曲线覆盖 WebView、三方应用获得相应体验，并说明 Find X8 和一加13首发该系统。这是国内 ColorOS 原生网页组件的直接系统级证据。

OPPO [企业开发者设备表](https://bdev.oppo.com/open/resource/index/document/detail?id=100)同时列入网型号、ColorOS 与 Android 版本；该表是企业 SDK 兼容矩阵，**不能直接当作出厂固件或目前全部机主的 OTA 版本**。动态页本次打开只返回脚本占位，所列字段已通过该官方 URL 的可检索正文核对；不将搜索缓存时间当成最新 OTA 时间。

| 代表机型 / 国行型号 | 官方列示系统 | Android 基线及来源性质 | 普通 WebView |
|---|---|---|---|
| Find X7 / PHZ110 | ColorOS14.0.1 | Android14，企业设备表列示栈 | 支持，Android 平台级 |
| Reno12 / PJV110；Reno12 Pro / PJW110 | ColorOS14.1.0 | Android14，同上 | 支持，同上 |
| Find X8 / PKB110 | ColorOS15.0 | Android15，同上；另有 ColorOS15 首发产品说明 | 支持，厂商系统级 |
| Find X8 Ultra / PKJ110 | ColorOS15.0.1 | Android15，企业设备表列示栈；不把它与标准版 SKU 混用 | 支持，厂商系统级 |
| 一加13 | ColorOS15.0 | 中国 [参数页](https://www.oneplus.com/cn/13/specs)直接列“基于 Android15” | 支持，厂商系统级 |
| Find X9 / PLJ110；Find X9 Pro / PLG110 | ColorOS16.0.0 | Android16，企业设备表列示栈 | 支持，Android 平台级 |

Find X7/Reno12 是 2024 代际样本，Find X8 是 ColorOS15 的首发代表；本轮不补造未核准的首销日。X8 型号/系统另见 [国内参数页](https://www.oppo.com/cn/smartphones/series-find-x/find-x8/specs/)；一加13 [发布活动](https://www.oneplus.com/cn/13-launch)列 2024-10-31。Find X9 [中国商城条目](https://store.oppo.com/cn/app/product/index?skuId=36848)列上市 2025-10，系统另见 [中国产品页](https://www.oppo.com/cn/smartphones/series-find-x/find-x9/)。一加未列在本轮读取的企业表内，不能拿 OPPO 型号对应关系套一加。

2026 年官网另已列 [Find X10 / ColorOS17](https://www.oppo.com/cn/smartphones/series-find-x/find-x10/)；[2026-09-24 的官方系统发布稿](https://www.oppo.com/cn/newsroom/press/549/)称将首发于 Find X10 系列和一加16。本轮未核准国行首销时间和 Android 基线，作为当前官方产品信息补充，不纳入已核上市时间的行，也不从 ColorOS17 自动推成 Android17 或四项扩展可用。

## vivo / iQOO 国内 OriginOS

vivo 国内参数页对这批机型直接列出“基于 Android 开发的 OriginOS”，上市月与基础版本较易核对，不需要借用国际版 FuntouchOS 的资料。

| 代表机型 | 官方上市月 | 官方参数列示系统 | 普通 WebView |
|---|---|---|---|
| [iQOO Z9x](https://www.vivo.com.cn/vivo/param/iqooz9x) | 2024-04 | OriginOS4 / Android14 | 支持，Android 平台级；中低端样本 |
| [vivo Y37](https://www.vivo.com.cn/vivo/param/y37) | 2024-07 | OriginOS4 / Android14 | 支持，同上；中低端样本 |
| [vivo X100 Ultra](https://www.vivo.com.cn/vivo/param/x100ultra) | 2024-05 | OriginOS4 / Android14 | 支持，同上 |
| [vivo X200](https://www.vivo.com.cn/vivo/param/x200) | 2024-10 | OriginOS5 / Android15 | 支持，同上 |
| [vivo X200 Ultra](https://www.vivo.com.cn/vivo/param/x200ultra) | 2025-04 | OriginOS5 / Android15 | 支持，同上 |
| [vivo X300](https://www.vivo.com.cn/vivo/param/x300) | 2025-10 | OriginOS6 / Android16 | 支持，同上 |
| [vivo X300s](https://www.vivo.com.cn/vivo/param/x300s) | 2026-03 | OriginOS6 / Android16 | 支持，同上 |

该判断来自型号 Android 基线与 Android 手机 API 要求，本轮没有找到 vivo 中国开发者资料中可用的原生 WebView provider/高级接口逐版本说明。快应用或小程序组件不是这种证明。这里的“支持”不表示已经在对应设备跑过本应用；包名、内核版本、四项扩展及实际学校链路仍未观察。

## 荣耀国内 MagicOS

荣耀开发者 [Android17 适配指南](https://developer.honor.com/cn/docs/adaptation_guide/guides/android_17_compatibility_adaptation_guide)明确说明 WebView 是 Android 组件，并指出 Android16 或更低系统也可能因 WebView 更新受到行为变化。这支持“原生组件存在、内核更新与系统大版本不完全绑定”的判断。文中 `139.0.7258.158` 是测试示例，不能分配给所有荣耀手机。

| 代表机型 | 已核公开时间 | 国内系统证据 | 普通 WebView |
|---|---|---|---|
| Magic6 | 2024-01 发布 | MagicOS8；官方社区客服的系统级答复称基于 Android14，非本机参数字段 | 支持，厂商系统级 |
| Magic7 系列 | 2024-10-30 发布 | MagicOS9；Android15 依据为官方社区对该系统的答复，非本机参数字段 | 支持，同上 |
| Magic8 Pro / BKQ-AN10 | 商城列 2025-10 上市 | MagicOS10.0 / Android16，官方商城参数索引 | 支持，同上 |
| Magic9 / MLY-AN00 | 2026-09-28 发布，商城列 2026-09 | MagicOS11 / Android17，官方商城参数索引及发布稿 | 支持，同上；不据 Android17 推断高级能力全有 |

来源：Magic6 [官方发布稿](https://www.honor.com/cn/news/honor-magic6-launch/)与 [系统级社区客服答复](https://club.honor.com/cn/thread-28339608-1-1.html)；Magic7 [发布稿](https://www.honor.com/cn/news/honor-magic7-launch/)与 [系统级答复](https://club.honor.com/cn/thread-28958884-1-1.html)；Magic8 Pro [中国商城](https://www.honor.com/cn/shop/product/10086048644581.html?cid=132349)与 [发布稿](https://www.honor.com/cn/news/honor-magic8-launch/)；Magic9 [中国商城](https://www.honor.com/cn/shop/product/10086225001424.html?cid=132367)与 [2026-09-28 发布稿](https://www.honor.com/cn/news/honor-magic9-launch/)。两商城动态参数在本次直接打开的正文中缺项，型号/上市月/Android 字段依据该官方 URL 的搜索索引，不冒充设备截图或运行结果。社区普通用户的推测帖子不作为官方参数。

MagicOS 升级计划只能证明可升级/拟推送范围，不表示每台机主已经升级。也不把国际版参数覆盖到国内同名型号。荣耀同样未给出上述每个固件的 provider 包名、实际内核和本项目四项扩展矩阵。

## 华为鸿蒙：按实际系统代际划分

华为公开安装指导对 HarmonyOS3/4.0/4.2/4.3 给出直接应用包安装路径；对 HarmonyOS5 及以上，官方说明部分 APK 经卓易通等兼容环境安装，是否支持取决于实际兼容范围。[旧系统安装说明](https://consumer.huawei.com/cn/support/content/zh-cn01089223/)、[5 及以上安装说明](https://consumer.huawei.com/cn/support/content/zh-cn16061787/)

| 代表机型 | 官方列示系统 / 批次差别 | 对当前 APK 与网页组件的判断 |
|---|---|---|
| [Pura70 系列](https://consumer.huawei.com/cn/support/pura70series/)（2024） | HarmonyOS4.2 | 存在直接 APK 环境，列为旧鸿蒙适配候选；具体 Android WebView 提供方/版本未核 |
| [Mate XT 非凡大师](https://consumer.huawei.com/cn/phones/mate-xt-ultimate-design/specs/)（2024） | HarmonyOS4.2 | 同上；与 Mate XTs 不混用 |
| [nova13 系列](https://consumer.huawei.com/cn/support/content/zh-cn16065579/)（2024） | 官方支持资料列 nova13 的4.2版本 | 同上，系统升级后需重新分类 |
| [Mate70](https://consumer.huawei.com/cn/phones/mate70/specs/)（2024） | 普通版4.3；NEXT先锋版出厂5.0；4.3可升级5.0 | 同名机型已有两条运行路线，不能只记“Mate70支持” |
| [Pura X](https://consumer.huawei.com/cn/phones/pura-x/specs/)（2025） | 5.0.1；部分批次预装6或以上 | 原生网页组件走鸿蒙体系；APK兼容容器中的 WebView 待单独验证 |
| [Pura80](https://consumer.huawei.com/cn/phones/pura80/specs/)（2025） | 5.1；部分批次预装6或以上 | 同上 |
| [Mate XTs 非凡大师](https://consumer.huawei.com/cn/phones/mate-xts-ultimate-design/specs/)（2025） | 5.1；部分批次预装6或以上 | 同上 |
| [Mate80](https://consumer.huawei.com/cn/phones/mate80/specs/) | 官网列6.0 | 同上，不能把能安装某个 APK 推成我们已兼容 |
| [Pura90](https://consumer.huawei.com/cn/phones/pura90/specs/) | 官网列6.1；[2026 发布会页面](https://consumer.huawei.com/cn/press/events/2026/huawei-pura-90-series-and-new-product-launch-event/)列该产品 | 同上，最新代际也需按 APK 容器核验 |
| [Mate90](https://consumer.huawei.com/cn/phones/mate90/specs/) | 官网列 HarmonyOS7；首发月本轮未核 | 原生 ArkWeb 与 APK 的 Android WebView 分开；不能按“7更高”推成原 APK 平台能力更全 |

原生鸿蒙具有 Web/ArkWeb 组件，并非不能显示网页；它与 APK 内 `android.webkit.WebView` 是不同平台接口。华为 [ArkWeb FAQ](https://developer.huawei.com/consumer/cn/doc/doccenter-dev-faq/arkweb-kit-faq-0003)对第三方内核的限制适用于原生组件，不能外推为卓易通内部一定支持或一定不能运行 GeckoView。本轮没有取得容器内部引擎的官方完整矩阵。

华为 [6.1 升级名单](https://consumer.huawei.com/cn/support/harmonyos/models-6/)含 Pura70、Mate XT、nova13、Mate70 等，当前另有 [7 的支持入口](https://consumer.huawei.com/cn/support/harmonyos/models-7/)。名单只说明支持范围/计划，实际固件以设备为准。特别是 4.x 升到5及以上后，要重新检查 APK 运行环境和资料保留，不能沿用旧系统的通过。系统回退也不能一概承诺：[官方回退条件](https://consumer.huawei.com/cn/support/content/zh-cn16030363/)取决于设备和版本是否配置回退链路。

## 对本项目的直接影响

1. 已核对的四家 Android 国内 ROM 应列为普通 WebView 的正常支持目标。基础网页打开不应要求 Google Play/GMS，不将手机品牌或 ROM 名称列为拒绝条件。
2. 这些公开材料没有给出本项目 `MULTI_PROFILE`、`DELETE_BROWSING_DATA`、`DOCUMENT_START_SCRIPT`、`JS_INJECTION_IN_FRAME_AND_WORLD` 的逐设备结果。不能从“2024后新手机”“Android17”或“有WebView”直接宣布学校通道可用，也不能从未知推成不支持。
3. 优先补这些目标环境的实际提供方与无账号能力摘要，再确定兼容后端投入；仅凭 MuMu110 的失败不足以决定整个手机端必须自带内核。总报告中的目录/进程与 GeckoView 仍是待验证候选，不是本轮批准的新实现。
4. 兼容矩阵要有“机型/SKU＋实际固件＋提供方/版本＋逐项能力＋合成行为”维度。至少覆盖2024 Android14中低端、2024/25 Android15、2025/26 Android16/17，以及旧鸿蒙4.x和新版鸿蒙APK容器；不只拿旗舰与新模拟器作样本。
5. 手机型号资料不包含私人账号和学校内容。以后取得设备摘要也只需系统/组件/功能结果，不需要登录学校、读取IMEI或完整应用清单；若加入产品诊断，按现有出站与日志契约另落实。

本轮结论是**具体平台与系统资料核对完成，实际学校兼容仍待运行证据**。不新增学校通过计数，不将用户的“最新版鸿蒙”自动解释成仍保有直接 Android APK 环境。
