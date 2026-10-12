# 关键模型与事务实验

本实验使用新合成数据、Conda `basic310` 的 Python 3.10.20 / SQLite 3.53.1。Python 是一次性验证工具；产品运行时不因此增加 Python、Bridge 或 CLI。SQLite 的结果支持事务语义判断，Flutter/Drift 实现及实际来源映射仍须分别验收。

## 关键模型边界

| 对象 | 最小定位与字段归属 | 实验结论与限制 |
|---|---|---|
| 来源记录 | `(account, source, stable namespace, external ID)`；标题、时间、来源状态及观察状态属于来源；本地 ID 首次创建后保持 | 改时、改名、查询窗口移动、缺失和再次出现不换本地身份；真实来源必须另证稳定 external ID。稳定 namespace 与查询 coverage 分开，不能把移动窗口放进 key |
| 查询覆盖 | 半开北京时间 `[start,end)`，只处理该窗口内旧来源记录的缺席 | 完整空快照标记 `missing_unconfirmed`，窗口外记录不改；不完整或坏输入零业务写。真实分页、成功/错误和完整性证据尚未成立 |
| 用户覆盖 | 独立 overlay 保存用户标题、时间对、备注、hidden 及单调 version | 来源刷新不覆盖用户字段；missing 和 source cancelled 均不自动变 user hidden；撤销只改用户字段，保留后来来源事实 |
| Task / PlanBlock | 独立稳定本地 ID；外键关联稳定事件 ID，PlanBlock 另关联 Task | 改时后外键和本地计划保留，foreign_key_check 通过；完整 Task 状态机、批量操作和冲突选择在相应切片定义 |
| 重复与单次例外 | 本地系列 ID + 原始 ordinal；move 保留 key/original_start，skip 保留记录 | 有界 daily/weekly、月末/跨年/闰日和移时例外通过；全天 local date、其他重复规则、系列整体修改及拆分尚未实现，不能据此宣布完整重复功能完成 |
| 作业与封存交接 | 原 job/account/source/generation/epoch/contract；记录和 coverage 脱离可变输入 | 关闭浏览器不参与 SQL 守卫，旧 epoch/generation 或取消先受理则拒写；本实验没有真实身份 verifier，不能证明学校产物可信 |
| 本地命令 | 稳定 operation + 不可变意图 + account/epoch + 目标 version；所需批准绑定同一 operation 和意图 | 重放返回回执且不再写业务/审计；改意图或移用批准拒绝；撤销保留单调 tombstone version，旧批准不能通过版本回到 0 再执行 |
| 业务提交 | 来源 upsert/观察状态、适用密文、具体分区许可、回执与安全审计同一 `BEGIN IMMEDIATE` 事务 | SQL 失败/进程退出共同回滚；COMMIT 后丢回执可以恢复查询，不重复导入。密文使用合成 bytes，真实 DPAPI 与 SQL 的最终产品连接未做 |
| 分区许可 | partition/attempt/owner/epoch/purpose 精确匹配，C3 唯一权威 | 控制模型验证账号存在不能认领、无许可候选回收、撤销后旧 claimed 隔离、清理失败保留 deletePending；真实浏览器 drain/删除由 Windows 实验另证 |

## 执行与结果

```powershell
& 'E:\conda\envs\basic310\python.exe' -m unittest discover -s verification/model -v
```

2026-10-09 最终执行 **34 tests 全部通过**：Luna / max 的纯模型自测 14 项，主代理独立边界及 SQLite 验收 20 项。实际锁竞争先以独立连接的 `BEGIN IMMEDIATE` 得到 locked，再验证两种受控赢家顺序。子进程分别在业务写后、全部 SQL（含回执/审计）后但 COMMIT 前、COMMIT 后用 `os._exit` 退出，重新开库检查完整性和持久结果；重认证失败还验证既有业务和旧密文逐值保持。每个测试用随机临时数据库，运行结束自动清理。

首次集成 31 tests 中有 1 项验收辅助构造函数将传入坏记录误换成正常记录；已修正并重跑全部通过。另一个 Sol / high 的独立只读复核复现两个真实实验缺口：coverage 引用原可变 dict、cancel 未检查原 job 全绑定；主代理已修复并各补回归。也补强了锁争用和全部 SQL 后退出的证据。失败作为本记录保留，不能把首次执行记作全部通过。

本次只完成最小关键语义。V-04/V-05/V-06 按覆盖范围取得自动证据；各消费者集成、完整 UI/Agent/工具、提醒和真实来源仍待对应阶段验收。
