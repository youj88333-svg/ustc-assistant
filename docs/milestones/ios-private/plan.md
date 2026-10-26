# iOS 私用迁移方案

日期：2026-10-26。状态：用户已批准开始 I0，正在实施独立原型；I1–I7及正式平台装配仍待后续推进。目标是用户的 iPhone 15 Pro / iOS 27；具体 27.x 和系统 build 在首个实机原型登记。原调研与实际过程见[记录](records.md)。

当前交付前提：用户 GitHub 账号正在申诉找回。本轮 I0 使用 Codemagic 邮箱注册的个人免费账号，经本项目短期只读部署令牌读取校内 GitLab 的 HTTPS 仓库；GitHub 登录或 Actions 不是准入前置条件。免费云构建属于 I0 授权；不启用付费超额。

## 目标、依据与待批准范围

依据[文档入口](../../README.md)、[07 产品约束](../../architecture/07-constitution.md)、[08 平台分层](../../architecture/08-target-architecture.md)、[09 关键契约](../../architecture/09-contracts.md)、[10 运行链路](../../architecture/10-runtime.md)、[11 组件](../../architecture/11-component-designs.md)、[12 横切约束](../../architecture/12-cross-cutting.md)、[13 验证登记](../../quality/13-risks-and-acceptance.md)和[15 工作流](../../workflow.md)。M0–M6、Windows/Android 公开版和原设备反馈均不替代 iOS 验证。

建议继续同一 Flutter/Dart 工程，补 Swift 平台层和原生 WidgetKit 扩展。保留 Agent、日程/任务、五来源内部能力、图片、日志、两槽提醒、晨报及前台每日二课同步；语音单独验核。首版只验这一台手机，不扩成多设备产品。

私用交付不进入 App Store、TestFlight 或公共 iOS Release；不增加服务器、APNs、跨端数据库同步或 iCloud 业务同步。现有开源代码、Windows/Android 身份与交付继续保留。iOS 使用独立且稳定的身份，在手机重新提供学校账号/模型 Key，不搬 Windows DPAPI 或 Android Keystore 密文。

拟随方案批准增加只读桌面/锁屏小组件，以及下述 iOS 普通 WKWebView 信任映射。Widget 的共享数据是受控本地副本，不是第二个业务库；不能借此绕过 Agent 授权或直接修改日程。

## 推荐的免费交付链路

Windows 编辑与共享测试 → 云端 macOS/Xcode 编译设备版 → 未签名 IPA → Windows 本机签名 → iPhone 安装/续签。

没有 Mac 不妨碍采用云端 Mac，但不能省去 macOS/Xcode 编译。Flutter 的 iOS 构建需要 Mac；官方[构建说明](https://docs.flutter.dev/deployment/ios)与[构建命令实现](https://github.com/flutter/flutter/blob/master/packages/flutter_tools/lib/src/commands/build_ios.dart)支持这一边界。拟用 `flutter build ios --release --no-codesign` 生成设备版 `Runner.app`，再按 `Payload/Runner.app` 打包未签名 IPA；`flutter build ipa --no-codesign` 会跳过 IPA 导出，不能把它当作现成 IPA。模拟器 app 也不能装到 iPhone。

日常私用使用 Release/AOT 包，不依赖 JIT、Windows 远程调试 iPhone 或每次接 Xcode 启动。签名 Apple 账号、2FA、私钥和配对记录留在本机，不给云构建。云端只处理受控源码、公开固定资源和合成测试。

| 选择 | 当前证据与代价 | 本项目建议 |
|---|---|---|
| GitHub Actions 标准 macOS runner | 公有仓库的标准 runner 编译分钟免费；私有仓库受账号免费额度限制，artifact 存储另计。公有仓库 artifact 对有读取权限的已登录用户可见 | 账号恢复后再评估的备选；当前不依赖 GitHub 登录/Actions，不擅自改公开级别或绕过账号恢复流程 |
| Codemagic 个人免费套餐 | 官方提供每月 500 分钟 macOS M2，个人账号可用，Team 不享受该赠额；支持邮箱注册及公开仓库 URL | 当前首选：邮箱登录、Personal 账号、Other/Public repository 接入校内 HTTPS 源；只开免费用量，不自动启用付费超额 |
| Sideloadly / Windows | 官网 v0.71.0 声称支持 iOS 7–27+；免费账号 7 天有效，可经 USB 或已配对 Wi-Fi 自动尝试续签 | 主应用首选；含 Widget 时必须先过双目标及共享容器探针 |
| AltStore Classic + AltServer / Windows | 同样 7 天与 3 个活动应用限制；AltStore 自身占一个应用位，有 Widget/App Groups 实现证据 | Sideloadly 的扩展重签不成立时，免费备选探针；验证后只保留一条日常安装链路 |
| SideStore | 可在初装后使用设备侧续签，但多出本地 VPN、配对文件和 beta 兼容性成本 | 不作为首选；不能把它的扩展重签能力推定给其他工具 |
| 付费 Apple Developer | 官方年费通常为 99 美元，地区价格另核；不必因此购买 Mac，但需要用户单独决定费用 | 仅在不愿周续签或免费 Widget 能力确实不足时考虑 |
| TestFlight / PWA / TrollStore | TestFlight 需会员且 build 最长 90 天；PWA 无法直接复用当前原生层和跨站采集；TrollStore 官方支持版本不含 iOS 27 | 不作为本项目的免费私用主线 |

来源：[GitHub 计费](https://docs.github.com/en/billing/concepts/product-billing/github-actions)、[artifact 下载权限](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts)、[Codemagic 个人定价](https://docs.codemagic.io/billing/pricing/)、[仓库接入](https://docs.codemagic.io/getting-started/adding-apps/)、[Sideloadly 官网](https://sideloadly.io/index.html)与[FAQ](https://sideloadly.io/faq.html)、[AltStore Classic](https://faq.altstore.io/altstore-classic/your-altstore)、[SideStore 要求](https://docs.sidestore.io/docs/installation/prerequisites)、[Apple 会员](https://developer.apple.com/help/account/membership/program-enrollment)、[TestFlight](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)、[TrollStore](https://github.com/opa334/TrollStore)。价格/支持声明均为检索时资料，不是本项目实测。

Codemagic 的[邮箱注册](https://docs.codemagic.io/getting-started/signup/)独立于源码服务账号。用户完成 Personal 注册；新增应用选择 Other、HTTPS URL `https://git.ustc.edu.cn/demo233/107_ustc_assistant.git`。实际匿名接入被 HTTP Basic 拒绝，根随后核对[校内 Git 当前说明](https://git.ustc.edu.cn/users/sign_in)，确认校外需要登录，HTTPS 要用令牌；不能以本机可达推定云端匿名可达。用户已批准仅限本项目、`read_repository`、7天到期的部署令牌，由本人直接填入 Codemagic。客户端取消 Public repository 选项以显示认证栏，不改变源码公开级别，不上传个人 API 令牌/SSH 私钥或用 GitLab OAuth。依据[任意仓库接入](https://docs.codemagic.io/partials/other/)与[GitLab 部署令牌](https://docs.gitlab.com/user/project/deploy_tokens/)。I0 项目类型手动选择 iOS，YAML 与脚本工作目录为仓库根，独立生成工程在忽略的 `app/build/ios-i0`。

I0 先验证 Codemagic 主机能匿名拉取指定修订和资源，再消耗编译分钟。根已验证本机匿名 HTTPS `git ls-remote` 成功，这不等于海外云主机已可达；若云端拉取失败，保留具体网络错误后再评估源码传递方式，不把本机校园网条件当成云端条件。官方[Mac M2/Xcode 27.1 清单](https://docs.codemagic.io/specs-macos/xcode-27-1/)可作为工具链候选，实际版本与赠额仍在账号内核对。

免费不是永久免维护安装。Apple 当前[Personal Team 说明](https://developer.apple.com/help/account/basics/about-your-developer-account/)列出 7 天 profile、每设备最多 3 个 app、最多 10 个 App ID 等限制。Sideloadly 的自动续签要求电脑在到期前能通过 USB 或 Wi-Fi 发现手机；首次需 USB 配对，同一校园 Wi-Fi 也可能受网络隔离影响，因此保留 USB 续签。续签现有包不需要每周重新编译。逾期后先用同一账号/身份重签覆盖，不以卸载或清数据作为默认修复。

CI 只手动触发、限制并发和单次时长，依赖/工具固定版本，短期保留产物并清理旧任务，不开启无限定时构建或付费超额。iOS 包不自动挂到当前 Public GitLab 项目。若用户还要求未签名 CI 产物也不对仓库读者开放，采用受权限控制的构建空间并核对免费配额。

## 当前工程与工具链

根已确认本机 Flutter 为 3.44.5 / Dart 3.12.2；`pubspec.lock` 不是 Flutter SDK 的精确版本锁。当前没有 `app/ios`，平台工厂仅支持 Windows/Android。官方[Flutter 变更记录](https://github.com/flutter/flutter/blob/master/CHANGELOG.md)列出 3.44.8 的 Xcode 27 构建修复，以及 3.47 系列的 iOS 27、SwiftPM 和原生资产修复，因此不直接照搬 3.44.5。

建议 I0 在云端以固定 Flutter 3.47.7、可用的稳定 Xcode 27.x 和对应 macOS 镜像作为首个候选，实际预装清单/版本输出核对后锁定；若可用镜像或插件不支持，记录具体原因后调整候选，不能声称未跑过的组合可用。不升级本机 Windows SDK 或重打已发布的 1.0.0；共享改动继续兼顾原维护基线。依据：[Flutter 平台表](https://docs.flutter.dev/reference/supported-platforms)、[Apple Xcode 要求](https://developer.apple.com/xcode/system-requirements)、[GitHub runner 清单](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)、[macOS 镜像软件清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)。

| 部分 | 保留内容 | 必须新增/适配的边界 |
|---|---|---|
| Agent、日程、任务、来源业务 | 现有 Dart 模型、工具、上下文、事务、去重/撤回、个人覆盖、冲突与北京时间规则 | 注入 iOS 能力；手机网络、流式中断、授权和生命周期重新验核 |
| Flutter 页面和七份 Markdown | 已有手机布局、审批弹层、周视图、设置和知识装载 | iPhone 安全区、键盘、返回手势、动态字体与分享流程 |
| 数据库与私有目录 | Drift schema、事务、`OwnedDirectory` 与所有权守卫 | iOS 沙盒目录、Darwin 原生锁与恢复；当前 Linux C 的 `O_PATH` 不能照搬 |
| 学校/模型凭据 | C3 单一事实、用途/提供方隔离及密文失败保留 | Keychain/CryptoKit 保护器；不读既有浏览器手填秘密 |
| 教务/二课浏览器 | 固定来源操作、身份/分页/日期契约、提交与取消规则 | Swift WKWebView、独立持久数据仓、导航/弹窗、文档绑定及清理 |
| 通知、晨报、每日同步 | 两槽期望、事务后对账、06:00 首开与前台空闲规则 | UserNotifications、容量适配、冷启动点击和系统挂起恢复 |
| 图片、日志、语音 | 图片清洗、白名单诊断、语音会话和固定模型 | PHPicker/UTI、分享导出、iOS 录音/中断及模型加载；插件徽章不等于本工程验证 |
| Widget | 可复用 C3 读取投影、目标定位与显示规则 | SwiftUI/WidgetKit extension 和只读 App Group 快照，不运行 Flutter 引擎 |

具体扩展点：[平台工厂](../../../app/lib/platform/runtime_platform_factory.dart)、[原生浏览器客户端](../../../app/lib/platform/native_observation_browser.dart)、[数据库](../../../app/lib/platform/native_database.dart)、[原生构建 hook](../../../app/hook/build.dart)、[Linux 所有权实现](../../../app/native/directory_posix.c)、[图片入口](../../../app/lib/platform/agent_image_picker.dart)、[语音识别](../../../app/lib/platform/sense_voice_recognizer.dart)。

## iOS 接口与运行语义

1. **存储与密钥。** iOS factory 提供可信 Application Support 根，保留演示/正式目录和进程内唯一运行实例；后台返回不再次获得自身已持有的排他锁。扩展不打开 C3。Keychain 保护不同用途的密钥，C3 仍持有密文事实；使用设备限定、非同步项，权限/密钥失效要求重新提供凭据，不清日程。配置敏感文件的备份排除并验证；不把没有 iCloud 实时同步说成系统绝不会备份。卸载、换 Apple Team、换设备不保证密钥/资料自动迁移。参考[Keychain 可访问性](https://developer.apple.com/documentation/security/restricting-keychain-item-accessibility)、[同步属性](https://developer.apple.com/documentation/security/ksecattrsynchronizable)及[系统备份](https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup)。
2. **学校自动化。** 保留应用主动保存的凭据自动登录和固定只读采集，验证码/额外授权由用户完成。采用 WKWebView，不以 Safari 登录窗口代替可控采集宿主。按来源/分区 UUID 建立独立持久 `WKWebsiteDataStore`，创建 WebView 前绑定，撤销后不用默认共享 store 兜底。固定脚本按主 frame、来源、文档世代和一次性操作绑定；页面变化和迟到结果不能继续提交。取消后收口受控操作，再释放宿主并调用官方数据仓删除 API，错误保留待清理状态，不访问或强杀系统 WebContent 进程。参考[数据仓](https://developer.apple.com/documentation/webkit/wkwebsitedatastore)、[按标识删除](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/remove(foridentifier:completionhandler:))与[异步 JS](https://developer.apple.com/documentation/webkit/wkwebview/callasyncjavascript:arguments:inframe:incontentworld:completionhandler:)。
3. **需要明确批准的浏览器映射。** 当前 07/09 的普通页面世界例外明确只适用于 Android，不能自动扩展到 iOS。提议 iOS 同样接受获准学校同源页面作为正常运行环境，不承诺抵御恶意学校同源脚本或保证页面看不到填入表单的密码；保留固定操作、文档/来源绑定、单次凭据租约、只读事务、网页原有 CSP/TLS 和用户授权。实施前把获批的 iOS 映射落入对应决定；若验证显示边界不足，回报具体缺口，不静默降级为共享会话、任意脚本或绕过认证。
4. **系统挂起。** 前后台、分享/选图、来电及 WebContent 终止分别处理。应用进入后台时保存可恢复事实并中止不能继续的操作，恢复后先对账再启动新作业；不假设退出回调一定执行。模型回复中断不自动重放旧写入或批准，学校取消不接受旧文档结果。
5. **提醒。** 用 `UNUserNotificationCenter` 读取权限、登记/取消和回读 pending，点击后只凭不透明目标定位并重新读取 C3。正常退出后由系统处理已登记请求，不能保证每条准时可见；Focus、通知摘要、重启及 profile 逾期分别验核。现代 API 没有已核实的 iOS 27 数字容量保证；旧 API/插件的 64 条说法不直接当作现代平台合同。首版建议以 60 条活动请求为保守实现策略，按时间滚动补位，C3 保留全部期望，界面/Agent说明覆盖截止时间和未登记槽位。长时间不打开导致覆盖耗尽必须可见，不能静默宣称全年两槽都已排好。参考[本地通知](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app)、[旧 API](https://developer.apple.com/documentation/uikit/uilocalnotification)和[成熟插件的限制说明](https://github.com/MaikuB/flutter_local_notifications/blob/master/flutter_local_notifications/README.md)。
6. **晨报和日同步。** 继续北京时间 06:00 后首次符合条件的前台使用触发，生成异步进行；每日二课仅在独立启用、应用前台空闲时运行。BGTask 不是准点闹钟，不承诺杀后台后 06:00 自动登录学校。参考[Apple 后台策略](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)。
7. **图片、语音与日志。** 图片用系统选择器，仅取得用户所选项，保持原字节/像素限制和去元数据；iPhone 常见 HEIC、方向信息与大照片要在原生边界有界转换为现有可接受的静态图，不能先无限读入再检查。安全日志用系统分享/存储入口，取消后清临时文件；不开放整个业务目录供电脑读取。当前 iOS `file_selector` 不支持现有保存位置流程，不能只改按钮。语音先沿用本地模型/合成 WAV 验核再做真机录音；约 239 MB 权重的安装体积、峰值内存和时延单独测。系统键盘听写可临时使用，但不冒充应用语音已实现，也不承诺其永远离线。系统 Speech 替换现有方案须另核数据流和语言支持。参考[照片选择](https://developer.apple.com/documentation/photokit/delivering-an-enhanced-privacy-experience-in-your-photos-app)、[分享](https://developer.apple.com/documentation/uikit/collaborating-and-sharing-copies-of-your-data)、[file_selector](https://pub.dev/packages/file_selector/versions/1.1.0)、[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx/blob/master/flutter-examples/README.md)。

无本机 Mac 时，排障主要依靠云端原生测试/模拟器截图与应用安全诊断。学校桥和启动阶段先具备固定阶段/原因/计数日志，避免所有失败只剩 unknown。真机在“设置 → 数据与隐私”导出最近安全日志，经用户选择的分享目标交回；必要时由用户单独提供该应用的崩溃报告，不批量采集整台手机的系统分析数据。

## Widget 首版

建议桌面小尺寸显示下一项的名称、时间、教室；中尺寸显示今天接下来的安排和临期任务；锁屏显示下一项时间或简短摘要。课程同名同色、地点优先教室、冲突标志和任务临期/逾期规则沿用主应用。点按进入对应内容，首版不在 Widget 中创建/改动安排或执行 Agent。

SwiftUI + WidgetKit 负责扩展，Flutter 保留主应用；不让 Widget 启动 Dart/Flutter 引擎、访问正式 SQLite/Keychain、登录学校或请求模型。Apple 明确扩展是独立进程，常用共享方式为 App Group：[WidgetKit foundations](https://developer.apple.com/videos/play/wwdc2026/277/)。

建议新增 `ios-widget-snapshot-v1` 本地只读契约：版本、数据世代/修订、生成时间、有效期、北京时间标识和有界的日程/任务显示字段；目标只带不透明 ID，不含密码、Key、备注正文、聊天、原始学校响应或浏览器资料。建议初始上限为未来 7 天/50 项/64 KiB，作为本项目策略而非系统限制。主应用在 C3 成功提交、撤销、来源失效、隐藏/出勤变更后原子重建快照并请求 reload；失败只标快照待更新，不回滚业务。重置/撤权清除相应投影，深链接重新检查现行目标与许可。

Widget 预生成课程开始/结束、跨日和截止点的时间线；它不是常驻进程，也不保证逐分钟或准点刷新。Apple 对 reload 有系统预算，时间线日期也可能被延后，不能用 Widget 替代系统提醒。显示最近更新时间；缺失、损坏、过期或无法读取共享组时显示“打开应用更新”，不以空缓存推断“今天没课”。锁屏默认保护私人标题，预览只用合成内容。参考[更新策略](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date/)、[时间线](https://developer.apple.com/documentation/widgetkit/timeline)和[App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups)。

**免费 Widget 的关键门禁是实际签名和共享，不是画面。** 不能按旧印象断言 Personal Team 一定不能 App Groups：[AltStore 官方 release notes](https://github.com/altstoreio/FAQ/blob/main/release-notes/altstore.md)有其 Widget 实现，[iPASide 作者变更记录](https://github.com/pwnapplehat/iPASide/blob/main/CHANGELOG.md)记录过免费 App Groups 的端到端结果。但这些不是本项目、iOS 27 或 Sideloadly 的验证；[SideStore 扩展问题](https://github.com/SideStore/SideStore/issues/1437)也说明重签后的映射可能失败。

I0 必须证明主应用与扩展均保留、各自 profile 授权同一共享组、双方实际读到同一合成值，覆盖重签和重启后仍成立。一个主应用加一个 Widget extension 按 2 个 App ID 预算；扩展不另作一个独立安装 app，AltStore 安装器自身另占 app 位，参考[App ID 规则](https://faq.altstore.io/altstore-classic/app-ids)。保留同一 Apple 账号和最终签名 ID，避免工具加后缀后仍读取旧 group 名。

若 Sideloadly 不满足，先验证 AltStore Classic 免费链路；仍不成立时才把“免费主应用先交付 / 调整 Widget 范围 / 付费会员”交用户取舍。不能默认改用系统日历导出、云快照或读取正式数据库来绕过；这些会增加数据流和产品范围。

## 切片、依赖与验收

本表为唯一实施任务单，当前只批准 I0。Sol 负责契约、跨层与集成；Luna/max 只承接契约已定、文件不重叠的实现/调查；Astra 按实际复杂问题参与。每片保留失败与实际检查，相关检查通过后建立 commit；自动与真人结果分开。

| 切片 | 范围与接口/不变量 | 依赖与通过条件 |
|---|---|---|
| I0 免费构建/安装与 Widget 原型 | Codemagic 邮箱个人账号、校内公开 HTTPS 源；固定 Flutter/Xcode，独立轻量 AOT 设备探针、未签名 IPA、Windows 本机签名；主应用+扩展仅用合成共享值。确定稳定 Bundle ID/共享组，不占用多余随机 App ID | 先核对个人赠额、云端匿名拉取可达性与产物访问权限；在目标手机首装、关闭重开、即时重签后值保留，Widget 真正共享而非默认占位。未通过前不大规模移植业务；7 天长期续签测试可与后续工作并行，未完成仍保留 |
| I1 目录/数据库/凭据/平台启动 | iOS factory、Darwin 所有权、Keychain 与独立用途、增量 schema 和维护恢复 | I0 主应用成立；临时库独占/释放、重复前台/重入、崩溃恢复、密文篡改/用途不符/SQL 失败保留通过；不读正式资料 |
| I2 教务和二课桥 | WKWebView、分区、固定认证/查询、身份、取消排空与清理；落实现行合同的 iOS 映射 | I1；先 loopback 对两 store、跨重启/单独清除、重定向/弹窗、伪 frame、文档变化和迟到结果做反例，再由用户在应用提供凭据/处理挑战完成真实同步验收 |
| I3 通知与前后台 | 两槽容量、期望/已登记对账、冷启动点击、06:00 晨报及前台二课日同步 | I1/I2；合成过载、取消/重排、拒权/撤权和时区测试；实机验正常退出、后台、强退、重启、Focus，分别登记送达和系统限制 |
| I4 Agent/手机交互与文件 | 复用主界面、工具/权限、图片和流式请求；PHPicker/UTI/日志分享 | I1；模拟器覆盖窄屏、安全区、大字体、键盘/审批弹层及分享取消；实机最小模型/联网验证由用户在应用主动触发，不做大规模真实 API 消耗 |
| I5 只读 Widget | 最小快照导出、原生 SwiftUI 时间线、小/中/锁屏配置及受控目标定位 | I0 双目标共享、I1/I3；主应用退出后按预知时间线展示；事务失败/撤销/隐藏/跳过/失效/重置后投影一致，旧深链接不执行写入，扩展无业务库/秘密访问 |
| I6 本地语音 | iOS 模型资源、录音权限/中断、短时有界识别和草稿回填 | I1/I4；先固定 WAV/离线资源校验，再目标机真人中文/术语、拒权、来电、退后台、内存与时延；不自动发文本、不记录音频/转写，不把系统听写当本功能通过 |
| I7 私用交付与维护 | 固定身份、源码/工具链/资产摘要、未签名/本机签名区分、续签教程、日志和已知问题 | 根执行 analyze、共享及相关 Windows/Android 回归、iOS 云端原生/模拟器与 AOT 构建；用户只做 Apple/学校授权、真实麦克风和目标机专项。至少一次到期前正常续签/升级保留，长周期/到期行为如实单列 |

拟修改目录限于 `app/ios`、iOS 平台适配/原生所有权与装配、必要的共享能力/投影接口、iPhone UI、合成/loopback 测试和构建工具。阶段在短期维护工作树登记，不复制/嵌套 Git；不顺带改动已发布包、其他账号的认证资料或公开 Android/Windows 身份。

Windows 本机的下载、脚本、测试与私用产物优先放 E 盘，交付拟在源码外的 `E:\107\releases\ios-private`；不把 Xcode 或整个模拟器镜像下载到 Windows。Apple 移动设备驱动、信任/配对与工具的系统配置可能仍由系统管理在 C 盘，不能承诺零 C 盘占用，也不为迁移强行移动这些资产。云端 Mac 的临时目录由云主机管理。

## 交付成功的判断

- 无自有 Mac，能从受控源码重复得到可侧载 AOT IPA，在同一身份下安装/续签/升级且保留自己的资料。
- Agent、课程/二课、日程/任务、通知及日志在该手机上具备明确成功和故障行为；普通浏览器、事务与隐私边界不降低到未批准范围。
- Widget 在实际免费签名链路上通过共享与重签验证；不通过时先明确范围取舍，不以模拟器截图代替。
- 7 天、系统挂起、通知覆盖/Focus、Widget 刷新预算及语音问题都有准确说明；Windows/Android 既有资料和行为保留。

用户“ok，我正在注册codemagic，请开始I0”授权独立构建/安装与 Widget 原型。正式业务平台装配及 iOS 普通 WKWebView 映射仍在后续切片单独落实。Apple 账号/2FA、Developer Mode和信任设置仍由用户在本机操作；免费账号资料仅交本机签名工具按用途使用，不进云端或聊天。

## I0 执行契约

I0仅新增`verification/ios-private-probe`、`tools/ios-i0`及Codemagic入口，不改当前`app`业务、依赖、平台工厂或公开包。当前授权工作区内使用短期`codex/fix-ios-i0`分支，避免新建嵌套Git或复制旧工程。生成工程和日志在忽略的`app/build/ios-i0`，私用下载/签名产物在源码外；不访问真实学校或模型。

探针候选身份固定为`cn.ustcassistant.ios.i0`，Widget为其`.widget`子标识，共享组基名`group.cn.ustcassistant.ios.i0`；最终本机签名身份需由安装门禁确认。主应用与扩展只共享`ios-i0-marker-v1.json`，字段限版本、`i0-`加8位十六进制合成标记和UTC生成时间，最多2 KiB。共享组不可用、快照损坏/缺失均明确失败，不读写私有目录作为共享成功兜底。

Flutter通道`ustc_assistant/ios_i0_v1`只允许无参数的`inspect`、`writeSyntheticMarker`。结果为`ios-i0-probe-v1`，只含源码修订、应用标识、共享可用/组摘要、合成标记/时间和固定失败码；无任意路径、账号、网络或脚本入口。Widget只读同一文件，按系统时间线展示合成值，点按仅打开探针。

Codemagic分为手动预检和手动设备构建两个workflow，Mac M2、固定Xcode27.1；设备构建固定Flutter3.47.7、Release/AOT、不签名、不自动发布或设置通知收件人。预检限5分钟、构建限30分钟；云端不得提供Apple凭据/证书/配对文件。设备包含Runner及一个Widget，不含业务库、学校页面、语音权重或实际秘密。

未签名IPA须核验ZIP路径/重复与体积、真实iOS arm64 Mach-O（不能用arm64模拟器代替）、两目标身份与共享声明、源修订和AOT内嵌修订、无profile/签名私钥/Debug资产。追溯文件`ios-i0-provenance.json`使用版本1，绑定源码、Flutter/Xcode、Release模式和unsigned-probe身份，不能只靠该文件自报通过。生成工程另校验两目标的entitlements源文件及其引用，随附固定声明供本机签名参考；Info自定义键和源文件均不是有效profile授权。Windows验证器优先Conda basic310，云端用现成Python标准库；不额外安装C盘工具链。操作入口见[探针说明](../../../verification/ios-private-probe/README.md)。

文件归属：Luna/max承接探针Flutter/Swift源和合成测试；另一Luna/max承接Python包校验器、反例测试及Windows包装；Sol负责云端生成/打包脚本、原生工程装配、Codemagic配置和独立验收。原生模板/脚本兼容性另做只读复核，文件不重叠。最终分别登记本机合成、云端实际构建、用户本机签名和目标机共享/续签证据，不以任一项替代其余项。

### 待确认修订：共享组请求元数据副本

当前仍按云端不签名实施。公开[AltSign实现](https://github.com/rileytestut/AltSign/blob/master/AltSign/Model/ALTApplication.mm#L147-L183)从Mach-O签名提取entitlements，[AltStore](https://github.com/altstoreio/AltStore/blob/marketplace/AltStore/Operations/FetchProvisioningProfilesOperation.swift#L376-L475)据此申请共享组；仅有外置`.entitlements`和自定义Info键不能作为它的请求输入。`ALTAppGroups`主要是重签后的运行时映射，也不等于profile授权。Sideloadly免费路径是否自动处理这些请求仍未验证。

建议在原始`ios-i0-unsigned.ipa`之外，另生成`ios-i0-signing-input.ipa`：对独立副本添加无开发者身份、无证书的ad-hoc元数据，host/Widget只声明既定共享组；固定Flutter框架只做同类封装。两目标Info附固定`ALTAppGroups`候选，另核验请求字典、ad-hoc标记和无profile，并对副本重复全部包校验。它仍不能直接安装，不向云端提供Apple账号/私钥/证书，不注册设备，不证明App Groups已获授权；实际Apple重签、授权与安装继续在Windows本机和iPhone验证。

这会超出原“云端仅编译”的文字边界。自动审批审查已拒绝实现该动作；截至本条没有落入构建脚本或执行。用户确认前只推进原始未签名包的格式修复与复验，不通过其他工具或间接执行绕过拒绝。
