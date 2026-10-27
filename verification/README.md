# 验证与诊断

本目录提供合成、回环与临时数据检查，帮助验证代码行为和协议边界。这些检查不访问真实学校，不读取正式业务资料、浏览器认证资产或秘密，也不替代目标设备或真实服务验证。

| 内容 | 入口 | 用途 |
|---|---|---|
| 模型与业务逻辑合成检查 | [model](model/README.md) | 使用合成输入验证事务、时间、稳定身份、覆盖和取消行为 |
| 回环 HTTPS fixture | [https_fixture](https_fixture/README.md) | 验证合成认证、重定向和 HTTPS 行为，不访问学校 |
| Windows 通知检查 | [notifications](notifications/README.md) | 使用独立测试身份检查通知接口与投递边界 |

检查命令见[开发说明](../docs/development.md)。自动检查通过不代表学校登录、真实数据对应关系、系统通知送达或所有设备组合均已验证；当前平台限制见[已知问题](../docs/releases/known-issues.md)。
