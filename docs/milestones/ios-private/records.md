# iOS 私用调研记录

## 2026-10-26：无 Mac 路线、工程边界与 Widget

用户要求针对无 macOS、仅个人使用的目标寻找免费方便的 iOS 方案，随后明确 iPhone 15 Pro / 最新 iOS 27，并提醒遵循项目工作流、询问 Widget。范围是调研与完整方案，未批准实施。唯一任务单见[方案](plan.md)。

Sol 主代理统筹并分别安排三个 GPT-6 Luna / max 只读任务：构建/签名/安装、当前工程平台缺口、iOS 系统能力。安装研究任务另接续 Widget/App Groups 核查。主代理复核当前源码和关键官方资料，未把代理声明当作构建或目标机验收；没有使用旧 Android 研究中“尚无 Android/平台工厂”的过时陈述。

根确认：工作区起点 main 3ee512d 且干净；没有 app/ios，当前工厂只选择 Windows/Android；本机 Flutter 元数据为3.44.5、Dart3.12.2、stable、修订f94f4fc76b4d74543ed9b085bbd75341ef65de22。hook只构建Windows/Android所有权库，Linux实现使用O_PATH。Drift及现有业务可复用，但不能宣称Darwin编译、iOS所有权或插件运行已成立。

关键公开资料经检索：Flutter设备构建与未签名IPA需分开；Xcode27的macOS要求、Flutter后续Xcode27/iOS27修复；GitHub公有标准runner/私有额度与artifact读取规则；Codemagic个人500 macOS M2分钟；Sideloadly官网iOS27+声明、7天/3应用/USB和Wi-Fi刷新条件；Apple Personal Team及WidgetKit/App Groups/通知/后台文档。出处集中在任务单相应结论旁，检索日期2026-10-26。

GitHub连接器对本仓库搜索返回422；匿名官方API返回403，进一步核对公开错误为共享出口配额耗尽、X-RateLimit-Remaining=0。不能据此断言origin公有或私有。没有读取GCM秘密或改变仓库可见性，构建费用/产物访问空间留待I0核对。网页取页工具对本仓库页cache miss也未作为私有证明。

Widget核查区分了三种证据：Apple支持共享容器与系统时间线；AltStore自身有Widget/App Groups实现、iPASide作者报告过免费账号共享组可用；但没有取得Sideloadly+iOS27对本项目双目标共享/重签的证据。SideStore公开问题还显示扩展组名重映射可能失败。因此不按旧印象强行判定必须付费，也不把签名成功当作共享成功；建议I0先用合成值检验。刷新预算、通知容量/覆盖和profile到期后的行为继续列为待验证，不从旧API的64条数字推断iOS27的保证。

本轮未创建iOS工程/Widget目标或workflow、未配置云账号/计费/Apple签名、未安装工具/IPA、未连接手机、未操作麦克风/权限、未访问真实学校或读取正式业务/浏览器资产。自动构建/测试和目标机结果均尚无；本轮只对文档运行检查，不重复Flutter或真实采集。

根文档检查通过：182份Markdown、1424个本地链接，归档清单按规则核验；`git diff --check`通过。方案与研究记录及导航分开保存，不向设计正文追加施工流水；批准前保持iOS未实现状态。

## 2026-10-26：GitHub找回期间的替代入口

用户补充GitHub账号正在申诉找回，担心I0无法进行。根对这个明确的小范围依赖修订直接调查：Codemagic官方支持邮箱验证码注册，Personal账号每月500分钟macOS M2；Other/HTTPS接入支持Public repository，软件清单包含M2及Xcode27.1。出处已补入唯一任务单。I0首选据此改为邮箱Codemagic加校内公开HTTPS源，不需要GitHub恢复，也不通过另一个账号规避找回流程。

本机关闭凭据助手及Git交互后，匿名`git ls-remote https://git.ustc.edu.cn/demo233/107_ustc_assistant.git refs/heads/main`成功读回9cfbfc71f5ecafa3b5e3abf9a51ac3ac00185645。这是本机HTTPS读取证据，不是Codemagic主机的网络或构建证据。没有注册Codemagic、配置应用/计费、上传Token/SSH私钥、触发iOS构建或尝试GitHub登录/推送。本次文档仅同步校内，GitHub镜像待账号恢复后核对补齐；实施仍待用户批准。

## 2026-10-26：I0 独立原型与首次云端接入

用户批准开始I0后，根从维护main `005f211d387ee9359cf206cb786f10852ea16012`建立`codex/fix-ios-i0`。没有复制工程、新建嵌套Git或修改正式app依赖/平台工厂。Sol负责范围、契约、云构建及装配；两个GPT-6 Luna/max分别实现合成host/Widget源和包校验器，第三个Luna/max做Flutter当前模板、Xcodeproj与Codemagic只读复核，根实际检查并集成，代理声明不计作Xcode或目标机结果。

探针源在`verification/ios-private-probe`，只有Flutter SDK及flutter_test依赖。当前模板使用UIScene和`FlutterImplicitEngineDelegate`，桥接messenger来自`engineBridge.applicationRegistrar`。两项无参固定操作写入/读取同一个有界合成标记，成功写入请求Widget时间线刷新；没有真实学校、模型、C3、Keychain或录音入口。Widget只读，共享不可用或损坏不使用主应用私有缓存兜底。生成工程、Pub/Python校验缓存均在E盘忽略目录；没有升级既有Windows Flutter。

云脚本生成Runner加单一I0Widget扩展，并校验entitlements源/目标引用。只在生成工程绑定App Group声明；Info自定义键不冒充实际权限。复核发现Xcodeproj会为SDKROOT无版本的目标引用旧SDK，包括new_target自动加入的Foundation，根统一改为SDKROOT相对框架并校验实际SDK路径；Embed App Extensions排在Thin Binary之前。复制探针独立analyzer配置，去掉新生成的MyApp模板测试，避免混入未声明flutter_lints或旧入口。实际Ruby/Xcode运行仍待云预检与构建。

仓库根`codemagic.yaml`只含手动预检/设备构建，M2/Xcode27.1，分别5/30分钟；仅后者选择Flutter3.47.7。构建Release/AOT设备app后按Payload打包IPA，校验真实iOS arm64、双目标、Info/manifest与AOT修订、ZIP大小/路径/重复/链接及禁止的profile/秘密/Debug资产。没有使用`build ipa --no-codesign`假定导出成功，没有Apple签名、自动发布、定时器或邮件收件人。固定entitlements sidecar只是本机签名输入参考，不能证明免费重签或App Groups有效。

根实际本机检查：Flutter3.44.5/Dart3.12.2的独立analyze无问题，6项桥接/界面合成测试通过；basic310的IPA反例22/22通过；两份shell脚本Bash语法检查通过。Git Bash首次在沙箱内初始化MSYS共享对象被拒，改用经批准的原生只读语法检查后成功，不将首次失败覆盖为通过。Codemagic配置通过当日官方JSON Schema校验，schema SHA-256为`6d8596cb0196d9f815804124b21bd5792a6dd0ebd193246f6c3e295fef20539c`；这不替代账号配额、工具版本或云执行。文档检查184份Markdown/1434个本地链接通过，归档核验与`git diff --check`通过；后续记录变更另执行文档检查。

用户完成Personal注册后，根在Codex内置浏览器使用Other/HTTPS/Public接入，Codemagic返回`git ls-remote`的HTTP Basic认证拒绝。根最初创建/绑定标签有两次超时；重新识别用户当前有效标签后正常，不据此判定网站故障。用户提供的截图与[校内Git当前登录页](https://git.ustc.edu.cn/users/sign_in)明确的校外登录/HTTPS令牌规则一致，原“云端匿名可读”假设退出。本机无凭据直连和既有7897代理各一次读取仍返回main 005f211；这些仅是本机路径结果，代理是否实际校外出口未独立确认，不能替代Codemagic。

用户明确批准本项目7天、`read_repository`部署令牌，并本人生成、直接填写Codemagic后回复“已接入”。根期间不读取凭据页或令牌，随后已见仓库扫描成功进入Finish；取消Public repository仅用于客户端认证栏，不改变校内项目可见性。手动选iOS并创建Personal应用，界面已到仓库根YAML设置，提示尚无配置是因为新源文件当时仍在本机。没有使用GitHub、上传个人API凭据、SSH私钥或Apple资料，也没有启用收费。

截至本条，本机合成/配置检查已取得证据；实际云编译、IPA下载核验、Windows签名、iPhone启动/共享/立即重签及7天续签仍未观察，不宣布I0关闭。操作入口见[探针说明](../../../verification/ios-private-probe/README.md)。

### 首个云任务与当前等待点

工程检查点`c51601a`与独立文档提交`8bb81ce`正常快进合入main并同步校内；没有访问GitHub、强推、打标签或上传iOS包。Codemagic已经从main读取根YAML，根手动启动唯一一次`ios-i0-preflight`，界面确认源码修订`8bb81ce0c649707628f38046d9bc5db42f85b495`、Mac mini M2及预检workflow。第1次任务在2026-10-26北京时间17:54后进入队列，18:10重新载入任务列表仍为`queued`；尚未产生机器准备/源码克隆/预检脚本日志，没有IPA或云端通过报告。不是脚本超时，也不能把metadata扫描成功写作builder已克隆。

根只读核对Personal计费页为免费分钟`0/500`，订阅未启用、无账单记录；没有点击订阅、切换收费机型或重复提交任务。官方状态页当时为operational，这不保证本任务无排队；根也没有确定其实际排队原因。本地Git对象6.03MiB loose加11.75MiB pack，不足以据此认定需要仓库历史清理；未执行官方通用排障中提及的gc/repack或force push。任务页和不含账号/令牌的截图、任务定位JSON仅保留在本机忽略的`app/build/ios-i0`，不提交这些私用资源。

根另实际运行Windows PowerShell包装器，合成IPA成功生成安全报告，缺参返回固定exit2；未触碰真实IPA或手机。`git diff 005f211..8bb81ce -- app`为空，工作树干净，正式app源码/依赖及公开交付未改。下一步等待现有预检结束，成功后才对同一修订启动`ios-i0-probe`；若失败先读具体阶段，不盲重试。保留`codex/fix-ios-i0`在该修订供选取，后续状态文档不改变该待构建源码。未作用户手机、免费profile、Widget共享或续签通过结论。

### 云预检通过、设备编译与通用二进制校验修复

用户反馈“好像ok了”后，根检查到首个预检实际finished：界面开始时间2026-10-26 18:12、总时长1分16秒，源码获取23秒；原生步骤输出`checkoutVerified=true`、修订8bb81ce、Xcode27.1、iPhoneOS SDK27.1、xcodeproj1.28.1、Syntax OK及无需Apple凭据。根逐项读取真实步骤日志，不只依赖卡片颜色；这时才确认builder源码获取与工具链实际通过。

根随后从已完成任务选择“Build commit #8bb81ce”，手动运行`ios-i0-probe`，保持M2、30分钟、无SSH/VNC、无Apple资料；未重复预检队列。该任务界面开始时间18:42、总3分19秒。Flutter3.47.7的analyze与6项合成测试实际通过，Xcode耗时70秒构建出15.6MB Runner.app；脚本对单一I0Widget目录检查亦通过。最后IPA校验返回`unsupported_macho_format`，故整个job失败；不能把编译成功写作包验收通过或提供安装建议。

根确认旧验证器遇到FAT头即拒绝，交由Luna/max限定修改两份校验/测试文件，Sol复核并补充ARM64_V8及带不同ABI标记的合法子类型。现支持FAT32/64与两种字节序，最多16切片，有界检查表/偏移/对齐/重叠/架构描述；每个切片仍须ARM64、预期Mach-O类型和LC_BUILD_VERSION的iOS设备平台。AOT修订在每个切片内流式匹配，不接受外层填充冒充；混入模拟器/x86仍拒绝。根basic310独立32项反例通过，构建脚本只补4个固定二进制的lipo诊断，Bash语法检查通过。真实失败包的本机复验仍未完成，须重新运行云端校验。

用户补充iPhone15Pro运行iOS27.0.1，Windows尚未安装Sideloadly；系统build、签名/配对与真机共享均未观察。根未安装或运行Sideloadly，未操作Apple登录、Developer Mode或信任。官网64位安装器已完整下载到E盘忽略的I0目录，144076887字节，SHA-256 `2f69c09f4669228fdfbe174b934640a21368e7afd2c160740c69c7c5bce306f7`；Windows读到NotSigned且版本资源为空，不将“官网来源”说成“已验证发布者签名”。此前128MiB下载上限不足、Python续传TLS EOF的失败保留；改用原生HTTPS客户端恢复后大小匹配。仅对安装元数据作只读检查，无现有Apple商店版命中，不卸载/替换任何软件。

浏览器预检ZIP下载两次等待事件超时，标准下载目录亦未找到对应文件；另一下载尝试返回TypeError，未形成已验证本机报告。不扫描浏览器缓存或认证资产，实际预检证据取自UI步骤日志，不伪称已下载artifact。任务定位及工具下载均留在E盘忽略目录。

另经Luna/max只读研究和根核对公开AltSign/AltStore源码，纯未签名IPA缺少共享组请求的签名元数据；外置sidecar不会自动代替它。根尝试新增独立ad-hoc元数据副本的补丁，被自动审批以超出“云端仅编译、Windows本机签名”拒绝，整份补丁没有落地，也未执行codesign。根保持原签名边界，只接入FAT修复/架构日志；[待确认修订](plan.md#待确认修订共享组请求元数据副本)交用户决定，不把未签名安装失败推断为免费Widget永久不可用。
