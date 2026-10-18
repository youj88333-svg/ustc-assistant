# 普通系统 WebView 实现与兼容验证

日期：2026-10-17–18。依据[已批准兼容修订](../../../decisions/android-system-webview-compatibility.md)、[A7-W1–W6](../plan.md#a7普通系统webview兼容修订已批准)、07/09/13及15工作流。实施仍属于A7；不以合成结果关闭真人验收或进入A8正式发行。本文记录根的实际结果，早期失败保留。

## 实现与保留

Sol负责普通浏览器、Binder生命周期、分区账本、C2迁移和集成；Luna/max承接固定脚本、界面端口及不重叠的合成测试，Astra按具体恢复问题复核。只操作本工作树和独立官方模拟器，SDK、缓存、AVD及临时文件继续E盘；没有访问真实学校、模型或正式业务/认证资产，没有安装、升级或清理用户MuMu。

主进程保留单一Flutter引擎及C2/C3，学校WebView放入同UID、非导出的`:school_host`。先落盘随机后缀映射，再在子进程第一次WebKit调用时设置`setDataDirectorySuffix`；切来源/分区必须结束旧进程。父Binder死亡、renderer退出、取消与关闭均收口；正常结束后需要确认旧PID消失、精确宿主进程不存在及排他槽位连续空闲，不能仅用`destroy()`宣称排空。卡住时只对已核对UID、进程名和已知PID的自有学校进程执行有界终止。

普通世界固定脚本通过`evaluateJavascript`回调返回，凭据仍用CAS精确origin的一次性消息投递，不进入求值文本或通用页面到Java入口。取消、document/operation戳、身份前后核验、只读固定GET、分页/日期完整性、1MiB响应上限及事务导入保留。接受学校同源脚本信任及正常后台网络；不再要求多Profile、私有世界、doc-start、Navigation API或全frame握手。实际未交给原生的iframe请求不能承诺零流量。

旧C3许可只在平台后端核验成立时复用；旧后端许可在新作业暂存前撤销，经原恢复流程释放占位，再用新后缀重新认证。课程、考试、二课日程及个人覆盖、共享加密密码和目录不随浏览器迁移删除。健康新后端分区正常保留。

平台账本只记录哈希引用、随机后缀、来源/暂存属性、生命周期、布局观察和可取得的提供方元数据。账本遗失时仅枚举受控后缀目录名登记orphan，不读取浏览器内容；未知布局不猜测删除。旧Profile元数据缺少独立布局覆盖依据，因此保留停用及物理清理待办，不能以两个猜测路径不存在宣布清空。已证明隔离的新后缀和本地能力可继续使用；旧执行体、撤销或事务状态不明仍保持恢复屏障。设置单独显示残留并提供受C2租约保护的重试，不宣称“关闭”等于“已删除”。仅确定需要新建后缀时检查16份待办上限及256MiB可用空间，恢复清理和健康分区复用不被新建预算反向阻断。

## 发现与修正

1. 最初Dart交叉接口类型提升和Kotlin尾随回调的默认参数顺序不成立，构建发现后改为显式端口转换及闭合回调签名。原生返回处理另改用Android33+返回dispatcher与旧版按键路径，修复lint的预测返回错误，不靠整体屏蔽检查。
2. Astra指出账本遗失会漏掉原后缀残留、open中途失败会重复回答pending，以及legacy猜路径清理可能误报完成；分别增加orphan、统一单次收口和持续legacy待办。复核又发现另一broker重试清理可越过旧owner，现增加owner门禁并复用同一进程的账本实例，避免Activity重建产生两份可写快照。
3. 首轮全套Dart为1533通过、1平台跳过、3失败：两个界面仍期待“已清理”旧文字；新JW测试误以为课表加考试只有一条。修正为“已关闭”和按课程类型定位，仍验证localId、隐藏、凭据及另一来源保留。随后全套1536通过、1平台跳过。
4. 旧113完整集成首次有两处失败：旧frame测试要求所有iframe请求零流量，已按批准边界区分可观察拦截和不完整覆盖；QA“点击关闭”的RPC先发关闭事件再回结果，主协调器正确取消后使测试收到stale。仅QA固定关闭操作改为先答请求已接受，再发用户关闭，真实关闭仍等待根排空。
5. 二次完整集成有五组通过，一组在已正确拒绝同URL旧结果后仍要求页面专属reason非空。普通原生history回调可能先于页面守卫拒绝，因此改为必须`staleResult`、零提交且旧数据/覆盖不变，页面守卫先观察时再核对其`stampChanged/mainRoute`；不接受任意错误充当通过。
6. 新跨进程测试初次有inner类和nullable编译错误，后续修正；提供方审计调用另补显式API26保护以通过min24的lint。元数据异常不作为新的提供方版本准入门槛。
7. API28官方镜像使用`ro.kernel.qemu.avd_name`，原运行器只认较新`ro.boot`属性，因而在安装前安全停止。现同时核对旧/新属性、模拟器控制台名称和qemu标志，固定AVD白名单不放宽。API28内置Chrome69亦未定义`globalThis`，固定页面脚本改用`window`。
8. Chrome69二课的失败由固定接口诊断进一步定位：`Location.href`及`Window.top`为数据属性而非getter；读取改为支持这两类浏览器属性表示，流Reader也通过实例原型取得，响应上限/真实请求关联不变。修复后五项二课传输测试通过，后续全套另暴露一次DOM存储刚写入即杀进程的丢失。普通关闭改为销毁页面后给异步写盘1500ms，再终止进程；根仍确认实际排空，不把等待当作持久性回执。该选择参考[Chromium对WebView异步DOM存储写入的说明](https://chromium.googlesource.com/chromium/src/+/a1f8d834ce9fc89e5e409e08bb00173c37854329)；最近未落盘状态或强杀后的免登录不作保证，固定凭据可重新认证，C3业务提交和密码保护不依赖网页存储持久性。
9. API28首次完整集成为2通过、1分支跳过、4失败。JW同样残留对Reader全局构造器的引用，使目录探针异常并安全关闭会话，故外层表现为verifying/cancelled；改为从实例取得方法后，五组业务链路通过。导航测试又暴露Chrome69下载附件只发`onPageStarted`而没有`onPageFinished`：仅当提供方仍指向上一已确认HTML地址时，保留新代际并重新安装固定脚本恢复就绪，不复活旧pending。测试改为观察最新代际和有界等待真正就绪，不用旧ready戳直接读。
10. Astra终审发现全局`checkSupport`误用了新建预算，会在另一来源残留较多或低空间时拒绝健康分区复用；预算现仅留在确定新建的`claim`路径。owner、共享账本、父子进程排空、新C3作业前撤旧许可和下载新代际路径静态复核未发现新增具体问题，不能把这份复核代替设备测试。
11. Windows第一次把五套原生集成放进同一Flutter调用，JW七组通过，随后四套在测试连接阶段失败；分别独立启动后Young两组、维护三组、诊断三组、M6五组均通过。保留首次运行器失败，最终20组仅按唯一测试计数；Debug使用独立通知身份，未启动或替换Windows正式Release。
12. 临时矩阵编排先将Java普通stderr当作PowerShell错误，后又遇后台启动器标准流/空退出码造成等待误判；改为核对实际启动完成、固定AVD/串号/模拟器标志并有界等待，不由日志出现“JAVA_TOOL_OPTIONS”认定产品失败。2026-10-17的API32完整集成因对话中断停在途中，原日志另存`integration-A2-interrupted.txt`，不算完成；18日重新从该设备整套执行后六组全部通过。

## 根检查记录

本轮早期报告位于忽略的`app/build/android-a0/reports/ordinary-*`，设备分组输出为`app/build/android-webview2/reports/<avd>/`。根直接读取每份原生status计数及Flutter结束状态，不能从`OK(含跳过)`、文件名或代理结论推断通过。SDK、Gradle/Pub、AVD、构建和临时文件均在E盘，官方模拟器顺序运行；用户模拟器即使出现在ADB设备清单中也不作为操作目标。

| 根检查 | 实际结果 |
|---|---|
| 最终analyze | 无问题；`reports/analyze.txt` |
| 全套Dart | 1536通过、1平台分支跳过；`app/build/android-a0/reports/ordinary-dart-second.txt`。后续来源文案修订另跑48项相关界面测试通过 |
| Windows原生与Release | 五套20组唯一测试通过；Release仅构建到`app/build/android-webview2/windows-staging-e36ccb5/x64/runner/Release`，预先核对CMake install prefix，未启动、替换原1.00 |
| Android构建 | 普通`lib/main.dart` x86_64 Debug、AndroidTest、生产Manifest处理及lint通过；lint无Error，既有/测试Warning仍保留，不整体屏蔽 |
| API28 / Chrome69.0.3497.100 | 普通路线原生23通过/1历史反例跳过；学校完整合成6通过/1独立smoke分支未选 |
| API29 / WebView74.0.3729.185 | 普通路线原生23通过/1历史反例跳过；学校完整合成6通过/1独立smoke分支未选 |
| API32 / WebView120.0.6099.193 | 普通路线原生23通过/1历史反例跳过；中断后学校完整合成6通过/1独立smoke分支未选；普通入口冷启动及保持进程通过 |
| API34 / WebView113.0.5672.136 | 全套原生84通过/8历史高级能力反例跳过；学校完整合成6通过/1独立smoke分支未选；来源预检/隔离残留两组和手机界面/文件一组通过；普通入口冷启动通过 |
| 当前提供方 / API37.2、16KB页 / WebView149.0.7827.5 | 全套原生92通过、零跳过；学校完整合成6通过/1独立smoke分支未选；普通入口冷启动及保持进程通过 |

普通路线六组覆盖原生可观察导航、未知frame覆盖如实报告、自动登录/密码保存、JW去重/保留与清会话、Young共享凭据但分离会话、关联日程/完整分页、本人身份不符、不完整结果保留旧数据、同URL代际拒旧、取消/用户关闭后排空并可重试。原生新增实际覆盖Cookie、DOM存储、IndexedDB、CacheStorage和Service Worker跨后缀隔离、自主请求退出后停发、父死亡与子强杀、协议分片、账本遗失/未知布局/删除失败/预算及恢复。测试只读取这些合成标记，不读取正式认证资产。

早期旧113 smoke与原生19项（18通过/1跳过）、API28首次原生21项（15通过/1跳过/5失败）、Reader/DOM存储失败和两轮导航/业务集成失败均已留在报告中；最终通过不覆盖早期失败，不将旧私有世界能力当作普通路线准入。

最终文档检查通过（146份Markdown、1152个本地链接），`git diff --check`通过。根复核五份原生summary及六组合成结束行，并重新计算两份交付APK和Windows1.00 ZIP的SHA256，均与各自清单相符。

## 私有QA交付核验

工程本地提交`e36ccb58933650e514aad79ab1f60e8038047219`；批准边界文档提交`3936ccd`。没有推送或公开发布，完整A7真人关闭及A8正式签名仍未完成。

x86_64普通入口包为`app/build/android-webview2/artifacts/USTC-Assistant-Android-A7-WebView2-QA-x86_64.apk`，`1.0.0-qa-a7-webview2`/4004，290903300字节，SHA256：`f351d1e446891cfd9128c77f6704a930626545040c8827a32e0762f909ef41a4`。核对包名`cn.ustcassistant.mobile.qa`、单一ABI、编译内核含上述工程修订且无集成测试入口、固定模型大小和全部随包语音许可。签名证书SHA256沿用旧QA：`16d3f9867f0a15d4d4ffc877bdd9ec240e92a3fddf6a0a66da857e2888846036`，可由用户同签名覆盖安装；`manifest-x86_64.json`、badging、签名和hash报告同目录保留。

另构建`USTC-Assistant-Android-A7-WebView2-QA-arm64-v8a.apk`，同版本名、同工程与QA签名，分ABI版本码2004，279172431字节，SHA256：`7ae29fde439ebe325db03afc2a79d1984e4586ba997074b2fb9bc97506b1eab0`。仅通过构建及同等包内容核验，没有arm64运行或实机结论；当前MuMu应选x86_64/4004，不用arm64/2004降级覆盖。两包均为普通`lib/main.dart`入口，随包元数据不等于真人验收。

生产合并Manifest排除`QaProbeActivity`、`QaBrowserParentService`、合成文件提供方和通知OS探针，学校Activity/Service非导出且在`:school_host`，明文网络仍关闭；QA不是已签名的生产Release。旧4003包保留。Windows1.00私有ZIP复核SHA256仍为`76af4056e026743d8966a212a5288a2a6234423774560f611a168ddea0417e96`。

测试结束后所有本轮官方AVD已正常停止。仅对白名单五个AVD的`snapshots/default_boot/ram.img`核对工作区绝对路径、无链接、无运行进程且可独占打开后删除；逻辑长度合计13422100480字节，不据此估算物理回收。SDK、模型、虚拟用户数据盘、APK、报告、旧QA和Windows交付继续保留，记录为`reports/temporary-ram-cleanup.json`；没有删除或搬动C盘、用户MuMu或其他工作树资产。

## 未验与交付边界

真实学校/目标Android手机、APK鸿蒙/兼容服务、真实模型、麦克风、通知栏手势和厂商策略继续由人工/实机验证；JW真实非空考试保持原批准后补。普通世界不防恶意同源页面，完整frame拦截不作保证，未知旧Profile物理残留可保持可见待办。Windows1.00、其他工作树及既有交付物继续保留，不推送或公开发布。
