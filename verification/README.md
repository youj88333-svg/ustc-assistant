# 前置验证与诊断

本目录保留设计前置实验、合成测试和脱敏证据，属于可行性/诊断资料，不替代产品验收。产品 M0/M1/M2 已正式关闭；当前状态见 [状态页](../docs/status.md)，实际阶段结果见 [阶段索引](../docs/milestones/README.md)。

| 内容 | 入口 | 用途 |
|---|---|---|
| 关键模型实验 | [model](model/README.md) | 新合成事务、时间、稳定身份、覆盖与取消反例 |
| Windows 原生前置实验/手动跳转工具 | [windows](windows/README.md) | SDK、隔离、生命周期、DPAPI 与登录链路线索；保留原严格候选失败 |
| 回环 HTTPS fixture | [https_fixture](https_fixture/README.md) | 合成认证/重定向测试，不访问学校 |
| 来源验证入口 | [sources](sources.md) | 当前来源契约与对应真实证据导航 |

## 边界与记录

自动实验只访问合成/loopback/独立临时资产，不读取正式业务、浏览器会话或秘密。真人观测由用户完成登录/学校授权，记录固定结构和计数，不保存原始响应、HAR、Cookie/Token 或认证内容。手动 Edge 只提供链路线索，产品身份/许可与自动认证须分别验收。

首版边界按 [DR-ADR-09](../docs/decisions/dr-adr-09-browser-boundary.md)：严格 CAL/完整网络隔离及补丁资格退出首版门槛，旧失败留档；不用已有实验通过推定未执行平台或学校结果。实验不直接复制为产品代码或 fixtures。

各实验目录的原记录保留发生时范围。整理前汇总和旧源码路径完整保存在 [档案](../docs/archive/README.md)；新的产品过程进入对应阶段记录，不再追加到本入口。
