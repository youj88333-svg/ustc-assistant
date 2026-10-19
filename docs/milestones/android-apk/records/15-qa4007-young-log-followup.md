# QA4007 二课日志复查

2026-10-19。任务边界与接口见[唯一任务单](../plan.md#a7-qa4007-日志复查与采集兼容)。这是既有来源故障修复，不是阶段关闭。

## 最新证据

用户明确要求查看最新日志，根只读MuMu共享文件夹固定 `USTC-Assistant-diagnostics (3).json`，没有操作MuMu、读取正式业务库或浏览器认证资产。导出时间为北京时间2026-10-19 16:31，333条事件，complete=true、invalid=0、dropped=0、selectionTruncated=false；新事件源码为 `29f3fe8d3e058e3c468fc6a7b1ade8297ecafc92`，对应QA4007。

该源码最近四次Young尝试中，两次进入collecting后约1.9秒转closing/idle，失败code=unknown；中间两次在login报告waitingForSchool/pageStructureChanged，其中一次来自每日自动尝试。没有committed记录，不能把新版工程检查当作真实采集修复成功。用户随后截图显示“二课返回内容不符合已验证结构，结果未提交”，同时有旧浏览器资料待清理提示；不从这张图推断唯一成因。

根确认诊断映射缺少封闭值 `YoungBusinessRejection.sourceFailure`，它被转成unknown；同一未知码可能有其它来源，不能仅靠旧日志恢复已经丢失的具体传输步骤。新版人格的版本名也被仅允许旧角色的格式检查洗成unknown。正式界面隐藏了旧同步摘要按钮，故撤回要求用户寻找该入口的提示，继续以用户已导出的日志排查。

## 实施与检查

本节随实际执行更新。自动检查只使用合成、loopback及隔离资产；不访问真实学校/模型。

根在自有API32 AVD先新增一个合法固定profile请求仅附加数字缓存时间戳的用例，使用未修订的QA4007读取器执行，实际1项失败（2.547秒）：dispatch返回error而非value。原报告保存在忽略的 `app/build/qa4008/reports/cache-buster-before.txt`，不改写为通过。这证明存在可重复的兼容缺陷，不证明学校当前请求实际带有该字段或已确定唯一成因。代码复核同时确认Windows CDP按固定端点/编译脚本关联请求时不解释查询串，Android新增的逐参数校验反而拒绝这一附加值。

Sol只允许页面请求拦截器附加单个 `_t`，值为10位秒或13位毫秒形态的正数字；应用不增加业务参数，不解释它为身份或分页依据。固定GET、origin/path、field/pageNo/pageSize/now仍逐项精确核验，未知键、重复键、非数字时间戳或账号选择器一律拒绝。传输/HTTP/MIME/大小/解析错误仅保留封闭原因，未知异常消息及URL/响应值仍丢弃。完整loopback使用异步拦截器、原生XHR readyState与缓存参数，避免仅以简单fetch夹具代替框架请求。

Luna/max在不重叠文件完成纯诊断映射和登录局部修订，Sol复核：source元数据只含封闭作业/失败阶段/读取步骤/失败码，兼容旧记录；人格版本接受当前及历史固定格式。登录脚本给无歧义的残缺表单一次1500毫秒准备宽限，重复控件/错表单仍立即拒绝，完整唯一表单才允许原单次凭据契约。根复核后补上空form、完整后再次残缺不重启期限、表单外帮助按钮及完整表单内普通按钮的反例；没有放松提交时节点身份或单次消费。

根已执行analyze无问题（11.6秒），来源/诊断局部68项通过。Luna仅静态检查，未运行原生或Flutter；后续根原生及完整学校合成检查继续，尚不记作真实MuMu通过。

首轮API32普通原生为37通过、1历史跳过、5失败；五处都停在共用测试断言对新封闭原因的旧白名单，实际闭合失败码仍正确。根扩充该测试的封闭词汇并保留逐项精确拒绝断言，未放松产品校验，原报告另存。Astra只读复核另指出框架helper可能在XHR readyState完成时先拒绝，掩盖随后原生load中的具体HTTP/格式原因；这也符合 [Axios浏览器适配器](https://github.com/axios/axios/blob/v0.18.1/lib/adapters/xhr.js)的完成顺序。Sol保留helper拒绝标志，由同一步已认领传输的终态给出原因；合法原生响应遇helper拒绝仍失败。新增HTTP503、非法JSON、合法响应但helper主动拒绝三反例，既有截止/取消不变。Astra后续静态核对未发现漏网成功或新增永久等待，其结论不替代根测试。

根最终API32 / Android12 / WebView120.0.6099.193普通原生43通过、1历史跳过，包含新增登录宽限、合法缓存参数、错误/重复/账号/页号/日期参数及XHR拒绝时序。完整学校合成仍继续，未将原生通过写成真实学校或MuMu验收。

API32完整学校六组随后通过，1个独立smoke分支未选（2分58秒）。API34 / Android14 / WebView113.0.5672.136的全套原生104通过、8个历史高级反例跳过；完整学校六组也通过，1个独立smoke未选（3分06秒）。覆盖两来源自动认证、缓存参数与XHR、身份/分页/路由反例、取消、重试和分区清理，没有访问真实学校。

测试编排在子进程已经报告API34启动后停留；根核对本轮自有AVD已启动及boot_completed=1，仅结束固定命令行、唯一匹配的本轮编排PowerShell，保留原启动报告并直接接续检查，没有操作MuMu或更改产品掩盖编排问题。两个AVD已正常停止。全套Dart为1566通过、1跳过（1分16秒）。

Windows Agent五组、Young三组、M6五组均通过；原生测试使用并还原进程级 `USTC_NOTIFICATION_TEST_HOST=1`，没有登记生产通知。最后analyze无问题（6.1秒），JS语法及Git差异空白检查通过。工程独立提交为 `239ffb0e9fe4b38936f0ac669f99872ab314f2d0`；安装包核验见下节，真实MuMu/学校验收保留。

## 私有包与实际交付边界

根构建同一源码的普通入口 `lib/main.dart` 两种ABI包，核对包名 `cn.ustcassistant.mobile.qa`、版本名 `1.0.0-qa-a7-webview2`、单调版本号、单一ABI、源码修订、当前人格及思考参数标记，并排除集成夹具入口。包内 `young_transport.js` 和 `jw_login.js` 的SHA-256逐份匹配本次源码；固定语音模型及许可齐全。签名证书SHA-256沿用 `16d3f9867f0a15d4d4ffc877bdd9ec240e92a3fddf6a0a66da857e2888846036`。

| 文件（忽略的 `app/build/qa4008/artifacts/`） | 字节数 | SHA-256 |
|---|---|---|
| `USTC-Assistant-Android-QA4008-x86_64.apk` | 290989516 | `f81c855a7a7d65439706fbcfb692af79b27e4d74ccee0065dfda2d2f74ac103a` |
| `USTC-Assistant-Android-QA2008-arm64-v8a.apk` | 279216655 | `673828edc59003b6e35d3342864d50124dc6d052368b60fb9fcedce33f03c029` |

Windows Release仅构建到 `app/build/qa4008/windows-staging/x64/runner/Release`，普通入口、源码修订、PE身份、模型/许可及36份文件哈希核验通过，manifest留在本轮artifacts。没有启动该暂存应用、替换正式Release或读取正式数据库。旧QA4007/2007和Windows1.00 ZIP的字节数及哈希与原记录一致。

新版由用户按[人工说明](../manual-validation.md)主动同签名覆盖，保留现有QA资料，不卸载、不清会话。只需集中重试二课同步；若仍失败导出最新安全日志，不要求寻找被隐藏的开发摘要入口。根未安装或操作MuMu，ARM64仅打包核验；真实学校是否带缓存参数、实际失败是否只有上述成因，以及新版真实同步、模型/声音/文件/通知/手机/鸿蒙等原未观察项继续保留，A7/A8没有关闭。

最终文档检查通过：152份Markdown、1205条本地链接及现存档案manifest；Git差异空白检查通过。导出日志、构建和临时资产不加入Git，工程与文档分开本地提交，未推送。
