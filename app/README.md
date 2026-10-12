# USTC Assistant · Windows 应用

新 Flutter 工程包含已关闭的 M0 离线演示、M1 教务自动采集与本地日程、M2 二课活动关联日程与活动只读查询，以及 M3 内部公开查询和精选文本知识库；M3 的关闭不表示 Agent 接入或正式公开查询用户入口已交付。当前范围见 [状态页](../docs/status.md)，历史失败/检查和用户关闭见 [阶段索引](../docs/milestones/README.md)。

## 启动与构建

在本目录执行（当前机器 SDK 未加入 PATH）：

```powershell
& 'E:\flutter\flutter\bin\flutter.bat' pub get --offline
& 'E:\flutter\flutter\bin\flutter.bat' run -d windows
```

依赖锁定在 `pubspec.lock`；sqlite3 原生 hook 首次需下载并缓存库，尊重既有 7897 代理环境。WebView2 SDK 固定为 NuGet `Microsoft.Web.WebView2 1.0.3967.48`，从用户 NuGet 缓存读取；自定义位置可用 CMake `USTC_WEBVIEW2_SDK_ROOT`。新机器安装通常的 Windows Flutter 工具链与 WebView2 Runtime，不需要旧 CAL 补丁资格。

构建正式入口：

```powershell
& 'E:\flutter\flutter\bin\flutter.bat' build windows --release --no-pub --target=lib/main.dart
```

启动 `build/windows/x64/runner/Release/ustc_assistant_m0.exe`；分发保留整个 Release 目录的 DLL、`data/` 和资源。集成测试可能替换该目录中的测试助手，测试后再构建正式入口。

## 教务日常采集

1. 在“M1 教务采集与本地日程”首次填写预期学号与学校密码，按需勾选本机加密保存；已有绑定和保存密码时留空，点击“自动采集”。输入启动后清空，不回填保存密码。
2. 固定自动认证后读取新学期目录。首次按北京时间从目录选择当前学期，成功后保存目录和学期；以后可在同步开始前改选，默认上次成功项，每次重新核验。指定项消失或当前标签不唯一时暂停选择。
3. 学校验证码、通行密钥或额外授权由你在学校窗口完成，再点击“登录完成，继续采集”。一次作业已提交的密码不会再次自动发送。
4. 导入完成后查看本地日程，时间按北京时间显示。“课表学期”只筛选本地展示，不改变采集选择；考试独立显示。隐藏/恢复在再次同步与重启后保留。

课表完整范围内的来源缺失只标示状态，范围外旧记录保留，不自动隐藏或删除。逐行检查后合并完全一致重复项，同键冲突拒绝；摘要分别报告来源行、唯一日程和合并数。真实非空考试已批准后续补验，当前零行不撤销旧考试。

## 二课查询与同步

首页使用“M2 二课日程与报名查询”。两来源共享同一份本机加密学校密码，二课业务身份、浏览器分区和许可独立；密码留空可使用已保存密码。

- “查询报名活动”自动认证并读取完整列表。展开条目看地点、活动时间与独立报名时段；结果仅在本次内存中，不导入日程，重启不恢复列表，也不会执行学校报名操作。
- 同步前输入北京时间日期范围，最多 62 天，首次默认当月、以后默认上次成功范围。“同步二课日程”逐日读取全部页，只导入学校个人日历中与活动关联的记录；未关联记录排除。活动关联不代表已独立证明本人报名成功或取消。
- 本地日程可隐藏或恢复；重复同步保留本地身份/隐藏设置，缺失和范围外记录仍保留。门户及回调期间自动等待，无需自行输入网址或登录后逐页选择。
- 没有可用密码、学校挑战/授权或页面结构无法安全确认时，在学校窗口处理后点击“登录完成，继续”。

## M3 内部验收入口

普通构建不显示 M3 入口。临时验收版使用同一正式内部端口，只需在构建命令增加：

```powershell
& 'E:\flutter\flutter\bin\flutter.bat' build windows --release --no-pub --target=lib/main.dart --dart-define=USTC_M3_VALIDATION=true
```

该面板用于课程/教师查询、课程与点评筛选、固定校园栏目及正文读取、本地精选材料检索和受控载入/清库。首次评课联网需单独授权；每次在线作业与 JW/Young 共用全局租约，本地检索不占网络租约。财务在线关键词与常见问题回复暂不可用，固定栏目和本地检索分别使用。结果显示来源、版本/人群、时间与实际覆盖；金额及流程的现行适用性保留未知。

点击“载入首批清单”接受随包的 7 项校核长期材料，之后可离线检索/读 Markdown；重复载入报告重放，不重复写。查询和启动不会隐式入库；“清除知识库”需两次确认，只清公开文本、索引与回执，保留 JW/Young 日程、密码和目录，重启不会自动重建。清库后如需恢复，主动重新载入。新版逐项事务回执与取消后的已提交事实分别显示。

“复制安全验收摘要”输出 public-query-validation-v1，只含状态/固定失败/安全计数，不含关键词、原文、引用值或账号。原文及附件 HTTPS 链接可以复制后由用户打开，应用不下载文件，Markdown 不自动联网加载图片。该入口不是正式产品路由，M3 不接 Agent、模型或工具注册；材料转换工具也不装入应用。

制作资料后，从仓库根运行 `tools/prepare-knowledge-assets.ps1 -Check`，确认校核摘要和固定编译资产一致；需要更新时由维护版本流程重新编译，不允许应用选择任意 URL 或本机路径。

临时面板是可选调试辅助，不要求用户重复点击才能验收内部能力。维护者可明确启动实际随包资料开发核验：

```powershell
& 'E:\flutter\flutter\bin\flutter.bat' run -d windows --debug --no-pub --target=tool/m3_reviewed_bundle_probe.dart --dart-define=USTC_M3_REVIEWED_BUNDLE_PROBE=true
```

该程序不显示界面，不访问网络或正式数据库；使用默认资源 Loader、正式服务和独立临时原生库核验全部 7 项的载入、中文检索、全文读取、重放、数据库重开、清库不重建及重载，关闭后删除自建临时根，仅输出安全计数与固定失败阶段。必须显式 opt-in，普通入口与 CI 不运行它；它核验已批准的实际公开文本，不冒充合成测试、政策现行证明或用户体验验收。

## 取消、清理与恢复

- 作业进行中可取消；取消不撤销已提交业务，未提交迟到结果不交付。窗口或认领未完成时使用相应“重试收口/认领”或“重试二课收口”，旧事实保留。
- “清除浏览器登录资料”清本应用教务分区；“清除二课登录资料”仅清二课分区。两个入口均保留相关日程及共享加密密码，清二课资料还保留 JW 目录/分区。
- “删除保存的学校密码”在全局空闲时删除共享密码，影响两来源；账号、浏览器资料、目录和日程保留。以后重新提供密码或手动登录。
- 普通退出保留本地数据。分区保留/复用不表示学校永久免登录；只管理本应用资料，不操作系统 Edge/Chrome 资料。

## 目录与诊断

正式根为 `%USERPROFILE%/.ustc-assistant/local_v1`，业务库文件名为 `jw.sqlite`，当前 schema v5，增量保留 JW/Young 表并加入公开状态、知识正文/片段/索引、材料批次及回执。学期目录、成功范围及受保护凭据与对应成功事务保存；保护机制为 Windows DPAPI CurrentUser，不承诺跨用户/设备解密，不宣称整个数据库加密。

独立离线演示根为 `%TEMP%/ustc_assistant_m0_demo_v1`。正式首页下方默认折叠“离线 M0 合成演示”；正常/重放、取消、失败和恢复只操作合成数据。目录排他保护第二实例，勿手动修改或清理使用中的数据库/分区。

“复制导入脱敏摘要”生成 `jw-import-v1`，“复制二课同步摘要”生成 `young-import-v1`，用于反馈固定状态/失败阶段、安全计数、密码存在及分区保留/复用标志；不发送账号、密码、原文或日程明细。旧观测/候选面板位于折叠的诊断区域，仅用于独立诊断，候选摘要不授予生产许可。

## 开发检查

```powershell
& 'E:\flutter\flutter\bin\flutter.bat' analyze --no-pub
& 'E:\flutter\flutter\bin\flutter.bat' test --no-pub
& 'E:\flutter\flutter\bin\flutter.bat' test integration_test/m0_flow_test.dart -d windows --no-pub
& 'E:\flutter\flutter\bin\flutter.bat' test integration_test/jw_sync_flow_test.dart -d windows --no-pub
& 'E:\flutter\flutter\bin\flutter.bat' test integration_test/young_sync_flow_test.dart -d windows --no-pub
& 'E:\flutter\flutter\bin\flutter.bat' test integration_test/young_automation_flow_test.dart -d windows --no-pub
& 'E:\flutter\flutter\bin\flutter.bat' test integration_test/public_knowledge_flow_test.dart -d windows --no-pub
```

按变更选择相关原生套件，里程碑关闭前完成全套相关检查和正式构建。所有自动检查只使用合成/loopback/随机临时资产，不访问学校或正式库。原生 HTTPS fixture 可用 Conda basic310 的 OpenSSL 或 `USTC_TEST_OPENSSL`，不写系统信任；既有测试助手只终止其自建进程并清理自身已排空目录。实际命令与结果记阶段记录，不在本帮助中积累轮次。
