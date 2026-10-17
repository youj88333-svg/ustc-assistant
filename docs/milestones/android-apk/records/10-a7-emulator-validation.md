# A7模拟器先行验证与MuMu交付

日期：2026-10-17。依据[批准计划的A7契约](../plan.md#a7模拟器先行与人工交付契约)及07–15；用户要求完成模拟器可验部分，实机项保留。本轮模拟器部分已完成并导出普通入口QA包；不作A7真人关闭或A8公开/正式发布。

## 范围和发现

Sol/max负责环境、关键修复与集成；Luna/max只读审查，并在固定文件范围分别补原生点击恢复和Dart重试行为测试。只用官方独立QA/合成/loopback，不访问真实学校、模型、麦克风、Windows正式记录或MuMu用户磁盘。

审查发现原生通知点击只在持久镜像标记clicked，待交接目标仅存在内存，冷进程在Dart读取前退出会丢失目标；C3解析暂时失败也因原先吞异常而丢失点击。已修为既有镜像中的有界待交接标记，旧条目向后兼容且不复播旧clicked，维护/取消/epoch/过期仍拒旧；Dart对存储/未知临时失败按1/2/4秒有限重试，明确无效结果仍舍弃。原生交给Dart后的崩溃不宣称恰好一次UI导航，C3始终重新校验目标。

两项浏览器原生测试原先在缺少私有世界时直接return，现改为Assume跳过，防止把未运行算通过；不降低学校采集门槛。A7新增API34独立AVD与系统强停/重开、过期、深度休眠，以及普通入口真实合成通知到日程/任务的检查。

## 环境准备与保留

SDK/Gradle/Pub/AVD/临时目录继续E盘，专用ADB5038，只设进程环境。API34官方下载零字节停滞，停止该下载后以既有7897代理作有界分段下载；只接受官方元数据的1563721130字节及SHA1 `e0f6c9a0691aa27bd597d0deb1bcfdc943ac8ca7`。Windows .NET解包器报告local file header错误；本机既有7-Zip对摘要一致的官方包解压，报告Headers Error警告及文件CRC解包成功，随后实际启动完成。该工具未访问MuMu实例资料。下载摘要、早期失败和解包报告保留；完成后删除冗余下载副本和解包暂存，见后文。

MuMu宿主5.30.1.3586位于D盘，唯一既有实例启动状态为false。只读盘点宿主/启动元数据，没有创建、启动、清空、升级或接管用户实例；APK与步骤供用户主动安装。[设备矩阵](../device-matrix.md)和[人工测试说明](../manual-validation.md)分别记录条件及留待验收项。

## 根检查

首次提醒行为测试21项通过、1项失败，失败发生在fakeAsync中等待维护/close Future的完成标志。改为真实await关闭并跨过首个重试截止；第二次22项通过，仍断言不重试、不导航，其他退避用例保留fakeAsync。初次失败不改写为通过。

API34首次A4界面回归在800×360、两倍字和180像素键盘时溢出37像素；完整诊断定位日程根Column只剩24像素高度。夹具把DPR改为1，却保留原1080像素设备136像素的顶部安全区，导致不同系统的视口指标不一致。已显式设24逻辑像素安全区，键盘打开时padding.bottom归零但viewPadding保留24；尺寸/字号/键盘和溢出断言均不削减，随后A4通过。未据此改动产品布局，原失败及完整诊断日志保留。

A5首次在新API34失败为`disabledBySystem`，因为此前系统边界脚本按约定恢复了通知拒绝状态，发布测试没有声明权限前提。运行器现只对固定独立AVD中的A5授予通知测试前提、结束恢复原拒绝状态，不更改正式用户权限；随后A5通过。拒绝场景仍独立保留，不把授予前的失败改写为产品成功。

QA版本码由4001提高为4002，split x86_64和非split集成统一，继续`--no-uninstall`。新增镜像字段仅保证向前读取旧条目；禁止隐式降级安装旧的严格读取器，不把保留旧APK解释为支持逆向读取新镜像。正式签名/版本仍属于A8。

普通入口点击的首次验核使用`am instrument`，但Android在开始/结束instrumentation时会强停目标包；实际ActivityManager日志证明被测闹钟/通知被测试本身撤销。删除该无效测试类，改用仅Debug的固定Activity驱动：只选择唯一的A7合成标题与本应用通知tag，发送该通知实际持有的PendingIntent；独立`uiautomator dump`核对普通MainActivity及真实详情控件，不在被测进程挂instrumentation。不会读取真实业务通知，不把程序触发PendingIntent称为真人通知栏手势。

独立驱动另暴露两处宿主断言问题：Android14输出`topResumedActivity=`/`ResumedActivity:`，不同于最初脚本假设的`mResumedActivity:`；Windows PowerShell5将无BOM的UTF8脚本按ANSI解析，中文断言成为错误码点。实际截图/可访问节点已显示正确日程详情；保留失败报告，修正字段匹配及以固定Unicode码点构造合成标签后复验。宿主脚本的失败不记为产品导航失败，也不把未复验的任务定位预记为成功。

首次宿主stderr处理导致运行器表面失败，但合成C3写入已完成；下一次夹具严格拒绝重复种子。A7夹具改为只通过C3删除本测试精确标题和类型的旧合成对象后重建，保留A1日程/任务，发现未知记录或多份自身种子仍拒绝。既有正式QA升级保留先于种子检查完成；没有通过卸载、清库或直接改业务表消除失败。

## 根实际结果

以下报告路径相对`app/build/android-a7/reports/`。测试只使用独立QA、临时资产、固定合成WAV和loopback；没有真实学校/模型请求或真实麦克风。API36的A1–A6历史结果仍留原记录，本轮不补记重复执行。

| 检查 | 根实际结果与证据 |
|---|---|
| 静态/全套Dart | 最终analyze无问题，`analyze-final.txt`；全套1517通过、1平台分支跳过，3分1秒，`dart-tests.txt`。本切提醒协调器22项均通过，覆盖有限重试、明确拒旧及维护/关闭取消；未知异常只记固定失败码，不泄露内容 |
| Windows共享回归 | M6五组通过，`windows-m6.txt`；原生SQLite临时库、Agent提醒写入/撤销/对账、维护故障与独立Debug通知入口均验证。进程级`USTC_NOTIFICATION_TEST_HOST=1`，不替换Windows1.00正式包 |
| Android构建 | `tools/android-a0.ps1 -Action Build`退出0，依次请求普通x86_64 QA及AndroidTest/Release合并清单/lint；Gradle采用quiet输出，`build-route-driver.txt`只显示Debug构建进度，不作为各任务详细日志。实际生成AndroidTest用于下列两环境原生运行；`build-products.json`复核其摘要、Release清单排除/备份/明文规则及lint XML的0错误/79警告，普通包另见artifacts/manifest.json。不是A8完整Release/所有ABI验收 |
| API34原生 | 最终76项中67通过、9因实际提供方缺能力跳过、0失败，`api34/native-final.txt`和`native-final-counts.json`。原生待交接恢复7项均通过；旧的77项批次含后来删除的无效点击类，不混作最终计数 |
| API34底座/升级 | A1六组通过，4001→4002同签名升级后`VerifyRetained`六组再通过；A1已有一条合成日程与一条任务保留且未静默重播种，`integration-A1.txt`、`upgrade-retention.txt`。这一步发生在新增A7种子前，不在已有额外种子时复用“一条”前提 |
| API34 Agent/公开/界面文件 | A3两组、A3_Public一组、修正夹具后的A4一组通过；实际HTTP合成Key/SSE/工具/C3操作和停止恢复，七份公开材料私有事务，手机大字/键盘/返回及固定文件提供方验证，分别见`integration-A3.txt`、`integration-A3_Public.txt`、`integration-A4-final.txt` |
| API34来源缺能力/提醒 | 新A7_Source一组通过，获取与恢复清理均明确`unsupportedPlatform`，不报清理成功；A5一组通过。见`integration-A7_Source-second.txt`、`integration-A5-second.txt`；名字含final的A5文件实际仍是先前权限前提失败，不用文件名推定通过 |
| API34实际系统边界 | 深度休眠投递、观察到强停后显式重开恢复未来提醒、强停期间过期不补发均通过，`api34/summary.json`。不声称所有系统版本都会在强停时独立撤销OS队列，不承诺强停期间通知 |
| API34普通入口通知定位 | A7 C3合成种子一组通过；日程、任务实际系统通知的PendingIntent分别从无QA进程起步，进入普通MainActivity并由C3解析到各自详情。`click-event.json`、`click-task.json`均success，根查看两张截图且核对可访问节点；固定驱动而非真人手势，原宿主失败报告保留 |
| 当前提供方/16KB原生 | Android17/API37（镜像37.2），实际页大小16384，WebView149.0.7827.5；76通过、0跳过/失败。多Profile、独立删除、document-start和私有执行世界均为true且隔离往返成立，`api37/native-final.txt`、`provider-final.json` |
| 当前提供方合成学校桥 | A2六组通过、一个旧提供方专属分支跳过，`api37/integration-A2.txt`。覆盖导航/frame/外部协议拒绝、JW取消/关闭排空、固定自动认证/密码保护/去重与分区清理、Young实际形状重定向/共享凭据/活动关联日程、身份不符/分页不完整保留旧资料、同URL新文档拒旧/重试。全部为loopback合成，不是实际学校 |
| 当前提供方模拟低电量 | 观察到模拟10%电量且power saver=1，在该前提下深度休眠、强停重开未来投递和过期不补发通过，`api37/power-state.json`、`summary.json`。结束恢复power saver=0及电池100%/AC，清空的仅是自有合成OS镜像；不宣称厂商省电或真实低电量可靠性 |
| 实际ASR/合成中文 | API34和当前16KB环境各一组通过，`api34/asr.txt`、`api37/asr.txt`。包内SenseVoice实际CPU推理、固定合成WAV录音后端、关键词、可编辑草稿/取消均成立，网络尝试0、无真实麦克风、无自动发送 |

API34旧WebView为113.0.5672.136：MULTI_PROFILE、DELETE_BROWSING_DATA和私有执行世界为false，DOCUMENT_START为true，`api34/provider-final.json`。不能将该环境本地功能通过解释成学校同步可用；同样不能把缺能力归因为Android14系统本身必然不支持，能力按实际提供方决定。

### 合成语音资源观测

两环境均为官方x86_64 QA/Debug，固定5045ms本机TTS中文WAV。以下是整个进程的RSS，包含Flutter/测试/SQL等，不是语音独占或Release手机基准；仅检验固定关键词，不推断课程术语准确率或真实收音。

| 环境 | 首次准备/复用 | 两次解码 | 初始/解码后/关闭后RSS（字节） | 进程峰值RSS（字节） |
|---|---|---|---|---|
| API34/4KB | 18656 / 0 ms | 346 / 443 ms | 380547072 / 712843264 / 464646144 | 745009152 |
| API37/16KB | 9866 / 0 ms | 388 / 372 ms | 449118208 / 799277056 / 545013760 | 814452736 |

## QA交付、保留与清理

最终代码来源`7d3005bc3077c42cc43cd12e5b631bf679a574e2`，关键修复提交`5fc966520769e53d7d7e5664bea573226485bf44`。普通包位于`app/build/android-a7/artifacts/USTC-Assistant-Android-A7-QA-x86_64.apk`，290827173字节（约277.35MiB），SHA256 `adb073e65d60ce2fd1182abdff1d33ee7aae7f884366bc371132350230307df8`；同目录保存manifest、签名、版本和摘要。包名`cn.ustcassistant.mobile.qa`，`1.0.0-qa-a7`/4002，仅x86_64；既有Debug证书SHA256 `16d3f9867f0a15d4d4ffc877bdd9ec240e92a3fddf6a0a66da857e2888846036`。无正式签名，不称为手机1.00发行版。

已核对kernel内源码号、普通`lib/main.dart`且不含集成入口，三个固定模型SHA与五份NOTICE/许可、仅x86_64及必要语音库。Release合并清单无Debug探针/提供方、保留禁止备份和明文规则；实际QA自身包含仅Debug的固定合成组件，A8仍须验Release排除。不能用这些检查替代arm64、完整16KB Release或正式签名升级。

最后以同签名覆盖安装该普通包，未卸载；当前16KB AVD冷启动`Status: ok / COLD`，5719ms，当前QA进程crash缓冲无崩溃；根查看`api37/ordinary-phone.png`，正常Agent空对话/模型待配置、麦克风及双主页可见。通知和麦克风权限均为false，未自动申请，`ordinary-version-permission.txt`。没有配置真实Key或学校凭据，不据首屏可见声称真实服务通过。

Windows1.00 ZIP与A6 QA包SHA256、当前APK摘要及`windows-v1.00`解引用提交均复核不变，`preservation-hashes.json`；未替换Windows正式运行包，未写main或flutter-native。既有两参考工作树仍各48项和3项状态条目；计数只用于发现意外变化，不证明逐文件内容相同。

结束后关闭两台官方AVD和专用ADB，固定白名单核验路径在本工作树、Git忽略、全树无重解析点及所有文件可独占读取，仅删本轮下载副本/两份解包暂存和两台已关闭AVD的再生`ram.img`。按文件长度合计10164612216字节（约9.47GiB），E卷可用空间从183465762816增至193630412800，变化10164649984字节；记录实际两种指标，不把它们视为恒等。清理前再次核对官方ZIP SHA1及保护包，清理后保护包不变，`generated-cleanup.json`。SDK、全局Gradle/Pub、报告/APK、签名、模型源/缓存、AVD用户盘和MuMu既有资料均保留；不改C盘原资产、全局环境、代理或系统信任。

## 保留项目与当前结论

A7模拟器可验部分完成，MuMu安装与真人体验尚未发生，步骤见[人工说明](../manual-validation.md)。目标arm64 Android、具体APK鸿蒙/兼容层、真实学校与模型服务、实际麦克风中文/来电、真实相册/日志保存、通知栏手势/锁屏及厂商省电、发热耗电和长期网络仍保留。当前提供方16KB x86_64开发样本不是全部ABI或目标机证明；旧WebView缺能力不绕过隔离。原Windows语音失败、JW非空考试后补等原有未观察项不改写。未创建真人acceptance或提前关闭A7，A8正式签名/Release/最终私有交付仍待推进；未推送或公开发布。
