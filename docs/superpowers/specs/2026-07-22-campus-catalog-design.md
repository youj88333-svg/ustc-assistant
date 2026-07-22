# 校园公开信息目录与按需阅读设计

## 1. 目标

为 USTC Assistant 增加一个公开校园网页搜索工具层。系统只定期采集目录页中的轻量元数据，不预先抓取全部通知和指南正文。未来 Agent 根据用户问题自主检索目录、选择候选条目，并按需读取详情、附件或一层关键外链。

这一能力类似 Web Search 的两阶段流程：先搜索轻量索引，再读取少量结果。当前阶段只实现可独立测试的目录、详情读取和缓存 service，不接入具体 LLM。

## 2. 首批来源

| 来源 | 目录类型 | 刷新范围 |
| --- | --- | --- |
| `https://www.teach.ustc.edu.cn/category/notice` | 教务通知 | 最近 7 个北京时间自然日 |
| `https://www.teach.ustc.edu.cn/category/service/svc-student` | 学生事务指南 | 每个自然月至少完整刷新一次 |
| `https://finance.ustc.edu.cn/tzgg/list.htm` | 财务通知 | 最近 7 个北京时间自然日 |
| `https://finance.ustc.edu.cn/xxgk/list.htm` | 财务公开 | 每个自然月至少完整刷新一次 |
| `https://finance.ustc.edu.cn/ywzn/list.psp` | 财务业务指南 | 每个自然月至少完整刷新一次 |

“最近 7 个自然日”是闭区间 `[今天 - 6 天, 今天]`，统一使用 `Asia/Shanghai`。通知刷新逐页读取，遇到早于窗口的发布日期后可以停止。稳定目录完整遍历分页；是否到期由最近一次成功刷新的北京时间自然月判断，同时允许手动强制刷新。

## 3. 非目标

- 不预抓取全站详情正文或建立向量库。
- 不在本阶段实现具体 LLM、对话编排或自动日程写入。
- 不登录学校网站，也不复用教务或二课浏览器 Profile。
- 不允许 Agent 直接读取任意 URL。
- 不无限递归跟随详情页中的链接。

## 4. 架构

新增独立来源模块：

```text
src/ustc_assistant/sources/campus/
    __init__.py
    catalog.py       目录对象、生命周期、检索和本地持久化
    teach.py         教务处目录与详情页面适配器
    finance.py       财务处目录与详情页面适配器
    detail.py        正文、附件和一层关键外链读取
    service.py       CLI、未来 App 和 Agent 共用的稳定接口
```

各站点保留独立 DOM 和分页规则，只共享 HTTP 生命周期、缓存、结构化对象和错误边界。App 和 Agent 直接调用 service，不通过子进程解析 CLI 输出。

## 5. 数据对象

### 5.1 CatalogEntry

目录采集只生成轻量记录：

```text
id                  基于 source + 规范化详情 URL 的稳定 ID
source              teach_notice、teach_student_service 等来源名
kind                notice、guide、public_information
title
category
publishedAt         页面未提供时为 null
detailUrl
discoveredAt
lastSeenAt
status              active、archived、unavailable
```

同一详情 URL 重复出现时执行 upsert。通知离开 7 日窗口后标记为 `archived`；稳定目录中曾存在但本次完整刷新消失的条目标记为 `unavailable`，不物理删除。

### 5.2 KnowledgeItem

只有详情被实际读取后才生成或刷新：

```text
id
catalogEntryId
source
title
content
url
publishedAt
fetchedAt
contentHash
category
attachments
followedLinks
status
stale
```

`attachments` 保存显示名称、URL、媒体类型、大小信息和可选的提取结果。`followedLinks` 记录最多一个跳转层级的关键外链读取结果。现有日程模型中的 `KnowledgeItem` 后续可吸收这些字段；本模块先输出清晰的来源契约，不在此阶段设计最终数据库表。

## 6. Service 与 Agent 工具边界

核心 service 能力：

```text
refresh_catalogs(sources=None, force=False)
search_catalog(query, filters=None, limit=20)
read_detail(entry_id, allow_stale=True, follow_link_ids=None)
read_attachment(item_id, attachment_id)
```

未来 Agent 只获得后三种受控工具，不获得通用 HTTP 请求工具。一次推理先自主选择最多 3 个详情条目；证据不足时可以再读取一批。候选存在歧义时也由 Agent 自主判断，不要求用户逐条选择。

`read_detail()` 只接受本地目录中存在的 `entry_id`。首次读取返回带稳定 ID 的候选关键链接；Agent 只能通过 `follow_link_ids` 选择这些已发现 ID，不能提交 URL。附件必须由已读取详情页直接引用。普通外链默认不跟随；仅当详情明确将关键内容放在该链接中且当前内容不足时，允许跟进一层。

## 7. 数据流与缓存

```text
公开目录页
  -> 站点适配器解析
  -> CatalogEntry 规范化和 upsert
  -> 本地目录检索
  -> Agent 选择最多 3 条
  -> read_detail()
  -> 30 天详情缓存或实时读取
  -> 可选附件/一层关键外链
  -> 带原始 URL 的 Agent 回答
```

详情正文和附件解析结果的有效期为 30 天。缓存到期后保留 CatalogEntry、内容哈希、最后读取时间及过期正文，并将其标记为 stale；下次读取时重新访问原 URL，成功后原子替换旧内容。若实时访问失败，可返回过期缓存并明确设置 `stale=true`。调用方必须把过期状态反映在回答中。

目录刷新采用事务式写入：单个来源只有在分页和解析全部成功后才能替换该来源的活动索引。页面结构变化、分页不完整或日期契约异常时保留上一次成功结果。

## 8. 内容与安全边界

- 初始目录域名白名单为 `teach.ustc.edu.cn` 和 `finance.ustc.edu.cn`。
- 跨域 URL 只能来自已经读取的详情页，且最多跟进一层。
- 页面、附件和外链文字全部是不可信数据，不能覆盖系统指令、工具参数或安全策略。
- HTTP 请求设置超时、响应体积和解析字符数上限。
- 错误消息不包含完整响应体、请求头、Cookie 或其他潜在认证信息。
- 详情读取失败不破坏目录，也不阻止 Agent 改读其他候选条目。
- 原始响应和真实缓存默认保存在忽略 Git 的 `tmp/` 下。
- 附件第一阶段至少识别类型和 URL；PDF、Word、Excel、图片正文提取由独立转换层完成。转换失败时仍返回附件元数据和原始链接。

## 9. CLI 原型

```powershell
python -m ustc_assistant collect campus
python -m ustc_assistant query campus --text "缓考"
python -m ustc_assistant read campus --entry-id <id>
```

- `collect campus` 刷新五个目录，只输出目录统计，不预抓取详情。
- `query campus` 只检索本地目录，返回标题、日期、分类、来源、条目 ID 和详情 URL。
- `read campus` 模拟 Agent 按需阅读，返回正文、附件、缓存状态和引用 URL。

CLI 只负责参数、脱敏状态和 JSON 输出，业务规则全部位于 service 和站点适配器中。

## 10. 错误处理

- 单个来源失败时明确报告该来源失败，其他来源可以继续刷新。
- 目录结构变化、分页计数不一致或解析结果异常时不提交该来源的新快照。
- 详情不存在、被删除或访问失败时返回可分类错误；有过期缓存时按调用参数决定是否降级。
- 附件超限、类型不支持或转换失败时保留详情正文和附件链接，不把整条详情判为失败。
- 搜索没有结果是正常空结果，不自动扩大到未配置的网站。

## 11. 测试

自动测试使用脱敏 HTML fixture，不访问真实网站，覆盖：

1. 教务和财务通知的 7 日窗口、北京时间边界及分页停止。
2. 指南、信息公开和业务指南的完整分页刷新。
3. URL 规范化、去重、更新、归档和 unavailable 状态。
4. 详情正文、图片、附件和一层关键外链识别。
5. 30 天缓存命中、过期重取和失败时 stale 降级。
6. 来源刷新失败时保留上一次成功索引。
7. 域名白名单、响应体积、超时和递归深度限制。
8. 外部内容不能影响程序配置、工具参数或安全策略。
9. CLI 与 service 编排及输出脱敏。

实现完成后执行一次公开网站真实验收：五个目录均能生成合理索引，通知均处于约定窗口，并随机读取少量公开详情验证正文和附件。真实响应不进入 Git。

## 12. 验收标准

- 一条目录刷新命令能独立更新五个来源，局部失败不会丢失已有索引。
- 通知活动索引只包含最近 7 个北京时间自然日，离窗条目可作为历史元数据保留。
- 稳定目录每个自然月可完成一次完整刷新。
- 本地搜索不访问网络，按需详情读取能正确使用 30 天缓存。
- Agent 接口无法读取目录之外的任意 URL，也无法递归抓取网站。
- 所有详情结果包含可引用的原始 URL 和明确的缓存新鲜度。
- 自动测试和现有完整测试套件全部通过。
