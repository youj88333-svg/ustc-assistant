# A3 Agent 与公开能力（2026-10-16）

## 范围、实现与分工

按[迁移任务单的 A3 契约](../plan.md#a3-agent与公开能力实施契约)实施，前置[空间清理](05-generated-cleanup.md)已完成。复用 M3/M5 与 A1/A2 的同一业务栈，不复制 Windows Agent，不增加工具、数据库迁移或手机代理设置。Sol 负责组合根、生命周期和模型到 C3 的集成；两名 `gpt-6-luna / max` 分别完成独立的公开能力检查与 loopback 模型夹具，根复核、修正并实际执行检查。

工程提交为 `e51ac2a06b873fc79de29a2c9afad3bc09f502c1`。具体变化：

- Android 的 `OwnedApplication` 在 hidden/paused/detached 时同步撤回 Agent 的新作业入口，沿既有 stop 路径取消模型、撤销工具和未提交批准、排空请求并刷新 C3；inactive 保留作业。回前台只重新开放入口，既有提交保留，不自动重发、批准或重复提交。Windows 不安装此策略。
- 沿用固定模型网关、Android Keystore、20 工具、单对话与安全完整交互、跨轮目标、许可、规划和回执。公开 HTTP 经既有 C2/C3；未发现需要另写 Android 版本的共享公开解析或知识服务缺口。HTTP 会话中没有 PC `7897` 硬编码，不把开发工具的 Java 下载代理写入手机。
- 普通 QA 构建可传 `-BuildRevision <40位SHA>`，Flutter 与后续 Gradle 编译均保留该定义。QA 后缀更新为 `-qa-a3`，版本码继续 4001，以保留合成 QA 资料；正式签名与版本码仍待 A8。默认模拟器改为保留的 API36，避免无参数启动时重新生成已删除的旧 API35。
- `analysis_options.yaml` 只排除生成的 `build/**`、`.dart_tool/**`；E 盘工具临时目录中的 Flutter listener 不再被当作本工程源代码检查。应用、测试与集成检查仍全部分析。

## 根实际检查

测试只使用独立 QA 私有临时根、合成凭据与模型、loopback HTTP，以及已批准的七份随包公开文本；不访问真实学校/模型或正式业务。API36 为保留的本地模拟器，不能据此认定完整学校自动认证或目标手机可用。

| 检查 | 实际结果与证据 |
|---|---|
| 静态分析 | `flutter analyze --no-pub` 无问题；`app/build/android-a3/reports/analyze-final-pass.txt` |
| 全套 Dart | 1448 通过、1 平台跳过；`reports/dart-tests.txt`。此轮之后仅增加 SSE 首片段用例，其所在网关套件另行实跑 29 项全通过，见 `reports/live-stream.txt`，不把两次数字相加为一次全套执行 |
| Android Agent | 2 组合成集成通过；`reports/android-agent-drained.txt`。实际 Keystore→列表/能力探针→SSE→20工具→日程查询→空闲时段→任务/时间块→自然语言确认→真实 C3 提交→最终回答503→后续回执恢复，数量不重复；重开、compact/clear、Agent知识查读、私人备注不出站及生命周期收口均断言通过 |
| Android 公开/知识 | 1 组通过；`reports/android-public-first.txt`。真实匿名 HTTP 经 C2/C3，列表、详情续读、未知日期/不完整图文、跨来源重定向拒绝、租约冲突及取消后迟到响应不改变 C3；财务关键词/FAQ保持unavailable。实际 rootBundle 七份 Markdown 的摘要核验、缓考/报销检索、适用性未知、重复载入、重开保留、清除后重开为空与临时根清理通过 |
| Windows 回归 | 三套 7 组通过：Agent 5、公开知识 1、应用壳 1；`reports/windows/`。每套单独 Flutter CLI；进程环境 `USTC_NOTIFICATION_TEST_HOST=1`，不登记生产提醒 |
| Android 原生 | Keystore 6、QA宿主 1，共 7 项通过；`reports/native-credentials-host.txt`。测试仅创建自己的密钥命名空间，不删除应用的正常密钥 |
| 普通构建 | `Build -BuildRevision e51ac2a06b873fc79de29a2c9afad3bc09f502c1` 成功；APK、AndroidTest、生产 Manifest 与 lint 均通过，见 `reports/build-final.txt` |

以上 `reports/` 均相对于 `app/build/android-a3/`。Android 集成 runner 结束后仍检查 QA 包已安装，未通过卸载/清数据制造重启保留成功。后台用例通过真实 `OwnedApplication` 的监听器投递框架生命周期序列，不等于真实按 Home、系统杀进程、锁屏或厂商省电验收；这些仍由 A7 实机补齐。

## 失败与修正

首次分析暴露夹具的常量/类型/导入错误及生成 listener 被分析，均已修正，早期报告保留。首次模型夹具把 C3 的 `committed` 状态误作 `success`，且未区分有界上下文的自动摘要与普通业务轮；修正协议分支后，实际提交后的 503 恢复不重复写入。没有据夹具错误修改 C3 的去重或权限规则。

生命周期检查先因测试 SSE 缓冲而看不到未结束响应的首片段；改成显式 chunked、非缓冲响应，并新增主机真实 HTTP 用例证明终态前收到片段。随后发现测试跳过 Flutter 要求的 hidden 中间状态，最后又在发送 Future 结束时过早读取尚在收口的展示状态；改为完整状态序列并等待实际 idle/刷新。最终 2 组通过，未隐藏早期失败或将它们记录成平台成功。

## 构建与保留条件

普通启动包为 `app/build/android-a3/artifacts/USTC-Assistant-Android-A3-QA-x86_64.apk`，125,080,615 字节，SHA256为 `43f9e25beebd8dab20c5cd1700b1e1c38cac81bf68a44d9a80a1b2dac1d1d102`；同目录保存 manifest 和 APK 元数据。核验包名 `cn.ustcassistant.mobile.qa`、版本 `1.0.0-qa-a3`/4001、仅 x86_64、MainActivity；流式读取 kernel_blob 核对内嵌源码 SHA 存在，两个 A3 集成入口均不在包内。实际覆盖安装后普通 Activity 返回 `Status: ok`，进程存在（`reports/ordinary-launch.txt`）；这只记启动冒烟，完整运行逻辑以此前独立临时根集成为据，不补造人工体验。

这是模拟器 Debug QA 包，不是手机 arm64 或正式签名交付。结束时已停止专用模拟器和 ADB5038，并清除重新生成的 Flutter 缓存及离线 RAM 快照；包含本次产物的项目最终约12.962GiB，详见[清理复核](05-generated-cleanup.md#a3-完成后的复核)。原 Windows 1.00 ZIP/标签、A2 QA APK、其他工作区的源码与未提交资料保留，SDK/缓存/AVD/临时目录继续位于 E 盘。

目标手机、真实 Key 的 toolReady、校园网/移动数据下实际 TLS/公开站点与学校工具联动仍待设备和用户；模拟器的合成 toolReady 不替代它们。A2 的提供方私有世界门槛及真实来源限制继续有效。手机布局/图片选择/SAF 属 A4，系统提醒/晨报/每日同步属 A5，本地录音语音属 A6；原非空考试、财务搜索/FAQ和语音问题不改写为已验收。
