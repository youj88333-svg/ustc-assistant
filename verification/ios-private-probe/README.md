# iOS I0 合成探针

本目录只验证无自有 Mac 的设备构建、本机签名和 Widget 共享链路。依据[唯一任务单](../../docs/milestones/ios-private/plan.md#i0-执行契约)，不接入正式应用、学校、模型或已有业务资料。

Flutter 主应用只显示本次源码修订和共享容器状态，可写入一个新的合成标记；SwiftUI Widget 只读同一文件。共享不可用、文件损坏或原生桥失败均直接显示失败，没有用主应用私有缓存伪造共享成功的路径。WidgetKit 的刷新是请求，不承诺立即出现。

## 本机合成检查

使用既有 Flutter，并把 Pub 缓存留在 E 盘：

```powershell
$env:PUB_CACHE='E:\Android\pub_cache'
Set-Location 'E:\107\main\verification\ios-private-probe'
& 'E:\flutter\flutter\bin\flutter.bat' pub get --offline
& 'E:\flutter\flutter\bin\flutter.bat' analyze
& 'E:\flutter\flutter\bin\flutter.bat' test
```

本机 Windows 的 Dart/界面测试不能验证 Swift、签名或 App Groups。生成的 iOS 工程使用云端固定 Flutter 模板，写入忽略的 `app/build/ios-i0/flutter_probe`，不提交生成工程。

## Codemagic 首次构建

1. Personal 免费账号以 Other/HTTPS 接入校内仓库。校内 Git 当前要求校外登录，使用仅限本项目、只有 `read_repository`、短期到期的部署令牌。部署用户名与令牌由用户直接填入 Codemagic 的仓库认证栏，不写入源码、脚本或聊天；取消勾选 Public repository 只启用客户端认证，不改变校内仓库公开级别。
2. 项目类型手动选 iOS，YAML 路径为仓库根的 `codemagic.yaml`，脚本工作目录为仓库根。不要启动默认的正式 Flutter 工程构建。
3. 选择本次已推送的修订/分支，先手动运行 `ios-i0-preflight`（Mac M2/Xcode 27.1，最长5分钟）。它核对实际 checkout、设备 SDK、Ruby/xcodeproj 和配置，不安装 Flutter，也不使用 Apple 凭据。
4. 预检成功后，同一修订手动运行 `ios-i0-probe`（Flutter 3.47.7，最长30分钟）。脚本生成独立 host/Widget 工程、检查与编译 Release/AOT 设备包，再打包和校验。没有 push/定时触发、发布或邮件收件人配置；不启用付费超额。
5. 构建保留两类私用包和报告，具体权限见下表。两份 `.entitlements` 是固定共享组的声明参考，不是证书、profile 或有效权限，也不保证 Sideloadly 会读取外置sidecar。禁止将签名秘密或手机配对资料上传到 Codemagic。

| 文件 | 用途与限制 |
|---|---|
| `ios-i0-unsigned.ipa`、`ios-i0-verification.json` | 原始未签名设备包与结构/源码校验报告 |
| `ios-i0-signing-input.ipa`、`ios-i0-signing-input-verification.json` | 追加批准的独立ad-hoc请求副本，供本机重签工具识别共享组；仍不能直接安装 |
| `ios-i0-entitlement-request.json` | 两目标固定请求及递归完整性核对，明确实际App Group授权尚未验证 |

副本的manifest与报告使用`ios-i0-signing-input-v1`/`adhoc-request-only`，原始包仍是`ios-i0-unsigned-ipa-v1`/`unsigned-personal-probe`；不能把两者误认为Apple正式签名。Apple身份、profile和真正授权只在后续本机流程中产生。`ios-i0-provenance.json`单独文件对应原始包，副本自己的追溯文件在其包内。

预检报告证明本轮云端工具链/源码可用；IPA 报告证明包结构、身份、真实 iOS arm64、Widget 和 AOT 修订。两者都不能证明 Apple 授权或目标机实际共享。若失败，保留具体阶段和安全日志，不连续消耗免费分钟重试同一原因。

## Windows 下载后独立校验

把下载文件放在源码外的 E 盘私用交付目录，用本次构建的完整40位源码修订校验，例如：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File 'E:\107\main\tools\ios-i0.ps1' -IpaPath 'E:\107\private\ios-i0\ios-i0-signing-input.ipa' -ExpectedRevision '<本次40位源码修订>' -ReportPath 'E:\107\private\ios-i0\local-verification.json'
```

包装器优先 `E:\conda\envs\basic310\python.exe`，不安装或签名。报告不包含完整本机路径或凭据。另可从仓库根运行验证器反例：

```powershell
& 'E:\conda\envs\basic310\python.exe' -m unittest discover -s tools/ios-i0 -p test_verify_package.py -v
```

## 本机签名与 iPhone 门禁

从 [Sideloadly 官网](https://sideloadly.io/)取得 Windows 客户端。Apple 登录、2FA、USB 配对、Developer Mode 和信任提示均由用户本机完成；不将这些资料发到聊天。未签名 IPA 不能直接安装或当作已经交付的 iOS 应用。

首次只安装独立的 `USTC I0`，不替换现有 Windows/Android/其他手机应用。使用已核验的`ios-i0-signing-input.ipa`进行本机Apple重签，保持host与Widget一起处理，不把“主应用可启动”当成Widget已保留的证明；免费Sideloadly的请求处理仍需实际验证，不能从AltStore源码推定它的行为。记录准确iOS27.x/build、签名工具版本、是否免费账号、最终bundle ID和两目标是否保留；无需导出或发送原始profile。

在 host 写入合成值后添加 `iOS I0 探针` Widget，核对相同标记和 UTC 时间；Widget 继续显示旧值时先记录等待/刷新行为，不能直接判定共享失败。再检验 Widget 点击能打开 host、结束进程后重开仍保留标记、同一账号/身份立即重签覆盖后 host 与 Widget 仍共享同一值。不要卸载来代替覆盖升级测试。

7天到期与续签属于另一个真实时间门禁，不能靠改系统时间或一次立即重签替代。若免费链路不能保留 Widget/共享组，回报具体事实并由用户决定后续范围；不默默取消 Widget、购买会员或改用业务库共享。I0 结果统一写入[阶段记录](../../docs/milestones/ios-private/records.md)与[验收登记](../../docs/milestones/ios-private/acceptance.md)。
