# M1.1 教务入口与导航记录

> 保留发生时的规格、失败、修复和检查；旧“待验/未关闭”不是当前状态。当前范围见 [任务单](../plan.md)，最终结论见 [验收](../acceptance.md)。正文只迁移链接，保留当时叙述。

### M1 范围与首个准备切片（2026-10-09）

用户在 M0 关闭后询问“这是M1的一部分吗，请继续”，授权继续普通 WebView 观测入口与第一条真实来源准备。新 M1 以第一条真实来源的身份/只读契约及本地交接为目标：先交付可观测的 Windows 浏览器基础，用户辅助确认 JW 身份、导航和响应，再定义该来源及正式账号/数据的必要模型，最终接通采集、事务与展示。旧资料的 M1 编号、v7/v8 迁移与完成记录不成为施工要求；当前不迁移旧资产，也不先铺完正式全模型。

本次唯一任务是 **M1.1 普通 WebView 观测入口**，已实现并通过本地自动验收；真实登录与来源契约待用户辅助验证，不代表 M1 完成。

- **目标/范围**：在现有应用增加可见的教务观测窗口，用户手填登录/验证码；本切不核验未知身份、不自动采集/导入学校数据、不读取认证资产或响应正文、不保存密码/Key。M0 演示数据与原用户验收保留。普通页面后台网络及既有策略按 DR-ADR-09 运行，不注入 CAL/全协议扩展、不禁 Worker、不替换 WebRTC。
- **未知项**：初始入口固定 `https://jw.ustc.edu.cn/`；首轮仅登记 JW/Passport，随后真实登录入口失败，公开逐跳检查补核实 ID/Analytics，当前 HTTPS 导航 origins 为 JW/Passport/ID/Analytics，依据及失败另记于下方兼容性修复。登录后身份、业务响应及其他认证分支仍待用户观测。额外真实 origin 须核实后改来源配置，未知跳转拒绝并提示；后台资源不做全协议白名单。
- **接口/不变量**：C1 固定目标/导航策略和页面就绪检查端口；C2 观测与合成作业共用同步取得的单租约，closing/recovery 保持持有；P 登记独立未认领观测分区后才创建浏览器资产，正常退出或崩溃恢复均删除，不作为正式账号分区认领。文档/会话 token 使跨导航和关闭后的检查返回失效；页面就绪不等于身份匹配。关闭、浏览器进程排空与真删除分别确认，未完成拒绝新观测，不报已清理。
- **最小持久化**：P 使用独立文件登记 observation provisional/deletePending，登记只含版本和本切随机分区标识，先 flush 后创建目录。该观测用途不能获得 C3 正式认领许可；启动只调和本应用登记的观测资产，不读会话文件内容、不删除旧工程/系统浏览器资产。正式账号/initial/recovery 许可仍由后续 C3 切片实现。
- **文件归属/依赖顺序**：Sol 定 `core/source` 端口、租约、`jobs` 编排与 `platform` 资产登记/清理、组合根；Sol / high 子代理写 runner 内 WebView2 MethodChannel 和原生保留控制；Luna / max 在契约确定后写 UI/端口测试及合成本机 fixture。独立文件才并行，原生 SDK 作为固定构建依赖恢复，不复制旧工程或 `verification` 源码。只写本 worktree 的 `app/` 和本任务/必要文档入口。
- **验证**：先用全新 loopback 页面自动证明顶层/frame 导航、弹窗、下载、权限、外部协议、跨文档迟到结果拒绝、打开中取消、排空及真删除、重启回收无许可候选，再提供真实窗口。自动测试不访问学校；真实身份/响应只按用户提供的实际证据记载。集成后执行 analyze/test/build；入口自动可用与真实来源通过分开。
- **完成条件**：本机保留控制及资源生命周期实际运行通过，界面能打开/检查就绪/取消清理/重试，M0 回归通过，用户可在可见 JW 窗口自行登录并进行下一阶段观测。未观测到的真实身份/空/分页/错误形状保持未验证；本任务结果仍追加于此，不另建派发包或重复报告。

#### M1.1 实施与检查

普通窗口、固定目标/检查、中文观测面板、全局租约、未认领观测登记及清理已接入 `app/`。登记使用 `.registering` 文件，flush/close 后原子改名为 `.pending`，随后创建 profile；只有对应 profile 与 `.pending` 都不存在的中断 registering 文件可自动移除。启动回收先重连同目录的隐藏空白环境，不导航；未知文件、孤儿目录、损坏封存登记或静态 reparse 均拒绝误删。资产 close 自身不能绕过 C2 drain 清理。

打开期间取消先向 native 发 close，等创建回调完成，再确认排空与删除；原生 RPC 及等待均有 deadline，超时或删除失败保留租约/登记并进入 recovery。旧会话/文档检查失效，页面就绪只表示当前页面加载完成；Passport 页不显示 JW 业务页已就绪。正式身份核验、分区认领许可、凭据保存和采集仍未实现。

**原生控制失败与修复记录**：首轮端到端在 frameDenied 后即刻检查请求数尚为零，随后 popup 阶段发现禁止端口请求数为 1；加入 350ms 收口观察后定位为 frameDenied 的迟到文档请求。此失败保持失败，不把弹窗事件或 FrameNavigationStarting 取消当作零请求证明。修复仅为首个 Navigate 前用 `ICoreWebView2_22` 注册 `DOCUMENT` 资源/`DOCUMENT` 来源过滤，外源导航文档同步替换固定空 403；不读 header/body，不增加 Worker/其他资源或全协议过滤。修复后的独立重跑已经通过全部动作，并证明所测禁止端口请求为零，参见[Microsoft 文档过滤接口](https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2_22?view=webview2-1.0.3967.48)。

独立生命周期复核还指出，单独等待 Browser PID 退出不足以证明子进程及 profile 全部释放。最终排空采用 PID 关联的 `BrowserProcessExited` 事件并保留 environment 到该事件；该事件的[官方语义](https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2environment5?view=webview2-1.0.3967.48)覆盖整组运行时资源释放。最终实现的普通关闭、打开中取消及真实父进程强杀恢复均已复测通过，前一次原生通过只代表当时实现。

**真实中断测试的脚手架失败**：第一次直接再启动 integration 测试 exe 时，它等待 Flutter 的远程测试驱动，30 秒内未打开测试环境；该尝试失败，不算崩溃恢复结果。现使用独立编译的 `tool/observation_crash_host.dart`：只创建隐藏空白 WebView、持有本切登记及目录锁，不导航学校；发布合成 ready 标记后，父测试只强杀自己启动的助手。恢复前确认目录锁已由操作系统释放，但 profile 与 pending 登记仍存在；新协调器重连、确认整组退出后真删除。此真实中断重跑通过。

最终主代理检查（2026-10-09）：

| 检查 | 结果与证据范围 |
|---|---|
| `flutter analyze --no-pub` | 零问题 |
| `flutter test --no-pub` | 83 项通过，含 M0、本切 UI/端口/资产生命周期和 native 消息返回值卫生 |
| `flutter test integration_test/m0_flow_test.dart -d windows --no-pub` | 1 项通过，最新 native 装配下 M0 回归 |
| `flutter test integration_test/observation_flow_test.dart -d windows --no-pub` | 1 项通过，实际普通 WebView 保留控制、禁止端口零请求、同/跨文档 token、真实 WM_CLOSE、打开中取消、登记候选回收及独立父进程强杀恢复 |
| `flutter build windows --no-pub --target=lib/main.dart` | Release 通过；确认结果为应用入口，测试助手另置 build 内 bundle |

测试仅使用新合成本机页面/空白环境及随机目录，不访问学校；未把 SDK 编译通过当作平台通过。WebView2 SDK 构建依赖固定为 `1.0.3967.48`，当前从已安装 NuGet 缓存读取，安装/路径要求见 [app README](../../../../app/README.md)。测试和 helpers 均为本工程新写，未复制旧工程/verification。Sol 完成接口、编排、持久登记、组合及最终实测，Sol / high 完成 native，Luna / max 完成明确的 UI/fixture/测试任务；独立复核发现由 Sol 裁决修复。

文档当前范围的 160 处本地链接、23 处锚点检查通过，07–15 的 9 份历史正文保持不变，`git diff --check` 通过。交付 Release 已启动供用户操作；仅启动主应用未打开学校窗口，实际用户登录仍未执行。

以上为首次自动交付时状态；随后用户的真实尝试及兼容性问题另记如下。JW 身份/响应、空/分页/错误形状仍未执行。五条来源继续 unavailable，V-01/V-02/V-03 及完整 M1 不关闭。本切不声称安全地处置同用户恶意程序持续换文件，也不承诺所有后台协议零外联。

#### M1.1 真实登录入口兼容性修复（2026-10-09）

用户实际打开观测窗口并点击“统一身份认证登录”，报告“什么反应都没有”，并提示其他分支曾遇到重定向/白名单问题。**此次真实入口尝试失败**，此前本机合成通过不覆盖它，不补写登录或身份通过。

主代理经现有网络/代理读取公开未登录页的固定按钮属性与未提交凭据的重定向状态；客户端默认代理核对为 `http://127.0.0.1:7897`，未改全局配置。按钮为同窗口 `/ucas-sso/login` 链接，不含 `target`。只输出 status、origin 及去掉 query/fragment 的路径，不读取认证响应正文、Cookie 或会话文件。实际链为：JW `/ucas-sso/login` → Passport `/login` → ID `/cas/login` → Analytics `/.isg/gateway/sso-init` → ID `/cas/login`。原配置只允许前两个 origin，因此拦截 ID，构成明确的入口兼容性缺陷。该无 Cookie 的只读探查不证明网关完成或真实登录通过；学校[统一身份认证手册](https://id.ustc.edu.cn/doc/)另确认 ID 是官方认证站点。

按用户要求只读参考 main 与 flutter-native 的成熟 JW 导航策略，确认四个精确 HTTPS origins 与本次链吻合；参考还包含认证路径族、HTTP 升级及脱敏诊断。当前切保留已批准的 origin 观测边界和 HTTPS 要求；未观测到 HTTP 降级，不搬旧实现/测试，也不把旧业务路径名单作为新来源契约。完整只读端点及业务路径在后续真实观测中重新定义。

本次任务范围：C1 与 native 的生产列表均固定 JW/Passport/ID/Analytics，仍禁止未知 origin、外部协议及未受控弹窗；每个重定向继续通过同一顶层/frame/文档检查，保留完整跳转参数在 WebView 内，不向 Dart/日志发送 URL、ticket 或 state。Debug loopback 目标仅可含最多四个互异显式端口 origin，Release 不接受该配置。Sol 负责契约/集成与验收，Sol / high 修改 native，Luna / max 修改独立 fixture/测试。

验证范围：新本机合成链业务入口 → 身份页 → 网关 → 身份页，确认非业务 origin 不报告 JW 已就绪、旧文档检查失效、固定入口恢复；另验证允许 origin 返回的未知 origin 重定向在请求前拒绝。原弹窗/权限/下载/外部协议/frame 控制、关闭/取消/中断恢复继续回归。主代理本次检查全部通过：`flutter analyze --no-pub` 零问题；`flutter test --no-pub` 86 项通过；M1 原生端到端 1 项通过（含新增多 origin 链、未知跳转端口零请求与原资源生命周期），M0 原生回归 1 项通过；`flutter build windows --no-pub --target=lib/main.dart` Release 通过，恢复为正式应用入口。历史正文 9 份保持不变，`git diff --check` 通过。旧应用正常关闭后更新；真实登录须用户重试，来源仍 unavailable，不覆盖首次失败或 M0 用户验收。

#### M1.1 登录后复杂跳转补齐（2026-10-09）

用户第二次真实尝试到达统一身份认证表单，但停在“登录中”，随后关闭应用。**此次真实尝试仍失败，具体停顿原因未确认**；没有读取账号、密码、认证请求或浏览器资产，也没有本次现场事件可供追溯。首次入口缺少 ID/Analytics 的修复记录继续保留，不将截图或本机测试写成真实登录通过。

只读参考另外两个 worktree 的成熟机制后，确认当前代码有两类独立缺口：认证文档的 HTTP→HTTPS 转换尚未实现；顶层尝试跳转失败时仍显示旧文档，frame 却绑定最后一次尝试的 navigation，导致旧页面及迟到/嵌套 frame 不能继续使用。旧分支曾将 ID `/.isg/gateway/sso-verify` 列为 HTTP 升级回归，这只是历史线索，不是本次真实登录流量证据。

本次唯一任务范围与完成条件：

- 顶层、frame、DOCUMENT 请求每跳执行同一 origin 边界；仅四个既定学校站点的正常 HTTP 默认端口可转为对应 HTTPS，保留路径与跳转参数，未知站点、异常端口、userinfo、反斜杠和控制字符拒绝。升级失败不得发送原 HTTP 文档请求。不采用 cancel+GET 重发，不读取或改写认证 header/body。
- frame 关联可见文档 epoch，并检查父链和 Destroyed；新文档提交才替换可见世代。失败的未提交导航恢复仍可见页面的 DOM/完成事实，旧检查 token 失效；迟到旧 frame 不影响新文档。
- 提供有上限的类型化诊断，只含动作类型、固定站点类别和协议类别；主窗口显示最近五项，当前会话保留最多二十项。不发送完整 URL、path、query、未知 host 或登录内容；关闭后可查看，下一次会话清空。
- 新 HTTPS loopback fixture 使用独占临时 profile、每次新自签名证书和合成表单/cookie/state。覆盖顶层与 iframe 的 302/303/307/308 多跳、无后续跳转的直达页面、POST 正文、页面 origin、HTTP/禁止端口零请求以及错误证书拒绝。只有 Debug 允许配置公开 PEM，Release 无例外；不安装系统信任或设置全局证书忽略。WebView2 的测试证书决定按 host+证书缓存，不能声明精确端口隔离。
- 本机集成还暴露跨 Dart/Win32 调用读取 last-error 被覆盖，普通目录偶尔误判 unsafeDirectory。将 attributes/create/open 的系统调用及错误捕获置于同一次 C ABI 调用，由 native assets 构建和打包；保留目录排他、reparse 和最终路径检查。测试进程使用独立 CLI bundle，不增加生产动态路径注入或运行时编译。见 [Dart FFI 错误捕获限制](https://github.com/dart-lang/sdk/issues/38832)。

Sol 总负责契约、Dart/P 集成和验收；Sol / high 处理 native 导航与原子 Win32 包装；Luna / max 实现明确的 HTTPS fixture 与 CLI 测试装配；Astra / high 复核 URI/证书/frame 边界和错误捕获方案。只修改本工程及当前记录，不复制旧工程实现或测试，不修改系统代理、学校页面策略和产品范围。

**升级方案对照**：同一真实 WebView2 fixture 中，就地 `request.put_Uri` 与本地 307 都能通过八组“服务端继续重定向到 HTTPS”的流程；仅此不足以证明等价。加入升级后直接返回 200 的端点后，就地改写的顶层检查返回 origin=null，未得到合法 HTTPS 文档身份，**该对照失败**。最终保留同步空 307，让浏览器提交 HTTPS 文档，不发送原 HTTP 请求；不采用读取 POST 后自行重发。最终两个直达场景（含 iframe 与父页面同 origin 的固定布尔检查）及八个多跳场景通过。307 的方法规则见 [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html#name-307-temporary-redirect)。

八组多跳实测：302/303 后浏览器转 GET，307/308 后保留 POST 与合成正文；原始 payload/state 保留，relay/gateway 的合成 cookie 均存在，明文及禁止端口请求数为零。合成 relay 的 Origin 为 null；后续 GET 的 Origin 缺省、POST 为 null，未人为补写。此为本机浏览器分类结果，不证明学校真实 Cookie、CSRF 或代理下的登录接受结果；必要真实来源契约仍待用户观测。

**平台及测试故障记录**：最初原生检查因正常目录被误报 unsafeDirectory 失败，保留栈后定位 create/attributes 错误码读取；预先解析函数或单独将 GetLastError 设 leaf 曾有一次通过，随后仍复现，不作为可靠修复。最终三项 C 包装在同一次调用中捕获错误，恢复严格分类。CLI 构建又暴露本机 Visual Studio 中文 JSON 被错误解码；hook 在启动器未给编译器配置时，显式 UTF-8 读取 vswhere 安装路径与工具版本元数据，通过公开 CodeAssetExtension API配置编译器。最终真实目录/跨进程及 fresh native 回归通过，无 SDK 缓存修改或生产运行时编译。Debug TLS 处理另补“证书失败完成事件先于 pin 回调”的时序，错误 PEM 反例确实拒绝；证书允许缓存按 host+证书，成功完成后缩短缓存寿命不等于端口隔离，Release 无该路径。

最终主代理检查（2026-10-09）：

| 检查 | 结果与证据范围 |
|---|---|
| `flutter analyze --no-pub` | 零问题，含 native hook |
| `flutter test --no-pub` | 94 项通过，含真实目录/跨进程、M0 事务恢复、HTTPS fixture、类型化诊断、迟到事件及 UI |
| `flutter test integration_test/auth_redirect_flow_test.dart -d windows --no-pub` | 1 项通过；10 组顶层/iframe 直达或多跳场景、方法/正文/state、HTTPS 页面身份、HTTP 零请求及错误证书拒绝 |
| `flutter test integration_test/observation_flow_test.dart -d windows --no-pub` | 1 项通过；未知跳转后无需重载仍可操作原/新/嵌套 frame，旧 token 失效；原控制、关闭/取消/排空和真实测试父进程强杀恢复 |
| `flutter test integration_test/m0_flow_test.dart -d windows --no-pub` | 1 项通过；最新 native assets 装配下 M0 原生用户行为回归 |
| `flutter build windows --no-pub --target=lib/main.dart` | Release 通过，正式主应用入口与目录 DLL 随 bundle 打包；首次权限审核超时未执行命令，重试成功 |

文档本次检查：当前入口及 00–15、app/验证说明的 94 处本地链接、20 处锚点通过；07–15 的 9 份历史正文保持不变，`git diff --check` 通过。新版正式应用已重新启动，未自动打开学校窗口或输入凭据。

两次用户失败均保留，真实登录及业务身份/只读响应仍未验收，五条来源继续 unavailable；不关闭完整 M1 或 V-01/V-03，不覆盖 M0 用户验收。交付应用供用户重新操作；若仍停顿，以主窗口固定类型诊断继续定位，不请求账号、密码、验证码、原始响应或 session 文件。

#### 用户导航重试结果（2026-10-09）

上述为修复交付时状态。用户随后报告：“能正常打开教务和考试界面，但是app未采集”。本次真实人工结果登记为**教务及考试界面导航可达**，保留前两次失败，不扩大为所有认证动作或所有导航场景通过。当前观测入口仅检查页面就绪，尚未实现真实课表/考试采集、解析和导入，因此未采集符合本切范围。可信业务身份、只读响应与完整性契约仍待验证；五条来源继续 unavailable，完整 M1 及 V-01/V-03 不关闭。下一切片需核验当前会话的业务身份，定义并验证教务只读数据契约，再接入采集和事务导入。
