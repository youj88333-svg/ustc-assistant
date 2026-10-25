# 跨端界面重构记录

## 2026-10-18：准备、安装与规格

用户明确采用[前端 Skill 调研](../../research/frontend-skill-selection.md)推荐的两个 Skill，授权安装，并按项目工作流开始整体重构。目标为简化层级、减少大块卡片、兼顾手机竖屏与 Windows 且保留现有功能。施工规格统一见[任务单](plan.md)，本记录不复制第二份当前规格。

### 实际安装

根读取内置 `skill-installer/SKILL.md`，使用其 `install-skill-from-github.py` 下载指定子目录，未安装仓库 CLI、整套插件或前端依赖：

| Skill | 上游与固定提交 | 实际全局目录 |
|---|---|---|
| UI UX Pro Max | [nextlevelbuilder/ui-ux-pro-max-skill](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill)，`56ea9cf174ed86786187daa9de0e6247cb0747e4`，`.claude/skills/ui-ux-pro-max` | `C:/Users/有机体/.codex/skills/ui-ux-pro-max` |
| Flutter 响应式 | [flutter/agent-plugins](https://github.com/flutter/agent-plugins)，`b60d0736a33a0de7d3f4ea2a7ad740ca0daa5c94`，`skills/flutter-build-responsive-layout` | `C:/Users/有机体/.codex/skills/flutter-build-responsive-layout` |

两次安装命令均退出 0，并返回 Installed。使用 `E:/conda/envs/basic310/python.exe`；下载/临时目录在 `app/build/ui-refresh/temp`，不改全局环境。全局 Skill 本身按 Codex 默认路径安装；SDK/AVD/Gradle/Pub 仍在 E 盘。新会话可自动发现，当前根已直接读取两份本地 SKILL 及 UIUX 的优先级/移动端参考后使用，不需等待重新启动应用。

### 推荐检索与适配裁决

查询输出仅在忽略的 `app/build/ui-refresh/research`，不带个人或业务数据：

1. `student productivity minimal --design-system --variance 2 --motion 1 --density 8`：风格匹配 Minimalism & Swiss Style，可借鉴功能优先、清晰对比和统一间距；页面模式却返回营销式 Product Demo + Features。一次收窄为 `productivity dashboard minimal` 后仍返回营销模式，因此**没有取得适用的应用布局推荐**，不照搬 Hero、视频/CTA、在线字体或网页动画。
2. `progressive disclosure hierarchy --domain ux` 结果主要为网页面包屑/标题；一次收窄 `progressive disclosure` 仍仅匹配网页标题，**没有取得已验证的应用渐进呈现条目**。收起辅助内容的依据是用户明确要求与项目现有审批/引用规则，不冒充检索结论。
3. 独立运行 `responsive layout density --stack flutter`，得到与当前 Flutter 3.44.x 适配的 `LayoutBuilder`、线性布局和 `SizedBox` 间距建议。首次将 `--stack` 混入 design-system 时工具明确提示被忽略，随后已分开执行。

本轮应用布局由用户目标、当前设计与 Flutter 官方 Skill 的可用空间/响应式准则确定。采用 UIUX 的本地移动端检查：Android 48dp 目标、清晰焦点、正文对比、避免键盘遮挡、字体缩放与减少动画。原有浅色主题继续使用，未新增暗色模式承诺。安装并非对 Skill 全部推荐的机械采纳。

### 保留与检查状态

开始时 `codex/design-reset` 位于 `3566a38`，工作区干净。Windows1.00、QA4004/4005 和既有失败证据保留。未读取正式库、学校响应、秘密或认证资产。本节仅记录准备；后续实际工程和检查结果另附，不借用前轮通过数当成本轮结果。

## 展示实现与集成修正

规格提交为 `806403b`。Sol 负责共享样式、应用壳、Agent/晨报及集成；两个 Luna/max 分别负责日程任务与设置表单，文件不重叠。另一 Luna/max 提供合成图像场景，Sol 随后修正并实际运行。Astra 对最终展示差异只读复核，没有代替根执行检查。

- `AppUi` 集中画布、文字、强调色、分隔线、控件边界、圆角及阅读宽度；`WorkspaceSection` 为透明章节。侧栏从 216 收至 184，窄桌面保留图标栏；手机仍用两个底部目的地和设置返回。
- Agent 去掉外层大框和助手整块底色，保留用户消息的轻量区分；输入框只留一层边界。当前审批仍有独立入口和手机自动弹层，历史过程/引用/思考继续按既有规则折叠。只建议开关增加明确的勾选状态。
- 晨报入口变为单行；阅读面板保留重点、安排、通知及覆盖提示。日程画布和同名颜色保留；详情直接展示时间、地点、教师和学期，教务补充字段放入“更多课程/考试信息”，未删除字段。任务列表、详情和时间块改用行与分隔线。
- 设置六区保留，平面文字分区取代成排胶囊；表单最大宽度 760。来源恢复、错误、共享密码影响、日志导出和危险动作提示不隐藏。未修改 Port、业务控制器、数据库、学校桥、认证和请求契约。

根在集成中修正了实际问题：任务选中行不能在无限高度父级使用 `CrossAxisAlignment.stretch`；设置章节重复 Key 及外层宽度约束；全局正文行高变化造成两倍字号周表表头溢出；短横屏下周表固定栏高度不足。后者用最小可用画布加局部纵向滚动回退，保留 48dp 日期/截止栏操作，不压小文字。

根查看原生图像后继续修正展示：短审批原先固定占可用高度 85%，存在大块空白，改为内容自适应且保留最大高度、长内容滚动和原 ID/世代检查；增加短方案不能拉成近全屏的行为检查。手机 OutlinedButton 原先仅覆盖触摸尺寸时丢失了全局形状，现在先继承样式再覆盖 48dp；分段按钮统一 8 圆角、默认底部弹层 12。晨报日期/状态按 3:1 分配，关闭按钮保持靠右。Astra 对这些后续差异再做只读复核，未发现可证实的权限或状态回归，根另行重跑相关检查。

图像 fixture 将 DPR 改为 1 时，最初误用了 AVD 的物理 136px 顶部 inset，截图出现夸大的顶部空白；这不作为产品布局结论。最终画布显式使用合成逻辑安全区 24/16dp，并在 teardown 还原。真实系统安全区仍由生产代码读取，A4 原生运行结果与 gallery 的受控画布分开解释。

### 检查中的失败与证据边界

检查输出、截图、SDK 临时文件统一保存在忽略的 `app/build/ui-refresh`。失败输出保留，复验结果另行记录：

- 子代理初检遇测试导入缺失和 SemanticsHandle 释放顺序错误，修正测试后重跑。根修正新合成 fixture 缺少页面枚举导入及静态检查提示。
- 最后补充教务字段折叠检查时引用了当前测试文件尚未定义的 `_tapKey`；最终 analyze 明确失败并中止后续检查。补齐带命中校验的辅助函数后重新运行 analyze，不用旧通过结果覆盖本次失败。
- 首次全套 Dart 捕获一份旧导航测试仍强制将日程分区按钮转换成 `ChoiceChip`。改为验证“任务详情是否实际出现、切回日程后是否实际消失”，继续检查一次性导航消费与后续用户选择，不锁定新控件类型。根第一次改写又错误预期周表，而该 fixture 明确使用日视图；保留这次失败，修正为检查日列表，先单独复验再重跑全套。
- 后续相关检查命令曾误列一份不存在的 `agent_phone_approval_test.dart`，命令明确失败；实际手机审批用例位于既有 `agent_workspace_page_test.dart` 及新增响应式场景中。保留失败输出并以正式全套和原生重跑结果为准。
- 新响应式检查实际捕获大字号表头和短横屏周表溢出，修复后相关 42 项通过；后续全套结果见交付核验。
- Windows 图像场景首轮以进程当前目录定位包根失败：原生 Runner 工作目录位于可执行文件旁。改为显式且受限的 QA 输出路径，校验包名、目录和非链接边界。随后两次断言分别错误地读取默认折叠的晨报列表、按纯标题匹配附带地点的全天项；这些属于测试预期错误，未据此改产品默认展开行为。
- 完整场景还修正了手机设置页返回、审批弹层完成后的关闭及详情弹层遮挡导航的测试操作；所有点击以实际命中检查为准，不忽略点击警告。
- Android 首轮图像场景在输出目录校验失败：平台临时目录可经 `/data/data` 与 `/data/user/0` 别名访问。改为先解析 QA 私有 `cache/code_cache` 根，再校验固定子目录类型与规范位置，保留对子目录链接/替换的拒绝；复验一项通过。随后导出 PNG 晚于下一次 APK 安装，`code_cache` 已清理；PNG 签名检查拒绝了实际为 `cat` 错误文字的 80 字节文件。该失败另存，单独重放图像场景并在安装其它入口前立即导出，不将错误文件当成图像证据。
- Windows 日程原生组首例耗时 5:04，整组 6:29 后四项通过；设置维护组第二例也出现长等待，整组 8:53 后三项通过，没有失败输出。Astra 复核没有找到展示差异引入的持续动画或定时器，耗时原因未证实，不将猜测写成根因或改业务规避，也不拿合成 Debug 执行耗时推断用户设备性能。

新 gallery 使用生产 Widget 与有限合成 Port，不联网、不读取正式数据；未预期的方法直接失败。它证明展示与入口可达，不代替真实学校、真实模型或目标手机验收。其中 fixture 主动提高 history epoch 并清空 pending action，因此只证明状态失效后入口消失，底层迟到审批拒绝仍由既有真实控制器测试覆盖。gallery 的设置入口直接装配来源页，六区设置由既有设置测试覆盖，不宣称仅凭该图像场景已验全部设置。

## 交付核验

根将既有设置/来源的宽窄及大字号检查改为使用生产 `productTheme`，避免只在默认 Material 主题下通过。正式核验使用本轮最终源码；结果按完成顺序登记。

| 实际检查 | 结果与范围 |
|---|---|
| 最终 `Analyze` | 无问题，6.0 秒 |
| 单独 `agent_discussion_ui_test` | 10 项通过，实际日程/任务导航行为复验 |
| 最终 `DartTest`（Windows 宿主） | 1558 项通过、1 项平台跳过，2:20；包括本轮响应式/图像交互场景和生产主题下的设置检查。跳过项是仅在非 Windows 检验 DPAPI 不可用的分支 |
| Windows `agent_model_flow` | 5 项通过：loopback 模型、工具往返、取消、审批提交/拒绝/撤销与重启 |
| Windows `calendar_workspace_flow` | 4 项通过：原生临时库中的日程任务写入/移动/撤销/重启、失效来源与冲突显示 |
| Windows `settings_maintenance_flow` | 3 项通过：偏好与资料保留、注册目录清理、失败意图恢复；只操作合成 nonce 目录 |
| Windows `m6_flow` | 5 项通过：提醒工具与假 OS 队列、修改/撤销、维护失败重试、Debug 隔离通知宿主 |
| Windows `young_automation_flow` | 3 项通过：合成认证、延迟 SPA 固定导航、回调与保存；没有访问真实学校 |
| Windows `ui_refresh_gallery` | 最终一项通过，10 秒；重新渲染 10 张生产 Widget 图像，包含教务信息折叠的最终展示 |
| Android API34 `UIRefresh` | 修正临时路径后 1 项通过；覆盖手机审批打开/关闭/批准/拒绝/失效显示、来源、晨报、周表、详情、提醒和任务 |
| Android API34 `A3` | 2 项通过：Keystore/loopback SSE/规划/审批/回执/历史及退后台撤销 |
| Android API34 `A4` | 1 项完整流程通过：原生临时 Runtime 的手机壳、日程、任务、偏好、图片和安全日志保存入口；真实相册/文件管理器手势另待人工 |

原 Windows1.00 ZIP、QA4004/4005 三个交付文件均重新计算 SHA-256 并与原记录比较，一致；结果保存在 `app/build/ui-refresh/preserved-artifacts.json`。本轮没有操作用户 MuMu，ADB 仅使用 5038 端口及确认名为 `ustc_android_a0_api34` 的独立 QA AVD。

根实际查看了 Windows 1280×800 和 Android 合成 360×780 的 Agent、当前审批、晨报、周表/课程详情、任务、来源恢复及提醒表单关键图像。手机正常字号保留七列；时间轴可纵向滚动，极大字号按既有最小列宽回退，不宣称手机一屏无滚动显示全天。最终 PNG 与逐图摘要分别位于 `app/build/ui-refresh` 和其 `android-gallery` 子目录，没有纳入发布资产或 Git。独立 AVD 已正常停止；没有启动用户正式 Windows 资料。

工程提交为 `0763909`，实际图像修订与 QA 路径/安全区修正为 `094a0560569989ad7350db83e9941e54a2f81ae3`。独立体验构建固定后者作为 `USTC_BUILD_REVISION`，不把后续纯文档提交当成另一份工程来源。

首次构建包装在 Windows PowerShell 5 将 Java 的 `Picked up JAVA_TOOL_OPTIONS` 信息性 stderr 当作异常，提前中止；该日志另存。临时包装改为逐项以真实退出码裁决，再运行构建/签名/包内容检查，没有更改项目编译规则、TLS 或全局环境。

### 独立体验产物

根从固定工程提交执行 `tools/android-a0.ps1 -Action Build -BuildRevision 094a0560569989ad7350db83e9941e54a2f81ae3`：Flutter x64 Debug、Gradle `assembleDebug` / `assembleDebugAndroidTest` / `processReleaseMainManifest` / `lintDebug` 均退出 0。另以相同 E 盘过程环境执行普通 `lib/main.dart` 的 arm64 Debug split 构建。两 APK 均核验包名、递增版本、单 ABI、沿用 QA 签名、编译修订、固定语音模型与许可，且 kernel 不含本轮合成入口标记。当前路径、大小、SHA-256 和主动覆盖说明统一维护在[人工说明](../android-apk/manual-validation.md)，不在此再维护一份分发元数据。

| 产物 | 实际结果与范围 |
|---|---|
| `app/build/ui-refresh/artifacts/USTC-Assistant-Android-UI-QA4006-x86_64.apk` | 普通入口、签名及资源核验完成，供用户主动覆盖 MuMu；本轮没有向 MuMu 安装 |
| `app/build/ui-refresh/artifacts/USTC-Assistant-Android-UI-QA2006-arm64-v8a.apk` | 同源码、同 QA 签名；仅打包核验，未在 ARM64 手机运行 |
| `app/build/ui-refresh/windows-staging/x64/runner/Release/ustc_assistant_m0.exe` | 独立 CMake Release/INSTALL 成功；只安装到预先校验的暂存前缀，未替换原 Release 或启动正式资料 |

Windows 先执行 `flutter build windows --release --config-only --no-pub --target lib/main.dart --dart-define=USTC_BUILD_REVISION=094a0560569989ad7350db83e9941e54a2f81ae3`，再以 VS18/x64 在 `build/ui-refresh/windows-staging/x64` 生成，校验 `CMAKE_INSTALL_PREFIX` 后执行 Release INSTALL。最终核验确认普通入口、AOT 中的工程修订、无合成入口标记、模型摘要与许可，以及 36 个文件的 SHA-256；结果在 `artifacts/windows-staging-manifest.json`。首次核验曾错误假设 SDK 用 `set(FLUTTER_TARGET ...)`，实际为环境列表中的 `FLUTTER_TARGET=lib/main.dart`；修正核验器读取方式后通过，没有据此修改或重建产品。

该 Windows 路径是完整暂存目录，不是新公开发行包；在原应用正常退出后再由用户主动打开其中 EXE，目录内 DLL/资源需一起保留。Windows1.00旧ZIP再次核验摘要与原值一致，旧QA均保留。没有修改系统代理、信任、用户/系统环境、MuMu或正式资料。

### 交付状态与待体验

U0–U4 工程及根检查完成，本轮用户体验仍待确认。源接口/认证、C3/工具与数据模型未变，既有日程、任务、聊天、凭据、偏好和原验收结论不迁移、不清空。仅需轻量查看对话层级、当前审批、日程/任务详情和设置组织是否顺手；不要求为视觉验收重登学校或删除现有资料。

真实手机/鸿蒙、MuMu真实来源与模型字段、麦克风、文件选择/保存和系统通知手势等原未观察项继续留在 Android A7；ARM64 构建不替代目标机验证，Windows 暂存构建也不替代本轮体验。未创建虚构的用户通过记录或关闭本阶段，未公开发布或推送。

交付前再次核对三份受保护旧交付的摘要及两份新 APK 的大小/摘要，均符合各自记录。最终文档检查覆盖 150 份 Markdown、1196 个本地链接和原归档清单；`git diff --check` 通过。构建、截图和临时检查器均排除在 Git 外；规格、工程与核验文档分别本地提交。
