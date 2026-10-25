# MuMu来源建窗失败与诊断入口修复

日期：2026-10-17。依据[本切契约](../plan.md#a7-mumu首轮反馈修复契约)、07/09的来源隔离与清理、13 V-07/V-08及15工作流。用户反馈点击教务/二课无反应、未找到日志导出；后续截图显示教务恢复态及`staleResult`。这是A7人工发现后的修复，不是A7真人关闭或A8正式发行。

## 现象、证据与根因

MuMu已由用户启动、安装并操作。只读宿主元数据与Guest系统版本：宿主5.30.1.3586，Android12/API32，支持x86_64/arm64-v8a等ABI；实际提供方为`com.android.webview` 110.0.5481.154.1。截图中的Galaxy S24 Ultra是模拟设备资料，不能据此推断Android或WebView版本。系统能解析`ACTION_CREATE_DOCUMENT`至DocumentsUI，不支持“没有系统文件保存器”的推断；这也不证明用户已完成实际保存。

先逐项审计原生`UstcA2`标签只输出固定方法/阶段/失败码，再只读取该标签并统计：`unsupportedPlatform` 1次、`staleResult` 15次、`sourceFailed` 0次。没有读取正式业务库、学校响应、网页URL/内容、密码、Key或认证资产，也没有安装、卸载、清空、强停或升级用户MuMu/WebView。

真正的首次拒绝来自WebView能力检查，发生在原生会话创建之前；上层随后按“native已开始”关闭该session，原生却没有保存该次未创建会话的关闭证明，后续`staleResult`覆盖了原始原因。正式来源协调器还在发现能力不足前启动C3作业/临时分区，进入了旧提供方无法执行的恢复清理。问题不能靠反复点击或修改模拟机型解决。

日志原入口已存在于“设置→数据与隐私”，但来源页无直接入口，本地状态未读成功时也看不到日志卡；维护恢复页同样缺少导出。MuMu有DocumentsUI，只能说明具备保存选择器，仍须用户主动验证实际选路径和保存。

## 修订与保留

- C2先同步取得全局租约，再以Android固定无参数`checkSupport`预检；位于新C3作业、凭据暂存和分区创建之前，5秒上限。无本次资产的拒绝释放租约并回idle，取消/关闭优先于迟到结果；不借预检失败触发旧作业调和。Windows端口默认不调用此方法。
- 直接观测入口也保留预检，但在已有pending恢复之后；原生`open`仍即时复验。合法open在能力拒绝前没有创建会话时，仅记录该session可幂等close/drained；其他session、既有owner和live会话仍拒绝。此证明不是Profile删除证明。
- 未采用“原生账本缺项就视为已清理”：账本本体和备份都缺失与从未创建不能等同。既存恢复/未知分区继续受原契约约束，旧提供方仍可能无法恢复，必须更换到具备所需能力的受支持提供方后再恢复；没有清库或伪造清理成功。
- 设置标题旁增加直接日志导出；状态读取失败时保留数据与隐私日志卡，维护恢复页也可导出。继续使用既有安全白名单和Android SAF，取消/失败不报保存成功，不扩展采集内容。
- 来源提示明确网页组件能力问题，恢复按钮不再误导为关闭一个未出现的窗口。已提交数据但关闭失败的提示优先级保留。QA提升为4003，同签名覆盖，不用卸载绕过降级保护。

Sol负责诊断、跨层实现、装配与根验收；Luna/max分别只读核对日志出口、补设置/维护导出行为和预检行为测试，文件不重叠。Astra独立复核账本缺项推理与最终预检/取消边界，没有替代根实际运行。

技术依据：[Android WebViewFeature](https://developer.android.com/reference/androidx/webkit/WebViewFeature)要求按实际提供方检查能力；[Chromium提供方说明](https://chromium.googlesource.com/chromium/src/+/c831dd85ffd4d15e91dcf524cbf1d6100808e347/android_webview/docs/prerelease.md)说明Android10及以后Chrome不等于系统WebView。未找到已核验的MuMu专用升级办法，不建议用未知APK、改系统信任或降低隔离取得表面可用。

## 检查过程

首次analyze发现跨接口类型提升不成立（6处getter/method解析及2处格式提示），已显式转换可选端口并整理格式，后续analyze无问题。首次全套Dart为1526通过、1平台跳过、2失败：Young测试把两层预检实现次数固定为2，实际为3；JW取消后重试的fake仍保持unsupported。修订测试前提与行为断言：首次拒绝仍必须只预检且零native open；成功重试验证结果、租约和提交，不锁定内部调用次数；JW恢复fake支持后才重试。不改变产品门禁或降低失败/取消断言。

报告位于忽略的`app/build/android-a7-fix1/reports/`。

| 检查 | 根实际结果 |
|---|---|
| 静态与全套Dart | `analyze-final.txt`无问题；`dart-all-final.txt`为1528通过、1平台分支跳过，3分58秒。覆盖预检拒绝无新作业/凭据/分区、原成功许可与目录保留、C2租约、双击/取消/关闭迟到、恢复后重试，以及320/360dp大字日志入口、状态不可读和维护恢复中的保存/取消/失败 |
| Windows共享回归 | 教务7组、二课2组、设置维护3组、安全日志3组，共15组通过，分别见`windows-*_flow.txt`。仅loopback/临时库/固定合成，使用进程级`USTC_NOTIFICATION_TEST_HOST=1`并恢复；未替换Windows1.00正式包 |
| API34实际旧提供方拒绝 | `integration-A7_Source.txt`两组通过：正式JW/Young预检失败后未存凭据/未建来源分区，租约释放且可提交个人安排；直接普通/恢复open仍拒绝，只有该次session可close/drained，错误session仍`staleResult`，未宣称旧Profile已删除 |
| API34手机/原生 | `integration-A4.txt`一组通过，普通根实际注入的设置日志按钮在360dp可命中、无溢出，手机日程/任务/草稿/重开/白名单保持；原生76项中67通过、9因实际提供方缺能力跳过、0失败，见`api34/native-final.txt`及计数。不是用户实际SAF选路径保存或真实手机验收 |
| 当前提供方原生与学校桥 | API37/16KB、WebView149.0.7827.5原生76项全通过，`api37/provider-final.json`四项能力及隔离往返均true；`integration-A2-current.txt`六组通过、1旧提供方专属分支跳过。实际原生预检已启用，导航/frame/弹窗/外部协议、JW取消/关闭/自动认证/去重、Young重定向/共享凭据/活动关联记录、身份/不完整分页保留及同URL文档拒旧仍成立；全部loopback合成，不是实际学校 |

工程检查点为`d3fe74556c57a1e10cfe43bcfe7f720ac1326978`，仅提交21份工程/测试/运行器文件，不含构建目录、资料或文档；新包使用该提交的普通入口构建。

## 修订包与保留核对

最终`build-final.txt`退出0；普通QA、AndroidTest、Release合并清单和lint均生成，`build-products.json`复核lint为0错误/79警告。Release清单继续禁止备份和明文，无Debug探针/文件提供方；没有构建或签署A8正式发行APK。

新包为`app/build/android-a7-fix1/artifacts/USTC-Assistant-Android-A7-QA-fix1-x86_64.apk`，290833683字节，SHA256 `650636254ea8dad2aef546cad962f6e7698f06048e3e2e832287470ba3463700`。包名仍为`cn.ustcassistant.mobile.qa`，`1.0.0-qa-a7-fix1`/4003，仅x86_64；Debug证书仍为`16d3f9867f0a15d4d4ffc877bdd9ec240e92a3fddf6a0a66da857e2888846036`。校验kernel含上述源码号且为普通入口、排除集成入口，三个模型文件摘要和五份许可/NOTICE完整；manifest、版本、签名和SHA报告随新包保存，不覆盖原4002交付。

同签名覆盖至独立当前提供方AVD后，以普通MainActivity冷启动成功，8661ms，当前QA进程crash缓冲无崩溃；根查看`api37/ordinary-phone.png`，Agent空对话、设置及双主页正常，未配置模型或请求麦克风/通知权限，两许可均false。没有安装到用户MuMu，不把官方AVD首屏解释为该MuMu已可登录学校。

Windows1.00 ZIP、A6 APK和原A7 4002 APK的前后SHA256均一致，Windows基线标签仍为`e9746b9013df2aafa2f04cdb5d740ecb4c75f5e9`；报告为`preservation-before.json`/`preservation-final.json`。两参考工作树的完整untracked状态查询遇到权限/长路径警告，只取得元数据，未打开列出资产的内容；其计数与历史normal模式不可比较，不能作为逐文件未变化证明，不继续遍历。源代码只在本工作树修改，未接管其他分支资产；未推送、公开发布或修改系统WebView/信任。

测试完成后关闭两台官方AVD与专用ADB5038；固定两文件白名单、工作区绝对路径、无重解析点及独占读取验证后，仅删除本轮再生的`ram.img`，不递归删除目录。`ram-cleanup.json`记录文件长度合计及实际E卷可用空间均变化6979452928字节（约6.50GiB）；四份受保护新旧交付物摘要复核不变。AVD用户盘、SDK/Gradle/Pub、模型与签名、全部报告和APK、MuMu及C盘原资产继续保留。

## 当前边界

此修订消除新尝试的错误恢复陷阱并恢复诊断可达性，不能让WebView110获得缺失的隔离/清理/私有世界能力。用户已有MuMu恢复态是否在受支持提供方上成功恢复、新版实际日志保存与学校登录仍待真人；旧数据/凭据和分区保留，不能把缺能力的明确拒绝记作学校同步通过。其他A7实机、鸿蒙、真实模型/麦克风和厂商通知条件继续保留。
