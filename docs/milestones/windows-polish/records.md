# Windows 收尾：研究与实施

日期：2026-10-15。当前范围与验收只在[任务单](plan.md)维护；用户已确认[M6关闭](../m6/acceptance.md#阶段关闭2026-10-15)。本页记录研究依据、实施和实际验核，不替代真人判断。

## 研究先行

| 一手来源 | 采用的方法与本项目适配 |
|---|---|
| [Windows内容布局与间距](https://learn.microsoft.com/en-us/windows/apps/design/basics/content-basics) | 字号/字重区分层级，按8/12/16间距分组；晨报先摘要与重点，详情按需展开；不整页铺技术状态 |
| [Fluent 2内容设计](https://fluent2.microsoft.design/content-design) | 先满足当前意图、简单句、自然一对一交流；日程讨论只给必要事实，不把档案字段和整份可选操作菜单都倒给用户 |
| [Flutter悬浮标签](https://api.flutter.dev/flutter/material/InputDecoration/floatingLabelBehavior.html) | 当前填值使标签浮到控件顶部；标题紧贴控件导致视觉碰撞。共享提醒局部改成独立标签并保留控件语义与键盘操作，避免改全局主题 |
| [OpenAI官方Prompting](https://developers.openai.com/api/docs/guides/prompting) | 用代码管理/版本化提示词，角色和输出语气显式配置，发布时复验代表场景。仅借鉴提示词方法，学校模型接口/供应商和Key配置不变 |
| [OpenAI 5.1人格示例（历史方法参考）](https://developers.openai.com/cookbook/examples/gpt-5/gpt-5-1_prompting_guide) | 根据对话调整温度和篇幅，减少机械致谢/旁白；不采用该归档页中的模型/迁移或时效性API结论 |

中文Humanizer以嵌入模式审校文案：保留事实和未知，删掉套话、夸张安慰、菜单式收尾及空泛结论。热心学长指交流风格，不虚构真人身份或个人校园经历。研究只访问公开设计/开发文档，不访问学校、模型或正式业务。

## 实施与检查

待本轮工程与根检查结果写入；未声称提示词已在真实模型上改善。原M6语音/非空考试、Windows跨重启/睡眠等保留项不由本切改写。
