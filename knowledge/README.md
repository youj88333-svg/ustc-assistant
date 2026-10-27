# 知识材料制作目录

本目录包含随应用提供的精选校园公开资料。当前材料清单见[catalog-v1.json](catalog-v1.json)；应用载入受控文本供 Agent 查询，不提供独立的知识库浏览入口。通用隐私、来源与材料维护契约见[09 K-07](../docs/architecture/09-contracts.md#k-07-公开文本材料与知识库)。

| 文稿 | 校核范围 | 入库状态 |
|---|---|---|
| [选课规则](curated/teach/course-selection.md)、[调整](curated/teach/course-adjustment.md)、[放弃修读](curated/teach/course-withdrawal.md)、[缓考](curated/teach/deferred-exam.md)、[证明 FAQ](curated/teach/certificates.md) | 公开 HTML 和相关图示中的选定范围；覆盖与排除范围见目录 | 5 项教务资料；现行适用性未知，校核不替代应用验收 |
| [财务索引](curated/finance/business-index.md)、[学生活动经费](curated/finance/student-activities.md) | 公开业务名称、指南入口，以及经费页中的范围、材料、例外和条件；金额保留来源版本 | 2 项财务资料；不包含关联制度全文或个人财务记录 |
| [本科学习指南单页](samples/teach-handbook-p10.md) | 物理第 10 页/印刷页 05–06 的文字和图示 | 样稿，仅覆盖该页；不是全书入库版本 |

`curated` 保存已校核的长期资料文稿；`samples` 保存不进入正式材料包的节选。清单绑定来源、文稿摘要、版本、选定范围与校核状态；只有列入清单的材料范围成为应用只读输入，当前文本和索引由 C3 管理。`tools/prepare-knowledge-assets.ps1` 从校核稿生成 `app/assets/knowledge`；`-Check` 只校验生成物。该脚本不联网、不运行 OCR；查询与启动不会自动载入或恢复已清除的资料。

当期缴费通知、选课通知、窗口/截止日公告、活动和新闻不放入知识材料清单；它们只供在线查阅。材料适用性可能变化，Agent 不替代学校正式政策说明。
