# A1 凭据保护端口

日期：2026-10-16。依据[计划A1凭据契约](../plan.md#a1凭据端口实施契约)、07/09/11/12及15；前置[A0模拟器门禁](01-a0-runtime-probes.md)已通过。本块完成保护端口，不等于A1整体或手机版可用性通过。

Sol固定接口、实现Dart适配/MethodChannel注册、审查并根运行；Luna（GPT-6 Luna/max）仅实现原生Keystore原语和自有QA测试。子代理没有运行Gradle/adb/Flutter或提交；根发现的`Key`静态类型、nonce切片、测试常量和无效输入断言在集成前已修正。

## 行为与保留

Android新增学校/模型两个类型端口，机制`android-keystore-aes-gcm-v1`，使用两个Keystore非导出AES-256/GCM密钥，完整C3用途作为AAD，每次由Keystore生成随机12字节nonce。学校与模型用途严格限制为现行C3两族，坏版本、tag、大小、用途和缺失密钥拒绝；解密不重建密钥、不改C3。没有新增秘密持久库或读取Windows DPAPI资料。

Flutter私有通道仅允许`protect/unprotect`和`purpose/data`，后台串行执行；原生只返回固定错误码，Dart不传递底层消息/details。通道接收副本、AAD及中间缓冲尽力归零，调用者输入和返回的有效结果归调用者所有；不承诺跨运行时副本绝对抹除。[Flutter线程契约](https://api.flutter.dev/javadoc/io/flutter/plugin/common/MethodChannel.Result.html)允许后台回复，队列明确设置serial。

MainActivity已注册通道，但当前Debug入口仍是A0原生探针。新端口尚未由Android平台工厂装配到正式业务启动，本轮未验证实际Flutter→原生通道→C3的组合链路；这属于后续A1装配验收，不能把原生/模拟通道分别通过当作已完成。

## 根检查

- 原生QA：官方API36/x86_64独立AVD，`.qa`身份安装当前主/测试APK，instrumentation `OK (10 tests)`，0.857秒。包括原4项和新增6项：两族往返/完整用途隔离、不同nonce、跨族拒绝、坏封套与边界、删除key后拒绝且不重建、重新保护后旧密文仍拒绝。测试使用每次随机namespace，finally只删除两枚测试alias，并核验Key不可导出；没有使用正式alias或真实秘密。
- Dart全套：1441通过、1项平台跳过，73秒，含原Windows目录/事务用例和新增6项适配检查。随后移除重复导入/无用注入字段，最终analyze无问题，新增6项再次通过；没有为纯风格修改重复整套。首轮analyze的4项info保留为已修正失败，不写成首轮无问题。
- Android：根执行`tools/android-a0.ps1 -Action Build`，Debug分包、AndroidTest、Release Manifest合并及lint通过。没有改Windows工程或重建/覆盖1.00私有包；未调用学校或真实模型。
- 一次格式化命令误带`app/`前缀，没有命中文件；已按实际工作目录修正。误置的本任务嵌套临时目录已核对绝对路径后删除，后续命令继续使用既有E盘临时根。

本地报告在`app/build/android-a1/reports/instrumentation.txt`及`app/build/android-a0/reports/a1-dart-tests.txt`，不入Git。工程检查点`0bc5cc5`，未推送。

| 当前QA产物 | SHA-256 |
|---|---|
| `app/build/app/outputs/flutter-apk/app-x86_64-debug.apk` | `244682ad177f7a399c1032ed7274a6c3549163c8635e87faeb8beab8191dc7ac` |
| `app/build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk` | `64ef854d4d8336df8b64904354896b892ad9fa34c2eae34086fe4a02e8c64dd2` |

A1剩余私有根/排他与子目录所有权、通用路径、平台工厂、数据库/诊断和启动恢复装配；只有这些合成链路完成后，才能说无来源配置的手机版本地日程/任务可用。真实设备、学校、模型和语音继续待验。
