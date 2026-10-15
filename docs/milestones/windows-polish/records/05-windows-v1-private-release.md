# Windows 1.00 私有交付收口

日期：2026-10-15。依据[任务单](../plan.md#windows-100-私有交付收口2026-10-15已批准)与[用户版本决定](../acceptance.md)。只在design-reset工作树工作，不公开发布/上传/推送，不改变资料根、生产通知身份、凭据用途或schema18，不直接检查正式业务与认证资产。

## 检查发现与修订

根先读现行设计、状态和15；Luna/max分别只读清点发布缺口与Android代码复用，未运行Flutter或访问私人资料。发现pubspec、正常诊断及公开HTTP仍为0.0.1，启动失败诊断还写schema16，About还说业务功能正在接入；PE名称仍是原型名称。Release运行资料完整，但没有面向接收者的私有包说明和清单，旧应用说明的schema已过时。

Sol/max统一显示1.00、工程1.0.0+1，PE产品/描述为USTC Assistant；保留包名和EXE，启动失败与正常诊断共同读取实际schema常量及版本，更新About和公开HTTP标识。本切不增加迁移、不改业务事务或用户设置。历史诊断样例的旧版本保持原事实，没有全局替换历史记录。

Luna/max按固定规格完成打包辅助与合成反例，根复核并补充锁文件摘要和ZIP旁的SHA256文件。工具仅接受本工作树app/build内的源目录，拒绝重解析路径及固定清单以外的文件。最终35个运行资产全部必需，静态构建库`notification_native.lib`排除；包括语音模型、7份知识文本、Flutter NOTICES、语音许可，以及根后补的WebView2加载器LICENSE/NOTICE。模型/tokens对照已审核NOTICE逐一核hash；加入交付/已知问题说明与manifest，逐文件复验ZIP，不含正式资料或测试助手。输出全新目录且拒绝覆盖，无发布/安装/网络动作。

最终核对发现加载器静态链接但未随包保留其SDK声明，根从固定公开NuGet 1.0.3967.48原样复制，CMake安装到`data/licenses/webview2`。LICENSE 1487字节、SHA256 `0AF8F1B807512AAE39C2AC1AA4D0CAE65CABECB6FD554B8439A5162A0D6ECA55`；NOTICE 3894字节、`106423785C5B7EBA0A8E61D1837F2132E9C828E20AD530F565D981C1DF60DD90`，与源逐项相同。上游LICENSE含尾空白，首次cached diff检查拒绝；采用只针对两个文件的原字节/空白属性，不改声明。编辑属性时曾覆盖已有归档/知识规则，根在构建包前审查发现并恢复，文档/归档hash检查通过；没有修改归档或知识资产字节。

## 根已执行检查

- 现有SDK3.44.5 / Dart3.12.2离线解析完成，无升级依赖。
- `flutter analyze --no-pub`无问题，16.5秒。
- 全套`flutter test --no-pub --reporter compact`：1435通过，1个平台分支跳过，约73秒。包括设置About可见当前能力/版本，不再显示正在接入的旧说明。
- 根运行`tools/test-package-windows-private.ps1`：13项合成检查通过；覆盖固定清单、路径/重解析边界、未知文件/数据库拒绝、版本对齐、语音哈希、ZIP清单/hash/篡改及额外项拒绝。
- Windows原生十套共37组通过，见下表；所有命令仅在各检查进程设置`USTC_NOTIFICATION_TEST_HOST=1`，结束还原，根复核调用进程未残留该环境变量。

| 原生套件 | 最终通过组数 |
|---|---:|
| settings_maintenance_flow | 3 |
| diagnostics_flow | 3 |
| agent_model_flow | 5 |
| calendar_workspace_flow | 4 |
| m6_flow | 5 |
| young_daily_sync_flow | 2 |
| young_automation_flow | 3 |
| young_sync_flow | 2 |
| jw_sync_flow | 7 |
| speech_input_flow | 3 |

语音首轮因根漏传必需的`USTC_SPEECH_TEST_WAV`而1失败/2通过，尚未进入第一个真实识别断言；根保留`v100-speech_input_flow.log`，使用既有固定合成WAV绝对路径重跑才3组通过，未修改测试断言或使用真人声音。重跑冷准备3750ms、冷识别239ms、暖准备0ms、暖识别220ms，仅是本机合成素材，不解释为实际语音质量已通过。

工程提交`f3a20e7ae77ea7021453f95312bbcb18fa878d88`包含全部Dart/PE版本与打包工具，并经上述全套及原生验证。后续`5bbcfd71252407b24bf7bd73fc2fc474ef274c05`仅补随包许可/打包清单，`862a13ac2ccbf85e4a4ef9fbf66c8279c169f3fe`恢复原有路径属性；没有再改Dart行为。许可后根复跑打包合成检查、文档/归档检查，并重新构建正式入口；不把此前的全套说成补许可后又重跑了一次。

日志在忽略的`app/build/v100-*.log`；本轮合成测试临时资料位于受控app/build或TEMP，打包测试创建的目录已按解析后的工作区边界清理。没有开启真实麦克风、学校采集或模型请求。

## 正式构建与私有包

最终工程修订为`862a13ac2ccbf85e4a4ef9fbf66c8279c169f3fe`。Flutter config-only后解码核对入口为`lib/main.dart`，仅有该构建修订及SDK正常版本define，不含测试WAV、M3验收、诊断/预览/演示等开关。独立`build/windows-polish/x64`的CMake配置与Release INSTALL均退出0，随后实际执行打包脚本成功。

PE的产品名/描述为USTC Assistant，FileVersion/ProductVersion均为`1.0.0+1`，数字四段为`1.0.0.1`。EXE仍为`ustc_assistant_m0.exe`，本次明确未签名（`NotSigned`）。

| 最终资产 | 字节 | SHA-256 |
|---|---:|---|
| `ustc_assistant_m0.exe` | 850944 | `4DBA69FCE3A9A484060D4449695D9C178CCE2186C02243F0E8C0F6362515BB01` |
| `data/app.so` | 12600208 | `7DFE7A727DFD4E2E70867BD22B42713BE6A003FE8430FC4397F10BAD07559FA5` |
| 私有ZIP | 185117053（约176.5MiB） | `76af4056e026743d8966a212a5288a2a6234423774560f611a168ddea0417e96` |

交付目录为`app/build/private-releases/1.0.0+1-862a13ac/`，内有`USTC-Assistant-1.00-windows-x64/`、同名ZIP及`.zip.sha256`。目录含35个固定运行文件、2份交付说明和manifest，共38文件；manifest列出除自身外37个文件的大小与SHA256，另记实际源码修订及锁文件摘要`59fc041413f2a8ff4d4fc3710cfa3522c6b45672e867cf77a65755a89983f6a1`。打包工具已从ZIP重新读取并校验条目集合、manifest和每项内容摘要，未把构建静态库放入ZIP。

根确认没有运行中的产品进程，解析核对源/原Release路径均在本工作区、互不相同且没有重解析点，只将35个运行文件复制回原`app/build/windows/x64/runner/Release`，逐项hash与正式暂存相同；该路径版本也为1.0.0+1。没有删除资料、打开正式库或自动启动应用，防止收尾本身触发真实学校/模型作业。原路径已可供用户自行启动。全新Windows机器与用户正式资料启动仍不冒充本轮验证。

工程和文档分别本地提交；所有包、日志和构建产物保留在ignored build，不进入Git。没有上传、推送、创建云发布或公开下载。

## 移动调研交接

根依据当前代码、锁定插件公开实现及Flutter/Android/华为官方资料形成[Android APK迁移评估](../../../research/android-apk-migration.md)。结论是保留Dart业务与Flutter组件，新增Android组合根/私有目录/Keystore/WebView/通知/文件和语音适配；先证明学校Profile隔离/清理与退出提醒。普通Android、直接APK鸿蒙、兼容服务内APK和原生HAP分别界定，不仅凭系统版本猜支持。本轮没有Android工程/SDK安装/APK构建/设备连接，不代表V-07通过。

## 保留项

用户认可1.00是整体版本决定，不是语音质量、非空考试、真实调休/二课撤回、通知实际投递/睡眠/重启或新机器运行已逐项通过。[已知问题](../../../releases/windows-1.00-known-issues.md)随包提供，完整V项继续登记。未发布和手机未实施的边界保持。
