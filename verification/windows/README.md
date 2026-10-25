# Windows 原生 SDK 前置实验

这是本分支新建的可丢弃实验，不是产品工程，不构成 M0 交付或真实学校验收。早期原生实验使用 .NET Framework WinForms 与 WebView2 SDK，另有下述独立手动跳转工具；没有复制旧工程、旧 fixtures 或旧浏览器资产。

**最新范围决定（2026-10-09）**：用户回复“approve，请修改设计”，批准[首版普通 WebView 与保留控制](../../docs/refactor-docs/07-constitution.md#首版浏览器安全边界与-m0-准入)。CAL 引擎修复、取得补丁运行时及完整协议隔离回归正式移出首版任务和 M0、真实观测入口、冻结/发布门槛，不主动追版本。原失败与 `qualified=false` 留档，不改为通过；实际学校页面或产品发生同类故障时再按兼容性处理。

首版装配不主动注入 CAL、不安装为全协议封闭而设的 DNR/CSP 防护扩展、不一律禁止 Worker、不以 JS 替换 WebRTC，尊重页面已有安全策略，接受正常后台网络活动。产品验收检查保留的导航/frame、弹窗、下载、权限申请和外部协议控制、固定操作、会话/文档隔离、凭据保护及排空真清理，并验证实际登录、身份、正确采集、取消、关闭和清理。应用自有请求继续严格限定；来源特定的常规请求规则按已证范围采用，不要求全部协议零外联。

## 手动登录跳转观测（2026-10-11）

[login_redirect_trace.py](login_redirect_trace.py) 用现有 `ustc_assistant` Conda 环境的 Playwright 打开独立可见 Edge。由用户完成登录，进入活动列表和个人日程后，关闭本工具打开的全部窗口即可自动保存；后台运行也不需要终端输入。默认只打开 Young 固定入口，`--source jw` 可另做教务对照，`--direct` 仅让本次独立浏览器直连；默认使用 `http://127.0.0.1:7897`，不改变全局代理。

```powershell
& 'E:\conda\envs\ustc_assistant\python.exe' verification/windows/login_redirect_trace.py
```

只记录文档请求的方法/状态/HTTP 重定向关联、主/子 frame 导航及弹窗匿名序号。URL 只保留登记的静态路径和参数名称，未知 origin/路径匿名编号；不读取 DOM、请求/响应头体、Cookie/Storage 或浏览器认证资产，不自动填表或操作学校业务。最多保存 2000 条事件，截断显式标记；输出仅在已忽略的 `tmp/login-redirect-trace/latest-young.json` 或 `latest-jw.json`。Playwright 的[独立上下文](https://playwright.dev/python/docs/api/class-browsercontext)、[请求重定向关联](https://playwright.dev/python/docs/api/class-request)与[系统 Edge 通道](https://playwright.dev/python/docs/browsers)是工具依据。普通 Edge 的手动链路是调试线索，不代表产品自动认证、身份或导入验收。

[合成回归](test_login_redirect_trace.py) 可用同一 Python 运行；自动检查不访问学校。根已通过八项投影/关闭/缺失 frame/上限回归及实际无界面 Edge 回环多跳、iframe、弹窗和页内路由检查，具体结果和真实手动链路统一记于 [15 同一 M2 任务](../../docs/refactor-docs/15-construction-methodology.md#m23-登录阶段-busy-与手动跳转观测2026-10-11)。

## 严格隔离增强路线历轮记录

以下命令、运行时资格工具与未放行裁决只保留当时范围和故障复现用途，不作为当前待执行任务或首版必需检查。没有新增产品装配、学校验收或引擎修复通过记录。

## 执行与环境

在本 worktree 运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File verification/windows/run.ps1
```

仅编译加 `-CompileOnly`。本机 SDK 缓存为 `Microsoft.Web.WebView2` 1.0.3967.48，`csc.exe` 为 Windows .NET Framework 4.x 的 C# 5 编译器，实测 WebView2 Runtime 为 **154.0.4258.62**。基础、DNR、worker-guard 与最小 CAL 套件不依赖 dotnet SDK、Flutter 或 Python；完整 CAL 和独立 CAL HTTPS 套件另需 Conda `basic310` 的 Python 与 `verification/.runtime/transport-deps` 中隔离安装的 aioquic，见 [HTTPS fixture](../https_fixture/README.md)。SDK 缓存只读，依赖副本和每轮随机资产仅放在已忽略的 `verification/.runtime/windows/`。

独立复跑 DNR 并保留已有证据：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File verification/windows/run.ps1 -Variant dnr -EvidencePath "E:\107\main\verification\windows\evidence-dnr-independent.json"
```

`EvidencePath` 只能位于 `verification/windows` 或 `verification/.runtime/windows`。DNR 变体只运行安装/重复请求/跨进程重启/排空/清理，不重复 SDK 和 CDP 候选；默认输出 `evidence-dnr.json`，独立验收应显式指定新文件名。全套自定义输出时，其 DNR 子证据也采用对应文件名前缀，避免覆盖原证据。

静态 CSP worker guard 和本机 UDP 反例可独立运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File verification/windows/run.ps1 -Variant worker-guard -EvidencePath "E:\107\main\verification\windows\evidence-worker-guard-independent.json"
```

该变体先运行新 UDF 的未加 worker guard 对照，再运行另一个全新 UDF 的 guard 与跨进程重启。当前预期退出码仍为 **1**，由实际 WebRTC UDP 漏拦产生；CSP worker 检查通过不等于整个浏览器出站覆盖通过。

Codex 沙箱内 `GetFinalPathNameByHandle(FILE_NAME_NORMALIZED)` 返回 Win32 5，实验在开浏览器资产前停止；获准原生执行后该检查通过。普通 Windows 终端可直接运行上述命令。Helper 使用 `CreateNoWindow`/Hidden 启动；实验宿主不透明、正常状态并位于屏幕之外。它没有学校地址入口。

基础出站套件及 `connection-allowlist-minimal-navigation` 的退出码 **1 是当前预期结果**：候选仍存在真实失败。最终 `connection-allowlist-https` 的所测方法约束通过，退出 0；它不能替代 RTC 反例。不得为了全绿跳过失败。每个浏览器 child 最多 45 秒，基础单轮 suite 最多 150 秒；超时不报排空/删除成功。

## 实测结果及证据

`evidence.json` 是最近完整套件的安全结构化结果；`evidence-dnr.json` 是独立静态规则候选的结果。检查细节只含已知合成路径、方法、资源种类、来源种类、计数、布尔结论和异常类型，不记录 URL query、响应、认证 header/body、Cookie、Token、账号或明密文。

已通过的原生能力：

- 用实际目录的排他文件句柄在任何浏览器资产打开前取得所有权；大小写/点路径别名归一；第二进程拒绝；强制终止后重启取得所有权；新建本机 junction 在资产打开前拒绝。
- 独立 UDF A/B 用浏览器内合成 localStorage marker 返回布尔结果证明隔离；另一个进程重开 A 证明持久复用。Host 没有读取浏览器认证资产。
- 同一重定向的逐跳 `NavigationStarting`/`NavigationId` 与最终 DOM ready 关联；拒绝 origin 的重定向跳在联网前取消；frame 使用独立事件；真实 `ExecuteScriptAsync` 待消费结果在换文档后由世代守卫丢弃。
- 一律处理弹窗、不创建第二 WebView；一律取消下载；非 HTTP 协议导航在 OS handler 启动前拒绝。
- 每次 Dispose 后实际收到 `Environment.BrowserProcessExited` 才删除分区。故意持有合成非秘密 sentinel 时物理删除失败，持久 deletePending 保留；释放后重试真删除，并检查目录不存在。删除前逐层拒绝 reparse，只删除已确认属于随机实验根的目录。
- DPAPI CurrentUser 随机假秘密保护/恢复；错误 entropy 与篡改密文拒绝。明密文没有打印或落盘，临时 byte[] 尽力清零。

SDK `WebResourceRequested("*", All, All)` 存在缺口：最小化、透明及不透明离屏宿主均测过。主文档 HTTP 请求拦截结果随可见性/运行时序变化，离 DOM 的 `new Image()` 仍有漏网；不能将一轮 fetch/POST 通过视为隐藏浏览器安全成立。主文档、iframe、专用 worker、service worker 的 WebSocket 均可能没有资源事件并实际到达服务器。`Websocket` 枚举存在不等于该 scheme 被事件覆盖。

CDP `Network.enable` + `Network.setBlockedURLs` 在导航前配置后补住了测试中的 HTTP 图片和主/frame 请求，但 **未挡任何 main/frame/worker/SW WebSocket**。没有订阅 Network 事件，也没有读取 headers/body；这个候选不满足出站安全契约。

静态 MV3 DNR 候选：先启用 `AreBrowserExtensionsEnabled`，安装本机静态扩展，登记 Add 返回的 ID；首次及另一个进程重启时均确认同 ID enabled 才导航。全新 UDF 的 API inventory 返回 3 个条目，因此不能把“恰为 1 条”用作安装成功条件。Manifest 仅 `declarativeNetRequest` 权限，无 host permissions、background、content scripts、webRequest 或页面读取代码。规则 priority 1 默认 block 全部 HTTP/HTTPS/WS/WSS，priority 2 只 allow 精确合成本机 origin 的 GET；明确列出 main_frame 等资源种类，不使用 allowAllRequests。

**DNR 的 HTTP、main/frame/专用 worker WebSocket 覆盖通过；ServiceWorker WebSocket 仍失败。** 首次拒绝 origin 和允许 origin 各收到 2 个 SW 握手，跨进程重启各收到 1 个。SW 在尝试前通过合成允许端请求证明 WebSocket 构造能力存在。最新独立 DNR 证据为 **45 pass / 4 fail**，四个失败是 SW 两 origin、两轮，不能关闭平台出站覆盖验证。GET 是实验许可；真实学校的只读许可仍须限定具体业务端点，不能照搬 origin 全 GET 许可。

worker-guard 补充候选已实测：DNR priority 3 在全部合成 origin 的 main_frame/sub_frame 响应 **append** `Content-Security-Policy: worker-src 'none'`，高于 GET allow 的 priority 2；不读取原始 header/body。静态 manifest 增加 `http://127.0.0.1/*` host permission 供浏览器原生改响应头，仍无 background/content scripts/webRequest。Chrome host permission 不能按端口收窄，因此实际规则用带端口的精确 origin regex 再限制。新 UDF 从创建即装规则，不复用有 SW 注册的候选分区。

main、普通 iframe、srcdoc、about:blank、blob 的 dedicated/shared/serviceWorker 原生尝试全部拒绝；正常 HTTP 请求在各上下文仍阳性，注册数为 0，worker 脚本、执行 sentinel、两 origin 的 worker WebSocket receipt 全为 0；重启重复通过。未 guard 的对照证明正常 main/frame SW 可注册、dedicated/shared worker 可执行及 shared/SW WebSocket 漏拦。about:blank/blob 等非 HTTP 文档的 SW 注册可能原生已不支持，记录为 reference surface，不能把固有拒绝全归功于 CSP。服务端原有 `img-src 'none'` 仍挡图片，证明追加 CSP 没有覆盖旧策略。首轮 fixture 的 srcdoc targetOrigin 与 worker sentinel 时序错误已保留在 `evidence-worker-guard-initial-failure.json`，修复后的纯 CSP 证据为 `evidence-worker-guard.json`。

**实际 WebRTC UDP 反例仍使平台出站候选失败。** `evidence-worker-guard-with-rtc.json` 中，在 `PermissionRequested=Deny`、DNR 和 CSP worker guard 同时开启时，主文档 `RTCPeerConnection` 成功创建 dataChannel、offer 并设置 local description；仅配置 `stun:127.0.0.1:<本轮独立端口>`。本机 UDP receiver 只计数并清零丢弃包，无解析/保存。对照、guard 首轮、guard 重启各收到 **4 个 UDP 包**；PC 已显式关闭，浏览器已排空、UDF 已删除。该文件有 113 pass / 2 fail / 6 info / 2 not_run；两个失败是 guard 两轮的实际 UDP receipt。WebTransport 与 RTCPeerConnection constructor 均存在；WebTransport/QUIC 连接约束仍未测试。纯 CSP 文件的 `No connection/packet test performed` 是该早期轮次当时的范围；RTC 文件中同类 API-surface 文字应与独立 RTC 执行/receipt 检查共同读取，最新源码已把它改为明确区分 WebTransport 与 RTC。

保留失败历史，不回写为通过：

- `evidence-filter-failure.json`：最小化 SDK 事件漏拦及服务器 receipt。
- `evidence-visible-filter-failure.json`：透明但逻辑可见，图片/WS 漏拦。
- `evidence-cdp-failure.json`：HTTP 辅助候选及各上下文 WS 失败。
- `evidence-dnr-initial-failure.json`：额外 inventory 数量断言失败，fail closed 未导航；该文件中零拒绝端 receipt 不能单独解释为覆盖通过，正向执行检查也失败。

## 未验证与产品限制

DPAPI 跨 Windows 用户/设备未测，不宣称可移植；业务 SQLite 的唯一密文事实源由主代理另验。Flutter 插件装配未测。当前代码只是实验，不包含完整持久分区登记/认领许可、真实来源 endpoint policy 或生产文档/作业 token 实现。worker guard 的真实学校兼容性未知，站点可能依赖 workers；WebTransport 仅后续同 URL GET/CONNECT 所测路径通过，后续文档 RTC 仍崩溃，完整出站约束未成立，不能据此开启真实学校入口或关闭 V-02。

密码投递 **unsupported**：没有证明 ExecuteScriptAsync 具备文档原子目标，不注入任何真/假秘密动作。用户手填密码时应用不读取页面秘密。真实学校身份、响应契约、导航授权均未访问；安全来源策略未建立前，manual 学校入口保持 unavailable。

## 本机代理与直连对照

2026-10-09 用户提醒本机代理端口为 **7897**，已设置环境变量。只读检查确认本次进程的 `HTTP_PROXY`/`HTTPS_PROXY` 是回环 HTTP 7897，`ALL_PROXY` 是回环 SOCKS5 7897，均无 URL 凭据；`NO_PROXY` 包含 `127.0.0.1` 和 `localhost`。WinINET 手动代理也已启用并指向回环 7897，含本机绕过设置，未配置 PAC。没有打印其他环境值或完整代理配置。原生 `TcpClient` 连接 `127.0.0.1:7897` 成功，未发送应用字节；这只证明 TCP 可达，不证明 HTTP/SOCKS 转发或远端出口可用。沙箱内监听器清点返回零，不能用来认定本机代理没有启动。

为复核代理影响，主代理在新的原生 PowerShell 实验进程中清空四个通用代理变量，仅向其后代设置 `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--no-proxy-server`，用全新 UDF 重跑 `worker-guard`。没有修改 User/Machine 环境变量、系统代理、7897 服务或旧浏览器资产。按实验根与创建时间限定进程清点，实际观察到三个新浏览器根进程均携带该参数；只保留数量和布尔结果，不保存命令行。

结果见 [代理对照元数据](evidence-proxy-control.json)和[直连运行证据](evidence-worker-guard-direct.json)：**116 pass / 2 fail / 6 info / 2 not_run**，对照、guard、guard 重启仍各收到 **4 个回环 UDP 包**，排空和分区删除通过，`deletePending=false`。与原独立复跑一致，说明显式 HTTP/SOCKS 代理配置不是这个 WebRTC 回环漏拦反例的必要条件；V-02 的失败结论保留。`--no-proxy-server` 仅用于诊断对照，不作为产品安全策略。

补验收尾还发现早期完整套件因异常在清理前结束，留下一个合成 UDF 和一个空分区目录。因此此前“所有实验分区已删除”的概括不准确。本次核对该轮已有 `BrowserProcessExited` 排空结果、当前原生进程不存在、目录规范化和排他所有权，逐层拒绝 reparse 后删除两个明确的实验分区；原失败 JSON 未改，未读取浏览器文件内容。回收事实已追加到代理对照元数据。这是实验残留的受控回收，不能用来证明产品的自动故障恢复。

本次没有测透明代理/TUN、远端 DNS/出口、7897 转发行为或学校的代理/直连兼容性。后续真实来源验证须分别记录环境变量、系统代理及候选客户端的实际路由，不能仅凭变量存在推定 WebView2、HTTP 客户端和外部调研工具使用同一路径。若出现超时、网关验证或重定向，先区分网络路径问题与来源契约问题，再判断架构能力。

## 原生 Connection-Allowlist 候选

2026-10-09 新增独立 `connection-allowlist` 变体。它使用全新 DNR+CSP 对照和另一个全新 CAL 分区，再由独立进程重开 CAL 分区；不改变 `all`、`dnr`、`worker-guard` 的规则含义，不覆盖既有 JSON。CAL 输出默认采用时间戳，指定已存在的输出路径会拒绝执行。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File verification/windows/run.ps1 -Variant connection-allowlist -EvidencePath "E:\107\main\verification\windows\evidence-connection-allowlist-independent-new.json"
```

可分别运行 `-Variant connection-allowlist-minimal` 的单主文档 RTC/服务端直接 CAL 对照、`-Variant connection-allowlist-minimal-navigation` 的第二个普通主文档 RTC 对照，以及 `-Variant connection-allowlist-https` 的相同 HTTPS URL 上 GET 和 WebTransport CONNECT 对照。完整 CAL 套件因每个上下文采用独立 browser child/profile，suite 上限为 300 秒；每个 child 仍为 45 秒。helpers Hidden，宿主离屏；不设置启用 CAL 的 feature flag、不改变 7897、系统代理或系统证书信任。

初步实际结果见 [RTC 最小 proof](evidence-connection-allowlist-rtc-proof.json)：Runtime **154.0.4258.62** 无额外 WebView2 参数时，DNR+CSP 主文档对照实际收到 **4** 个 STUN UDP 包；DNR 静态 `set Connection-Allowlist: ("http://127.0.0.1:<port>/*"); redirects=block; webrtc=block` 的主文档首次及跨进程重启各收到 **0** 包。各轮 constructor、dataChannel、offer/local-description 均完成，正常允许 HTTP GET、静态扩展提前启用、排空与分区真删除通过，退出 0。这个结果仅证明所测单主文档的一次 RTC，不构成完整出站安全结论。

[服务端与注入方式的最小复核](evidence-connection-allowlist-minimal-injected-and-direct.json)再次得到 **21 pass / 5 info / 1 not_run**、退出 0：reference 4 个 UDP 包；DNR 注入和服务端直接发送相同 CAL 各自首次/重启 0 包，constructor、offer/local-description 均实际完成。该轮无 Worker/frame/WT 构造，三个 profile 排空并物理删除。它排除了“DNR 注入本身必然使 RTC 崩溃”的解释，保留所测页面组合的崩溃缺口。

[仅增加普通同源第二导航的最小反例](evidence-connection-allowlist-minimal-inert-navigation.json)得到 **18 pass / 12 fail / 5 info / 1 not_run**。reference 从 inert `/storage` 导航到同样 inert `/landing` 后第一次构造 RTC，实际收到 4 个 STUN 包并正常完成。DNR 注入 CAL 和服务端直接发送 CAL 的首次/重启，两个文档携带相同策略、五组普通第二导航全部成功，但随后这一个 `RTCPeerConnection` 均导致 `RenderProcessExited / Crashed`、脚本未完成、0 包检查判 fail。没有 frame、worker、WT 或先前 RTC，所以复杂 scaffold 并非必要条件。首次文档 RTC 通过，后续文档 RTC 失败是两项并列事实；binder 或其他内部生命周期根因仍未知。三个 profile 排空后真删除，deletePending=false。

[主代理独立导航复跑](evidence-connection-allowlist-navigation-independent.json)结果完全一致：**18 pass / 12 fail / 5 info / 1 not_run**、退出 **1**；reference 实际 4 包且完成，注入/直接 CAL 两种方式各自首次/重启四组均为原生 renderer 崩溃、脚本 Timeout 和未完成接收检查失败。所有 `close_and_drain`、物理 cleanup 均通过，deletePending=false。该结果拒绝当前 Runtime 的完整 CAL 出站候选，不通过更多 fixture 绕开真实的后续文档失败。

[分上下文实测](evidence-connection-allowlist-independent-contexts.json)暴露新的 Runtime 可用性失败。main、普通 HTTP frame、srcdoc、about:blank、blob 分别在独立子进程尝试网络，未 CAL 的 DNR+CSP 对照每个上下文都实际收到 **4** 个 STUN UDP 包、**1** 个 TURN TCP 连接、**5** 个 WebTransport 初始 QUIC UDP 包。CAL 首次/重启各上下文均为 0 接收，但 `RTCPeerConnection` 停在固定 `beforeConstructor` 阶段，收到原生 `ProcessFailed: RenderProcessExited / Crashed`，没有完成 RTC 执行。因此这些零接收全部记 **fail**，不当作阻断通过；该轮 306 pass / 40 fail / 41 info / 1 not_run，15 个 `/storage → /guard` 普通连续导航均通过，各浏览器排空后十个 UDF 真删除。该早期 JSON 将 ProcessFailed 记为 info，仍有相关执行/接收失败；当前源码直接将 ProcessFailed 记 fail。

此前定位轮证明普通第二导航本身可完成，不能据此排除其后 RTC 的生命周期影响；最新 inert 第二文档实验才证明复杂 scaffold 非必要条件。其他窄对照中，取消 WT 的轮次仍挂；仅运行原 WorkerGuard 页面时正常导航和 worker 禁止通过；仅 STUN parser 仍挂；新 CAL receiver 全换为专用后台线程仍挂；延到 load 后仍挂；移除服务端宽 CAL 仍挂。不能把最先触发的 srcdoc 误认为仅 srcdoc 失败，独立上下文实测显示所测组合中主文档同样会崩溃。固定阶段消息和已知路径的响应写出计数只用于合成定位，未读取 crash dump、诊断文件或认证资产。

原失败全部保留：`evidence-connection-allowlist-five-contexts-initial.json`、`-five-contexts-first-navigation.json`、`-five-contexts-no-server-header.json`、`-navigation-diagnostic.json`、`-navigation-without-wt.json`、`-workers-only-diagnostic.json`、`-stun-only-diagnostic.json`、`-dedicated-listeners-diagnostic.json`、`-after-load-diagnostic.json`。其中临时关闭服务端宽 CAL 的定位轮次，其早期 `CAL_wide_header_fixture` 文案未同步变量；实际初始/first-navigation 两轮使用宽 CAL，no-server-header、navigation-diagnostic、navigation-without-wt、workers-only、stun-only、dedicated-listeners、after-load 均没有服务端 CAL。后续源码按实际变量记录，此处更正范围，不改原证据。

TCP TURN receiver **只 accept 计数、从不读取任何字节**；假用户名/密码不打印。UDP receiver 只计数，立即清零并丢弃 datagram，没有解析、保存或打印。worker guard 和服务器原 `img-src 'none'` 继续测试；正常 GET 阳性、执行完成和接收器无故障是零接收判定的前提。

CAL 本身不限制 HTTP 方法。最初 HTTP-only CAL 的 WT 零流量仅说明 HTTPS 目标不在许可中；生产允许 HTTPS 时不能据此声称 WebTransport 被禁止。新增 HTTPS fixture 为相同精确 `https://127.0.0.1:<port>/query` 提供 GET 与 HTTP/3 WebTransport，reference 明确允许 CONNECT，guard 在 GET allowance 之上加入不依赖 `resourceTypes` 的 CONNECT block。GET 只在该精确本机 URL 和 DER SHA256 证书匹配时经 `ServerCertificateErrorDetected` 放行，WT 使用 `serverCertificateHashes`，不修改全局 trust。所用 Python 为 Conda `basic310`，aioquic 依赖位于忽略目录；fixture 仅输出计数与安全异常类型。

[HTTPS/CONNECT 实测及 fixture 故障](evidence-connection-allowlist-https-fault-types.json)：五个独立上下文的 reference 每轮 **GET=1、QUIC UDP=8、WT CONNECT=1、固定 datagram echo=1**，页面 native ready/echo 布尔结果阳性。guard 首次/重启各 **GET=1、UDP=0、CONNECT=0、echo=0**，native WebTransport 拒绝，普通 HTTPS GET 仍可用。这证明所测同一允许 HTTPS URL 的方法规则有效；但每轮 fixture 同时报告 `ConnectionResetError`，其 stop 回复为已清理后进程退出码未满足 0，所以这些接收器与 shutdown 检查仍严格判 fail，不能作为最终无故障的通过证据。该轮 **91 pass / 16 fail / 16 info / 1 not_run**，15 个 browser child 全部排空，十个 HTTPS UDF 真删除，deletePending=false。`-https-control-fixed.json` 是同样网络行为但当时只记录异常数的先一轮；不覆盖失败。

[fixture 修复后的回归](evidence-connection-allowlist-https-fixture-regression.json)已确认 stop 正常退出 0、所有分区排空与真删除完成；同 URL 网络行为保持一致。但该轮 15 个 case 中 13 个仍报告 `ConnectionResetError`，当时尚待 fixture 对已接受 HTTPS 连接的读/关闭阶段做准确处理。该轮 **93 pass / 14 fail / 16 info / 1 not_run**：14 个失败均为接收器故障或对应无故障 reference 阳性未建立，不能忽略。当前代码要求每个 guard 零接收具有对应上下文/通道的无故障、真实未 guard 接收阳性，不允许以 API 存在或仅等待后为零来通过。

随后主代理接手最终集成。自有 HTTPS protocol 主动消费 close Future 及严格关流后，[第一次独立轮](evidence-connection-allowlist-https-independent.json)仍失败；[固定类型诊断轮](evidence-connection-allowlist-https-close-context.json)得到 91 pass / 16 fail / 31 info / 1 not_run。唯一异常上下文为 Python 3.10 的 `asyncio.proactor_events._ProactorSocketTransport` 回调及其 `asyncio.sslproto.SSLProtocol`，并非页面响应内容。依据本机 Python 标准库实现，将仅此 socket 合成服务切换为标准 `WindowsSelectorEventLoopPolicy`，没有把这个异常全局忽略，也没有修改 WebView2 规则、代理或产品实现。

**最终 HTTPS/CONNECT 独立验收通过**，见 [Selector 轮证据](evidence-connection-allowlist-https-selector-independent.json)：**107 pass / 0 fail / 31 info / 1 not_run，退出码 0**。main、普通 frame、srcdoc、about:blank、blob 各自 reference 为 **GET=1、QUIC UDP=7、WT CONNECT=1、固定 echo=1**；guard 首次及跨进程重启各为 **GET=1、UDP=0、CONNECT=0、echo=0**，有原生构造/拒绝结果及同上下文无故障 reference。全部 fault 数为 0；停止退出 0、stderr 非空行数 0 且管道已排空；15 个 browser child 排空、十个合成 UDF 真删除，deletePending=false。只采纳所测同 URL WebTransport CONNECT 的能力，不以此关闭其他出站通道。

主代理另验合成服务的证书指纹、TLS 拒绝后 GET、snapshot/reset、stdin 保持打开时 stop、EOF、重复控制字段拒绝；最终三组通过、stderr 空、临时证书/私钥无残留。故障分类的五个反例确认自有 HTTPS reset 可消费，其他 protocol/关流错误及不相关 reset 保留；旧端口连接探针超时未当作释放证据，另用停止后 TCP/UDP 重绑定确认。独立验收元数据及源码指纹见[续验记录](../evidence-continuation-review.json)。当前所有 `.runtime` 合成分区及临时凭据、已知实验 helper 的原生清点数量均为 0。

`evidence-connection-allowlist-with-https-connect.json` 与 `-https-initial.json` 记录首次 C# fixture 客户端把 reset/snapshot 回复的 `event=command` 误按请求名校验而停止。已修正客户端；这两轮异常发生在第一 TLS browser child 启动之前，只留下两对未创建 UDF 的 HTTPS profile 容器。按原随机 run 根取得所有权、验证固定目录无 UDF、逐层拒绝 reparse 后已物理回收，追加证据为 [回收一](evidence-connection-allowlist-startup-cleanup-one.json)和[回收二](evidence-connection-allowlist-startup-cleanup-two.json)。原失败 JSON 的 deletePending=true 保留，不回写为成功。

CAL 静态 `set` 尝试覆盖服务端宽 CAL 是合成实验设定，**不是可直接应用到真实来源的生产策略**。宽 CAL fixture 已安排，但对应 RTC 构造崩溃使其零接收未形成正常执行的覆盖通过证据。CAL 不像多 CSP 自动取交集；来源已有更严 CAL 时，不得用 `set` 放宽。重定向许可、已有响应策略的保守处理、真实站点 worker 依赖及来源兼容性由主代理另行裁决。没有学校访问、真实授权、真实秘密或 report-to 外发配置；当前仍不关闭 V-02 或开启真实学校入口。

## RTC 导航崩溃根因与运行时准入（2026-10-09）

用户要求确定并修复问题、询问 Astra。本次主代理 Sol / xhigh 修改和验收工具，Astra / xhigh 只读分析官方源码并复核修订。**根因已确定；当前 WebView2 154 的引擎故障仍未修复，不能宣布浏览器候选通过。**

新增[退出码诊断](evidence-connection-allowlist-rtc-exit-diagnostic.json)：两个无脚本文档 `/storage` → `/landing` 后，DNR 注入 CAL 与服务端直接 CAL 的首次、重启四组都为 `RenderProcessExited / Crashed / exitCode=3`；未加 CAL 的对照完成 RTC 并收 4 个 STUN UDP 包。没有读取 crash dump、诊断文件、请求正文或会话资产。Chromium [退出码定义](https://chromium.googlesource.com/chromium/src.git/+/refs/heads/main/content/public/common/result_codes.h)将 3 明确对应到 bad-message 终止。

官方 [CL 8485457](https://chromium-review.googlesource.com/c/chromium/src/+/8485457) / [精确修复提交](https://chromium.googlesource.com/chromium/src/+/46fcf3faed9db394de7046a100301f64c2842f0e)已经说明同一缺陷：`DidCommitNavigation` 重建接口 binder 表早于新文档策略容器安装，旧代码读取前一文档的 CAL；被禁止的两个 WebRTC binder 未注册，随后原生 RTC 请求缺失接口使 renderer 被终止。修复是在请求时读取当前策略，并始终提供 `NoOpP2PSocketManager` / `NoOpMdnsResponder`，以正常失败回复维持接口生命周期。该提交于 2026-10-08 17:30:59 UTC 合入 Chromium main，当时 Chromium 为 157.0.8094.0；这不是已安装 WebView2 的版本证明。

首文档不崩溃也有对应解释：[M154 renderer RTC 实现](https://chromium.googlesource.com/chromium/src/+/refs/branch-heads/8037/third_party/blink/renderer/modules/peerconnection/rtc_peer_connection.cc)会按当前 CAL 过滤 ICE servers；但 browser 注册 binder 时仍看到初始空文档，接口存在，因此构造和 offer 可以结束而 STUN 为零。后续文档才触发接口缺失。重建 controller 无法修复继承 CAL 的 `about:blank/srcdoc` 子文档，未采用为产品绕法；禁用 CAL 或 JS 替换 RTC 也不符合约束。

截至本次查询，[微软官方产品目录](https://edgeupdates.microsoft.com/api/products?view=enterprise)提供的 Stable 155.0.4283.45、Beta 156.0.4314.8、Dev 157.0.4322.0 都没有包含此补丁的证据；未找到 M154 回补记录。[官方 FixedVersion 下载](https://developer.microsoft.com/en-us/microsoft-edge/webview2/)最新为 155.0.4283.45。[Canary 目录](https://edgeupdates.microsoft.com/api/products)为 157.0.4327.0 但没有离线 artifacts；从官方页面脚本取得的 [Canary 链接](https://go.microsoft.com/fwlink/?linkid=2084706&Channel=Canary&language=en-us&Consent=0)实际返回约 1.8 MB 在线安装器。没有执行它、安装系统浏览器或下载不明镜像；未找到可在工作区隔离验证且已证明含补丁的微软运行时。

本次已修复工具侧处理：收到原生故障后，导航和脚本等待立即结束，记录 `NativeBrowserProcessFailureException`；不再用脚本超时掩盖已知进程故障。Dispose 后仍独立等待 `BrowserProcessExited`，排空失败不能报清理成功。增加[运行时资格脚本](qualify-runtime.ps1)，按后续导航最小反例 → 首文档最小实验 → 完整 CAL 套件依次验收；完整套件包含五类上下文的 RTC/Worker 和真实 HTTPS/WebTransport 收据。任一失败、缺必要阳性、混合运行时版本或未完成删除都阻止资格通过，并将后续阶段标记为未执行。它只是合成回归门禁，不自动开启学校入口或关闭 V-02。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File verification/windows/qualify-runtime.ps1 -EvidencePath "E:\107\main\verification\windows\evidence-runtime-next.json"
```

未来隔离候选可向 `run.ps1` 或 `qualify-runtime.ps1` 同时传 `-BrowserExecutableFolder` 与 `-ExpectedRuntimeVersion`。只接受 `verification/.runtime/engine-candidates` 下无 reparse 祖先、版本匹配且具有有效 Microsoft Authenticode 签名的运行时；启动后再次核对实际 exe 的精确路径和浏览器版本。选择只写入自有 helper 的子进程环境，不改变系统安装、用户代理或持久 WebView2 设置。当前没有该候选，所以签名候选的实际启动及整个资格通过分支尚未执行，版本号不能代替回归。

[最终门禁](evidence-runtime-qualification-154-final.json)正确得到 `qualified=false`、退出 1；其[后续导航子证据](evidence-runtime-qualification-154-final-connection-allowlist-minimal-navigation.json)为 **18 pass / 12 fail / 5 info / 1 not_run**。四组原生故障均立即成为明确失败，零 UDP 因未完成执行仍失败，五个 child 排空、三个分区物理删除，`deletePending=false`。门禁保存源码及子证据 SHA-256；早一版门禁和退出码诊断均保留。正常首文档[最终回归](evidence-rtc-crash-handler-first-document-final.json)为 **21 pass / 0 fail / 5 info / 1 not_run，退出 0**，参考 STUN 为 4、四组 CAL 为 0 且都完整执行、清理完成。参数缺配、工作区外候选共四个启动前反例均拒绝且未生成实验资产；编译和 PowerShell 语法检查通过。

Astra 对最终三个源码的只读复核未发现阻断问题；指纹与最终门禁所记录的一致。主代理核对源码/子证据指纹、46 份 JSON、165 处当前本地链接及 15 份受保护历史文档均通过。2026-10-09T10:01:46Z 原生清点：合成分区、临时证书/私钥和自有 WindowsProbe helper 均为 0；HTTP/HTTPS/ALL 代理仍指向无凭据的回环 7897，未修改日常设置。模型及 HTTPS fixture 源码本次未修改，既有验收指纹没有回写。

真正消除引擎故障仍需取得包含上游修复的 WebView2 候选并跑完上述门禁；即使通过，CAL 原政策保守处理、重定向边界和学校兼容性仍须分别证明。当前真实来源入口、V-01/V-02/V-03、整体冻结和产品 M0 保持未放行。

## 依据

- 本机 SDK XML：`CoreWebView2.AddWebResourceRequestedFilter` 三参数重载、`RequestedSourceKind`、`BrowserProcessExited`、`CoreWebView2Profile.AddBrowserExtensionAsync`、`GetBrowserExtensionsAsync`、`AreBrowserExtensionsEnabled`。
- [Win32 GetFinalPathNameByHandle](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfinalpathnamebyhandlea)。
- [WebView2 可见性问题的原始报告](https://github.com/MicrosoftEdge/WebView2Feedback/issues/4697)：仅提供定位线索；本地结果独立记录，不以该报告代替测试。
- [Chrome DevTools Protocol Network](https://chromedevtools.github.io/devtools-protocol/tot/Network/)：`setBlockedURLs` 是实验性命令，`urls` 已标 deprecated；无稳定覆盖承诺。
- [Chrome declarativeNetRequest](https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest)：静态规则、优先级、方法限制和无需读取请求内容的规则能力。
- [WebView2 浏览器参数](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/webview-features-flags)：实验用 `no-proxy-server` 及代理参数；这些参数不能作为长期产品能力保证。
- [Chromium 代理行为](https://chromium.googlesource.com/chromium/src/+/HEAD/net/docs/proxy.md)：本机地址的隐式绕过规则，提供对照设计依据；本机实测独立保留。
- [Chrome Connection Allowlist 发布说明](https://developer.chrome.com/blog/connection-allowlist-announcement)：Chrome 152 正式发布，Edge/WebView2 的有效性以本实验实测为准。
- [WICG Connection Allowlists](https://wicg.github.io/connection-allowlists/)：文档 policy container、WebRTC 与重定向参数，已有 CAL 不能按多 CSP 自动合并的语义。
- [Chromium DNR WebTransport browser tests](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/chrome/browser/extensions/api/declarative_net_request/declarative_net_request_browsertest.cc)：CONNECT 方法规则及 WebTransport 本地反例设计依据，不以官方测试代替当前 Runtime 的实测。
