# 校园公开信息：教务处与财务处

状态：2026-10-12，内部 public-query-v1 与首批 knowledge-edition-v1 已装配；正式 Dart HTTP 已有限复验公开栏目、文章和教务关键词，实际随包资料末端核验通过，[M3 已关闭](../../milestones/m3/acceptance.md)，未观察项继续保留。两提供方属于同一逻辑校园来源；通用要求见 [09 K-01/K-03/K-04/K-07](../../architecture/09-contracts.md)，本期范围见 [M3](../../milestones/m3/plan.md)。研究时数量不作为站点常量。

## 通知日期窗口

晨报只查询昨天的固定通知栏目。无关键词的教务通知/财务公告登记为从新到旧的发布时间线，`newestFirst` 是该遍历契约，并非对任意一页做排序就推断全站：C1 排除明确置顶后，仍须验证所有有效行日期完整合法且页内非递增；C2 在本地切片及跨页时传递当前页元数据。缺失/无效日期、乱序、关键词、服务指南等保持 `unknown`。晨报还复核已读页之间的日期顺序，越过目标日前边界后再确认一个后续真实页（缓存切片不算），之后按登记时间线停止；如果后页出现更晚日期，禁用提前停止。此“完整”限于指定日期、栏目和所依赖的来源排序契约，不是全站/全部历史抓取或未读页永不变化的证明；预算截断与网络失败分开报告。

## 教务处

固定提供方为 https://www.teach.ustc.edu.cn。主入口是 [通知新闻](https://www.teach.ustc.edu.cn/category/notice)及 [学生事务](https://www.teach.ustc.edu.cn/category/service/svc-student)。前者有分页和跨页重复置顶，后者是办事主题/FAQ/多个年份指南的集合，不能共用一个新闻时间线解析器。

栏目表单为 GET、字段 s，目标是当前栏目路径。无关键词时，通知按正文列表及真实下一页读取，排除跨页 sticky/post-sticky；学生事务按 main 内流程、FAQ 和指南集合读取，同一页的较多候选由有界游标续读。两个栏目的关键词查询均使用搜索结果列表，学生事务须具有 category-svc-student 归属，允许同时属于通知的条目；搜索分页保持原栏目及 s。合法空态需明确 search-no-results，不把无目标结构当无结果。全站 /search/<词> 会跨栏目，不进入本期通道。

| 种子候选 | 实际入口与内容注意点 |
|---|---|
| 选课/调整/放弃 | [选课一般说明](https://www.teach.ustc.edu.cn/service/svc-student/3543.html)、[调整](https://www.teach.ustc.edu.cn/service/svc-student/12522.html)、[放弃](https://www.teach.ustc.edu.cn/service/svc-student/2648.html)；按首批目录选定范围校核，流程图转为完整描述 |
| 缓考 | [办理流程](https://www.teach.ustc.edu.cn/service/svc-student/2690.html)正文是流程图，不能按空文本接受；包含学生/院系/教务处角色及条件分支 |
| 成绩证明 | [FAQ](https://www.teach.ustc.edu.cn/service/svc-student/13824.html)，公开正文可读，页首发布和页尾日期不同，额外日期须有明确标签才映射更新时间 |
| 国内交流 | [流程](https://www.teach.ustc.edu.cn/service/svc-student/15640.html)，说明年份/更新与实际适用性分别记录 |
| 本科学习指南 | [2026 入口](https://www.teach.ustc.edu.cn/service/svc-student/20496.html)，介绍页与 PDF 是两个关联材料；PDF 62 个物理页、约 29 MB，有多栏/跨页表格 |

[2026 秋选课](https://www.teach.ustc.edu.cn/notice/notice-teaching/20425.html)、[科研项目中期检查](https://www.teach.ustc.edu.cn/notice/notice-teaching/20623.html)等时效通知只在线查阅，明确排除知识库；其中链接的长期制度须独立核验后另列材料，不把整篇通知作为入库候选。

正文定位以对应 article#post-<id> 和内容区为依据，排除站点导航/相关推荐；发布与更新分别从 meta-date、meta-last-modified 取可证标签。在线文章仅接受 /service/svc-student/<编号>.html 与 /notice/<分类>/<编号>.html；主栏目内教师事务/资源等其他路径先排除，解析与请求共用路径登记，不因位置在栏目中放大范围。附件常在同站 /wp-content/uploads/，仅输出主内容关联的已校验链接；图片/PDF 未读取时明确正文覆盖不完整，不自动获取文件。官网引用的外站、成绩公示和个人记录不因域名归属进入知识库。

## 财务处

固定提供方为 https://finance.ustc.edu.cn，入口 [首页](https://finance.ustc.edu.cn/main.htm)。本期在线栏目为 /tzgg/list.htm（通知）、/ywzn/list.psp（业务指南）、/22118/list.psp（流程）、/22119/list.psp（操作）。读取 w6 列表中全部 li.news.clearfix，计数与排除项分开；下一页必须为同栏目实际 page+1，终页 void 占位只有明确当前页＝总页数才接受，不执行 JavaScript。正文定位为 .wp_articlecontent，表格有界展开 rowspan/colspan，保留列/单位/条件关联；发布时间取 arti_update，不推断更新时间。

常见问题 /22120/list.psp 是公开留言标题列表，尚无可用的官方回复读取契约，已试回复入口返回 404；内部 financeFaq 明确 unavailable，不把问题当政策答案。下载 /xzzx/list.psp、官方聊天及留言提交不进入本期在线端口；旧年份回复也不自动成为当前规则。

| 种子候选 | 实际入口与内容注意点 |
|---|---|
| 高频业务 | [官方汇总](https://finance.ustc.edu.cn/2025/1128/c21817a712082/page.psp)，正文为 HTML 表格，保留事项/入口/说明的列关系 |
| 报销指南 | [入口](https://finance.ustc.edu.cn/2024/0606/c21817a643245/page.psp)正文由脚本配置嵌入 PDF，不是四张正文图片或空正文；已定位同站公开 PDF，38 页、约 6 MB，包含文本/图片/空白页 |
| 学生活动经费 | [HTTPS 正文](https://finance.ustc.edu.cn/2021/0128/c22118a470108/page.psp)，本机代理/直连均读取到正文；原 IP 受限观察保留，不能推断所有环境都可达 |
| 费用说明候选 | [行政事业收费](https://finance.ustc.edu.cn/2012/0902/c21820a440895/page.htm)、[服务收费](https://finance.ustc.edu.cn/2012/0902/c21820a440894/page.htm)，URL 年份与显示发布时间不同；现行适用性待核对，不能直接作为当前金额依据 |

[本科 2026–2027 缴费通知](https://finance.ustc.edu.cn/2026/0729/c21813a748969/page.psp)、[研究生 2026–2027 缴费通知](https://finance.ustc.edu.cn/2026/0729/c21813a748968/page.psp)属于时效通知，仅在线查阅，明确排除知识库。长期收费制度/常见问题与当期通知分别识别，不因存在金额表就自动入库。

开发时可由已核对的 PDF viewer 配置关联材料地址，不执行网页脚本。已见 file 指向同站 /_upload/article/files/，只能解析固定配置结构并复验目标/类型，不授予任意文件获取能力。普通 HEAD 曾 403，带公开来源页 Referer 的 GET 可读；HEAD 失败不证明不存在，Referer 只用已核验父文章，不借用 Cookie/令牌。应用本期消费校核 Markdown，不装配该原始文件转换工具。

原生搜索表单为 POST /_web/_search/api/search/new.rst，输入 keyword，带站点公开上下文字段（含 _p）；浏览器实测“缴费”可翻页，最小 HTTP 试探曾 403。固定匿名生产契约未成立，财务在线关键词明确 unavailable，不预设 API、不隐式换浏览器；首版通过栏目条目和精选本地全文检索查阅。搜索未观察范围不以未命中证明内容不存在。

## 请求路由、拒绝与链接

用户确认本机在校园网且使用 7897 代理，授权遇明确校内 IP 提示时用本机直连。C1 只对已注册校园请求使用该路由策略；保持全局环境、TLS、逐跳规则及内容/大小限额。普通 403、超时、结构错误与明确 IP 限制分开；直连仍失败则记录，不升级为认证抓取。匿名 GET 的连接中断最多重试一次，沿用原预算及已选择的直连路线，取消或拒绝响应不重试。

财务已注册列表/文章的 .htm 可能 301 到同路径 HTTP .psp。通道只允许该精确同站/同路径、无查询/片段/用户信息的别名，并在实际请求前改为 HTTPS 后重新验证；不发送 HTTP 请求，不升级任意其他 HTTP 地址。最终提供方、文章/栏目路径和查询意图同样复验。一般 403、认证重定向和路径改变仍拒绝。

/39151/list.htm 的财务公开目录引向统一认证，仍跳过。用户的 IP 路由授权不扩大到账号登录、个人账单/报销资料或业务提交。外部原文/附件链接只在用户明确点击时受控委派，不自动抓取其所有关联页面。

## 文本目录与证据范围

首批清单为 campus-longterm-2026-10-12-v1，7 项选定长期资料，具体出处/版本/完整选定范围见 [目录](../../../knowledge/catalog-v1.json)与 [任务单](../../milestones/m3/plan.md)。62 页本科学习指南和 38 页财务指南不在首批，通知/年度窗口不入库；校核稿编译为受限 Markdown，原件不打包。C3 保存已接受文本、片段和必要元数据，载入/清库与在线查询分开，中文检索不生成政策答案。

合成/loopback/临时 Windows 检查与根手工公开请求分别记录；当前公开成功样例只证明所测路径，不证明全部页面或政策现行。明确校内 IP 限制后的直连逻辑有回环反例，本轮真实收费页可读但没有再次触发该提示，不能补记真实自动回退通过。根在独立临时原生库已验实际随包 7 项载入、中文检索/全文读取、重放、重开、清库/重载及真清理；不读正式数据，也不记作用户操作通过。具体实验和失败见 [研究记录](../../milestones/m3/records/02-public-materials.md)、[实现记录](../../milestones/m3/records/04-internal-implementation.md)及 [实际资料核验](../../milestones/m3/records/05-evidence-based-verification.md)。
