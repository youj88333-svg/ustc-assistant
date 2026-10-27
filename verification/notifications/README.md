# Windows 原生通知测试

本目录是独立 Windows C++20 通知合成检查，不依赖 Flutter 或正式数据。构建输出位于已忽略的 `build/`；测试使用隔离身份，不登记产品通知。构建与运行方式见下文。

`activation_probe` 只验证严格协议、内存队列、COPYDATA 及本进程隔离窗口；不创建 OS 注册、不测多进程转交。`notification_probe` 需要调用方生成独立 32 位十六进制身份和 GUID，只管理 `USTC.Assistant.M6Probe.<identity>`、同名快捷方式及 `ustc-m6-probe-<identity>`；不得使用产品身份。动作包括 `protocol-initialize`、`protocol-schedule <秒数>`、`protocol-pending`、`protocol-replace <秒数>`、`protocol-cancel`、`protocol-history`、`protocol-activate`、`protocol-parser` 和 `protocol-cleanup`。

通知探针会修改自己的 HKCU 和快捷方式，检查结束须执行对应 identity/GUID 的 cleanup 并核对资产不存在。队列消失不等于用户看到；History 与 Shell 冷启动分别取证，真实 Toast 点击、重启和睡眠另行验收。保留有界 COM 诊断动作是为了可复现原失败，不作为产品激活路径。
