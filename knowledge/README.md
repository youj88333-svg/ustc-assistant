# 知识材料制作目录

这是 M3 开发时的公开资料 Markdown 工作区，材料为未来 Agent 的内部检索能力准备。用户已批准恢复，首批目录在 [catalog-v1.json](catalog-v1.json)，应用消费受控文本版本，无独立用户浏览入口，本期不注册工具。范围、格式及版本/维护契约以 [M3 任务单](../docs/milestones/m3/plan.md)和 [09 K-07](../docs/architecture/09-contracts.md#k-07-公开文本材料与知识库)为准，不在这里维护第二份架构设计。

| 文稿 | 制作与校核范围 | 入库状态 |
|---|---|---|
| [选课规则](curated/teach/course-selection.md)、[调整](curated/teach/course-adjustment.md)、[放弃修读](curated/teach/course-withdrawal.md)、[缓考](curated/teach/deferred-exam.md)、[证明 FAQ](curated/teach/certificates.md) | 公开 HTML 或完整图示的选定范围，经 Luna / max 整理、Sol 核对；具体覆盖/排除在目录登记 | 首批教务 5 项；现行适用性未知，制作校核不替代应用验收 |
| [财务索引](curated/finance/business-index.md)、[学生活动经费](curated/finance/student-activities.md) | 20 项业务名称/直接指南入口，及公开经费页的范围、材料、例外和条件；金额保留来源版本 | 首批财务 2 项；不包含关联制度全文或个人财务记录 |
| [本科学习指南单页](samples/teach-handbook-p10.md) | MinerU 单页转换后由 Luna 补全，Sol 对照物理第 10 页/印刷 05–06 核对 | 样稿，仅该物理页；不能作为全书入库版本 |

curated 保存长期资料的校核文稿；samples 保存部分页/方法试验，不能自动进入正式材料包。正式清单绑定稳定来源、原材料/Markdown 摘要、制作版本、选定范围与校核状态；只有列入清单的已核对范围成为应用只读输入，导入后 C3 管理当前文本和索引。运行 `tools/prepare-knowledge-assets.ps1` 从校核稿选取语义小节生成 app/assets/knowledge 及固定身份；`-Check` 只校验生成物。该开发脚本不联网、不运行 OCR，不进入安装包；查询与启动不会自动载入或恢复清掉的资料。

当期缴费通知、选课通知、窗口/截止日公告、活动和新闻不放入入库清单；无论是否已经转换，都只供在线查阅。这里不保留原 PDF/图片、MinerU 原始输出/缓存、临时文件、Token 或转换工具。制作与失败的实证见 [M3 研究记录](../docs/milestones/m3/records/02-public-materials.md)。
