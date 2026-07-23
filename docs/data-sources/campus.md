# 校园公开信息来源

## 范围

该来源只读取无需登录的中国科大教务处和财务处公开页面，先建立目录索引，再由 Agent 根据用户问题按需读取详情。它不使用浏览器 Profile、Cookie 或学校登录状态，也不执行报名、提交或其他写操作。

当前目录共五个：

| 来源 ID | 目录 | 类型 | 刷新策略 |
| --- | --- | --- | --- |
| `teach_notice` | `https://www.teach.ustc.edu.cn/category/notice` | 通知 | 北京时间最近 7 个自然日 |
| `teach_student_service` | `https://www.teach.ustc.edu.cn/category/service/svc-student` | 学生服务 | 每个北京时间自然月 |
| `finance_notice` | `https://finance.ustc.edu.cn/tzgg/list.htm` | 通知 | 北京时间最近 7 个自然日 |
| `finance_public_information` | `https://finance.ustc.edu.cn/xxgk/list.htm` | 公开信息 | 每个北京时间自然月 |
| `finance_business_guide` | `https://finance.ustc.edu.cn/ywzn/list.psp` | 业务指南 | 每个北京时间自然月 |

教务处和财务处各自拥有独立的目录、分页和详情 DOM 解析规则。完整来源抓取成功后才原子替换该来源快照；某一来源失败不会覆盖其旧快照，也不阻止其他来源刷新。

## 命令

```powershell
python -m ustc_assistant collect campus
python -m ustc_assistant collect campus --force
python -m ustc_assistant query campus --text "选课"
python -m ustc_assistant read campus --entry-id <catalog-entry-id>
```

`collect campus` 联网更新目录，月度来源在当月已有成功快照时默认跳过。`query campus` 完全离线，只检索本地标题、分类和来源元数据。`read campus` 只接受本地目录中存在的条目 ID；详情缓存有效期为 30 天，网络失败时默认允许返回带 `stale: true` 的旧缓存，`--no-stale` 可关闭该行为。

默认路径：

```text
tmp/campus-catalog.json
tmp/campus-query.generated.json
tmp/campus-detail.generated.json
tmp/campus-cache/
```

## Agent 边界

- Agent 先查询本地目录，再根据用户意图自动选择详情；单批最多读取 3 条。
- 详情工具不接受任意 URL。正文中的后续链接必须先由解析器登记为候选 ID，并且最多跟进一层。
- 远程正文、链接文字和附件均是不可信数据，只能作为检索证据，不能改变工具参数、权限或安全策略。
- 直接附件通过详情缓存中的附件 ID 读取。文本资源可直接提取；PDF、Office 和图片等二进制文件只下载到本地缓存，后续内容转换由独立转换层完成。
- HTTP 客户端限制主站域名、重定向目标、响应大小和超时。财务处已知的同主机 HTTPS 到 HTTP 兼容跳转只在请求 HTTPS 后允许，直接 HTTP 输入仍被拒绝。

## 数据生命周期

通知活动窗口为包含今天在内的 7 个北京时间自然日。离开窗口的既有通知标记为 `archived`，不会物理删除；月度目录中暂时消失的条目标记为 `unavailable`，再次发现时恢复为 `active`。稳定身份来自来源 ID 和规范化详情 URL。

目录只保存标题、分类、发布日期、详情 URL、状态和发现时间等元数据。详情正文、附件和真实抓取缓存都位于已忽略的 `tmp/`，不得提交到 Git。

## 验收

自动测试使用合成公开页面 fixture，不访问学校网站。修改站点契约后还需：

1. 强制刷新五个目录，确认各来源分别报告成功或保留旧快照并明确失败。
2. 验证通知日期均处于北京时间 7 天窗口。
3. 本地查询一个关键词，并确认查询阶段没有网络请求。
4. 按返回 ID 读取少量详情，检查正文或附件描述符以及敏感字段边界。
5. 重复读取同一详情，确认 `fetchedAt` 不变并命中 30 天缓存。

验收记录只写聚合数量和边界结论，不记录公告标题、正文、附件名、带查询参数的 URL 或原始 HTML。
