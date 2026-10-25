# Windows私有包刷新

日期：2026-10-25。用户在核对旧Windows交付后同意刷新，范围与不变量见[任务单](../plan.md)。Sol直接处理打包器与交付文档，不改变产品代码、版本、Windows身份或资料目录，不公开发布。

## 输入与旧交付保留

当前输入为`app/build/android-onboarding/windows-staging/x64/runner/Release/`，来自源码`441a68b99ea713eb891b269dc0210a1c41b63f77`的普通Release；[Android记录23](../../android-apk/records/23-onboarding-and-brand.md)已包含完整共享、相关Windows/Android及构建检查。此前仅整理Android最终交付，Windows仍保留旧1.00包；本轮只补当前Windows便携目录和ZIP。

旧包`app/build/private-releases/1.0.0+1-862a13ac/`、原默认Release及用户资料保留。源暂存manifest有37项，其中`notification_native.lib`是构建静态库，应沿打包器原规则排除；实际运行文件为36项，较旧包增加品牌PNG。之前暂存核验的37项计数是全目录计数，不作为最终运行载荷数。

## 修改与核验

打包器固定清单加入品牌PNG并校验获准图标哈希，保留其余运行资产和许可证；交付manifest补明Release、普通入口、schema20及非公开属性。文档更新为当前构建的安装/升级与已知问题，不以旧schema18说明指导新版。工程辅助提交为`55130e03afc7485fc28d0f026003550d3ed82188`，只涉及打包器和相关测试，产品二进制仍来自441a68b。

| 根检查 | 本轮实际结果与范围 |
|---|---|
| 冻结源码及暂存输入 | 对441a68b比较`app/lib`、Android/Windows/原生、assets、pubspec及锁文件无产品差异；37个暂存文件逐项大小/哈希与原构建manifest一致，PE产品名USTC Assistant、FileVersion/ProductVersion均1.0.0+1 |
| 打包器合成检查 | `powershell -NoProfile -ExecutionPolicy Bypass -File tools/test-package-windows-private.ps1`：17项通过；包括缺少/替换图标、未知文件/业务库拒绝、边界/重解析属性、ZIP内容篡改与额外条目拒绝，以及当前manifest语义 |
| 实际打包 | 固定36项运行载荷、2份说明、manifest共39文件，目录和ZIP均生成；打包器重新读取ZIP，对条目集合、文件大小及SHA-256逐项检查通过，语音/模型/许可与品牌哈希通过 |
| 独立校验 | Conda basic310独立流式重算全部39项及ZIP CRC；目录、ZIP与原暂存运行载荷一致，当前说明副本一致，构建静态库/未知文件不在包中。AOT含441a68b、首次设置、tools-v7/persona-v15，排除测试入口标记；PE为x64且无Authenticode证书表 |
| 旧交付保留 | 原ZIP仍为`76af4056e026743d8966a212a5288a2a6234423774560f611a168ddea0417e96`，打包前后核对均一致；没有替换旧默认Release |

独立校验器与结果在E盘忽略目录`app/build/windows-private-refresh/verify.py`、`verification.json`。本轮没有出现产品或打包失败；文档检查通过168份Markdown、1311个本地链接及冻结归档核验，`git diff --check`通过。

## 当前交付

路径为`app/build/private-releases/1.0.0+1-441a68b9/`，内有完整`USTC-Assistant-1.00-windows-x64/`、同名ZIP及`.zip.sha256`。完整目录304196821 bytes，36项运行文件加说明/manifest共39文件；manifest列出除自身外38项，并携带实际构建源码及锁文件摘要。ZIP和目录只需使用其一；不打包用户资料、日志、秘密或浏览器会话。

| 文件 | 字节 | SHA-256 |
|---|---:|---|
| `ustc_assistant_m0.exe` | 1037312 | `3662b7cf39037e62b3b392f420eab7e9b0aa794985d0e678a2da9a67e6aef8f2` |
| `data/app.so` | 12977040 | `172a7e85ec0ee3ca28bb23d0051fff2ecae750433dd512b1b07c6f210c31c49e` |
| 私有ZIP | 187545367 | `c89264f9a787eea329a2917df0a5144e3fa9ba1448cac56b509bf99cf68c07cb` |
| `manifest.json` | 10602 | `47344edaa19c18fd5c8508b3ede16dcd50678786a1fafb943c85c6c949370bd2` |

本地源码标记`windows-private-1.00-20261025`固定到实际构建修订441a68b，原`windows-v1.00`不动；本轮文档与工程辅助提交分开，不推送。当前[交付说明](../../../releases/windows-1.00.md)明确正常退出旧应用、完整目录启动、schema20升级及旧版不能直接回读；更新后的[已知问题](../../../releases/windows-1.00-known-issues.md)随包提供。应用仍未代码签名，不增加安装器或公开下载。

本轮不运行应用，不解密或检查正式业务，不访问学校/模型，不替换正在使用的旧EXE。产品源码未改，完整工程证据仍对应441a68b，不将旧测试计数写为本轮重跑。原非空考试、真实麦克风、通知/睡眠/重启及新机器等未观察项继续保留，手机/MuMu反馈不借作Windows真人验收。
