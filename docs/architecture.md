# USTC Assistant 架构

## 目标

`ustc_assistant` Python 包是 Windows App 和后续手机 App 的本地数据源层。
`app/` 是已经实现的共享 Flutter 应用核心。CLI、Windows Bridge 和未来移动端
采集适配器遵守相同的来源契约；CLI 只负责参数、输出和脱敏状态，不承载网站规则。

## 分层

- `common.browser`：专用可见 Edge 持久会话、生命周期和脱敏浏览器错误。
- `common.storage`：UTF-8 JSON 与显式原始文件写入。
- `sources.jw`：课表、考试采集和统一教务导入包。
- `sources.young`：报名中活动和已报名日程两个独立只读来源。
- `sources.icourse`：公开 HTTP、HTML 解析、缓存、匹配与排序。
- `sources.campus`：公开目录索引、本地检索、按 ID 读取详情和附件缓存。
- `bridge`：Windows 临时 loopback 服务、认证回环和可恢复采集作业。
- `cli`：所有采集、查询和读取命令的统一入口。
- `app/lib/features/import`：SourceBundle 解码、语义校验和单事务导入。
- `app/lib/core/database`：账号分区的 Drift/SQLite 本地事实来源。
- `app/lib/features/schedule|calendar|tasks`：共享日程、个人事件、Task 和
  PlanBlock 业务核心。
- `app/lib/features/accounts|sync|reminders`：Windows 账号安全、Bridge 编排和
  平台提醒适配。

来源 service 返回结构化字典和必要的内存原始对象。只有需要导入 Flutter
本地数据库的完整来源快照使用 `SourceBundle`；报名中二课、评课社区、校园目录
查询和详情读取继续使用各自版本化的 `QueryResult` 或 `DetailResult`。

Windows 第一版中，Flutter 不能直接导入 Python 包，因此通过只监听
`127.0.0.1` 的临时 Python Bridge 调用来源能力。Bridge 直接导入
对应的 `ustc_assistant.sources.*` service。JW 与已报名二课日程返回版本化
`SourceBundle`；查询型能力返回各自结构化结果。Bridge 不运行采集 CLI，也不让
Flutter 解析终端文字或中间 JSON 文件。CLI 仅用于开发、调试和独立验收。

迁移到 Android 和 iOS 后，移动端 `SourceGateway` 使用 WebView 登录会话及
移动端 HTTP/页面适配器重新实现采集。移动端适配器仍输出相同的
`SourceBundle`，因此 Flutter 的 `ImportService`、SQLite、用户覆盖层、日程和
Task 逻辑不需要随采集实现重写。Python Bridge 是 Windows 平台适配器，不是
跨平台应用核心。

该 Windows 链路已经实现。Android/iOS 目录目前只有 Flutter 平台脚手架，移动端
`SourceGateway` 仍是后续工作。

## 数据流

```text
Windows:
official/public site
  -> Python collector/client
  -> parser/normalizer
  -> source service
  -> local Python Bridge
  -> versioned SourceBundle
  -> Flutter ImportService

Mobile:
official/public site
  -> WebView session + mobile collector
  -> MobileSourceGateway
  -> versioned SourceBundle
  -> Flutter ImportService

Development:
source service -> CLI -> local normalized JSON
```

SourceBundle 1.0 的规范性契约见
`docs/data-sources/source-bundle-v1.md`，机器可读 Schema 位于
`schemas/source-bundle-1.0.schema.json`。一个 Bundle 只对应一个独立同步来源
和一个完整范围，并由 Flutter 在单个事务中导入。

学校来源数据通过本地 `accountId + source + entityType + externalId` upsert。
来源刷新不得覆盖 `UserOverlay` 中的用户备注、出勤、听讲和提醒设置；窗口外记录
也不等于删除。来源 Bundle 不携带本地数据库主键、学号或远端用户身份。

校园公开信息先把目录元数据写入本地索引，Agent 再根据对话意图选择至多 3 个目录 ID 按需读取。详情读取不接受任意 URL；正文发现的后续链接只能按解析器生成的候选 ID 跟进一层。二进制附件只下载和缓存，文档转换属于独立处理层。

## 错误边界

- 页面、接口或计数契约变化时明确失败，不输出不完整快照。
- 浏览器上下文始终关闭。
- 错误消息不包含请求查询参数、响应体或认证值。
- 原始数据默认只驻留内存。
- 远程页面正文和附件内容均是不可信数据，不得改变工具参数、权限或 Agent 策略。

## 时间

日程统一使用 `Asia/Shanghai`。二课滚动窗口和 `collectedAt` 均按北京时间计算。
