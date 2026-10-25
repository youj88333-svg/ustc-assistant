# 当前QA身份的私有交付收尾

日期：2026-10-25。依据本阶段计划“A8当前QA身份的私有交付收尾”；Sol直接完成文档与现有产物整理，无新业务实现。用户MatePad总体反馈、目录故障补验及沿用QA身份的选择统一记入[验收](../acceptance.md)，不在本记录重写逐项真人结论。

## 冻结范围

工程源码仍为`441a68b99ea713eb891b269dc0210a1c41b63f77`；之前完整analyze、1654项共享/1平台跳过、相关Windows与Android原生检查、双ABI及Windows暂存构建见[记录23](23-onboarding-and-brand.md)。本轮不修改产品代码、版本、签名、schema或权限，不访问学校、模型、目标设备及正式资料，不覆盖原APK或Windows1.00。

输入为`app/build/android-onboarding/artifacts/`中两个已核验普通APK及原始构建manifest。交付整理到E盘忽略目录`app/build/private-releases/android-1.00-qa2024-441a68b/`，只纳入两个APK、两份构建manifest、安装说明、已知问题、APK内相同的许可、交付manifest与SHA256SUMS。没有数据库、凭据、Keystore、浏览器目录、用户日志或构建缓存；不另做重复的大体积ZIP。

## 根检查

整理前重新核对输入的固定字节数/SHA-256、SDK签名和包名/版本/ABI；复制后重新计算全部文件哈希。Flutter依赖通知、语音/模型许可逐项从两包读取，要求一致，并与工程内既有语音许可核对。交付manifest列出全部载荷，SHA256SUMS覆盖manifest本身，检查没有额外或遗漏文件。

| 检查 | 本轮实际结果 |
|---|---|
| 冻结产品源码 | `git diff --exit-code 441a68b -- app/lib app/android app/assets app/native app/windows app/pubspec.yaml app/pubspec.lock`无差异；没有重编或另换入口 |
| APK输入及副本 | 两包固定字节数/SHA-256与记录23一致；aapt实际包名/版本码/版本名及ZIP内唯一ABI通过，SDK apksigner实际验签和既有证书核对通过 |
| 许可 | 7份许可/通知在两APK与交付副本间一致；其中5份语音组件许可另与工程原件核对，无额外下载或替换 |
| 独立交付校验 | Conda basic310流式重算15个文件，13项manifest载荷、14项SHA256SUMS条目及两个固定APK均通过；目录总计575497799 bytes，README本地链接全部可达，无额外文件或符号链接 |
| 文档 | `tools/check-docs.ps1`通过：167份Markdown、1298个本地链接及冻结归档核验；最终差异检查通过 |

`manifest.json` SHA-256为`cccef77ea035131183103aa4dec8c06bac054e0a739cd252970392926de21606`；`SHA256SUMS.txt`为`958d11a13fb0262b0d230aca1085f579c312362e71f71c8cc6044b2deb9527a7`。主manifest不把自身纳入载荷，SHA256SUMS再覆盖主manifest，校验文件自身的哈希记录于本段，避免自引用。

整理使用E盘忽略目录`app/build/android-private-handoff`内的一次性脚本；首次辅助脚本目录层级偏差在读取manifest时失败、未创建交付目录，修正后加入固定工作区断言再运行。独立校验器首次使用Python3.11才提供的hashlib接口，在basic310中失败；改为流式SHA-256后全部通过。这两项是本地交付辅助脚本问题，没有修改产品源码、已有APK或用户资料，旧失败不作为产品验收结果。

本轮无产品代码变化，按文档/文件交付边界仅运行上述产物核验、`tools/check-docs.ps1`和`git diff --check`，不重复Flutter全量，不借用旧计数作为本轮执行结果。当前私有QA安装说明与限制分别见[交付说明](../../../releases/android-private-1.00.md)和[已知问题](../../../releases/android-private-1.00-known-issues.md)。本地文档提交记录本轮交付与验收，代码标记`android-private-1.00-qa2024`固定到上述441a68b源码修订；不推送或公开发布，A8独立正式签名延后。
