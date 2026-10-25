# M5.8 本地中文短句听写

## 范围与施工依据

2026-10-14，用户批准采用调研推荐的 `record + sherpa_onnx + SenseVoice INT8`，按指定工作流作为 M5.8 尝试实施。范围、接口及验收只维护 [任务单 §20](../plan.md#20-m58本地中文短句听写)，批准和最终人工结果见 [验收页](../acceptance.md)。依据现行 07–12、13 和 15，保持 C4 固定工具、学校/模型出口、C3 schema 13 及用户批准写边界。

Sol / max 负责 C0、状态/取消、原生 isolate、固定模型资产、组合根/维护/日志及根检查；三名 Luna / max 分别承接录音适配、输入框和独立合成状态测试，任务提示均明确设计依据、不变量、文件边界及验收。Astra / high 对跨层排空及后续 ONNX ABI 修订做只读独立复核；子代理结论不替代根执行。

## 实际实现

- Windows x64 首先交付。点击麦克风才载入本地模型并开启录音；再次点击停止并识别，30 秒或 960000 字节达到上限自动结束。目标 3–15 秒、最短 0.5 秒；输入固定为 16 kHz/单声道/PCM16 little-endian，短暂内存缓冲。空白、太短、断流、坏帧、资源超限及权限/设备/模型失败用固定状态显示，普通键盘输入保留。
- 本地 CPU 识别在持久、按需创建的 Dart isolate 内，固定 `provider=cpu`、2 线程、`debug=false`，输出用模型标点/数字规整。模型初始化、哈希校验及同步 FFI 不在 UI isolate 执行；首次加载之前不创建录音插件实例，不扫描设备。
- 转写只插入开始时的草稿光标/选择位置，保留既有文字和附图，不自动发送或批准。会话、历史、草稿、端口/controller、页面或维护状态改变以及应用进入后台都会先撤销交付；取消/退出再停止录音并等待在途原生工作排空，不强杀 FFI。退出失败保留目录所有权供重试。
- Runtime 持有同一端口，页面只取消；维护先取消听写再排空 Agent。没有新增 C4 工具、模型 Key、云端接口、录音文件、自动下载、持续监听、TTS 或移动端验收。只有用户主动发送后的草稿才按既有对话规则处理；原声/中间采样结束后尽力零化，不承诺运行时全部副本绝对抹除。
- M5.7 日志沿用原有白名单和有界存储，仅加入固定语音阶段/失败码、计数与耗时；不保存声音、转写文本、设备名或异常正文。语音不能调用学校采集、读凭据或操作业务库。

## 固定资产与许可

SDK 固定 `record 7.1.2`、`record_windows 2.3.0`、`sherpa_onnx/sherpa_onnx_windows 1.13.8`。[公开模型](https://k2-fsa.github.io/sherpa/onnx/sense-voice/pretrained.html)为 `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17`；仅提取下列三项，不带公开示例录音。开发者使用 [准备脚本](../../../../tools/prepare-speech-assets.ps1)获取/检查，应用没有下载器。权重、缓存及生成构建留在 ignored build，不进入 Git。

| 资产 | 字节 | SHA-256 |
|---|---:|---|
| 官方 tar.bz2 | 163002883 | `7d1efa2138a65b0b488df37f8b89e3d91a60676e416f515b952358d83dfd347e` |
| model.int8.onnx | 239233841 | `c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51` |
| tokens.txt | 315894 | `f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc` |
| 原 LICENSE | 71 | `221c6df10b0931a5629adad671ea48fb7747e034c414b6d2bfa275bc3dd4ea17` |

运行时只接受可执行文件旁 `data/speech/sensevoice` 的固定普通文件，逐项复核路径/重解析点、长度及模型/词表摘要。包内 `sherpa-onnx-c-api.dll` 和 `onnxruntime.dll` 随固定插件分发；先绝对路径加载 ORT，再核版本 1.28.2 / API 28 及 basename 实际模块，最后按 SDK 的目录参数初始化 Sherpa，避免 PATH 中旧依赖导致原生崩溃。不改全局 PATH、代理、TLS 或系统信任。

权重使用 FunASR 模型协议 v1.1，区别于 SDK Apache-2.0、录音 BSD 3-Clause 和 ORT MIT。随包保留原 LICENSE、固定版本模型协议和 SDK/ORT 许可及出处，[NOTICE](../../../../app/resources/speech/NOTICE.txt)为发行归属。版本摘要属于公开资产核验，不是对录音或政策适用性的验收。

## 实际失败与修正

1. 首次提取命令因 PowerShell 拼接/数组优先级合并 tar 选择器，未提取文件；归档摘要正确。改为三条完整固定名称后提取、长度和 SHA 全部通过，准备脚本采用同一明确选择器。
2. 根 analyze 检出静态误用 `resolveSymbolicLinks`、测试可见性和样式问题；改为实际实体实例路径解析及内部固定目录传递，最终 analyze 无问题。临时公开资产探针一度被 analyzer 纳入，完成定位后删除，没有为它放宽分析规则。
3. 状态监听中同步取消可能重入 broadcast.add。操作 Future 改为先持有再发布，事件异步交付；UI 同时检查端口当前 revision/idle，采集失败绑定撤销后的 revision，防污染下一轮。监听 preparing/stopping 内取消及迟到失败测试保留。
4. 首轮 Windows 两组失败：SDK `initBindings` 会追加 DLL 名，误传文件路径导致模型准备失败；测试还未在真实无 Key 应用中创建会话。前者按固定 SDK 源码改为目录，后者走 UI 新建真实空会话，无网关请求。
5. 公开模型纯 Dart 探针在环境中误加载 ORT 1.17.1，C API 请求 API 28 后发生原生访问冲突。已通过随包 ORT 的明确加载和版本/API/basename 守卫拒绝不兼容初始化；修订后公开模型创建成功、原生合成三组通过。探针只读公开模型/DLL，没有实际秘密或录音，临时代码已删除。
6. 30 秒 widget 测试混用了 fake/real zone，出现 stopping 与 teardown 挂起；根全套该批失败，不计通过。已按实际命令与父子关系收口自建测试进程，不停用户应用。计时改为独立 FakeAsync，定时例使用可控单订阅流，计时断言后在真实 zone 排空并刷新 fixture 队列；独立真实异步关闭测试继续验证完整 drain。最终状态测试 15 项及根全套通过。
7. 固定 TTS 素材准备脚本在 Windows PowerShell 5 中按默认编码误读 UTF-8 中文字面量，解析失败。改用 ASCII 源码的固定 Unicode 码点构造同一句话，进程级脚本重新执行通过；不改全局编码或执行策略。

## 根实际检查

自动检查仅使用合成、loopback 和 TEMP；没有访问学校、真实 Key/业务记录、浏览器认证资料或真实麦克风。

| 检查 | 实际结果 |
|---|---|
| `flutter analyze --no-pub` | 无问题，3.0 秒 |
| 根 `flutter test --no-pub --reporter expanded` | **1068 通过 / 1 平台条件跳过**，38 秒；跳过的 Windows 凭据平台分支另有原生套件 |
| 定向语音行为 | 状态/边界 15、录音适配 9、UI 12、原生 worker/坏输入 4 均纳入根全套；计时、上限、静音/坏帧、失败/重试、取消/关闭、迟到、草稿/附图和日志哨兵分别验核 |
| Windows `speech_input_flow_test` | **3 组通过**：严格合成 WAV→真实模型冷/暖识别；无 Key 的真实空会话与草稿/退出/重启；TEMP reset 等待取消排空，不关闭可复用端口 |
| 既有十套 Windows | **31 组全部通过**：Agent 5、设置 3、日程 4、应用壳 1、知识 1、JW 7、Young 2、Young 自动化 3、M0 2、诊断 3。每套独立 SDK 命令；连同新增语音为 **十一套 34 组** |
| 固定资产 `prepare-speech-assets.ps1 -Check` | 三项长度/SHA 和随包许可通过 |
| 合成素材准备脚本 | Windows PowerShell 5 下执行通过，固定本机 TTS/PCM16，不用麦克风 |
| 正式 Windows Release | **通过**，60.2 秒；默认正式入口，携带下述代码 SHA，没有开发/测试 define；安装后的模型/词表长度/SHA、三项原生库及六份许可/出处再次核验通过 |
| docs / diff | `tools/check-docs.ps1` 通过：104 份 Markdown、774 个本地链接及档案清单；`git diff --check` 无空白问题 |

原生使用 Windows 本地中文 TTS 固定合成“明天下午三点，在图书馆复习一个小时。”，PCM 约 5.0 秒；不使用麦克风。冷加载 **3328 ms**、冷识别 **175 ms**，第二次准备 **0 ms**、识别 **166 ms**；测试只输出耗时和目标词匹配布尔，不输出转写。该样本证明本机公开模型/ABI/排空和中文路径，不代表课程、教师、教室或真实环境准确率。固定合成素材由 [测试准备脚本](../../../../tools/prepare-synthetic-speech.ps1)复现。

## 交付与待验

代码已本地提交 **`6e2922015e3788b1b10f557b20cea01f28c6bf9c`**（`feat(speech): add local Chinese dictation with safe lifecycle`）。正式构建以 `lib/main.dart`、`--release --no-pub --dart-define=USTC_BUILD_REVISION=<该SHA>` 交付，不启用开发/测试/临时入口；文档单独提交，不推送。新版 `app/build/windows/x64/runner/Release/ustc_assistant_m0.exe` 已启动供集中体验，只读取进程元数据，不直接查看正式业务或开启麦克风。M5.8 工程与真人确认分开，整个 M5 仍等待最终统一体验、尚未关闭。

用户方便时，在现有对话点击麦克风说几秒中文，停止后检查/修正草稿再自行发送；再试一次取消即可。不需要重新执行机械故障矩阵或发送音频/秘密。Windows 实际权限、设备录音、真实短句和课程术语准确率及真实延迟仍未核验；保留 M1 非空考试后补、其他来源未观察样本及 M5 既有最终清单。
