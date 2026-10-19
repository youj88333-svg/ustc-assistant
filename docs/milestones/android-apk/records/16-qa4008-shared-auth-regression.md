# QA4008 共用认证回归

2026-10-19。任务依据与修改归属见[唯一任务单](../plan.md#a7-qa4008-双来源认证回归)。本切修复用户反馈，不关闭A7/A8。

## 用户证据与定位

用户已同签名覆盖QA4008，反馈Young仍失败且JW自动认证也失效。根只读MuMu共享文件夹的固定安全导出 `USTC-Assistant-diagnostics (4).json`；北京时间2026-10-19 17:27导出，complete=true、invalid=0、dropped=0、selectionTruncated=false，当前事件源码为 `239ffb0e9fe4b38936f0ac669f99872ab314f2d0`。没有操作MuMu、读取正式业务库、秘密、原始学校响应或浏览器认证资产。

该修订下Young三次、JW三次均从opening进入login，再报告waitingForSchool/pageStructureChanged，没有进入collecting或committed。此次证据明确指向共用认证检查；此前QA4007进入采集后的拒绝仍是独立未确认问题，不能据此声称已经查明或修好全部真实Young故障。

根比较QA4007与QA4008发现后者将表单候选从“含可见所属控件的表单”改成“表单自身未被CSS隐藏”。已有公开模板形状夹具的autoLoginForm只有hidden字段、没有display:none；它会被新逻辑计为第二表单，导致正常可见密码表单也被拒绝。上轮Android完整JW夹具显式给辅助表单加了display:none，Young仅有单一表单，未覆盖这一组合；Windows认证夹具原已包含该形状，Android没有执行该套夹具。此为根确认的工程回归，不借日志推断当前学校DOM所有细节。

## 修复与实际检查

只用合成/loopback及自有隔离模拟器，不访问真实学校或模型；保留原失败报告及旧QA包。

Luna/max在独立测试文件先加入无样式辅助表单、隐藏用户名镜像及未激活通行密钥tab的正向用例。根保留QA4008生产脚本实际构建，并在自有API32执行该目标测试：1项失败（1.949秒），预期formReady却返回pageStructureChanged。原报告为忽略的 `app/build/qa4009/reports/login-before.txt`，不覆盖成成功结果。

Sol恢复按可见所属控件判断活动表单；空容器/hidden-only表单只可进入原固定1500毫秒宽限，永不直接提供formReady。其余歧义、额外可见输入、挑战及提交中的节点复核保持；定向投递、单次消费、来源身份与最终完整事务均未更改。

两来源的完整loopback登录页改为同样的无CSS隐藏辅助表单组合，并记录合成字段哨兵是否保留和实际提交次数。根复核Young夹具时另修正HTTP表单解析：display:none用户名镜像仍属于表单提交控件，必须显式保留并检查两个同名username值，不能用折叠重复键的解析器掩盖主账号或错误拒绝合成登录。这只改变测试夹具，不改变产品读取/认证协议。

根API32 / Android12 / WebView120.0.6099.193普通原生46通过、1历史反例跳过（71.352秒），包括原失败转为通过、单次定向投递、辅助字段未写、hidden-only不授权，以及投递过程中辅助账号/隐藏镜像变可见时拒绝且不写密码。随后完整学校合成六组通过、1个独立smoke未选（3分14秒）：覆盖JW自动认证/凭据/导入去重及Young多段跳转/共享凭据/活动与关联日历、身份/分页拒绝、取消排空和重试。自有API32已正常停止，不据此宣称真实MuMu已修好。

根analyze无问题（8.9秒），全套Dart/widget为1566通过、1平台条件跳过（1分33秒）。未增加数据库schema或改变业务、会话、模型/Agent权限；Android SDK、依赖缓存、AVD及本轮临时仍在E盘。不以子代理静态检查代替根实际执行。

API34 / Android14 / WebView113.0.5672.136的全套原生107通过、8个历史高级能力反例跳过（84.965秒）；完整学校合成六组通过、1个独立smoke未选（3分21秒）。这8个跳过不是跳过普通登录或采集。两自有AVD都已正常停止；未重跑API28/29/37，不从本轮样本推定MuMu110、arm64或鸿蒙通过。

Windows固定认证四组、教务七组、Young自动化三组均通过；测试使用并还原进程级 `USTC_NOTIFICATION_TEST_HOST=1`，不登记生产通知。Windows生产代码未改，本轮没有重建/替换正式Windows Release。JS语法及默认Git差异空白检查通过，工程提交为 `95a6451a753de3b82ec764df18be93473fe321ca`。测试编排过程一次用禁用换行规范化的临时Git参数误报整份CRLF文件为空白问题，根恢复普通 `git diff --check` 后通过，没有为消除该误报改写文件或全局Git配置。

## 私有升级交付

根以工程提交构建普通入口 `lib/main.dart` 的x86_64/ARM64 QA，单调版本4009/2009。Android构建、AndroidTest、lint和正式Manifest检查通过；两包均逐项核对包名 `cn.ustcassistant.mobile.qa`、版本名 `1.0.0-qa-a7-webview2`、单一ABI、源码修订、人格/思考策略标记及非集成夹具入口。包内 `jw_login.js` 和 `young_transport.js` 的SHA-256均与本次源码相同，语音模型和许可齐全。签名证书SHA-256仍为 `16d3f9867f0a15d4d4ffc877bdd9ec240e92a3fddf6a0a66da857e2888846036`。

| 文件（忽略的 `app/build/qa4009/artifacts/`） | 字节数 | SHA-256 |
|---|---|---|
| `USTC-Assistant-Android-QA4009-x86_64.apk` | 290989661 | `4a36a7a6d7df3f20ba8136f8b4ab189b171e76d13b755cda6f1050e70880a813` |
| `USTC-Assistant-Android-QA2009-arm64-v8a.apk` | 279216803 | `67c4a7db4a8798b7b76de8dafbef2bfc6930325b3db8c10c1d0cdba1f88ed799` |

元数据均标明publicRelease=false、realSchoolValidated=false；ARM64仅完成打包及内容核验，没有实机运行。旧QA4008/2008及Windows1.00 ZIP的字节数和SHA-256与原记录一致；Windows正式Release未替换、未启动或读取其数据库。

只交用户按[人工说明](../manual-validation.md)主动同签名覆盖，不自动安装/卸载MuMu，不清数据或浏览器会话；集中复验两来源自动认证与采集即可，若失败继续使用设置标题旁的“导出日志”。真实学校、手机/鸿蒙和原未观察项继续保留，A7/A8未关闭。文档和工程分开本地提交，不推送；导出日志、构建和临时资产不入Git。

最终文档检查通过：153份Markdown、1210条本地链接及现存档案manifest；普通Git差异空白检查通过。交付后重新核对旧QA4008/2008和Windows1.00 ZIP，大小及SHA-256均保持原值。
