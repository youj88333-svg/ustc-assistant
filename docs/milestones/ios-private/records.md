# iOS 私用调研记录

## 2026-10-26：无 Mac 路线、工程边界与 Widget

用户要求针对无 macOS、仅个人使用的目标寻找免费方便的 iOS 方案，随后明确 iPhone 15 Pro / 最新 iOS 27，并提醒遵循项目工作流、询问 Widget。范围是调研与完整方案，未批准实施。唯一任务单见[方案](plan.md)。

Sol 主代理统筹并分别安排三个 GPT-6 Luna / max 只读任务：构建/签名/安装、当前工程平台缺口、iOS 系统能力。安装研究任务另接续 Widget/App Groups 核查。主代理复核当前源码和关键官方资料，未把代理声明当作构建或目标机验收；没有使用旧 Android 研究中“尚无 Android/平台工厂”的过时陈述。

根确认：工作区起点 main 3ee512d 且干净；没有 app/ios，当前工厂只选择 Windows/Android；本机 Flutter 元数据为3.44.5、Dart3.12.2、stable、修订f94f4fc76b4d74543ed9b085bbd75341ef65de22。hook只构建Windows/Android所有权库，Linux实现使用O_PATH。Drift及现有业务可复用，但不能宣称Darwin编译、iOS所有权或插件运行已成立。

关键公开资料经检索：Flutter设备构建与未签名IPA需分开；Xcode27的macOS要求、Flutter后续Xcode27/iOS27修复；GitHub公有标准runner/私有额度与artifact读取规则；Codemagic个人500 macOS M2分钟；Sideloadly官网iOS27+声明、7天/3应用/USB和Wi-Fi刷新条件；Apple Personal Team及WidgetKit/App Groups/通知/后台文档。出处集中在任务单相应结论旁，检索日期2026-10-26。

GitHub连接器对本仓库搜索返回422；匿名官方API返回403，进一步核对公开错误为共享出口配额耗尽、X-RateLimit-Remaining=0。不能据此断言origin公有或私有。没有读取GCM秘密或改变仓库可见性，构建费用/产物访问空间留待I0核对。网页取页工具对本仓库页cache miss也未作为私有证明。

Widget核查区分了三种证据：Apple支持共享容器与系统时间线；AltStore自身有Widget/App Groups实现、iPASide作者报告过免费账号共享组可用；但没有取得Sideloadly+iOS27对本项目双目标共享/重签的证据。SideStore公开问题还显示扩展组名重映射可能失败。因此不按旧印象强行判定必须付费，也不把签名成功当作共享成功；建议I0先用合成值检验。刷新预算、通知容量/覆盖和profile到期后的行为继续列为待验证，不从旧API的64条数字推断iOS27的保证。

本轮未创建iOS工程/Widget目标或workflow、未配置云账号/计费/Apple签名、未安装工具/IPA、未连接手机、未操作麦克风/权限、未访问真实学校或读取正式业务/浏览器资产。自动构建/测试和目标机结果均尚无；本轮只对文档运行检查，不重复Flutter或真实采集。

根文档检查通过：182份Markdown、1424个本地链接，归档清单按规则核验；`git diff --check`通过。方案与研究记录及导航分开保存，不向设计正文追加施工流水；批准前保持iOS未实现状态。

## 2026-10-26：GitHub找回期间的替代入口

用户补充GitHub账号正在申诉找回，担心I0无法进行。根对这个明确的小范围依赖修订直接调查：Codemagic官方支持邮箱验证码注册，Personal账号每月500分钟macOS M2；Other/HTTPS接入支持Public repository，软件清单包含M2及Xcode27.1。出处已补入唯一任务单。I0首选据此改为邮箱Codemagic加校内公开HTTPS源，不需要GitHub恢复，也不通过另一个账号规避找回流程。

本机关闭凭据助手及Git交互后，匿名`git ls-remote https://git.ustc.edu.cn/demo233/107_ustc_assistant.git refs/heads/main`成功读回9cfbfc71f5ecafa3b5e3abf9a51ac3ac00185645。这是本机HTTPS读取证据，不是Codemagic主机的网络或构建证据。没有注册Codemagic、配置应用/计费、上传Token/SSH私钥、触发iOS构建或尝试GitHub登录/推送。本次文档仅同步校内，GitHub镜像待账号恢复后核对补齐；实施仍待用户批准。
