# 维护交接与Git迁移记录

日期：2026-10-25。当前范围见[任务单](plan.md)。用户批准主工程`E:\107\main`、统一总目录，以及GitHub与校内远端同步当前维护主线。

## 起点

当前工作树`codex/design-reset`在fd9c48d，产品构建源码441a68b，工作区干净。旧main在e1b7ed3，放弃版rewrite/flutter-native在5ac2db0；两者与当前重写没有共同祖先。前三个工作区共用`E:\107\.git`，不是三个独立工程仓库。

前次只读核对main有48条状态、放弃版3条，执行前仍须重新捕获。源包和现有交付已按前序记录核验；本轮不启动应用、访问学校/模型、打开正式业务或秘密，不覆盖先前失败/未观察项。

## 备份与保留

备份位于`E:\107\backups\maintenance-20261025-f01b3082`。868个共用Git元数据文件逐项大小/SHA-256核对通过，另生成并验证`all-refs.bundle`、准备后的`prepared-refs.bundle`；refs和原根条目/移动清单在本地`state.json`保存，不推送这些备份或用户本地资料。

原main的48条状态为34条未暂存修改、14条未跟踪记录；放弃版3条未跟踪记录。29个原根顶层条目通过同盘目录/文件改名移入`archive/competition-minimal`，未读取业务库或认证目录内容。预建no-checkout的archive linked worktree并设置旧main索引后接收原文件，因此归档后48条状态逐项一致；放弃版移动后3条状态也逐项一致。忽略文件随原目录保存，未用clean/hard reset删除。

## 合成与真实迁移

Luna/max只写`tools/test-maintenance-layout.ps1`及自建GUID临时仓库。根审查后独立执行旧工作区与新main两次：目的地碰撞/越界拒绝、旧值CAS拒绝、独立根接续、tracked/untracked/ignored哨兵及脏linked状态/内容保留、四个worktree共用元数据、干净主树及Git完整性均通过；临时目录只在边界核对后删除。测试工具提交为9ca9db1，准备路径/维护文档提交为2d2f3b0。

真实迁移提交`4c8a8e39087420597745b74a9a66b2585bbd39e7`的树为`a7b68f26d24d18aab9d4e6391c11f2e17ebb9ff8`，精确等于准备好的重写提交2d2f3b0；父历史保留旧main e1b7ed3和当前重写。CAS推进main、read-tree/checkout-index物化后主目录干净，两段旧历史均为祖先，没有强推或旧代码内容冲突合并。

实际目录与引用：

| 位置 | 作用与保留 |
|---|---|
| `E:\107\main` | main主工程，唯一共用元数据`main/.git` |
| `E:\107\archive\competition-minimal` | archive/competition-minimal，旧main e1b7ed3及48条本地状态 |
| `E:\107\archive\flutter-native` | archive/flutter-native，原5ac2db0及3条本地状态 |
| `archive/design-reset`引用 | 准备完成的重写2d2f3b0，历史本地保留 |
| `E:\107\.worktrees\rewrite\design-reset` | 当前会话的临时交接工作区，保留原构建/运行证据；因目录共享冲突暂留原位，记录提交后detach到维护主线 |

最后一项为当前会话的临时交接目录，不作为第二个长期主线；后续打开`E:\107\main`继续维护。原总目录不再有.git，不重新init/clone第三个工程，不改归档文件内容或冻结历史中的原路径。

### 唯一保留的目录归位项

目标仍为`E:\107\worktrees\maintenance-handoff`。工具和用户普通PowerShell均执行Git worktree move失败，源仍存在、目标未创建，注册关系未改变。源目录/祖先和目标父目录无显式拒绝规则或重解析属性；只读Win32句柄查询中读取属性成功（0），改名所需DELETE访问返回32（共享冲突）。合成空目录的自建进程当前目录探针同样阻止改名，结束自己的探针后才成功；首轮尚未定位真实占用进程，未直接归因于某个Codex进程，后续查询见下。

不再反复移动、改ACL或结束用户进程。当前会话/相关终端切出或关闭、占用释放后，才执行下述命令；若仍失败则保留原位继续定位，不改主工程：

```powershell
git -C 'E:\107\main' worktree move 'E:\107\.worktrees\rewrite\design-reset' 'E:\107\worktrees\maintenance-handoff'
```

这项只影响临时工作区的目录名称；主工程、归档和双远端正常可用。所有工作区已经共用`main/.git`，原总目录没有独立.git，因此暂留的.worktrees不是另一个嵌套工程仓库。恢复清单记录该尾项，不将它误写成已移动成功。

### 用户再次手动失败后的句柄核对

用户报告Git反复询问重试，最终仍以Permission denied退出。根未继续移动：重新核对源存在、目标不存在、四个worktree指向有效、main干净，旧目录读取属性仍成功而DELETE访问仍返回共享冲突32。

根在忽略的临时构建目录编写只读句柄探针，先用自建空目录与自建子进程验证能检出当前目录句柄和共享冲突，再查询实际可访问进程。探针只获取句柄/路径元数据，不读取文件内容、命令行或进程内存，不启用调试特权；只输出目标根目录及其内部句柄的进程和匹配类别，不输出内部文件名称。探针只结束自己的合成子进程并删除自己的空目录。

本次快照中，Codex桌面程序实际名为`ChatGPT.exe`，持有旧根目录2个句柄；其cua_node运行时的`node.exe`及3个`node_repl.exe`各持有旧根目录1个句柄。程序位置和父PID元数据核对这些Node进程属于Codex运行时。另有`QQ.exe`持有旧目录内部2个句柄，未检查对应文件内容。仅按codex进程名搜索曾漏掉实际桌面进程与Node运行时，扩大到可访问进程后才检出；183个进程成功查询到文件句柄，不宣称覆盖所有受保护进程。

这是当前持有者的证据，不能倒推用户上一次退出Codex时哪些进程仍在，也不把所有打开句柄都直接认定为不允许删除共享。后续应在用户保存工作、正常退出Codex及相关QQ文件使用后，从独立PowerShell执行Git移动；不要在移动前先恢复绑定旧目录的会话。若仍失败，使用Windows资源监视器的CPU/关联句柄搜索`design-reset`，核对当时的持有者。未强制关闭句柄、结束用户进程、改ACL或进行复制删除替代；本轮仍保留原目录。

## 私有交付与环境

通过冻结manifest、ZIP摘要及逐文件前后哈希，完整搬移96个文件：

| 长期交付目录 | 文件数 | 冻结证明 |
|---|---:|---|
| `releases/windows/1.0.0+1-441a68b9` | 41 | ZIP `c89264f9a787eea329a2917df0a5144e3fa9ba1448cac56b509bf99cf68c07cb` |
| `releases/windows/1.0.0+1-862a13ac` | 40 | 旧ZIP `76af4056e026743d8966a212a5288a2a6234423774560f611a168ddea0417e96` |
| `releases/android/android-1.00-qa2024-441a68b` | 15 | 主manifest `cccef77ea035131183103aa4dec8c06bac054e0a739cd252970392926de21606`，两APK及全部载荷哈希未变 |

路径相对`E:\107`。现有APK、ZIP、随包README和manifest保持原字节；有效源码说明更新长期位置，不通过重写包内说明伪造新构建。三个固定公开语音缓存资产（模型、tokens、模型LICENSE）另经固定哈希核对后移入新main的app/build，未搬用户录音。SDK/Pub/Gradle继续使用既有E盘环境，没有新装C盘环境或改全局设置。

## 新目录根检查与修正

- 新main从E盘Pub缓存离线恢复锁定依赖，`flutter analyze --no-pub`无问题（13.1秒）。产品`app/lib`、Android/Windows/原生、发布资产和pubspec/lock与441a68b保持Git内容一致；不启动产品或访问学校/模型。
- 新目录文档检查通过172份Markdown、1344个本地链接及冻结归档；差异检查通过。旧15导航锚点继续有效，不改冻结原文。
- LF旧工作区、CRLF新检出中的Windows打包检查均17项通过；新main的合成Git迁移检查也通过。未因Git/路径变动重复Flutter全量或重建已经冻结的Windows/APK，既有完整工程证明仍查原记录。
- 离线pub get以LF重写了三项Windows生成文件；确认相对HEAD及441a68b均无内容差异后，只更新这三项规范化索引，暂存差异仍为零，主工程恢复干净，没有提交生成噪声。

发现和处理的失败保留：合成脚本早期数组/空输出及.git指针快照问题在临时仓库内修正；初次末尾空行被diff检查拒绝。一次性备份状态曾将单行Git输出误取首字符，在任何移动前按已保存refs纠正并核对完整SHA，868项实际备份未损坏。维护标题改名造成旧导航锚点失败后恢复原锚点。真实.git目录改名被Codex沙箱显式保护ACL拒绝，未改ACL或绕过保护；用户从普通PowerShell移动并repair后根继续验证。新main首次打包测试缺少生成目录，创建后又暴露NOTICE的CRLF解析问题；仅修测试正则（b43c2dd），LF/CRLF均通过，没有修改产品行为或发布包。

## 认证和远端

GitHub实时main为6e8fd35，校内实际main为068b1b7，均为迁移后main的祖先。最初SSH没有可用主机信任，HTTPS没有可复用凭据；通过校内官方HTTPS配置页核对公开ED25519指纹`SHA256:8mLA9E4qvGYPkNmc0OMdDyB6ePeboA8qhg6ge3EEY8k`，使用仓库专用known_hosts并保留严格校验。Windows keyscan的KEX兼容失败后改用已安装的Git自带SSH工具，不降低校验或安装服务。

显式指定已有身份文件后，校内Git实际接受该密钥并允许目标仓库读写；未生成/上传新密钥，不能从日志确定原授权的添加时间。仅本仓库core.sshCommand固定已验证客户端、已有身份文件路径和忽略的`.local/git/known_hosts`；私钥仍留原位置，不复制/输出，不启用本机SSH入站服务，不改全局SSH或系统信任。

已实际用普通推送将两个远端main推进到`21226c6252a3671d69dedc27963da7648bb8e044`，随后ls-remote读回均相同；这是真实服务结果，不是仅看remote-tracking缓存。最后的交接文档提交后再同步并核对，最终HEAD和所选版本标记在本地恢复清单与最终交付说明中登记；不用force/mirror/all，不删远端分支、不推本地archive成果或安装包。
