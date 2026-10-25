# 真人缺陷修订：安排意图与中文回复

实施日期：2026-10-13。依据 [M5 任务单 §18](../plan.md)、[07–12](../../../architecture/07-constitution.md)、[13](../../../quality/13-risks-and-acceptance.md)和 [工作流](../../../workflow.md)。用户真人体验发现问题，M5 仍未关闭；本修复在已批准的本地提案/当前卡批准范围内，不新增权限。用户截图只用脱敏的自然语句描述，不保存实际课表、原始页面或账号。

## 实际原因

用户问句的关键顺序是“下周二交作业，请帮我下周一安排一个小时”。系统提示当时已包含提案/当前卡批准，但 C4 只匹配“安排…作业”的单向模式，实际只给了该回合查询工具，没有 propose_local_changes/find_free_slots。模型说“本轮没有创建接口”由漏选工具造成，不是 C3 没有创建能力。此前脚本场景使用明确“创建任务”等说法，没有覆盖这个真实词序；早期工程通过与本轮缺陷分别保留。

英文来自未明确回复语言，并且 C4 把多个 tool_calls 回合中的过渡文字拼进最终正文/历史；普通中文最终回答前出现一串 I will/Let me 旁白。过长的 coverage/未知/免责声明重复也违背用户期望。未知引用继续由界面标记，不能为清爽而伪造出处或抹掉真实限制。

## 修复与边界

Sol / max 持有 `agent_request_intent`、C4 路由/正文生命周期、动态系统提示与工具描述。动作和规划识别不依赖任务词在动词前还是后；补新建、写入等常见说法。相邻短澄清可继承一个前人类问题的本地意图，新普通/公开问题不继承；显式只建议、不保存、只公开优先排除提案。选择工具不产生写许可，当前卡与 C3 的原子/停止/世代守卫不变。

`agent_system_prompt` 按真实清单生成，固定版本 ustc-student-agent-v2（安全摘要新增 promptVersion）。明确新个人安排/任务不用已有引用，修改旧项才查询本轮引用；学校网站只读与本地创建分开。普通旧回复中的能力自述不覆盖本轮清单。Key、图像、来源出站和历史守卫不变，无 schema 升级。

按 humanizer-zh 参考的表达原则，默认简体中文，用户明确要求时切换语言；直接给方案/结果及必要理由，减少开场、过程旁白、重复整份课表和免责声明清单。事实、给定截止/时长、未知和失败不删除；没给的具体截止时刻不猜。空冲突检查没有证据 ID 时不造引用。没有额外“润色”模型调用或费用承诺。

确认完整 native tool_calls 回合后，C4 撤下该回合过渡文字并更新持久 assistant 正文；下一次网关请求仍携带完整 assistant call/tool result 配对。最终普通回复继续流式；停止/断流发生在未完整回合时保留已接收的安全片段。步骤、失败和实际提交卡仍保留，不能因正文简洁隐藏批准或提交事实。

## 根验证

Luna / max 只新增独立 `agent_request_behavior_test`，未运行 SDK；根完成分析和执行，使用真实 AgentActionTools/C3、内存库、合成保护与脚本网关，PublicQueryCoordinator 会话工厂明确拒绝所有网络，不检查正式数据或 Key。

- 根既有 C4/动作/批准/停止 59 项通过。
- 根新增 6 组通过：双词序和新建/写入出站能力；澄清/新话题/只建议边界；普通聊天无业务工具及旧英文能力自述；create_personal 无旧引用等待当前卡、拒绝零写/过期卡无效/当前批准只一条；超过 512 字符英文旁白已 checkpoint 后完整工具回合撤下、协议配对和最终历史正确；普通停止保留片段。
- 初次分析要求补一处括号，独立新回归移除两个未用导入；实际修正后无问题。未用真实模型回应来替代自动证据，风格和原句体验还需用户核对。

最终检查均由根执行，日志在忽略的 app/build/；先前 [M5.5/M5.6 检查](05-continuity-and-delivery.md)保留原时点证据，不改写为本次结果。

| 检查 | 实际结果 |
|---|---|
| `flutter analyze --no-pub` | 无问题，exit 0；m5-intent-analyze-final.log |
| `flutter test --no-pub --reporter expanded` | 975 通过、1 非 Windows 保护不可用分支在 Windows 跳过，exit 0，34 秒；m5-intent-unit-final.log |
| Windows Agent | 五组通过，exit 0，30 秒；m5-intent-windows-final.log；含当前卡批准/整组撤销、普通停止、知识/图片、维护和失败退出 |
| 默认 Release | `flutter build windows --release --no-pub --target=lib/main.dart` exit 0，34.8 秒；m5-intent-release-final.log |
| 文档/diff | tools/check-docs.ps1 与 git diff --check 通过，本地链接及冻结档案检查 |

工程本地提交 ec61194，文档另行提交，不推送。正式入口仍为 app/build/windows/x64/runner/Release/ustc_assistant_m0.exe；构建前确认该 Release 未运行，不强关应用。修订版正常窗口启动，只验证精确本轮 PID、USTC Assistant 标题和非零句柄，不用窗口元数据替代语义/风格真人验收。用户可以直接重试原问句，不要求清历史、重新配置 Key 或删除日程；历史原回复保留原样。
