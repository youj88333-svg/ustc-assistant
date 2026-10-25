# Flutter跨端界面Skill候选调研

调研日期：2026-10-18。由Luna/max独立查阅公开仓库、实际SKILL.md和参考资料，Sol复核主要候选的仓库、技能正文、Flutter规则及许可。仅选型，不安装或执行候选脚本，不启动用户延期的整体UI重构；现有修复仍按[Android任务单](../milestones/android-apk/plan.md)推进。

## 选择指标

按本工程适配、可执行的详细程度、维护/采用证据、采用成本和许可比较。Stars只是辅助：综合skill仓库的星数不能当成某项skill的独立采用数，也不能证明能改善本项目界面。优先Flutter/Dart、Windows与Android窗口、中文排版、键盘/安全区/触摸与大字；网页生成器不能直接迁移为Flutter代码。

## 候选对比

以下Stars为查询日GitHub显示的约数，会变化。未运行实作评测，适配判断是基于实际资料的工程推断。

| 候选 | 采用与维护证据 | 内容深度及项目适配 | 限制/建议 |
|---|---|---|---|
| [UI UX Pro Max](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill) | 约136.9k Stars，整个仓库；MIT；有版本发布与持续提交 | 以一个主skill为中心，含设计系统、排版/颜色/交互、规则参考、本地CSV搜索及[Flutter专用规则](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill/blob/main/src/ui-ux-pro-max/data/stacks/flutter.csv)。实际规则表52项，列明Flutter 3.44.x，与本工程3.44.5接近 | 首选设计方法。仍混合网页/CSS/在线字体与营销页面语境，需明确校园助手/工具型应用、中文和Flutter栈；不接受默认生成的大卡片/柔和阴影组合 |
| [Flutter官方Agent Plugins](https://github.com/flutter/agent-plugins)中的[responsive layout](https://github.com/flutter/agent-plugins/blob/main/skills/flutter-build-responsive-layout/SKILL.md) | 约3.1k Stars，整个多skill插件仓库；Flutter团队维护；BSD-3-Clause | 明确LayoutBuilder/MediaQuery和窗口约束、触摸/指针输入、断点及横竖屏验证，直接对应Windows与Android | 推荐技术补充。正文短、无完整审美系统；只取适配skill，不引入整个插件或改变本项目架构/测试工作流 |
| [Anthropic frontend-design](https://github.com/anthropics/skills/tree/main/skills/frontend-design) | skills总仓库约181.8k Stars，不是该skill单独星数；该项[许可](https://github.com/anthropics/skills/blob/main/skills/frontend-design/LICENSE.txt)为Apache-2.0 | [实际正文](https://github.com/anthropics/skills/blob/main/skills/frontend-design/SKILL.md)短而集中，强调基于产品的视觉方向、排版、信息层级、自我批评，直接指出同质化卡片等常见问题 | 可作审美参考。主要网页语境，无Flutter/Dart或完整移动实现规则；单靠它不足以完成本工程跨端落地 |
| [TheSimpleApp Flutter App Skills](https://github.com/TheSimpleApp/flutter-app-skills) | 0 Stars、仅少量提交；MIT；采用和长期维护证据不足 | 实际[flutter-native-ui](https://github.com/TheSimpleApp/flutter-app-skills/blob/main/skills/flutter-native-ui/SKILL.md)及相邻资料涵盖主题、安全区、键盘、导航、设计系统、可访问性 | 内容贴近产品UI，但规则面向较新Flutter/Dart版本，不能据此升级本工程。先保留参考，不作主选 |

## 推荐及后续使用边界

推荐 **UI UX Pro Max负责视觉与交互原则，Flutter官方响应式skill补充实现约束**，不必再叠加第三个必需skill。选它不是因为Stars最高：其Flutter规则比通用frontend-design完整，又有比新建Flutter技能仓库更充分的采用证据。官方适配资料负责把视觉要求落到约束/断点/输入方式，不能反过来把整周日历当成桌面网页缩放。

如果用户后续决定采用，先针对实际页面给出简洁的设计方向和令牌，再实施。优先解决现在提出的问题：减少相同软卡片的重复包裹，以文字层级、分隔和留白组织信息；Agent正文优先，过程按需展开；日历优先画布和教室信息，手机7列采用紧凑表示与可达详情。颜色保留来源/同名日程和冲突、到期警示等业务含义，不能只为统一外观抹平。

此时仍须遵循07–12和项目工作流，保留Agent/日程两主页、任务归日程、设置为辅助、现有端口与控制器、许可/凭据/业务保留。外部skill的安装器、`--persist`、联网字体/素材、框架升级和第三方依赖不自动获准；本地搜索可按需只读使用，但必须先按实际安装版本重新阅读指令。候选的脚本与技能提示不是本项目当前施工指令，也没有在本切执行。

未来验核以320/360/412dp、横竖屏、1.0/1.5/2.0文字、键盘、安全区、48dp常规触摸、桌面窗口和真实截图/命中为准。技能文案、Stars和“看上去更美”不能替代这些行为检查。当前未安装、未做候选A/B页面样稿，最终效果仍未知。
