# A6 Android本地中文听写（2026-10-17）

## 范围与实现

依据[迁移任务单A6契约](../plan.md#a6本地中文语音实施契约)、架构07/09/12、质量13 V-09与工作流15，规格提交为`3b4ce40`，工程提交为`7410977846a4c1c7e71a8125b1932ab5836c9550`。本切接入Android本地听写，保留schema18、20工具、C3业务权威、既有Windows入口和全部历史资料，不增加云语音、持续监听或Agent录音工具。

Sol负责共享状态、平台模型/识别装配、Agent生命周期、Gradle/Manifest、集成和根实际检查。两名明确指定`gpt-6-luna / max`的子代理分别实现原生模型缓存/测试与录音适配/测试，`gpt-6.1-sol / high`作只读边界复核；子代理未运行Flutter/Gradle，其声明不替代根证据。

- Android平台工厂实际装配`OfflineSpeechInput`、`AndroidSpeechRecorder`及`AndroidSpeechModel`；构造/启动不打开麦克风、读取模型权重或请求权限。首次主动点击进入请求权限阶段，系统弹窗的inactive可等待；hidden/paused/detached使本次请求失效。只有前台且仍有效的请求可以继续准备、录音，回前台不会自动重开。
- 固定`record 7.1.2 / record_android 2.2.0`，默认系统输入、16kHz mono PCM16，关闭主动蓝牙管理，音频中断策略为pause。监听pause、意外stop和状态流错误，终止本次输入并排空，不自动resume；自身正常stop保留尾帧，停止失败可重试。Windows仍使用原默认端点和非监视的录音路径。
- 固定SenseVoice INT8 2024-07-17、`sherpa_onnx 1.13.8`、中文zh、双线程CPU isolate。Gradle通过当前Variant API声明生成资源，构建前逐项核验既有权重/tokens/LICENSE摘要并带上五份NOTICE/许可；权重仍在忽略的build目录，不进入Git。Android加载包内`.so`，Windows的DLL与ONNX API校验保留。
- 固定`ustc_assistant/android_speech_v1.prepareModel`不接受参数；原生串行工作线程将固定资产流式提取至`noBackupFilesDir/speech_v1/sensevoice-int8-2024-07-17`。跨实例共用锁、固定大小/SHA256、拒绝后代链接、临时文件校验后原子替换；失败不报ready且保留既有有效文件。仅对受信Context根解析Android合法系统别名，注入根和后代仍拒链接。关闭给在途请求单次closed结果，迟到回调丢弃。
- 识别worker再次核验模型，音频仍限0.5–30秒/960000字节，仅在内存；取消先撤销结果再排空。原草稿光标、用户编辑、页面/历史/维护世代和图片守卫继续生效，识别只回填、可编辑，不自动发送。日志只记固定阶段/失败码、计数及耗时，无声音、转写、设备名或任意路径。

技术依据见任务单链接的Android权限/录音共享、record及sherpa官方资料；生成资源使用[AGP SourceDirectories API](https://developer.android.com/reference/tools/gradle-api/9.1/com/android/build/api/variant/SourceDirectories.Flat)，实际行为以锁定包源码和本轮测试为准。

## 根实际检查

全部使用合成/loopback、独立QA身份和私有临时根，不访问真实学校、模型服务、正式业务记录或认证资产，不打开真实麦克风。以下`reports/`均相对`app/build/android-a6/`。

| 检查 | 实际结果与证据 |
|---|---|
| 静态分析 | 最终`flutter analyze --no-pub`无问题，`reports/analyze-final.txt` |
| 全套Dart | 1513项通过、1平台跳过，`--concurrency=2`，2分41秒；`reports/flutter-all-first.txt`。覆盖权限拒绝/后台竞争、迟到转写、录音中断/尾帧/恢复、长度/时长上限、中文配置、草稿/图片保留及现有全部业务回归 |
| Android原生 | JUnit报告69项，其中62项通过、7项按提供方条件跳过，无失败；A6模型缓存9项均通过。`reports/native-final.txt`。不据此改变A2的隔离世界门槛或宣称旧提供方已获得能力 |
| Android实际本地ASR与界面 | `tools/test-android-a6.ps1`通过1组实际运行时/中文识别/草稿集成；`reports/speech-run-second.txt`。原生包内模型与`.so`、合成PCM流及停止尾帧、原光标回填、两次使用、编辑和取消保留均成立，网络尝试为0，QA包保留。麦克风后端为固定合成WAV，不是硬件录音 |
| Windows回归 | 三套9组通过：本地ASR/草稿/退出与维护排空3、Agent5、应用壳1；`reports/windows/`。每套独立Flutter CLI，进程级`USTC_NOTIFICATION_TEST_HOST=1`，只用独立Debug测试身份，未覆盖Windows1.00 Release |
| 构建/包 | Android QA、AndroidTest、Release合并清单与lint完成，最终`reports/build-delivery.txt`；lint为0错误、79警告。普通交付包的版本/hash/入口核验见下文 |

## 性能与限制

独立官方API36 x86_64模拟器，2个虚拟CPU、2048MiB、软件图形、Debug/JIT；固定本机TTS合成中文WAV为5045ms。首次模型准备含提取、摘要复验、worker与模型初始化，11946ms；同实例复用0ms。两次解码为434/404ms，均识别到预设中文关键词，不把此结果推广为课程/教师/教室术语准确率。

进程RSS在未加载模型时400801792字节、识别后721571840字节、关闭后480768000字节，进程生命周期峰值762368000字节，约382/688/459/727MiB。它包含Flutter、测试运行时及数据库，既非ASR独占内存，也非Release手机基准；关闭不保证操作系统立即回收全部已分配页。Windows同一合成WAV冷准备3642ms、两次解码181/166ms，仅作为本切兼容回归。

固定模型三文件共239549806字节（约228.45MiB），手机首次使用需要额外私有缓存空间。ARM64锁定包的三个语音`.so`已静态检查LOAD对齐为`0x4000`；这是这三份库的静态证据，不是完整APK的16KB、arm64运行或A8发布验收。实际手机录音、3–10秒中文/术语效果、来电、耗电、温度/发热、内存压力和APK鸿蒙仍待A7。原Windows真人“I.”及未识别语音反馈继续保留，不能由本轮合成通过覆盖。

## 发现与修复

初轮Dart测试发现跨平台测试时Android路径被Windows路径工具改写，以及测试直接跳生命周期状态不符合Flutter转换图；现Android模型使用POSIX路径，界面测试经过合法转换。录音适配复核发现中断只发错误但未关闭流会使终止等待挂住，已修正；最初权限适配用例误用widget假时钟等待真实流，根停止未完成批次，改为普通异步测试后4项通过，未把中断批次计作通过。

构建阶段修正Gradle的java扩展名遮蔽、Provider不能直接放入SourceSet的当前API限制，以及Kotlin误用不存在的unlink调用。首次原生批次因夹具使用系统目录别名而7项失败，夹具改为受信Context规范路径；第二批剩1项失败，原因是测试错误要求失败替换删掉旧的有效tokens。根按“失败保留旧有效资产”核对实现，改为断言内容未变、临时文件未残留，随后完整原生批次通过。原始日志分别保留，不改写旧失败。

首次A6集成启动脚本把ADB成功的stderr进度误判为PowerShell错误，尚未进入应用测试；现只按原生exit code判定，第二次完整集成通过。结果见`speech-run-first.txt`与`speech-run-second.txt`，不将脚本启动失败算作识别失败或通过。

## 交付与保留

普通包以`Build -BuildRevision 7410977846a4c1c7e71a8125b1932ab5836c9550`生成，保存在`app/build/android-a6/artifacts/USTC-Assistant-Android-A6-QA-x86_64.apk`，290809539字节（约277.34MiB），SHA256为`7c330a801b683b508deec46d8ddd684940efea99fc982a5009483c46193004d5`。同目录`manifest.json`、`apk-metadata.txt`和`signature.txt`记录独立包名`cn.ustcassistant.mobile.qa`、`1.0.0-qa-a6`/4001、普通`lib/main.dart`入口、仅x86_64、源码号及核验结果；签名为既有Android Debug身份，不是A8正式签名。

流式核对APK内三个模型文件的固定SHA、五份语音NOTICE/许可及两个必要语音动态库；kernel含上述源码号且不含A1–A6/Windows语音集成入口。Release合并清单保留禁止备份/明文规则，麦克风硬件为可选，增加的录音权限不伴随电话状态/后台麦克风服务/媒体库或所有文件权限，未混入Debug探针/提供方，`reports/production-manifest.xml`。普通QA自身保留既有Debug专用合成夹具，不能称为正式发行包。

最终普通包同签名覆盖安装，未清库或卸载；冷启动为`Status: ok / COLD`、5346ms，当前QA进程崩溃缓冲为空，启动后`RECORD_AUDIO granted=false`，未自动申请麦克风，见`reports/ordinary-launch.txt`、`ordinary-current-crash.txt`和`ordinary-version-permission.txt`。首张截图含System UI无响应提示；事件只记录02:51:37 UTC的`com.android.systemui/.keyguard.KeyguardService`等待20004ms，早于本轮03:10的合成ASR及03:19普通启动，不能据此认定由本次识别引起，也不补推具体系统原因。选择已观察到的Wait后根实际查看`ordinary-phone-recheck.png`，正常Agent首屏及麦克风入口可见；原图`ordinary-phone.png`和`emulator-anr-events.txt`继续保留，不能称系统异常已根治。

Windows1.00 ZIP、A2/A3/A4/A5 QA包及`windows-v1.00`标签摘要复核不变，`reports/preserved-assets.json`；main仍为34项修改/14项未跟踪，参考工作树0项修改/3项未跟踪，本切没有写入这些工作树。初次统计命令错误使用NUL排除文件而失败，未将空输出视为最终统计；已按成功退出码重新核对后保存上述实际结果。计数本身不是逐文件内容相同的证明。

SDK、Gradle/Pub缓存、AVD和临时目录仍在E盘，无全局环境/代理/信任变更。结束后关闭专用AVD及ADB5038，核对无活动编译/模拟器、目标在本工作树内、Git忽略及全树无重解析点，只删再生的`app/.dart_tool/flutter_build`和API36离线RAM快照，按文件长度合计3193083823字节（约2.97GiB）；卷空间前后值见`reports/generated-cleanup.json`，不将逻辑长度等同物理回收。交付、报告、模型源、AVD用户盘/模型缓存及QA签名保留。

A6工程与上述合成/模拟器验证完成，下一阶段为A7目标实机收口。当前没有实机，本切不作真人关闭，不关闭完整V-07/V-09，不替代真实模型服务/学校/通知/文件及麦克风验收。
