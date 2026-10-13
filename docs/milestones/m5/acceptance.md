# M5 批准与验收

## 总方案批准（2026-10-13）

用户在阅读总方案及按功能分类的工具说明后明确回复：

> 总方案批准，请开始实施

据此批准 [唯一任务单](plan.md) 的首版范围、M5.1–M5.6 顺序、单 Agent 有界循环、具体方案批准写、有界规划、用户确认的来源刷新、安全历史/显式偏好及重启拒旧规则。按指定 Sol / max、Luna / max、Astra 按需工作流，从 M5.1 开始实施。

本条是范围与施工批准，不是工程或真人验收。真实 Key 只在应用提供，校方挑战和额外授权由用户处理；既有 M1 后补/来源未观察项和完整 V 项继续保留。M5 尚未验收关闭。

## M5.1 真实模型能力（2026-10-13）

用户在应用主动提供 Key、获取目录、选择模型并执行验核后提交安全摘要：

```json
{"kind":"agent-model-validation-v1","phase":"idle","keySaved":true,"modelSelected":true,"modelCount":12,"capability":"toolReady","checks":{"text":true,"streaming":true,"toolCall":true,"toolResult":true},"failure":null,"requests":5,"conversations":0,"messages":0,"businessToolsEnabled":false}
```

这份实证确认所选学校模型的目录、文本、流式、原生工具调用及工具结果续答，满足 M5.2 的 toolReady 依赖。未取得普通聊天与停止的真人体验确认，也未取得模型具体 ID 或图片能力；不能据此关闭 M5.1 或 M5。工程证据仍见 [M5.1 记录](records/01-model-entry.md)。

## 图片输入范围修订（2026-10-13）

用户在继续实施时明确提出“我建议同时支持图片输入”。据此将用户主动选择、预览并随本轮问题发送的图片纳入 M5.2；不增加任意文件上传、截图自动获取、图片入库或 OCR 工具。原图仅参与当前运行，历史保留附件数量，不保存原图。图片协议与本地限额由根落实；工具能力不代表视觉能力，真实看图另行核验。
