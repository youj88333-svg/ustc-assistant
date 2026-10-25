# 维护与仓库操作

工程默认打开`E:\107\main`，主线为`main`。`E:\107`是总目录，唯一共用Git元数据在`main\.git`；兄弟worktree中的`.git`只是指针。迁移授权、原状态、备份和实际同步结果见[任务单](milestones/maintenance-handoff/plan.md)、[记录](milestones/maintenance-handoff/records.md)和[验收](milestones/maintenance-handoff/acceptance.md)。

| 目录 | 用途 |
|---|---|
| `E:\107\main` | 当前源码、文档、测试及可重建的本地构建输出 |
| `E:\107\worktrees` | 按需登记的短期修复或迁移交接工作树 |
| `E:\107\archive` | 旧参赛与放弃版工作区、原未提交/未跟踪/忽略成果；不作为新业务权威 |
| `E:\107\releases\windows` | 当前和历史Windows完整便携目录、ZIP及哈希 |
| `E:\107\releases\android` | 当前私有QA双ABI APK、manifest、许可与哈希 |
| `E:\107\backups` | 迁移元数据备份、bundle及移动/恢复记录；不能当业务备份公开分享 |
| `E:\107\private` | 用户本机发布签名等受保护资料；不入Git/安装包，不作为缓存清理或扫描内容 |

归档引用保留旧历史，主线文件采用已验收的重写版本。归档工作区里的本地改动不自动提交或推送；移动路径不等于允许读取业务数据库或认证资产。实际应用资料、Windows DPAPI和Android Keystore与源码目录迁移分开，迁移不启动应用。

## 修复一个问题

先记录版本/构建修订、设备、操作与现象，优先使用应用主动导出的安全日志。不要要求账号密码、模型Key、学校原始响应或业务库。按[15工作流](workflow.md)确定修改边界，从main建立`codex/fix-<问题>`，复现后修复并运行相关检查；产品跨层变化再按影响补完整检查。纯文档或仓库布局不重复Flutter全量。

临时worktree通过Git登记、移动和移除；移除前确认未提交、未跟踪、忽略的重要文件及交付均已保留。不要删除`.git`指针或直接清理其他工作树。SDK、Pub/Gradle和AVD沿既有E盘环境，生成缓存与私有包不入Git。

## 集成与两个远端

在主工程确认工作区状态和相关检查后集成修复，使用普通向前推进。GitHub `origin`和校内`ustc`都跟随当前维护main，不单独冻结校内参赛版。同步步骤为：

```powershell
git fetch --no-tags origin
git fetch --no-tags ustc
git push origin main:main
git push ustc main:main
git ls-remote --heads origin main
git ls-remote --heads ustc main
```

应核对两个远端main均等于本地main。推送被拒绝时先核对新提交与权限，不使用force、mirror或all覆盖；不要把archive分支、恢复备份或所有本地标签一并推送。仅明确选定的交付源码标签单独同步；安装包继续私有，不上传源代码托管的Release附件。

认证由本机Git的既有凭据或用户主动配置完成，不把密码/Token/私钥交给Agent。SSH主机指纹须与官方HTTPS公布值核对；可使用任务/仓库专用known_hosts，保留严格校验，不改系统信任或全局代理。校内认证缺失与同步成功分开记录，不能只凭本地remote-tracking引用宣称远端已更新。

本机经核验后可在仓库级`core.sshCommand`固定SSH客户端和现有身份文件，服务器公钥放在本地忽略的`.local/git/known_hosts`。这只是本机连接配置；私钥仍由原位置的SSH客户端使用，不复制进工程、备份包或远端。换设备需自行重新配置认证，源码不携带这些机器路径或秘密。

## 私有交付与恢复

安装/升级说明见[Windows](releases/windows-1.00.md)和[Android / APK鸿蒙](releases/android-private-1.00.md)。构建器仍在本工程`app/build/private-releases`生成并核验新包，再将核验后的完整目录移入总目录releases；已经交付的APK/ZIP按哈希冻结，不因源代码文档更新而重写。

源码迁移备份只用于Git/工作区恢复，不能恢复卸载后的手机业务或替代正式业务备份。恢复前读取迁移记录和移动清单，先核对源/目标，保留现有未提交成果；不要对未知工作区使用硬重置或清理命令。

## 构建缓存与空间维护

阶段APK和Windows暂存目录不作为永久交付留存；核对最终releases后，只保留必要的小型报告、日志、截图和源码修订。闲置合成AVD按需重建，不为历史API矩阵长期保存全部设备镜像。Flutter/native编译缓存可以再生成，清理后第一次构建会较慢；维护完成后不为证明缓存可重建而立刻跑完整构建。

清理使用先盘点、固定白名单、校验路径/重解析点/跟踪状态/占用、删除、核对保留项的顺序，不对整个工作树或build目录一键递归删除。AVD稀疏逻辑体积和实际分配/可用空间分开报告，SDK、真实模拟器/设备、认证与业务资料不因目录名像缓存而被清理。2026-10-25的实际边界与结果见[空间记录](milestones/maintenance-handoff/records-cleanup.md)。
