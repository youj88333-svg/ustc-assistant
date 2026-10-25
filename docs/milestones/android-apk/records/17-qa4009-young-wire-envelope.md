# QA4009 二课请求封装排查

2026-10-19。任务边界见[唯一任务单](../plan.md#a7-qa4009-二课请求封装兼容)，不关闭A7/A8。

## 最新真实证据

用户覆盖QA4009后确认教务自动认证恢复，二课登录后同步仍失败。根只读固定安全导出 `USTC-Assistant-diagnostics (5).json`：北京时间2026-10-19 18:05导出，complete=true、invalid=0、dropped=0、selectionTruncated=false，新事件工程修订为 `95a6451a753de3b82ec764df18be93473fe321ca`。

Young的calendar每日尝试与activities主动查询均越过登录准备进入collecting，约1.8秒后以invalidSnapshot/requestTarget失败，具体步骤为profileBefore；作业没有推进到日历或活动读取阶段、没有提交，不推断学校页面自身的后台请求。JW在同份日志中到达committing及committed，安全计数183。用户反馈和当前日志共同确认上一轮共用认证修复的教务效果，不据此补造其余真人项。

根对照Windows发现Android强制检查所有wire查询明文键，profile只允许空查询或_t；当前Windows固定helper构造同样参数，但原生关联在问号前截断路径，不解释查询值。M2原实证明确记录“不读取或解密不透明requestParams”，见[当时记录](../../m2/records/02-contract.md)。现行普通WebView信任学校同源helper；Android移植及夹具未覆盖该框架封装。

requestTarget涵盖多种拒绝原因，因此最新导出不能证明实际请求一定包含requestParams，也不能据此确认唯一真实根因。本切先补上有历史依据的兼容缺口，同时细分封闭拒绝原因，便于后续仍失败时准确排查，不读取或导出实际URL/参数。

## 实施与实际检查

Astra/high独立只读核对Windows固定入参/路径关联、M2记录与已批准Android同源信任边界，认可两种互斥wire形状的修复方案，并要求同步修订现行来源契约；这不替代根检查或真实MuMu复验。Sol负责生产脚本/映射及装配，Luna/max仅修改不重叠的原生测试和Young合成夹具。

根保留QA4009的原传输脚本，在自有API32先运行新增合法profile封装用例，实际1项失败（2.897秒），预期value信封却收到error，报告保存在忽略的 `app/build/qa4010/reports/opaque-before.txt`。旧共用断言只打印信封键，未输出error.reason；临时编排额外要求文本含requestTarget因而也失败。这不改变原生反例结果，但不补记未实际打印的原因。

Sol兼容固定helper传参后的单个不透明封装，仍拒绝混合/未知/重复参数和错误目标。明文检查保持，新增五个封闭请求子原因贯通原生、Dart与诊断；未知异常仍丢弃正文。完整URL仅用于当前步骤一致性，交付/取消/结束清引用；Astra复核指出未send的XHR映射也需清理，根补齐每步有界open记录及按记录身份撤销，防旧回调误删新映射。该静态复核不证明浏览器内部URL或运行时GC被清除。

根审查后接管测试冻结与剩余修正，包括恢复作业时轮询新的operation。第一次修复版API32普通原生为48通过、1跳过、2失败；合法不透明profile及两端点连续读取均通过。两个失败来自新增测试自身：缺失封装的活动用例仍打开了日历页面；非法XHR body已同步拒绝却被断言为dispatch成功。根修正路由和拒绝时机，保留原失败报告 `app/build/qa4010/reports/native-first-green-fixture-failures.txt`，随后重建复验，没有为测试放宽生产控制。

第二次为49通过、1跳过、1失败：新增取消用例错误预期外层已结束作业的poll返回staleResult，实际固定page-call包装先以sourceFailed/sourceFailure拒绝，未调用内层transport。根据现行契约修正该精确断言，仍要求零请求、无交付及新operation成功；原报告保留为 `app/build/qa4010/reports/native-second-fixture-failure.txt`。没有修改生产包装层或将这两个测试编排缺陷归因为真实MuMu故障。

## 根最终检查

根analyze通过，共享Dart/widget全套1566通过、1平台条件跳过（1分21秒），包括所有Young原因的封闭映射。

| 独立环境 | 原生实际结果 | 完整学校loopback |
|---|---|---|
| API32 / Android12 / x86_64 / WebView120.0.6099.193 | 普通原生50通过、1历史私有世界反例跳过、0失败 | 六组通过、1独立smoke未选（3分06秒） |
| API34 / Android14 / x86_64 / WebView113.0.5672.136 | 全套原生111通过、8历史高级反例跳过、0失败 | 六组通过、1独立smoke未选（3分07秒） |

完整Young正向及失败/恢复组实际启用合成不透明封装；服务端解开的是夹具自造Base64 JSON，核对固定入参、两页活动和逐日now，正向查询/两次导入共10个业务请求均断言对应参数。该模拟不代表真实学校密文格式或其内容已经被独立证明。JW继续使用QA4009隐藏辅助表单/镜像夹具，自动认证、取消及事务均执行。原生覆盖明文与封装、fetch/XHR互换、重复/空/大小写未知/混合参数、错误origin/path/GET、HTTP/解析、helper拒绝、未send的取消及新作业恢复。

Android QA构建、AndroidTest、lint及Release manifest检查通过。受影响Windows Young自动化三组通过（27秒）；仅进程内使用并还原USTC_NOTIFICATION_TEST_HOST=1，Windows生产代码与正式Release未改。JS语法及普通Git差异空白检查通过，工程检查点为 `794185cd484d60d32876fdf1826abab19c710153`。

两自有AVD均正常停止；自动检查仅合成/loopback，不访问学校或模型，SDK/缓存/AVD及临时都在E盘。当前真实反馈只确认QA4009教务恢复；QA4010的Young实际效果尚待用户覆盖复验，不关闭A7/A8。

## 私有升级交付

普通入口 `lib/main.dart`、源码修订 `794185cd484d60d32876fdf1826abab19c710153`、包名cn.ustcassistant.mobile.qa、版本名1.0.0-qa-a7-webview2；同签名证书SHA-256继续为 `16d3f9867f0a15d4d4ffc877bdd9ec240e92a3fddf6a0a66da857e2888846036`。版本号递增为x86_64/4010及arm64-v8a/2010，可以主动同签名覆盖对应ABI的旧QA资料，不卸载或清数据。

| 文件（忽略的app/build/qa4010/artifacts） | bytes | SHA-256 |
|---|---:|---|
| USTC-Assistant-Android-QA4010-x86_64.apk | 290990854 | `357223f35ad2468b30c5d110b0b7f5883b0572c35c698ac959fad9def2afaf94` |
| USTC-Assistant-Android-QA2010-arm64-v8a.apk | 279217667 | `a4a0a1a2d113864d5f6f9a562ea7a82ea508f7d8d9e001112f6934504ffa589a` |

根核对普通入口、唯一ABI、版本及签名、准确的Young/JW固定脚本哈希、源码修订、既有persona/reasoning策略、239233841字节ASR模型和随包许可；排除已知集成/gallery入口。元数据保持publicRelease=false、realSchoolValidated=false，ARM64只完成打包/内容核验而未实机运行。旧QA4009/2009和Windows1.00 ZIP继续保留，没有自动安装MuMu或替换Windows正式交付。

交付后根复核旧QA4009/2009及Windows1.00 ZIP的字节数和SHA-256，均与记录16一致。文档检查通过154份Markdown、1214条本地链接及现存档案manifest，普通Git差异空白检查通过。真人范围只需主动覆盖QA4010后重试Young，失败则导出新安全日志；不要求重复已获确认的教务认证，也不要求卸载、清数据或清登录资料。
