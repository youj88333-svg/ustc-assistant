# A4 手机界面、图片与日志导出（2026-10-16）

## 范围与分工

按[迁移任务单的 A4 契约](../plan.md#a4手机界面与文件实施契约)实施，沿用 07–15、A1 私有根及 A3 Agent，不改 schema18、20 工具、来源租约、既有授权或 Windows 1.00 资料。规格提交为 `56e8a33`，主要工程为 `a3c0c7098cef29a1d1dab81068acbfc566b72a5e`，QA 夹具兼容修订为 `8dbe8a2ab206c5e67281b8ca4f678bde70f69976`。

Sol 负责主壳、Agent、组合根、偏好保存、Dart/Kotlin 文件桥和原生集成；两名明确指定的 `gpt-6-luna / max` 分别承接不重叠的日历与任务/设置布局，另复用一名既有子代理编写原生合成检查。根复核并修正布局、夹具、生命周期和打包问题，实际执行下列检查；子代理的通过声明不替代根结果。

- 手机保留 Agent/日程两个主页，改用底部导航，设置为辅助入口；键盘出现时释放顶部与底部导航占用。设置返回原主页，日程返回 Agent；先关闭键盘或弹层。Agent 单独保留挂载，切页保留未发送文字和已选图片，停止听写并拒绝离页后的旧选图结果；其他页面仍在离开时销毁，保留旧回包防护。
- 新 Android 数据库初始化为日视图，日/周选择经现有设置事务保存，重开保留；已有数据库偏好不被初始化参数覆盖。周视图横向浏览，保留教学节次、同名同色、教室优先、全天/任务截止栏及冲突语义。任务、时间块、日期/时间和提醒表单可在小屏、大字、横屏及键盘下滚动操作，常用按钮和日程/截止入口按至少 48dp 处理；桌面周列最小宽度保留。
- `ustc_assistant/files_v1` 只有 `pickImages` 与 `saveDiagnosticLog`。系统照片选择器不可用时回退限定图像的 SAF；不索取媒体库/所有文件权限、不持久授予 URI，不把 URI 转成文件路径或发送给 Agent。原生逐项有界读取，最多三张、每张 10MiB；不信外部 SIZE/MIME/名称，先验 PNG/JPEG/WebP、1600 万像素，再经共用单帧、去元数据、1536 长边/单张 3MiB/合计 6MiB 规范化。不写图片缓存，临时字节尽力清零。
- 日志仍由既有 DiagnosticsPort 生成，保留 7 天/1MiB 日志规则；Dart 重建封套/事件白名单，原生复验固定封套并限制导出 2MiB，经系统创建 JSON 文档后写入。取消不显示已保存，失败尽力删除本次不完整新文档；不存在通用保存路径、数据库或认证资料导出入口。
- 文件读取/写入在原生工作线程，选择文件的人工时间不限，提供方 IO 限 30 秒。进入后台时不取消正在打开的系统选择器，返回后的 IO 若再失去宿主则撤销。超时先回复失败，直到提供方真正排空才释放唯一槽位；若第三方提供方永久忽略取消，需其排空或重启应用后恢复，不能将超时回调说成已停止所有外部 IO。进程消失不恢复旧选择/自动重发。

## 根实际检查

仅使用合成数据、独立 QA 私有临时根和内容提供方；没有访问真实学校、模型、正式业务记录或浏览器认证资产。以下 `reports/` 相对 `app/build/android-a4/`。

| 检查 | 实际结果与证据 |
|---|---|
| 静态分析 | 最终 `flutter analyze --no-pub` 无问题；`reports/analyze-delivery.txt` |
| 全套 Dart | 1471 通过、1 平台跳过，`--concurrency=2`；`reports/dart-tests-final.txt`。不将独立复验数量另加到全套结果 |
| 手机布局与文件适配 | 全套内覆盖 320/360/412dp、800×360 横屏、1.0/1.5/2.0 文字、键盘、长审批、返回、草稿、日/周保存失败和旧回包；检查控件矩形/实际命中。覆盖规范化、超限/坏图、原始缓冲清理、脱敏封套与取消，不用缩小系统字体消除溢出 |
| Android UI/持久化 | API36 一组合成集成通过；`reports/android-ui-first.txt`。真实 OwnedApplication/RuntimeBootstrap、Android SQL 私有根、底部导航、任务与日程、草稿保留、设置返回、大字横屏和模拟键盘遮挡、日视图初始值、改周视图后重开及日志白名单均断言通过；网络尝试为零 |
| Android 原生 | API36 共 22 项通过：文件读取/保存 9、通道/生命周期 6、Keystore 6、QA 宿主 1；最终 `reports/native-instrumentation-api24-fix.txt`。合成提供方故意谎报 SIZE/MIME，验证有界读取、尺寸、坏图、URI/重复项、取消、迟到回包、真实 codec 字节副本、部分写入删除及超时占槽/排空；不打开真实系统选择界面 |
| Windows 回归 | 五套共 16 组通过：应用壳 1、日程/任务 4、设置/维护 3、诊断 3、Agent 5；`reports/windows/`。每套独立 Flutter CLI、进程级 `USTC_NOTIFICATION_TEST_HOST=1`，不登记生产通知、不访问真实来源/模型 |

Android 集成中的键盘/横屏/大字使用 Flutter 测试参数，不等于实机系统 IME、触摸、系统返回手势或厂商交互验收。原生文件检查使用 QA 宿主和合成内容提供方，不把受控 Intent 与 activity-result 测试称为真实相册/下载目录已验收。

## 失败与修正

早期报告完整保留，不将名称含 `pass` 的报告自动视为通过。任务/提醒表单首次存在小屏/大字和短视口溢出，根依据实际可用高度约束工具栏和表单，任务标题改入滚动列表；自定义提醒弹窗的控制器改由弹窗状态持有，取消选择会恢复旧值。部分测试同时匹配了外层列表和输入框内部 Scrollable，改为明确外层后复验；48dp 浮点边界允许机器精度误差，没有降低触摸尺寸。

首次全套 Dart 发现桌面批准占位文案变化，恢复原桌面 `确认 / approve / 取消`，手机继续用紧凑中文提示。其后一轮全套中两项既有来源短时限用例超时（`reports/dart-tests-pass.txt` 实际不是全通过）；未修改生产超时，先单独运行相关 44 项全部通过，再以较低并行度执行最终全套通过。

首次 instrumentation 的测试内容提供方独立进程缺 Kotlin 运行库，且凭据测试类限定名有误；将提供方和宿主放入仅 Debug 的 QA 源集，保持不导出，使用正确测试类限定名，22 项通过。普通构建的首轮 lint 又发现该 QA 夹具使用 API29 的 ContentResolver.call 重载；改用既有 URI 重载，未提高 API24 下限、未加 lint 抑制或基线，重编并再次运行 22 项通过。失败见 `reports/native-instrumentation-first.txt`、`reports/native-crash-first.txt`、`reports/build-final.txt`、`reports/lint-first.txt`；兼容修订后的构建/lint 见 `reports/native-api24-fix-build.txt` 和 `reports/lint-pass.txt`，后者为 0 错误、76 警告，不能称为无警告。

## 普通包与保留边界

最终 `Build -BuildRevision 8dbe8a2ab206c5e67281b8ca4f678bde70f69976` 成功，普通 APK、AndroidTest、生产 Manifest 与 lint 检查通过，见 `reports/build-delivery.txt`。普通入口包保存为 `app/build/android-a4/artifacts/USTC-Assistant-Android-A4-QA-x86_64.apk`，125,147,031 字节，SHA256 为 `59deb57c180b047849a2863f7fb8fd87b26423bbcc2b7a5a358d1d5a61df6c01`，同目录保存 manifest 和 APK 元数据。

核验包名 `cn.ustcassistant.mobile.qa`、版本 `1.0.0-qa-a4`/4001、仅 x86_64、MainActivity；流式检查 Dart kernel 中有最终源码 SHA，且不含 A3/A4 集成测试入口。生产合并 Manifest 不含 QA Activity/内容提供方/明文配置或媒体库/所有文件权限，备份和明文禁用规则保留，见 `reports/production-manifest.xml`。这是独立 Debug QA 包，包含本轮不导出的 Debug 合成文件夹具，不是 arm64、正式签名或 A8 发行证明。

普通包首次覆盖安装后的启动联合命令未满足成功守卫，当次原始启动输出未保留，不能补判原因；复查时 Activity 已运行，崩溃缓冲只有更早的系统和已修正测试进程记录。随后仅停止独立 QA 进程、不清数据，再实际冷启动取得 `Status: ok`/`LaunchState: COLD`，耗时 5834ms，进程存在且当前进程崩溃缓冲为空，见 `reports/ordinary-launch.txt`、`reports/ordinary-current-crash.txt`；普通首屏截图 `reports/ordinary-phone.png` 经根查看，导航、正文和输入区无重叠。该启动冒烟不能替代完整实机体验或性能验收。

Windows 1.00 ZIP、A2/A3 QA 包摘要及 `windows-v1.00` 标签复核不变，main 的 34 项修改/14 项未跟踪、参考分支的 3 项未跟踪继续保留，见 `reports/preserved-assets.json`。SDK、Gradle/Pub 缓存、AVD 和临时目录继续在 E 盘；本阶段不修改系统环境或用户代理，不读取正式资料。

结束时已停止专用模拟器和 ADB5038。确认无活动模拟器/编译后，逐个校验绝对路径、Git 忽略状态和目标/后代无重解析点，仅删除本轮再生的 `app/.dart_tool/flutter_build` 及 API36 离线启动快照；实际释放约 3.104GiB，见 `reports/generated-cleanup.json`。SDK、全局缓存、两个 AVD 用户磁盘、QA 签名密钥、全部报告和明确交付件保留；不执行会删掉这些内容的整目录 clean。

A4 工程与合成检查通过，下一切片为 A5 提醒、晨报与前台每日二课同步。目标手机的实际相册/SAF、系统 IME/返回手势、触摸体验、Android14/其他低版本、可安装 APK 的鸿蒙仍待 A7；真实模型和学校仍按 A2/A3 保留条件补验。无设备时不作真人关闭，不将 API36 合成结果替代这些条件；原语音问题继续留给 A6 及实机复验。
