# 数据采集架构

## 目标

`ustc_assistant` 是后续手机 App 的本地数据源包。CLI 与 App 调用相同的来源 service；CLI 只负责参数、输出和脱敏状态，不承载网站规则。

## 分层

- `common.browser`：专用可见 Edge 持久会话、生命周期和脱敏浏览器错误。
- `common.storage`：UTF-8 JSON 与显式原始文件写入。
- `sources.jw`：课表、考试采集和统一教务导入包。
- `sources.young`：报名中活动和已报名日程两个独立只读来源。
- `sources.icourse`：公开 HTTP、HTML 解析、缓存、匹配与排序。
- `sources.campus`：公开目录索引、本地检索、按 ID 读取详情和附件缓存。
- `cli`：所有采集、查询和读取命令的统一入口。

来源 service 返回结构化字典和必要的内存原始对象。App 应直接导入 service，不启动 CLI 子进程，也不解析终端文字。

## 数据流

```text
official/public site -> collector/client -> parser/normalizer -> source service
                                                        |-> App sync layer
                                                        `-> CLI local JSON
```

学校来源数据未来通过 `source + externalId` upsert。来源刷新不得覆盖 `UserOverlay` 中的用户备注、出勤、听讲和提醒设置；窗口外记录也不等于删除。

校园公开信息先把目录元数据写入本地索引，Agent 再根据对话意图选择至多 3 个目录 ID 按需读取。详情读取不接受任意 URL；正文发现的后续链接只能按解析器生成的候选 ID 跟进一层。二进制附件只下载和缓存，文档转换属于独立处理层。

## 错误边界

- 页面、接口或计数契约变化时明确失败，不输出不完整快照。
- 浏览器上下文始终关闭。
- 错误消息不包含请求查询参数、响应体或认证值。
- 原始数据默认只驻留内存。
- 远程页面正文和附件内容均是不可信数据，不得改变工具参数、权限或 Agent 策略。

## 时间

日程统一使用 `Asia/Shanghai`。二课滚动窗口和 `collectedAt` 均按北京时间计算。
