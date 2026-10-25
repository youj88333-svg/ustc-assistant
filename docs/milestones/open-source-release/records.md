# 开源与公开安装包准备记录

2026-10-25开始。范围与验收见[任务单](plan.md)。用户要求从开源准备推进至Release安装包交付，已明确接受Apache-2.0，随后选择Android独立正式身份并完成本机签名初始化；现有测试版、数据和私有交付保留。

起点main 78835c9、工作区干净，私有Windows及双ABI APK的实际源码仍为441a68b。此前只读盘点main历史623个提交、两段根历史，当前850个受控文件，无项目级LICENSE；公开前需要历史/资源与发布审计，不能直接把可见性切换当作开源完成。校园GitLab匿名API项目请求404，网页请求302到登录页；仅证明本次匿名未读到项目，未据此断言后台Private/Internal具体值或站点允许的公开设置。

现有Android交付是cn.ustcassistant.mobile.qa及调试构建；新公开版本不能在未核实签名与数据影响前替换它。SenseVoice权重现有NOTICE明确使用FunASR Model Open Source License Agreement 1.1，不统一替换为项目代码许可。学校精选Markdown与公开原始资料的归属/再分发边界另核查。

## O0–O1：源码范围、许可与说明

固定Gitleaks 8.30.1官方Windows归档，经上游checksum及Release资产摘要核验（归档SHA-256 `d29144deff3a68aa93ced33dddf84b7fdc26070add4aa0f4513094c8332afc4e`）。当前受控源码快照11处、main及校内实际head/tag可达历史14处初始命中，均逐处按脱敏位置和合成语义核查：JavaScript API对象、公开tokens摘要及明确的测试哨兵/顺序假值；没有据此认定真实凭据泄露，也没有修改历史。`.gitleaksignore`只列14条精确历史指纹，不整体豁免tests或generic规则，新提交仍扫描。扫描不包括私有stash、忽略的认证资产或正式资料，也不构成“绝无秘密”的保证。

复验首次因本机Git外部textconv失败，扫描器却返回0及空报告；本次明确记录为无效结果。关闭textconv/ext-diff并检查原生stdout/stderr后，既定范围复验退出0、报告0命中且无底层错误。新增本机审计入口及GitLab CI使用同样防误报通过的检查，仅输出规则、路径、行号和提交，不包含Match/Secret字段；CI容器版本已与上游公开包页核对，校内runner尚未执行。本机脚本已实跑main 78835c9可达历史、0命中，且正确标出工作树未提交内容不在此轮覆盖内；最终提交另复核。

加入Apache-2.0正文、NOTICE、第三方分界、开始使用/开发/贡献/安全反馈说明和共用已知问题页。AndroidX、WebView2、record、sherpa-onnx、ONNX Runtime、SenseVoice权重、学校资料和图标分别保留来源/许可；不声称学校或模型方背书。用户明确沿用现有图标后，已停止替代图标任务，不把追溯原作者作为本次阻塞项。

## O2–O3：签名与候选工具装配

用户在普通PowerShell本地输入签名密码完成初始化。源码外`E:\107\private\android-signing`保存PKCS12与CurrentUser DPAPI配置；根只核验文件存在、保护ACL及公开DER，不直接查看私钥或配置内容。公开证书为RSA3072、CN=USTC Assistant、有效期至2054-03-12，SHA-256为`8f5022f13297f11ad3049d1da5d9eb61493b48f4745859b48d060dc99d549fa7`；公开DER复制到`docs/releases/android-release.cer`用于身份核对。密钥不进源码、日志或附件。

Release生产任务无签名时失败；禁止QA alias及开发面板defines。Dart临时诊断/M3面板另受kDebugMode约束，普通日志导出和生产采集脚本保留。签名仅经构建进程环境传递，恢复原环境、禁用Gradle daemon/configuration cache，日志先脱敏再落盘。候选要求干净HEAD、AOT内嵌修订、APK真实签名/包名/版本/ABI/Manifest与固定资产、Windows固定运行载荷和逐文件SHA-256。公开组合计划只列3安装包及manifest/sums/notes六个公开附件，不包含本地执行plan或签名资料；工具本身不创建tag、改可见性或上传。

根已独立运行：签名初始化61项、Windows私有17项及公开25项、Android打包44项、GitLab组合计划48项合成检查通过；构建客户端初版102项、依赖报告增量122项及最终143项均通过。最终增量验证Windows不依赖Android工具或签名配置、不向子进程泄露既有签名环境；非C盘路径仍经过普通本地路径校验，D盘实际构建未执行。Android打包已根据实际Flutter源码兼容准确的`.apk.sha1`旁文件并检查匹配，发布完整性仍采用SHA-256，不用SHA-1代替签名。

## 整体检查中的失败与处理

根`flutter analyze --no-pub`无问题。首次共享测试在执行用例前被SQLite3固定二进制的Dart TLS握手失败阻断；没有放宽TLS或修改系统信任，经上游固定版本下载并匹配依赖内置SHA-256后补入E盘原生钩子缓存。第二轮执行1653项通过、1项既有平台跳过、1项失败：二课每日同步的测试在自动计时器并发检查期间立即断言调用次数，观测尚未完成。测试改为有界等待实际接纳完成，再核对次数/新日重置/取消非成功，不改变生产调度逻辑。修订后该套21项通过，共享全套1654项通过、1项既有平台跳过，退出0；没有把失败轮计入通过。

GitLab CI YAML由既有Dart yaml依赖解析通过；本机Conda basic310未安装PyYAML，未为此额外安装环境依赖。根文档检查当前180份Markdown、1386个本地链接通过，差异检查通过；随着最终证据更新再检查链接，校内CI执行仍单独保留。

## Windows恢复关闭预算及最终共享/原生检查

根五套Windows原生检查18项先通过（引导2、维护3、Agent5、M6提醒5、诊断3）；每日二课原生首例在清资料后busy、次例staleResult失败。Sol子代理以短TEMP重现并用临时Debug/test-mode固定bool/count定位，路径缩短没有消除问题；不是每日grant或真实学校失败。恢复窗口的回调计数和controller/core/window都已清空，但浏览器进程句柄仍未signaled、官方BrowserProcessExited未到；诊断中约20秒才取得完整退出证明，原12秒预算不够。次例独立通过，原失败是首例遗留状态继发。

根决定只把Young构造默认drainTimeout改为30秒，不改RPC协议和退出/租约/删除判据；未知退出仍保留租约进入recovery，不强制结束浏览器或把close回执当作排空。自定义短超时与失败反例保留。临时native诊断协议及MethodChannel trace已全部撤回，C++源码无残余差异；保留clearSession后的idle/租约断言和安全清理失败提示。子代理74项相关共享及2项原生通过后，根再次独立执行：analyze无问题，每日二课原生2项通过（46秒），至此六套20个唯一原生场景通过，不把重复次数相加。

根最终共享轮还暴露晨报测试先观察到C3失败、随即断言本地订阅取消完成的异步时序问题；生产逻辑未改，测试改为有界等待实际cancelAndDrain调用后再断言。该套21项通过，随后根完整共享测试1654项通过、1项既有平台跳过，退出0。没有用失败轮或重跑次数覆盖原记录。

发布说明改为中文，图标沿用事实只保留在来源/许可说明，不再作为Release正文的选择题。组合清单48项再次通过。官方glab 1.124.0便携归档SHA-256 `9b58b54cf841b43215ef01ba90793d8a845e81ddb7b3dfa2b5a238cde4b77b34` 已与上游checksum核对，位于E盘忽略工具夹；官方客户端只读检查显示校内GitLab发布接口尚未登录，未输出Token或执行发布。源码SSH认证不替代Release API登录。

已创建一个自有无窗口API34官方模拟器，WHP可用、冷启动80.5秒、独立ADB5038/端口5588，AVD/临时资产在E盘；不操作MuMu、真实设备或原私有资料。正式APK安装与启动结果待实际构建后核验。

Windows稳定Debug产品入口构建及纯音频方法消息编解码目标也实际通过，未打开麦克风或启动正式资料。Android真实工具链预检发现Kotlin DSL的java访问器遮蔽`java.util.Base64`，改用显式导入后编译通过；无签名的`assembleRelease`确实因本项目签名门禁退出失败，非其它编译错误冒充通过。正式runtime依赖图解析成功，补齐传递原生组件归属；初次直接调用尚未生成的wrapper、以及不存在的无签名validateSigning任务均未计为成功证据。使用的Flutter 3.44.5 / Dart 3.12.2、engine 83675ed、AGP9.0.1 / Kotlin2.3.20已实际核对，未修改全局JAVA_HOME或代理。

## 首轮候选实际构建

干净ae64abac构建中，Windows Release和公开打包已通过，41项载荷及manifest/ZIP重读一致，ZIP183725084字节，SHA-256 `fe2bc0fe431a5b83b963bbea7efa9623979c166f92801a9f1b5c2a3ca3db15a2`；根另验VersionInfo为1.0.0+1、Authenticode为NotSigned。这是本地候选，不是已发布或最终选定版本。

同轮Android Java编译失败：先前测试/普通pub准备生成的Java插件注册仍含integration_test，而Release Gradle已正确排除该开发依赖。查实际SDK `flutter_command.dart`/`flutter_plugins.dart`确认`--no-pub`还会跳过Release插件重新生成。构建入口改为先离线校验锁文件、正式构建保留标准`--pub`再生成；没有手工删生成Java或把测试插件纳入正式依赖。源码/锁文件变动仍拒绝继续打包。首轮Android未产出成功候选，不将Windows部分成功当作双平台完成；修订后从新干净修订重建。
