# 鸿蒙返回前台后的目录所有权

日期：2026-10-25。对应[A7任务规格](../plan.md#a7-鸿蒙返回前台的目录所有权修订)，A7/A8不据本记录关闭。范围限Android原生目录所有权的异常生命周期回收，保留所有业务、密码、模型配置及原Windows所有权实现。

## 用户证据与设备

用户报告APK切后台后返回可稳定复现“应用数据目录正被另一个应用实例使用”，清后台后恢复。设备为用户确认的MatePad 11.5″S、HarmonyOS 4.2.0，APK直接安装，不通过兼容应用。本次未连接或远控该设备；不以官方Android模拟器代替该机复验。

主动提供的`USTC-Assistant-diagnostics.json`为723字节，SHA-256为`34e84090cee8ab87214071a0b49d270ce3adc8cd4773209fa9e9540ae2594a42`，导出时间2026-10-25 10:42:34北京时间，`coverage=startup_error_only`、complete=false、invalid/dropped均0。唯一记录为10:42:08的`applicationFailed/startup/failure/ownerConflict`，工程`37ce18804754cc8d395df4b44658e5447769cd2a`、schema19、tools-v7、prompt-v14。它证明启动排他所有权未取得，不能证明另一个真正的应用正在使用数据，也不足以唯一定位厂商的Activity重建动作；未读取正式数据库、浏览器认证或学校原文。

## 代码与方案

原Android拥有者由FFI分配C结构，持有目录描述符及`flock`；只有Dart显式`release()`最终调用C `drain()`。根应用仅在正常退出请求中关闭runtime，Android销毁FlutterActivity/引擎不保证经过该回调。同进程内旧Dart环境销毁但原生描述符未关闭时，新运行环境会被旧锁正确拒绝；清除整个进程后操作系统回收描述符，与用户现象相符，仍需反例和目标机分别验证。

Sol负责生命周期修订，Astra/max只读核对了资源链、当前SDK引擎销毁及SQLite连接关系；Luna/max仅编写独立FlutterEngine/合成目录测试。生产使用共享拥有者上的单一`NativeFinalizer`与`Finalizable`标记兜底：正常收口先关闭消费者/数据库、detach终结器再按原有可报告错误的释放路径执行；异常环境销毁时，仅回收原生资源，不删锁文件或业务。注册失败也须释放刚取得的原生资源。仍活的运行环境及任一未释放子租约必须继续排他。

依据为[Dart NativeFinalizer](https://api.dart.dev/dart-ffi/NativeFinalizer-class.html)、[Finalizable存活保证](https://api.dart.dev/dart-ffi/Finalizable-class.html)、[FlutterActivity生命周期](https://api.flutter.dev/javadoc/io/flutter/embedding/android/FlutterActivity.html)及[应用退出回调](https://api.flutter.dev/flutter/widgets/AppLifecycleListener/onExitRequested.html)。终结器不依赖暂停/后台事件，不引入常驻引擎、重绑学校/文件/通知通道或改写launchMode。实际反例、检查和构建按完成情况续记。

## 根复现与修复

只在独立官方API34、`emulator-5588`、ADB5038与QA包运行，SDK/Gradle/Pub/AVD及临时输出均留E盘；没有操作用户MuMu或MatePad。专用Dart入口不装配业务runtime，不访问学校或模型；真实`FlutterEngine`只打开UUID临时目录和合成SQLite哨兵17。测试前先修正夹具的Flutter/Drift同名导入冲突、Java非泛型调用及系统`/data/user/0`与`/data/data`目录别名假设；这些初始失败不算产品反例，报告另留。

旧生产代码有效反例的两项方法均失败（16.165秒）：活跃拥有者能阻止第二引擎，但销毁持锁引擎且不调用Dart显式close后，后继引擎在5秒内持续返回ownerConflict；正常显式释放分支已先通过。原生目录实现与用户日志`37ce188`对应代码一致。根保留`owner-lifecycle-red.txt`，随后才修改生产代码。

生产补丁仅给共享`_Owner`增加一次原生终结注册与Finalizable标记，注册放在异常清理保护内，正常close先detach后保留原释放及失败语义。C回调只drain指针所拥有的描述符/内存，正常后台不释放、不删锁文件、无PID猜测或旧owner借用。原生重建后同一组两项方法全部通过（7.556秒），包括两轮无显式close销毁/重取/读回17、只释放demo仍排他、重复close及旧引擎销毁不影响新owner；报告`owner-lifecycle-green.txt`与旧失败分开保留。没有用强制GC、杀进程或重新安装来代替测试内部的引擎销毁与重取。

这证明已复现的资源泄漏路径得到修正，不证明所有鸿蒙重启策略或MatePad上的原故障已实际复验。现有A1、共享检查和普通双ABI构建结果按完成后续记。

原A1回归首轮五组通过、一组在检查默认QA业务根的任务标题时失败：该根已被后续阶段合成测试复用，并非用户或本轮锁修复造成的数据缺失；同一旧用例还仍硬编码schema18。根保留失败，改为先单独核验真实平台默认根，再将保留/重开旅程放入A1专属的受控保留子目录，实际原生凭据与其他平台适配继续委派给生产Android工厂；不删除旧QA资料，不放宽每个合成对象和SQLite配置断言，schema按当前公开契约核对。修订后的A1六组全部通过（5秒），覆盖排他双租约、非法路径、所有权丢失/事务回滚、未知版本保留及失败启动释放、正常启动与凭据往返/本地资料重开、激活失败保留与恢复。独立AVD随后正常停止，未停止MuMu或共享ADB服务。

根analyze无问题，完整共享1617项通过、1项平台跳过（103秒），其中仍执行Windows目录排他/所有权丢失及实际进程事务测试；受影响Windows Agent原生五组通过（52秒），使用Debug测试通知宿主，不登记生产通知。工程提交`a67a06f3203b3d798dd3844bd691a70ed47354b9`，仅本地保存、未推送。测试和输出都在忽略的`app/build/android-owner-lifecycle/`，没有为本轮重跑来源全矩阵、真实学校/模型或用户MuMu；普通双ABI包与实机复验分别记录。

## 私有覆盖包

由工程`a67a06f`构建的普通`lib/main.dart`入口两包均通过版本、唯一ABI、同QA签名、源码修订、原生终结导出与Dart绑定、固定学校脚本/语音资产/许可检查。包内确认没有`qa_owner_lifecycle_v1`、`ownerLifecycleProbe`或合成目录标记；专项Dart入口没有进入产品包。x86_64另完成AndroidTest编译、lintDebug和Release manifest检查；构建用时22.5/67.2秒不是目标机性能指标。

| 文件（`app/build/android-owner-lifecycle/artifacts/`） | bytes | SHA-256 |
|---|---:|---|
| `USTC-Assistant-Android-QA4023-x86_64.apk` | 291059059 | `2b72cc088a0969492acd9d3bbf3621e5fe361d34cd257272611005d2b3d49080` |
| `USTC-Assistant-Android-QA2023-arm64-v8a.apk` | 279251991 | `18977965abefbba1c04c7a36d5812f65bbc57fe0660a0f683395e3e543a18823` |

两包均为`cn.ustcassistant.mobile.qa`、`1.0.0-qa-a7-webview2`、schema19、tools-v7、prompt-v15，证书SHA-256沿用`16d3f9867f0a15d4d4ffc877bdd9ec240e92a3fddf6a0a66da857e2888846036`。构建manifest保留`publicRelease:false/realDeepSeekValidated:false`，不回填以往真人结果。本轮未给MuMu或MatePad覆盖安装新普通包，不改Windows1.00旧交付；MatePad使用ARM64包按原稳定步骤复验，结果尚待用户确认。

专项入口随后固化到`app/tool/android_owner_lifecycle_probe.dart`，只在明确构建该入口并向instrumentation传`-e ustc_owner_lifecycle_probe true`时运行；普通原生全量默认跳过这两项需特殊Dart bundle的检查，避免误把不含测试入口的产品包当成失败。该收口仅修改测试入口/运行选择，不改变上述产品包的生产代码或构建修订；专项复验另记。

根已重建并复验固化入口：显式专项两项通过（10.037秒），不传标记时两项均以预期assumption跳过，没有尝试加载测试Dart入口；独立AVD再次正常停止。最终analyze无问题（8.9秒）。此处仅测试装配变更，未重复无影响的共享/Windows全套或重建字节已固定的普通交付APK。当前普通包仍精确对应工程a67a06f，测试装配收口单独提交`dd3876dd15bc659642f0c9b7c81dd4bb2a2bc897`；A7/A8和MatePad实机反馈继续开放。

可重复的专项命令如下。使用`tools/android-a0.ps1`同样的E盘SDK/JBR/Gradle/Pub/AVD进程环境，目标只允许自有`ustc_android_a0_api34`/`emulator-5588`和QA包；执行前核对AVD名称，禁止对MuMu或目标手机执行这些测试安装命令：

```powershell
# 工作目录 app；先按 tools/android-a0.ps1 的进程级环境准备并启动自有API34。
& 'E:\flutter\flutter\bin\flutter.bat' build apk --debug --no-pub --target tool/android_owner_lifecycle_probe.dart --target-platform android-x64 --split-per-abi
# 工作目录 app/android，使用同一 target 编译对应 instrumentation。
.\gradlew.bat :app:assembleDebug :app:assembleDebugAndroidTest '-Ptarget=tool/android_owner_lifecycle_probe.dart' '-Ptarget-platform=android-x64' '-Psplit-per-abi=true'
# 工作目录 app；前两份是专用合成包，不是上表普通交付APK。
$avd = (& 'E:\Android\Sdk\platform-tools\adb.exe' -P 5038 -s emulator-5588 shell getprop ro.boot.qemu.avd_name).Trim()
if ($avd -cne 'ustc_android_a0_api34') { throw 'Unexpected emulator' }
& 'E:\Android\Sdk\platform-tools\adb.exe' -P 5038 -s emulator-5588 install -r build/app/outputs/flutter-apk/app-x86_64-debug.apk
& 'E:\Android\Sdk\platform-tools\adb.exe' -P 5038 -s emulator-5588 install -r build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk
& 'E:\Android\Sdk\platform-tools\adb.exe' -P 5038 -s emulator-5588 shell am instrument -w -r -e ustc_owner_lifecycle_probe true -e class cn.ustcassistant.mobile.qa.OwnerEngineLifecycleTest cn.ustcassistant.mobile.qa.test/androidx.test.runner.AndroidJUnitRunner
```
