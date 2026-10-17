# A5 Android提醒、晨报与前台每日同步（2026-10-17）

## 范围与实施

依据[迁移任务单A5契约](../plan.md#a5提醒晨报与日常同步实施契约)、架构07–12、质量13、审查14和工作流15实施。规格提交为`9d7d275`，工程提交为`611d252a9265bb19d0e60d1b6009a14da51a7e67`；保留schema18、20工具、C3业务权威、C2租约、默认关闭的独立开关和Windows1.00交付，不增加常驻服务、推送服务器、后台学校采集或真实资料迁移。

Sol负责原生提醒、Dart适配、维护与组合根、集成及根实际验收；明确指定`gpt-6-luna / max`的两名子代理分别完成前台同步收口和权限界面，随后承接不重叠的原生/MethodChannel合成测试。`gpt-6-astra / high`只读复核持久门禁、冷点击和恢复边界。子代理的交付及静态自查不替代下列根检查。

- 使用AlarmManager与NotificationCompat固定渠道，声明通知、精确提醒和启动恢复权限，不引入新Dart插件。通知许可、精确提醒设置与系统通知界面只由用户点击打开；无精确权限时登记非精确提醒并说明可能延后。Android最多480项登记，C3仍保留180天/512的有界期望及部分完成状态。
- `android_notifications_v1`只承载固定能力、当前C3允许身份、登记、撤销和点击。私有`notifications_v1/reminders.json`是有界原生投影，AtomicFile持久化，不复制业务库或凭据。`pending`表示本地持久登记加系统调用回执，不是AlarmManager队列独立枚举，更不是送达证明；界面与Agent分别展示此依据、精确能力和登记上限。
- 维护先暂停/排空提醒，再持久block并推进原生generation，之后才提交C3 intent。原生投递最终校验、notify、撤销和恢复共用串行边界；清理先撤销投递资格，再取消待发及本身份已展示通知，失败保留待办。明确无intent的失败出口重新按当前C3绑定；结果不明继续阻止，初始化/启动广播不能自行解除。普通退出仅释放适配资源，保留未来登记。
- 每条PendingIntent的身份包含原生generation及独立nonce，Intent不携带标题、地点或C3 token。Receiver只读取私有镜像，不启动Flutter、业务库、模型或学校通道。先持久消费再显示，避免重放，但存在消费后、显示前进程消失而漏发的窗口，不承诺exactly-once。时钟回拨时相同已消费请求拒绝重新登记，暂报stale直到重新对账，不重新生成nonce投递。
- 冷点击在适配器具备初始化及订阅条件后才排空；协调器另以最多32条原始activation等待首帧订阅，再经C3复核当前目标和generation。维护/关闭撤销旧导航；点击不执行业务写入。原生恢复改为批量持久未登记/登记结果，避免480项恢复逐项写完整镜像；普通同进程重复initialize不反复重建相同权限状态。
- 晨报沿用首帧本地事实、独立限额公开查询和无工具模型通道、06:00准入、缓存及前台聊天优先，不阻塞启动/输入。Android退后台会撤销并排空本协调器的二课每日许可，包括claim竞争和手动续行；不取消外部来源作业，回前台重新准入，不恢复旧尝试。Windows默认行为保留。

## 根实际检查

仅使用合成/loopback、独立QA应用及临时所有权根；不访问真实学校、模型、正式业务记录或认证资产。以下`reports/`相对`app/build/android-a5/`。

| 检查 | 根实际结果与证据 |
|---|---|
| 静态分析 | 最终`flutter analyze --no-pub`无问题；`reports/analyze-complete.txt` |
| 全套Dart | 1498项通过、1平台跳过，`--concurrency=2`；`reports/flutter-all-complete.txt`。此前1495项及补充37项检查独立保留，不累加为全套数量 |
| 共享晨报与日更 | 全套覆盖05:59/06:00、缓存/跨日、缓慢来源/模型、聊天优先、取消/后台/迟到结果、清空/重置、预算/挑战/退避/范围及许可；Android额外覆盖后台撤销、claim竞争、不取消外部作业和Windows默认行为。未调用真实来源/模型 |
| Android原生 | API36最终32项通过：提醒镜像/投递边界10、凭据6、文件9、通道与生命周期6、QA宿主1；`reports/native-final.txt`。480项镜像批量恢复通过小于7秒断言，仅使用Fake OS driver，不宣称480条真实OS调度耗时 |
| Android系统 | 独立QA身份实际允许通知/精确闹钟。验证普通进程退出后投递、已展示及待发撤销、block后恢复不投递、权限撤销状态、无精确权限的非精确登记、模拟器重启恢复及到期后系统activeNotifications存在；`reports/os-run-final.txt`、`reports/os-api36/`。重启由变化boot_id和boot_completed核验，非用界面重开代替；不把系统已接收等同用户已看见 |
| Android业务联动 | API36一组合成集成通过；`reports/android-runtime-first.txt`。真实RuntimeBootstrap/Android SQL私有临时根/C3写入/系统桥贯通：日程登记、普通关闭后保留、重开对账、完成后撤销、任务截止登记、维护撤销。断言网络尝试为零，QA应用保留安装；不作真人体验结论 |
| Windows回归 | 六套20组通过：M6提醒5、每日二课2、设置维护3、日程任务4、Agent5、应用壳1；`reports/windows/`。每套独立Flutter CLI、进程级`USTC_NOTIFICATION_TEST_HOST=1`，不登记生产通知，退出恢复原进程环境 |

接口/nonce/维护恢复、冷点击两层排空、队列超时放弃及正常close保留都在合成检查中有反例；实际系统通知栏点击与权限界面人工操作仍归入下方未观察项。Agent提示修订为v11，`query_reminders`补充平台登记证据、精确能力和上限，不增加工具或授权类别。

## 发现与修复

Luna首次在沙箱内调用Flutter启动脚本，没有实际进入Dart测试；根在允许写E盘SDK缓存的进程环境重跑成功，没有修改SDK或全局环境。初次全套暴露了排队调用把等待前序时间计入原生调用超时的问题：现按真正开始调用计时，并为放弃的排队请求设置有界等待，禁止其稍后才执行写入，迟到原生调用仍持有槽位直到排空。旧“第几次current检查后失效”的测试改为在实际发布时注入版本变化，继续验证发布后的补偿。

独立审查指出适配器到协调器、协调器到首帧两层冷点击丢失，以及时间回拨重新投递问题，均已补边界检查。初次原生批次误用了凭据测试类的包名；修正为`cn.ustcassistant.mobile.qa.credentials`后整批通过，保留`native-instrumentation-first.txt`，不把类加载失败算作应用缺陷或通过。初轮OS脚本在模拟器重启阶段得到ADB非零，未保留具体子命令，不能补判应用Receiver失败；脚本现保留错误并核对变化的boot_id与启动完成，整轮重跑成功，见`os-run-first.txt`、`os-run-final.txt`。精确设置入口补API24–25回退，不提高安装下限或压掉lint检查。

普通启动首张截图包含System UI无响应弹窗。事件缓冲只记录`com.android.systemui/.SystemUIService`在02:13:15 UTC执行服务等待20137ms；该时间属于模拟器重启期，早于本轮02:14:29到期通知检查，不能据此认定提醒导致ANR，也不把系统异常抹去。应用本身当前PID崩溃缓冲为空。选择“Wait”后首屏恢复，根已查看`ordinary-phone-recheck.png`；随后重新投递固定合成提醒并展开系统通知区，根实际看到“A5 合成提醒”及地点内容，截图`system-notification-shade.png`。最终清理摘要为零登记/零已展示项，`os-visual-final-clear.json`；ANR原图与事件记录保留，不把这些结果当目标机体验通过。

## 普通QA包与保留

`Build -BuildRevision 611d252a9265bb19d0e60d1b6009a14da51a7e67`通过，包含普通入口、AndroidTest、生产Manifest及lint；`reports/build-delivery.txt`。lint为0错误、79警告，`reports/lint-delivery.txt`，不能称为无警告。

普通包保存为`app/build/android-a5/artifacts/USTC-Assistant-Android-A5-QA-x86_64.apk`，125,251,090字节，SHA256为`6eda718a9c299234996da65102368d5dfd318b169e26897444b6fc55e593f704`；同目录manifest与APK元数据记录包名`cn.ustcassistant.mobile.qa`、版本`1.0.0-qa-a5`/4001、仅x86_64。流式检查kernel内有工程提交SHA且不含A1–A5集成入口；生产Manifest不含QA Activity/提供方/明文配置，两个提醒Receiver不导出，未增加媒体库/所有文件或USE_EXACT_ALARM权限，备份和明文禁用保留。QA包含Debug专用合成夹具，不是arm64、正式签名或A8发行。

覆盖安装普通包及对应测试APK后，32项原生检查再次通过，`reports/native-delivery.txt`。实际冷启动`Status: ok`/`LaunchState: COLD`，5889ms，当前PID崩溃缓冲为空，`reports/ordinary-launch.txt`、`reports/ordinary-current-crash.txt`；首屏和系统弹窗复查分开留证，不把冷启动成功当完整性能或触摸验收。

Windows1.00 ZIP、A2/A3/A4 QA包与`windows-v1.00`标签摘要复核不变，`reports/preserved-assets.json`。main仍为34项修改/14项未跟踪，参考工作树为0项修改/3项未跟踪，本切未写入这些工作树；计数不是逐文件内容证明。SDK、Gradle/Pub缓存、AVD及临时目录继续在E盘，不改全局环境、代理或系统信任。

收口已关闭专用模拟器与ADB5038。确认没有活动编译/模拟器后，逐个验证目标绝对路径、Git忽略状态和全树无重解析点，仅删除再生的`app/.dart_tool/flutter_build`及API36离线RAM快照。按文件长度合计约3.139GiB，卷可用空间前后值另记于`reports/generated-cleanup.json`，不将逻辑长度等同物理回收量。SDK/全局缓存、AVD用户盘、QA签名密钥、所有报告和A2–A5交付件保留，没有执行整目录clean。

## 边界与未观察项

普通业务提交与原生发布/撤销是既有最终一致性关系；提交后、原生对账前进程消失，旧提醒可能发生，重开修复。维护额外block不能据此声称所有业务写入与OS原子提交。普通退出后的提醒与系统“强制停止”不同；节电、权限撤销和厂商策略可能取消或延迟通知。未精确授权的实际送达延迟、480条真实OS登记性能、实际点击系统通知栏到业务页面、用户操作权限界面、目标手机/Android14/鸿蒙和厂商后台策略仍待A7；合成镜像480项恢复计时不能替代这些条件。

真实学校认证、每日自动采集与真实模型晨报不在本轮自动测试中，继续遵守A2/A3条件；既有考试等未观察项保留。A5工程与上述模拟器/合成验证完成，下一切片为A6本地中文语音；本切不作实机或真人关闭。
