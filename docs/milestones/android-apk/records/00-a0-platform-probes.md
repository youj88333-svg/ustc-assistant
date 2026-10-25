# A0：工具链与原生能力原型

日期：2026-10-16。状态：QA主包/测试包构建及Android lint通过；模拟器运行验证待宿主硬件加速，不关闭A0或设备验收。

## 批准与本切规格

用户要求“请按照项目工作流和迁移计划开始进行迁移”，随后说明暂无Android手机，鸿蒙“应该是最新版”，模拟器选择成熟兼容版本。按[计划](../plan.md)先使用Android15/API35/x86_64官方镜像，Android14为后续兼容回归；鸿蒙具体版本、是否有APK兼容环境和实际能力均未验证。

设计依据为[07](../../../architecture/07-constitution.md)、[08](../../../architecture/08-target-architecture.md)、[09](../../../architecture/09-contracts.md)、[10](../../../architecture/10-runtime.md)、[11](../../../architecture/11-component-designs.md)、[12](../../../architecture/12-cross-cutting.md)、[13](../../../quality/13-risks-and-acceptance.md)、[14](../../../reviews/14-overall-review.md)及[15](../../../workflow.md)。Sol负责宿主、工具链、WebView及集成，Luna/max分别承接固定契约的Keystore和通知探针，文件不重叠。

只新增Android宿主和Debug专用QA原型，沿用现有Flutter工程与锁定依赖，不改Windows正式数据库、凭据、通知身份或1.00交付。QA包使用`.qa`独立身份；原型仅合成数据、loopback网页、临时密钥和固定静态提醒，不访问学校或读取已有浏览器/业务资产。生产Release不包含QA入口与Receiver。

验收条件：实际安装QA APK；两个Profile隔离及按Profile清理、重启恢复有可重复证据；Keystore用途绑定/nonce/缺失密钥拒绝；退出进程后实际OS投递与取消；如实报告提供方/权限/模拟环境的不足。源码完成、编译通过与上述运行结果分别登记，不用Android版本号推断WebView能力。

## 工具链盘点

- 原工程为Flutter3.44.5、Dart3.12.2，批准前无Android宿主；Windows1.00标签与私有包保留。
- 已有`E:\Android\Sdk`，platforms34/35/36/36.1、build-tools36/36.1/37、NDK28.2.13676358；未发现已安装系统镜像。沿用本机SDK，不另装整套工具链。
- Android Studio自带JBR21.0.10；采用现有Flutter模板的Gradle9.1.0、AGP9.0.1、Kotlin2.3.20，Java/Kotlin目标17，min24、compile/target36、NDK28.2.13676358。两份APK实际构建通过，未升级Flutter或现有Pub锁定依赖。
- 安装Google官方`system-images;android-35;google_apis;x86_64`修订9，新增独立Pixel7 QA AVD。使用自有ADB5038端口/5580模拟器，不接管默认5037服务或已有设备；测试探针不是手机版业务应用。

## 已实现的探针与运行边界

- Debug包名`cn.ustcassistant.mobile.qa`，启动原生`QaProbeActivity`；正式`cn.ustcassistant.mobile`的合并Manifest不含QA Activity/Receiver。正式Release没有配置Debug签名，尚未制作正式APK。备份前后两代规则均排除私有资料。
- `KeystoreProbe`只生成自有临时AES-256/GCM密钥，固定合成数据验证用途AAD、随机nonce、往返和密钥删除；查询硬件级别未知则报告null。C3正式保护器仍待A1实现，不另建密码仓库。
- `WebViewProbe`使用固定保留域的内联页面，不发HTTP；两个独立Profile写入合成Cookie/localStorage，按Profile清理并等待SDK回调、验证另一Profile保留。已加载Profile的逻辑删除留待冷进程清理；`prepare/verify/cleanup`分别验证跨进程保留和撤销后的清理，不把清理回调当法证抹除。
- `NotificationProbe`只操作QA固定41001提醒；能力区分系统通知/精确许可。15秒实际AlarmManager→非导出Receiver→OS通知，报告本包活动通知；没有许可就拒绝或明确`exactUsed=false`，不伪造退出投递。测试脚本要求进程已结束后等OS接收，不能用强停取代普通退出。
- [运行脚本](../../../../tools/test-android-a0.ps1)只接受上述专用AVD和QA包；可执行instrumentation、冷重启Profile验证、退出投递和取消，安全摘要写`app/build/android-a0/reports`。**这些设备用例尚未实际运行**。

## 构建与修复记录

根从固定Flutter SDK生成临时Android模板，仅合入宿主；临时模板已删除，没有复制main/参考分支资产或改变Windows路径。

1. 首次受限调用Flutter因不能写SDK锁而无进展，终止本轮调用后通过受审查的SDK缓存写入权限执行，未改SDK权限。首轮Android构建775.9秒成功，后续使用缓存。
2. 单独`:app:assembleDebugAndroidTest`触发此Flutter SDK未注册`compileFlutterBuildDebug`。核对本地SDK源码后同时请求Debug与AndroidTest任务，不修改Flutter安装。
3. Android版`JSONObject`没有测试使用的`keySet()`；改用`keys().asSequence().toSet()`。Flutter `integration_test`传递旧runner1.3.0，与测试runner1.6.2被AGP一致解析拒绝；只在Debug对齐runner1.6.2/core1.6.1，ext-junit1.2.1。
4. Flutter默认fat APK会携带插件的其他ABI，尽管引擎只构建x86_64；实际检查发现后改为官方`--split-per-abi`及对应Gradle参数。最终QA包仅声明x86_64，不交给arm手机使用。
5. lint对Flutter生成的Windows路径冒号报`PropertyEscape`，且旧报告不会因`local.properties`改变失效。构建脚本规范化生成文件的Properties转义，并把该文件声明为lintAnalyze的输入；未屏蔽错误或建立baseline。最终lint为0错误、37警告：版本升级建议6、KTX建议8、已审查的跨异步Profile能力门禁16、为同步持久化保留的commit建议2、低版本分支3、QA文案2。
6. 首轮Flutter分析读到临时模板的示例测试，因其包未解析失败；删除自有生成模板后分析通过。完整Dart测试结果在下方单独登记，不把首次失败覆盖为通过。

根实际通过的构建命令为：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/android-a0.ps1 -Action Build
```

它执行固定依赖解析、x86_64分包、Debug/AndroidTest构建、Release Manifest合并与lint。SDK模板的旧Kotlin DSL/AGP弃用提示仍存在，未借迁移顺手升级全部依赖。

| 本地生成物 | 字节数 | SHA-256 |
|---|---:|---|
| `app/build/app/outputs/flutter-apk/app-x86_64-debug.apk` | 124874753 | `4cf670bd26ff8191e2f9155f16daefa0b3f3c7bb9cad2c708817c29bf63a11e5` |
| `app/build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk` | 20174 | `ec861398d1bb50bfd7506b29f6cb2d5db4ee3181da69a51239a79ce630ed87ff` |

根用aapt2确认包名、QA启动Activity、仅x86_64及分包versionCode4001（基础工程仍`1.0.0+1`），两包apksigner验签通过。QA调试证书SHA-256为`16d3f9867f0a15d4d4ffc877bdd9ec240e92a3fddf6a0a66da857e2888846036`，不是长期生产签名身份。

## 模拟运行阻塞与下一次恢复

受限及提升进程的`emulator -accel-check`均报告不可用；固件虚拟化/SLAT/VMMonitor为true，HypervisorPresent为false。无管理员只读权限确认可选功能的具体安装状态，未尝试修改系统功能或启动配置。

两轮软件模拟均未进入Android：第一轮`-accel off -gpu swiftshader -cores2`，第二轮单核、关闭Vulkan并显示kernel；ADB始终offline、CPU累计极低。根只终止自有进程和专用5038服务。Astra只读复核未找到适用于36.6.11的明确安全参数修复；不把现行文档中的实验TCG开关当作已验证方案。官方推荐[WHPX](https://developer.android.com/studio/run/emulator-acceleration#vm-windows)，启用后需要重启。

用户同意自行启用并重启，要求教程。最小步骤：Win+R→`optionalfeatures`→核对并勾选“Windows虚拟机监控程序平台 / Windows Hypervisor Platform”→确定→保存工作后重启。若已勾选但重启后仍失败，再读取具体状态，不自行关闭安全功能或修改BIOS。Root在用户重启后执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/android-a0.ps1 -Action CheckAcceleration
powershell -NoProfile -ExecutionPolicy Bypass -File tools/android-a0.ps1 -Action Start
```

待独立模拟器启动并核对AVD后，安装上述两份QA APK，仅为该QA包授予POST_NOTIFICATIONS和SCHEDULE_EXACT_ALARM测试能力，再执行`-Action Test`、保存实际报告、`-Action Stop`。所有参数/资料仍限定QA；不安装到其他手机，不访问真实学校，不在运行验证前放行A0或声称已安装成功。

## E盘与保留

用户要求环境尽量不占C盘。实际SDK为`E:\Android\Sdk`，Gradle为`E:\Android\Gradle`，Pub为`E:\Android\pub_cache`，Flutter为`E:\flutter\flutter`；AVD、Android用户配置、新QA调试证书、Java/Dart临时目录和报告在本工作树`app/build/android-a0`。脚本只设置本进程及子进程，结束还原，不改用户/系统全局环境。

C盘原有Android调试证书创建于2026-07-08、2618字节，模拟器原有crash元数据创建于2026-10-09；仅核对文件元数据，未读密钥内容、搬迁或删除。Windows功能本身由系统管理，不能承诺C盘完全零写入；本次没有在C盘安装整套SDK或系统镜像。

Windows源码/数据根未改，`windows-v1.00`仍指向`e9746b9013df2aafa2f04cdb5d740ecb4c75f5e9`；原私有ZIP根复核SHA-256仍为`76af4056e026743d8966a212a5288a2a6234423774560f611a168ddea0417e96`。A1仅完成目录耦合只读盘点，待A0运行门禁通过再实施共享所有权/平台工厂，未提前改写数据库边界。

## 检查记录

Android QA主包/测试包构建、lint（0错误/37警告）、验签、ABI与生产Manifest隔离已通过；Flutter analyze通过；全部Dart测试1435项通过、1项平台跳过（68秒，包含Windows目录所有权和事务中断等合成检查）。本进程通知测试身份与TEMP/TMP在finally还原。两份PowerShell脚本语法通过，文档检查129份/1033本地链接及归档清单通过，diff检查通过。

批准文档检查点为`abb3c57`，工程检查点为`f6a6eca`；均仅本地提交，未推送。APK为这个工程状态的QA产物，不是A0运行放行或完整手机版的交付。

模拟安装/原生测试、Profile实际隔离清理、Keystore实际运行和退出投递仍未执行；目标实机、真实学校、真实模型和中文语音均未验证。没有改共享Dart/Windows工程，也没有重建或覆盖Windows1.00正式包；本轮不重复执行未受影响的十套Windows集成或将其旧结果写成本轮结果。
