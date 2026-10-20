# QA4010 Young历史状态与路由排查

2026-10-21，任务范围见[计划](../plan.md#a7-qa4010-young历史元数据与路由误判)。A7/A8继续开放。

## 当前真实证据与前轮差距

根只读用户授权MuMu安全导出USTC-Assistant-diagnostics (6).json：北京时间2026-10-21 06:27导出，complete=true、selectionTruncated=false、dropped=0、invalid=0，共514条保留事件；版本修订794185cd484d60d32876fdf1826abab19c710153，与QA4010一致。

本轮主动activities于06:26:43进入collecting，约2.66秒后在profileBefore以staleResult/mainRoute失败，没有提交。另一次每日calendar在login以waitingForSchool/pageStructureChanged暂停，不能合并归因为读取路由问题；JW随后再次committed，安全计数183。截图的“页面或作业状态已变化”与主动失败一致。与QA4009的requestTarget相比拒绝类别发生变化，但仍停在首次身份读取，不能据此宣称已完成任何真实Young查询或导入，也不能证明本次实际请求采用何种封装。

根与Astra/high只读复核发现：JS在pushState/replaceState调用原生动作之前无条件推进routeSerial，地址不变或原生最终抛异常也撤销；原生visitedHistory又无条件推进document、拒绝pending及rebind。单改其中一层不足。Android集成把history.pushState(null,'',location.href)直接写作必须失败的条件，固化了未经过规范审查的假设；此前原生transport harness不装生产SchoolBrowserEngine，不能独立证明双层生命周期兼容。

这解释了前轮测试覆盖的不足，不是已证明学校执行的具体history动作。多次返工同时包含此前共用登录回归、未覆盖的wire封装和当前生命周期误判候选；合成夹具只验证已列出的模型，测试通过不等于真实单页应用链路通过。根负责这些假设和验收差距，不归因用户操作或未经证实的MuMu内核缺陷。

## 外部语义与最小修复契约

[Vue Router3.6.5的setupScroll源码](https://raw.githubusercontent.com/vuejs/vue-router/v3.6.5/src/util/scroll.js)会用同一地址的replaceState写入历史key；这证明成熟路由器存在正常同址元数据写入，不证明学校使用该版本。[HTML历史API](https://html.spec.whatwg.org/multipage/nav-history-apis.html#dom-history-replacestate)区分同Document的历史状态与完整导航；[Android visitedHistory回调](https://developer.android.com/reference/android/webkit/WebViewClient#doUpdateVisitedHistory(android.webkit.WebView,%20java.lang.String,%20boolean))报告历史更新并提供reload标记，不能单凭回调名字断定新主文档。

只对Android Young固定业务读取允许同Document/top/origin/root/完整href不变的push/replace，且不读取history.state。原生方法仍正常执行及抛错，finally复核实际href；发生真实变更即永久撤销，A→B→A也不得接受。popstate遍历（同址也包括）、hash变化、完整同址重载、文档/root/helper变化、取消/旧步骤仍拒绝。宿主同址例外仅限已ready/非loading/!reload、已提交固定Young业务页和一致bootstrap世代，不影响CAS/JW认证动作。固定GET、opaque投影、前后身份、分页/日期完整性及C3原子提交不变。

## 实施与检查

Luna/max先制作固定原生行为红例；根保留QA4010生产脚本，在自有API32实际运行stateOnlyHistoryKeepsProfileReadValid，1项失败（24.081秒），明确staleResult/mainRoute。报告位于忽略的app/build/qa4011/reports/history-before.txt，未覆写为成功；这个红例证明工程兼容缺口，不证明学校实际history动作。

Sol负责生产双层逻辑、六个封闭history/地址原因、装配与实际检查；原生新文档拒旧沿用contextLost，仅Young页面读取的pending回调携带原因，认证与预导航不改变返回形状。以下检查证明工程行为，真实修复效果仍待MuMu允许操作后验证。

Astra/high独立复核根实际差异，未发现阻塞项，确认原生返回/抛错、真实地址变化的失效锁存、宿主同址例外及认证返回形状仍符合本切契约；也指出两步间导航可能只有通用拒绝码。根检查Luna的三份测试差异，并补齐XHR发送后同址写入、片段事件竞态的两种正确原因和实际地址变化的封闭断言。静态意见不替代运行结果。

根执行check-dart.ps1：4份Dart格式检查无变化，analyze无问题；完整Dart/widget为1566通过、1项平台跳过。Node语法检查通过，初次文档检查155份Markdown/1216条本地链接通过。

第一次修订版API32普通原生为52通过、1历史跳过、1失败（82.841秒）；正常同址replace、push及DataCloneError用例均通过，失败是片段跳转的细分原因断言。根保留原报告native-first-history-assertion.txt，再仅增加封闭原因断言消息重建定向运行，实际为historyTraversal（1失败，5.313秒），报告history-focus-fragment-reason.txt。[HTML片段导航规范](https://html.spec.whatwg.org/dev/browsing-the-web.html)明确也触发popstate，故该事件先于hashchange拒绝符合契约。根将该反例允许原因修正为historyTraversal/historyHashChanged/routeAddressChanged，仍要求staleResult、无value和仅一次请求；未修改生产拒绝行为，也不归因为MuMu故障。

修正后同一定向原生组实际通过（2.838秒），覆盖query push/replace、地址往返、片段、同址back遍历及预先捕获原生方法的地址改变。随后执行全套原生与完整来源集成，不以这个定向通过替代完整链路。

API32/WebView120.0.6099.193最终普通原生53通过、1历史私有世界反例跳过、0失败；完整生产宿主学校loopback为6组通过、1独立smoke未选（3分10秒）。Young正向启用固定helper延迟、opaque参数、原生XHR以及调用前/发送后/响应后的同址历史写入，查询与两次导入的10个固定请求仍逐项核对；实际地址往返和完整同址重载均拒旧，已有事件标识/隐藏覆盖/回执不变，之后重试及清分区通过。JW自动认证/去重和取消恢复亦执行，API32正常停止。

API34/WebView113.0.5672.136全套原生114通过、8历史高级反例跳过、0失败（113.017秒）；相同完整学校loopback为6组通过、1独立smoke未选（3分20秒）。API34也正常停止；本轮未重跑API28/29/37，不推定MuMu110、目标手机或鸿蒙结果。

Windows受影响Young自动化3组通过（30秒），仅进程内使用并还原USTC_NOTIFICATION_TEST_HOST=1，所有业务和浏览器资料均来自临时loopback夹具。Windows固定读取器及正式Release未改，夹具默认不启用Android同址例外，原Windows路由拒绝行为继续通过。Android构建、AndroidTest、lint及Release manifest检查通过；工程检查点为885b41e52e641dd3a37b69e921987ed61d7652e8，未推送。

用户随后明确授权computer-use打开现有MuMu、同签名覆盖新APK、使用应用既存加密凭据点击二课同步并导出安全日志、按结果循环排查。根已读computer-use技能及运行/确认规则；本次具体安装和固定自动认证有用户直接授权，验证码及额外授权仍由用户处理。真实UI验证独立记录，不与合成计数合并，不读取正式数据库、秘密或原始学校响应，不卸载清数据或更改系统设置。

computer-use已列出既有MuMu窗口；首次应用访问授权超时，用户明确完成授权后重试，工具报告窗口处于最小化，根未恢复或输入。随后用户说明MuMu正在运行其他任务并要求等候，故暂停全部MuMu交互，待用户明确恢复；独立代码修复、合成检查和构建继续。此时尚未安装新版、触发真实同步或导出新日志。

## 私有升级交付

工程885b41e52e641dd3a37b69e921987ed61d7652e8构建普通入口lib/main.dart，包名cn.ustcassistant.mobile.qa、版本名1.0.0-qa-a7-webview2；版本号递增为x86_64/4011和arm64-v8a/2011。签名证书SHA-256为16d3f9867f0a15d4d4ffc877bdd9ec240e92a3fddf6a0a66da857e2888846036，沿用旧QA签名，可覆盖升级，不卸载或清数据。

| 文件（忽略的app/build/qa4011/artifacts） | bytes | SHA-256 |
|---|---:|---|
| USTC-Assistant-Android-QA4011-x86_64.apk | 290991189 | `068b822d39bf09bc9871b6e7210b6a0653282b170027ce27070cea925625a692` |
| USTC-Assistant-Android-QA2011-arm64-v8a.apk | 279217899 | `064805dd3643a9cce4057539cd5e773045cae54b9a2ea5838a3e275570d11612` |

根实际核对包名/版本/签名、唯一ABI、准确Young/JW脚本哈希、普通入口与源码修订、原persona/reasoning策略、239233841字节ASR模型和许可，排除已知integration/gallery入口。最终x86_64构建29.6秒、arm64构建81.5秒，元数据均为publicRelease=false、realSchoolValidated=false；ARM64只有构建/包内容证据，未运行。

根只读复核保留的QA4010/QA2010及Windows1.00 ZIP，字节数和SHA-256与原交付记录一致；未覆盖旧包或正式Windows资料。环境、SDK/Pub/Gradle缓存、AVD和本轮临时/报告均在E盘。构建交付时MuMu仍按用户要求暂停，真实二课效果及每日calendar登录暂停待实际复验，A7/A8不关闭。

最终文档检查通过155份Markdown、1216条本地链接及现存档案manifest，Git差异空白检查通过；工程与文档分开本地提交。上述自动检查和APK核验不替代恢复操作后的真实MuMu采集结果。

## MuMu真实复验2026-10-21

用户明确恢复MuMu操作，并再次要求覆盖QA4011、使用既存加密凭据同步和导出日志，失败则继续循环。根使用已读的computer-use技能，通过文件资源管理器打开准确的x86_64/4011文件，触发其既有MuMu关联安装；运行时安全日志修订885b41e52e641dd3a37b69e921987ed61d7652e8，与已核对SHA-256的APK相符。没有卸载、清数据、处理学校授权页面或修改模拟器/系统设置；密码框保持留空，自动链路复用应用保存资料，根不读取凭据。

| 真实作业（北京时间） | 根实际动作与结果 | 证据边界 |
|---|---|---|
| calendar，07:29:34→07:29:53 | 点击既有范围的同步按钮，自动完成login、collecting、committing，最后idle/committed，安全计数0 | 本次已有31日选择提交0条活动关联日程；不读取原始日历行，不能据此记非空导入通过 |
| activities，07:31:10→07:31:28 | 点击活动查询，自动完成读取并idle/committed，安全计数102 | 覆盖此前实际失败的活动入口和当前全分页查询；未操作报名，不宣称本人报名状态 |

两次均无需根或用户补输密码、点击学校登录继续或选择登录后页面，没有新失败码。closing与idle的同一trace提交事件只代表同一次作业，不计作两次导入。没有直接检查正式数据库、学校响应或活动明细；只消费UI状态及固定安全日志。此前QA4010真实失败保留；本次相同私有包的两条真实链路成功，不反推学校具体history实现或唯一历史根因。

根在应用点击“导出日志”，通过系统保存界面写入既有MuMu共享文件夹，两次均观察到“日志已导出”。随后只读核对，并原样复制到忽略的app/build/qa4011/reports/live，复制前后哈希一致，文件不入Git：

| 安全导出 | bytes / 保留事件 | SHA-256 |
|---|---|---|
| USTC-Assistant-diagnostics (7).json，07:30:06导出 | 200017 / 537 | `7d2e4950ab3a5eb28ee38bfb2fb3d8a62cbe2730569aef710cf93c40a27e958e` |
| USTC-Assistant-diagnostics (8).json，07:31:35导出 | 204958 / 550 | `70fb6a77d865e85047335753e1e4c39065f60d9c85e036e96a8821b086a85cb6` |

两份均为ustc-diagnostics-export-v1、complete=true、selectionTruncated=false、dropped=0、invalid=0，版本均指向885b41e。构建时的artifact manifest保持realSchoolValidated=false原事实，本节单独记录后来发生的有限真实证据，不重写旧构建报告。

根尝试将范围改为用户此前确认有活动的9月以补非空验证，但本轮computer-use发送的按键和文字没有改变日期值，原因未独立确认，额外作业没有发起；屏幕确认原日期选择保持。该附加项未完成，不记作学校采集失败或已确认的产品输入缺陷，也未借此改变模拟器配置。非空日程、用户业务明细对应和目标手机/鸿蒙验收继续保留。

启动时另有一条无trace的youngDailySyncState/waitingForSchool状态投影；它没有伴随本轮新的每日来源作业，不能与上述手动作业混为一次失败。根未独立触发每日当前滚动窗口，不宣称每日自动同步已补验。旧浏览器待清理提示仍保留，没有执行清理。没有新增工程修复，A7/A8仍开放。

本轮仅更新真实验证记录与当前状态，运行文档检查155份Markdown/1217条本地链接及档案manifest通过，Git差异空白检查通过；以独立文档提交保存，未因记录更新重复工程测试或重新构建APK。
