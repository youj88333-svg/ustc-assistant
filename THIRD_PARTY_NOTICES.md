# 第三方与来源材料

根目录[Apache-2.0](LICENSE)覆盖项目有权授权的原创代码及原创说明，不替第三方重新授权。二进制分发需要同时保留下面的通知与相应原许可。

| 部分 | 来源与适用说明 |
|---|---|
| Flutter、Dart及Dart依赖 | 保留构建生成的`NOTICES.Z`；依赖身份以`app/pubspec.lock`和各包原许可为准，不把整个依赖树统一改为本项目许可 |
| Microsoft WebView2 SDK Loader | [SDK原许可和NOTICE](app/resources/webview2/README.md)，固定1.0.3967.48；Windows包保留`data/licenses/webview2`。客户端另需微软WebView2 Runtime，本项目不将系统Runtime当成自行授权的组件 |
| record音频采集 | BSD-3-Clause，保留[原许可](app/resources/speech/RECORD-LICENSE.txt)及[来源说明](app/resources/speech/NOTICE.txt) |
| sherpa-onnx本地推理SDK | Apache-2.0，保留[原许可](app/resources/speech/SHERPA-ONNX-LICENSE.txt)；SDK许可不等于模型权重许可 |
| ONNX Runtime | MIT，保留[原许可](app/resources/speech/ONNXRUNTIME-LICENSE.txt)及对应来源声明 |
| SenseVoiceSmall INT8权重 | 使用[FunASR模型协议1.1](app/resources/speech/FUNASR-MODEL-LICENSE.txt)，独立于本项目Apache-2.0；固定来源、模型名、作者、转换包和摘要见[NOTICE](app/resources/speech/NOTICE.txt)。保留原`LICENSE`及完整协议；其中用途、责任、社区和终止条款以原文为准，不宣称这是Apache/MIT权重 |
| Android原生依赖 | AndroidX、Kotlin/协程/annotations、Guava ListenableFuture、JSpecify、ReLinker等分别保留Apache-2.0及上游归属，[Android原生通知](app/resources/android/NOTICE.txt)随APK携带；实际解析版本由正式构建依赖报告记录 |
| 学校公开资料 | [知识材料目录](knowledge/README.md)记录来源和整理范围。本项目对办事事实的整理、索引和校核说明不改变学校原文/图示的权利，也不证明政策现行；不把原资料标成Apache-2.0或授予其商标/原图再利用权 |
| 应用图标 | 用户确认是AI改编，参考学校标识及网络流传的二创形象，并决定公开版沿用现有图标；[来源记录](app/assets/branding/README.md)保留取用与摘要。项目代码许可证不额外授予学校标识、参考形象或原素材的相关权利 |

公开代码不代表可以省略这些原许可、把源资料当作当前有效规则，或声称项目得到学校、模型作者或其他权利人的背书。新增、替换依赖或素材时，应更新来源与随包通知；未知项在[发布任务](docs/milestones/open-source-release/plan.md)中保留，不能以安装成功替代分发核对。
