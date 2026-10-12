# 校园公开信息：教务处与财务处

状态：2026-10-11 公开研究参考；尚未形成产品受控 HTTP/提取验收。两提供方属于同一逻辑校园来源；通用要求见 [09 K-01/K-03/K-04/K-07](../../architecture/09-contracts.md)，本期范围见 [M3](../../milestones/m3/plan.md)。下列数量是调研时观察，不是站点常量。

## 教务处

固定提供方为 https://www.teach.ustc.edu.cn。主入口是 [通知新闻](https://www.teach.ustc.edu.cn/category/notice)及 [学生事务](https://www.teach.ustc.edu.cn/category/service/svc-student)。前者有分页和跨页重复置顶，后者是办事主题/FAQ/多个年份指南的集合，不能共用一个新闻时间线解析器。

栏目表单为 GET、字段 s，目标是当前栏目路径。手动 HTTP 已读取通知栏目的“缓考”和学生事务栏目的“成绩单”查询；通知检索仍含置顶项，须识别其与关键词匹配项的区别。全站 /search/<词> 会跨栏目，不能作为限定两栏目的完整查询证据。生产分页、终页、空态与置顶处理仍待验证。

| 种子候选 | 实际入口与内容注意点 |
|---|---|
| 选课/调整/放弃 | [选课](https://www.teach.ustc.edu.cn/service/svc-student/1440.html)、[调整](https://www.teach.ustc.edu.cn/service/svc-student/12522.html)、[放弃](https://www.teach.ustc.edu.cn/service/svc-student/2648.html)；提取前逐份核对正文与图片 |
| 缓考 | [办理流程](https://www.teach.ustc.edu.cn/service/svc-student/2690.html)正文是流程图，不能按空文本接受；包含学生/院系/教务处角色及条件分支 |
| 成绩证明 | [FAQ](https://www.teach.ustc.edu.cn/service/svc-student/13824.html)，公开正文可读，页首发布和页尾日期不同，额外日期须有明确标签才映射更新时间 |
| 国内交流 | [流程](https://www.teach.ustc.edu.cn/service/svc-student/15640.html)，说明年份/更新与实际适用性分别记录 |
| 本科学习指南 | [2026 入口](https://www.teach.ustc.edu.cn/service/svc-student/20496.html)，介绍页与 PDF 是两个关联材料；PDF 62 个物理页、约 29 MB，有多栏/跨页表格 |

[2026 秋选课](https://www.teach.ustc.edu.cn/notice/notice-teaching/20425.html)、[科研项目中期检查](https://www.teach.ustc.edu.cn/notice/notice-teaching/20623.html)等时效通知只在线查阅，明确排除知识库；其中链接的长期制度须独立核验后另列材料，不把整篇通知作为入库候选。

正文定位以对应 article#post-<id> 和内容区为候选，排除站点导航/相关推荐。附件常在同站 /wp-content/uploads/；只接受选定文章主内容中关联的已校验材料，不允许任意该前缀 URL 读取。官网引用的外站、成绩公示和个人记录不因域名归属进入知识库。

## 财务处

固定提供方为 https://finance.ustc.edu.cn，入口 [首页](https://finance.ustc.edu.cn/main.htm)。已观察栏目：/tzgg/list.htm（通知）、/ywzn/list.psp（业务指南）、/22118/list.psp（流程）、/22119/list.psp（操作）、/xzzx/list.psp（下载入口）、/22120/list.psp（常见问题）。栏目各自有列表/分页和分类关联；正文用 .wp_articlecontent 定位。

首页问题与官方回复成对显示；只有问句的列表不能作为政策答案，旧年份回复不自动成为当前规则。网站含官方聊天嵌入，本期不调用。

| 种子候选 | 实际入口与内容注意点 |
|---|---|
| 高频业务 | [官方汇总](https://finance.ustc.edu.cn/2025/1128/c21817a712082/page.psp)，正文为 HTML 表格，保留事项/入口/说明的列关系 |
| 报销指南 | [入口](https://finance.ustc.edu.cn/2024/0606/c21817a643245/page.psp)正文由脚本配置嵌入 PDF，不是四张正文图片或空正文；已定位同站公开 PDF，38 页、约 6 MB，包含文本/图片/空白页 |
| 学生活动经费 | [HTTPS 正文](https://finance.ustc.edu.cn/2021/0128/c22118a470108/page.psp)，本机代理/直连均读取到正文；原 IP 受限观察保留，不能推断所有环境都可达 |
| 费用说明候选 | [行政事业收费](https://finance.ustc.edu.cn/2012/0902/c21820a440895/page.htm)、[服务收费](https://finance.ustc.edu.cn/2012/0902/c21820a440894/page.htm)，URL 年份与显示发布时间不同；现行适用性待核对，不能直接作为当前金额依据 |

[本科 2026–2027 缴费通知](https://finance.ustc.edu.cn/2026/0729/c21813a748969/page.psp)、[研究生 2026–2027 缴费通知](https://finance.ustc.edu.cn/2026/0729/c21813a748968/page.psp)属于时效通知，仅在线查阅，明确排除知识库。长期收费制度/常见问题与当期通知分别识别，不因存在金额表就自动入库。

开发时可由已核对的 PDF viewer 配置关联材料地址，不执行网页脚本。已见 file 指向同站 /_upload/article/files/，只能解析固定配置结构并复验目标/类型，不授予任意文件获取能力。普通 HEAD 曾 403，带公开来源页 Referer 的 GET 可读；HEAD 失败不证明不存在，Referer 只用已核验父文章，不借用 Cookie/令牌。应用本期消费校核 Markdown，不装配该原始文件转换工具。

原生搜索表单为 POST /_web/_search/api/search/new.rst，输入 keyword，带站点公开上下文字段（含 _p）；浏览器实测“缴费”结果可翻页，直接 HTTP 最小试探曾 403。产品实际表单上下文、请求和分页契约尚未证明，不能预设搜索 API 或隐式切到浏览器实现。搜索结果对历史/最新文章的覆盖尚未确认，不以未命中证明内容不存在。

## 请求路由、拒绝与链接

用户确认本机在校园网且使用 7897 代理，授权遇明确校内 IP 提示时用本机直连。C1 只对已注册校园请求使用该路由策略；保持全局环境、TLS、逐跳规则及内容/大小限额。普通 403、超时、结构错误与明确 IP 限制分开；直连仍失败则记录，不升级为认证抓取。

真实研究中 /2021/0128/c22118a470108/page.htm 返回 301，Location 为同站 **HTTP** 的 .psp；主代理未跟随 HTTP，另核对实际 HTTPS .psp 正文可用。若采用别名规则，只限定已实证的财务路径转换，目标重新验证；不能从这一例推出所有 HTTP 链接均可升级或绕开重定向守卫。

/39151/list.htm 的财务公开目录引向统一认证，仍跳过。用户的 IP 路由授权不扩大到账号登录、个人账单/报销资料或业务提交。外部原文/附件链接只在用户明确点击时受控委派，不自动抓取其所有关联页面。

## 待完成的生产契约

产品客户端的证书/代理/直连、重定向与内容类型；列表分页/终页/归属；长期目录及校核 Markdown 的稳定键/完整性；中文索引、渲染预算和版本/维护仍待 M3.1。浏览器可达、MinerU/Windows OCR 实验与两个材料样稿不构成产品通道验收；制作时校核与应用验收分别记录。具体实验、失败和未观察状态见 [研究记录](../../milestones/m3/records/02-public-materials.md)。
