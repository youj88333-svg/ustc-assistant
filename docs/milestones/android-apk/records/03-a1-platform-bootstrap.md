# A1 私有目录、数据库与平台启动

日期：2026-10-16。依据[迁移计划A1](../plan.md#a1目录与启动实施契约)、07/09/10/11/12、13和15；承接[A0模拟器准入](01-a0-runtime-probes.md)及[凭据端口](02-a1-keystore-port.md)。本切只使用独立QA沙箱、合成数据与loopback，没有访问真实学校、模型、正式业务或浏览器认证资料。

Sol固定契约并实现原生所有权、数据库与组合根，负责全部集成和实际检查。两名Luna（GPT-6 Luna/max）分别适配固定目录消费方、实现明确不可用的通知/语音端口；文件互不重叠。Astra按需只读复核POSIX所有权，并追查跨进程复验出现的测试数据消失；根核对本机源码和实际结果后采纳，没有以子代理结论替代运行验收。

## 装配结果

- 提取最小`OwnedDirectory`端口。Windows仍使用原`DemoDirectory`实现、原两目录默认值、Windows路径与DPAPI，没有迁移原目录或业务资料。
- Android只从固定原生通道获取`noBackupFilesDir/ustc_assistant_v1`的规范路径。原生逐祖先持柄、检查目录/锁文件身份并取得非阻塞`flock`，之后创建并固定`demo_v1`和`local_v1`；两视图共享父锁，最后一个释放才关闭所有者。拒绝别名、符号链接、特殊文件、不安全数据库槽及锁替换；失效后停止SQL与受所有者约束的日志/登记，允许回滚、关闭排空。这不承诺防御恶意同UID文件系统竞态。
- `jw.sqlite`继续是正式业务权威，演示库保持独立，schema18和业务迁移规则不变。数据库沿用外键、WAL、FULL同步与3000ms忙等待。诊断仍为有界四段、合计1MiB/7天，不记录秘密或业务正文。
- 平台工厂先取得目录，再装配数据库、诊断、分区登记、启动维护恢复和各业务协调器；来源与Agent继续使用现有共享租约。Android注入双用途Keystore端口，Windows注入原DPAPI。激活失败保留恢复入口及所有权，重试恢复，不清库重建。
- Android Debug默认入口从A0探针改为普通Flutter `MainActivity`。A0合成探针仍只能按明确Activity入口调用，不再占第二个启动图标；QA身份仍为`cn.ustcassistant.mobile.qa`。生产Manifest继续排除QA入口和通知探针许可，禁用明文网络，保留备份/设备转移排除。既有`record_android`依赖会合入`RECORD_AUDIO`静态声明；A1不请求其运行时许可或启动录音，实际语音仍等A6。
- Android学校桥、系统通知、语音分别等待A2/A5/A6接入；A1明确返回不可用，不伪造空OS队列或清理成功，也不在启动时请求权限、录音或联网。本地日程/任务启动独立可用，不代表手机版全部功能已完成。

## 本轮失败与修正

1. Android系统祖先目录可能只有搜索权限，没有目录读取权限。初版`O_RDONLY`不能取得所有权；Astra指出后根改为`O_PATH`固定身份，再在实际应用UID下验证。没有扩大Android目录许可。
2. 既有登记消费方用`.`表示自身目录，POSIX拼接后形成`root/.`，被严格路径检查正确拒绝。改消费方直接使用已知根路径，不放宽所有者的别名/越界检查；Windows账本及删除语义不变。
3. 实际Flutter引擎返回不可修改的`Uint8List`消息视图。凭据端口原`finally`归零会抛`UnsupportedError`，覆盖已经成功的加解密结果；模拟通道测试未暴露它。改为尽力清理引擎视图，继续返回调用者独有的可修改副本；实际Flutter→后台Keystore→Dart往返重新通过。不宣称跨运行时副本绝对抹除。
4. 两项首次测试断言不符合原契约：SQL守卫可能同步抛错，应传闭包给异步匹配；未来schema初始化失败会返回受维护阻挡的恢复句柄，应检查恢复状态并正常关闭。修正测试后，原值与schema保留、所有者释放均可验证。
5. Flutter为x86_64分包版本码增加4000，而非分包集成测试原为1，安装降级会触发工具的卸载重装回退。QA两种构建现统一最终版本码4001，脚本遇更新的已安装QA包直接拒绝降级。该规则仅用于当前QA验证，不更改生产版本/签名方案。
6. 修正版本码后，第一次严格保留复验仍得到0条。根与Astra追查本机Flutter源码：`test --uninstall`默认true，测试结束成功后同样卸载应用。因此不能把“六组通过”之后重新安装的空根当作数据库丢失。脚本显式加`--no-uninstall`并在结束后核对包仍安装；重新播种、普通APK覆盖、回收进程、禁止播种复验后，原日程/任务均保留。修正前失败报告仍保存。
7. 本机Flutter桌面运行器把同一`DesktopLogReader`用于一条命令内的多套集成测试；首个进程退出后关闭其流，后续无法发现调试连接。根核对`desktop_device.dart`后改为每套独立Flutter进程，未修改SDK或产品来规避问题；失败的批量日志和逐套实际结果分开保留。
8. 最终Manifest验核初始把既有`record_android`依赖的`RECORD_AUDIO`声明误判为本切新增许可。合并来源追溯确认后，按固定声明清单核验，仍拒绝QA入口和通知探针许可；静态声明与用户运行时授权分开记录，没有因此申请麦克风权限或声称语音可用。

## 可重复验证入口

从仓库根使用`tools/android-a0.ps1 -Action IntegrationTest -ApiLevel 36`运行六组合成集成检查；`-VerifyRetained`要求已有一条合成日程和一项合成任务，缺失时直接失败，不能重新生成样本。测试拒绝非独立QA沙箱，并禁止任何Dart HTTP客户端启动。

保留链路按“集成播种且不卸载 → `Build`生成普通入口 → `adb install -r`同版本覆盖 → 普通入口启动至新`applicationReady` → Home后`am kill`确认进程已退出 → 新进程再次到达ready → `IntegrationTest -VerifyRetained`”执行。仅对指定API36 AVD和`.qa`包进行故障演练，不使用卸载、清数据或生产资料。普通APK启动画面另有实际截图，本切没有把启动截图当作手机交互体验验收。

Windows各套命令独立运行，进程内设置`USTC_NOTIFICATION_TEST_HOST=1`、E盘`PUB_CACHE/TEMP/TMP`，只构建Debug测试助手；不替换1.00 Release。具体常用命令见[应用说明](../../../../app/README.md#android本地开发验证)，历史A0操作保持原记录。

## 根检查与本地产物

| 检查 | 实际结果与证明范围 |
|---|---|
| Dart静态与全套 | 最终analyze无问题；全套1446通过、1项平台分支跳过，78秒。涵盖既有Windows所有权、迁移/回滚、业务与维护，以及新增不可用端口检查。后加的Android PRAGMA断言另通过最终analyze及模拟器集成，不冒计为新增Dart单测数量 |
| Android应用UID集成 | API36/x86_64，六组通过；最后一轮3秒（不含构建/安装）。父锁共用与重复取得拒绝、路径/链接/数据库槽拒绝、锁替换后事务拒绝且回滚零提交、未来schema保留原值及版本、真实凭据RPC、本地日程任务关闭重开、激活失败重试与诊断可用；全程Dart网络尝试为0 |
| SQLite实际配置 | 重开后schema18、`foreign_keys=1`、`journal_mode=wal`、`synchronous=2`、`busy_timeout=3000`均断言通过 |
| 覆盖及进程回收 | 同版本QA包`install -r`后普通入口ready；Home后回收并确认旧PID消失，新进程重新ready；严格禁止播种读取，原一条合成日程和一项合成任务保留。另存`process-recovery.json`，`businessRetained=true`，不是实机证明 |
| Android原生 | 最终主/测试APK安装后instrumentation `OK (10 tests)`，0.514秒；双用途原语、nonce/用途/坏封套/密钥失效等原生反例通过。实际Flutter凭据通道证明来自上一行六组集成，不以两套各自通过代替组合证明 |
| Windows原生 | 五套十三组逐套通过：`m0_flow`2、`app_shell_flow`1、`calendar_workspace_flow`4、`settings_maintenance_flow`3、`diagnostics_flow`3。包括真实Windows目录、loopback双来源/登记、本地任务/日程保留、来源停用、恢复/维护及安全日志；没有访问学校或真实模型 |
| 构建与包 | Debug x86_64普通入口、AndroidTest、Release Manifest合并及lint通过；lint为0错误、38警告，保留既有Debug探针的feature-flow/落盘提示及依赖/文字建议，未增加抑制。QA包只有x86_64 ABI并含POSIX所有权库，生产Manifest无QA入口和通知探针许可，静态录音声明来源见前文 |

本轮工程检查点`5c5e5d1f367a449a1c504bdd246131ae46f39060`，仅本地提交、未推送。未提供`USTC_BUILD_REVISION`的QA诊断继续记为unknown，不推断构建时Git状态；工程提交和下列APK摘要共同保存关联。

| 生成物 | 字节数 | SHA-256 |
|---|---:|---|
| `app/build/android-a1/artifacts/ustc-assistant-a1-x86_64-qa.apk`，与标准输出普通启动APK逐字节一致 | 124917159 | `b06028058dd89b903205a6f10762b4ba6daa8dcdf05d828b4df5f21beb3a4ecd` |
| `app/build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk` | 29200 | `64ef854d4d8336df8b64904354896b892ad9fa34c2eae34086fe4a02e8c64dd2` |

本机报告在`app/build/android-a1/reports/`：`integration-final.txt`、`integration-retained-preserved.txt`、`process-recovery.json`、`instrumentation-final.txt`、`dart-tests.txt`、`windows/`、`analyze-final.txt`、`build-final.txt`及`artifacts.json`；修正前失败报告同时保留。报告、APK、模拟器与生成目录均不入Git。

SDK/JBR、Gradle/Pub缓存、AVD与本轮临时目录继续使用E盘和进程级环境，没有迁移/删除原C盘资产或改全局代理。Windows1.00私有ZIP重新核验为`76af4056e026743d8966a212a5288a2a6234423774560f611a168ddea0417e96`，`windows-v1.00`标签仍指向原提交；本切未覆盖或启动生产Release。

## 放行范围

A1工程验证完成，可推进A2学校原生桥及合成协议。当前仍是开发QA包，非完整手机交付；Android实机、APK鸿蒙、学校/模型真实链路、手机交互、图片/SAF、系统提醒整合与语音仍按A2–A8验证，没有替用户记录真人通过。Windows已知语音问题、非空考试及其他原未观察项继续保留。
