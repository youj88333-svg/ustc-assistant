# M6.0 Windows 计划通知与激活

日期：2026-10-15。依据[已批准任务单](../plan.md)、[09 K-09](../../../architecture/09-contracts.md#k-09-晨报与本地提醒)及工作流。全部使用独立临时身份、合成内容和本应用原生源码，不读取正式业务、认证资料、真实学校或模型。

## 平台结果与方案

现有普通 EXE 可以使用 WinRT `ScheduledToastNotification`，不必改 MSIX、安装服务或维持托盘。使用固定 AUMID、当前用户快捷方式、占位 CLSID 和私有协议激活；正式协议为 `ustc-assistant-rewrite`。原生只校验/排队 opaque 引用，C3 最后决定当前目标，不能绕过业务世代或取得写权限。

最初全新身份直接 AddToSchedule 返回成功、跨进程队列存在，时间到后消失，但 History 为 0、Setting 返回 80070490，不能判投递成立。根据微软 Toolkit 的首次调度兼容实现，显式启用后的 initialize 内建立静默临时身份并立即清历史，再读取真实 Setting；不把未知 Setting 伪报可用。迁移和未启用启动不做注册。

COM 热服务器接口/回调正常；冷 CoGetClassObject 返回 80040154，多种有界客户端和注册视图诊断未确定代码根因。不修改全局 COM/系统安全/通知设置，也不推断必须 MSIX。改用微软支持的普通 EXE 私有协议激活，独立 URI 经 Shell 能在原进程退出后启动新进程并收到严格校验引用。这个结果不冒充实际 Toast 点击。

参考：[Windows 调度通知](https://learn.microsoft.com/en-us/windows/apps/develop/notifications/app-notifications/app-notifications-scheduled)、[Toolkit 首次身份建立](https://raw.githubusercontent.com/CommunityToolkit/WindowsCommunityToolkit/main/Microsoft.Toolkit.Uwp.Notifications/Toasts/Compat/ToastNotificationManagerCompat.cs)、[桌面通知激活选项](https://learn.microsoft.com/en-us/windows/apps/design/shell/tiles-and-notifications/toast-desktop-apps)、[通知 schema](https://learn.microsoft.com/en-us/uwp/schemas/tiles/toastschema/element-toast)。

## 根实际检查

| 检查 | 实际结果 |
|---|---|
| MSVC / C++/WinRT 兼容 | C++17 在当前 MSVC14.51/SDK10.0.26100 的协程头失败，通知静态库独立 C++20、EHsc；不更改 Flutter runner 的 STL 异常设置。受限宿主曾有 PATH/Path 重复构建错误，合规本机构建通过，不修改全局环境 |
| 独立 native CMake Release | 两个 probe 构建通过；Flutter Debug 原生桥构建通过。曾遇 Windows `small` 宏冲突，局部变量改名后通过 |
| `activation_probe.exe` | 147 项通过：严格 URI、长度/转义/空白、32 条队列/去重、COPYDATA、隔离窗口生命周期；固定生产注册存在状态与修改时间未变化。明确不含多进程转交 |
| 全新协议身份 initialize → schedule12秒 | Setting=Enabled，完整七字段读回一致，count1；调度进程退出后另进程读 count0、History1 |
| 取消已展示合成提醒 | cancel 成功；History 从1降0，队列0 |
| 私有协议 Shell 冷启动 | Shell 接受、子进程退出0、校验后的接收标记存在；未点击真实横幅 |
| 替换/重复对账 | 前一轮独立身份两次替换后仍只有1条，时间/摘要/token 一致；取消后0 |
| 所有权冲突 | 前一轮独立身份验证 Register 遇其他 owner 返回 access denied、原值保留；删除时 owner 变化也拒绝，恢复本身份后可清理 |
| 测试资产清理 | 原始A/B和最终身份 cleanup 均成功；根逐项核对3组协议/AUMID/CLSID/快捷方式不存在。中间C/D/E身份的清理也已核对；生成证据只留忽略的build，不进Git |

完整方法通道还由 Dart 合成 messenger 与 Windows Debug 隔离宿主验证，结果随[工程记录](02-integration.md)更新。正常关闭保留未来通知；维护只删除本应用计划及历史，读回完成后才允许清映射。Debug 合成宿主不登记生产身份，Release 忽略其环境旗标。

## 未观察项

用户实际看到横幅、实际点击进入当前任务/日程、Windows 重启/重新登录、睡眠/唤醒及勿扰显示未由上述探针证明，留在统一真人验收。Windows 的投递窗口和用户系统设置仍可能造成未显示；没有关机提醒或唤醒保证。M6 未关闭。
