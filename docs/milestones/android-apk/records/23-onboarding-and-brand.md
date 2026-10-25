# 首次设置与图标

日期：2026-10-25。任务规格见本阶段任务单“A8首次设置与品牌准备”。用户授权直接实施四段引导和复用main图标；A7/实机未观察项继续开放。

## 研究与选择

使用已安装ui-ux-pro-max及flutter-build-responsive-layout：沿用项目已批准白色平面风格、窄表单和48dp触控。UX搜索建议跳过/返回，Flutter表单建议按提交验证并为键盘滚动。设计系统搜索中的Flat Design可用；Product Demo营销页结构、新字体及配色不适合本工程，因此不采用，不新增设计系统来源。

参考Android官方[权限请求](https://developer.android.com/training/permissions/requesting)：在相关功能处主动请求，拒绝可继续，不在进入引导时弹全部权限；应用本地提醒开关与OS通知许可分开。[自适应图标](https://developer.android.com/develop/ui/compose/system/icon_design_adaptive)使用108dp图层与66dp安全区，保留完整原图，不重画。

## 图标来源

main提交e1b7ed32238e4fa2dba3d4a99855b2cf2268bb13仍是默认图标；用户意图所指自定义图标在E:\107的main工作区中（PNG未跟踪、ICO已修改），本切只读复制这两项，未修改该工作区。1024方形PNG的SHA256为a89623e9364cd95fe916ff0764407bf45ac11932a7eafc14bda47cb5175bbd7c，Windows ICO为40cf4b0e5d9fd6354b8fe747d2724bd984172ec75e8cfa0f56a7ae4d0a908c6d。根实际查看PNG；Android各密度缩放与自适应安全区采用此原图，系统背景白色，不新增AI图像或下载素材。

## 实施与检查

Sol负责schema20、进度控制器、四页装配、根生命周期与最终检查；Luna/max分别完成模型专页模式、来源专页和授权专页，图标机械准备也由Luna/max完成。子代理未运行Flutter或真实服务；下述检查由根实际执行。

- C3仅新增首次设置进度表。新库active/account，旧schema1–19迁移done；owner/resetEpoch/revision与维护屏障拒绝旧写，完整重置回到账号页，清日程保留进度。导航表不存账号、密码、Key或授权；实际同步、模型验证和逐项许可仍由原领域端口负责。
- C5账号页暂存候选与可选密码，进入模型/稍后/销毁时清学校草稿；没有独立应用账号或“填写即登录”断言。同步页主动分别启动原JW/Young链路，显示成功回执、空集、人工挑战、学期选择、取消和恢复；无候选且尚未绑定时提示回上一步。二课默认上次成功范围或当前北京月，日期选择器校验最多62天。源在途或恢复不允许跳页遗留。
- 模型页复用固定提供方、隐蔽Key、出站同意、主动取模型与验证保存；不回填已存Key，切服务清草稿，进入不取模型。授权页独立保存提醒、晨报、评课、私人读取和日常操作，保留两槽、隐私显示和另一许可值；系统许可只从按钮请求，拒绝可继续。完成引导不隐式写授权。
- 根在读取/进行引导时暂停晨报与每日二课自动准入，显式业务操作仍走原仲裁。稍后/完成后恢复原策略，不更改原持久开关或尝试预算。升级用户不强制进入；设置按钮继续未完成步骤，已完成者重开从账号页开始。

### 已发现并修正

源专页最初在任意父重建时作废generation和pending，根审查修正为仅控制器更换时重置，并用父setState/在途Completer检查不能提前解锁。原生Windows旅程又捕获授权页持续刷新：Dart StreamController.stream每次可返回不同但相等的包装器，原identity比较把普通重建当安装更换。改为流的相等比较及订阅源守卫，真正更换流只替换监听，不反复重读本地偏好；父组件使用真实broadcast.stream的新包装器补验。旧Windows失败日志保留为`app/build/android-onboarding/windows-stream-red.txt`；修正后整个重启/重置旅程通过。

首次全套共享检查中有三项旧版本夹具仍带schema20导航表或把新增表当旧资料，根修正明确合成副本的降级构造与旧表快照范围；不放宽生产迁移，旧业务/凭据/回执保留断言仍在。原生截图等待也改为正确的runAsync所有权与有界状态等待。旧业务原生旅程显式构造“已完成设置”；完整重置先确认新引导，再续验原Agent数据/恢复链路，不能把新行为错记为数据丢失。

### 根检查进度

| 检查 | 实际结果与边界 |
|---|---|
| C3首次设置/迁移专项 | 6项通过：新建/续行、schema19旧用户保留、迁移碰撞回滚重试、并发旧写、清日程/重置/维护失败、所有权丢失与损坏状态 |
| 四页合成界面 | 最终31项通过；全跳过零学校/模型调用与零授权写入，独立许可/失败、在途导航、密码清理、日期/学期与挑战取消恢复；已绑定账号不可被新候选替换，恢复期间可导出日志；模型操作有独立取消入口，800×360横屏/180px键盘/2倍文字仍可达；320/360/412及宽屏、1.5/2.0字号检查 |
| 共享全套 | 最终`flutter test --no-pub --reporter expanded`：1654项通过、1项平台跳过。初次旧夹具失败、前一轮1650项通过和最终结果保留`shared-initial.txt`、`shared.txt`、`shared-final.txt`；没有真实服务请求 |
| 静态检查 | `flutter analyze --no-pub`无问题；后续原生测试夹具更新后随相关检查复核 |
| Windows新引导原生 | 2项旅程通过：新建、全跳过/稍后、重启、设置继续、完成后重启与完整重置；启用晨报时引导内零网络入口，退出后才在拒绝联网的拦截器中尝试，不实际访问来源。根查看四页412px及账号1100px的实际截图 |
| Windows受影响原生 | Agent五组、设置维护三组通过。新旧引导契约的断言已对应修订，原配置/业务/历史/撤销/维护及失败恢复检查保留 |
| Android真实引擎合成 | 独立API34（ustc_android_a0_api34，emulator-5588，ADB5038）首次设置两组与A1六组通过：私有目录、排他/锁替换、事务回滚、未来schema拒绝、保留与激活恢复；首次设置、重启/重置与自动晨报门禁。不是目标手机或真实服务验收 |
| 图标 | 根核对main原件与副本SHA；basic310/Pillow验证全部五密度逐像素机械缩放、自适应432/264安全区与白背景、ICO九尺寸通过；不改main |

## 本地交付

设计提交d885cc4，主要工程提交91f0b0a；收尾恢复日志入口和横屏/键盘布局提交441a68b99ea713eb891b269dc0210a1c41b63f77，之后冻结工程并构建。普通x86_64通过lint、AndroidTest APK及生产Manifest检查；最终双ABI均由441a68b构建并核验签名、唯一ABI、普通入口、工程标记、图标及固定脚本/语音许可，排除测试入口与生命周期探针。校验器及manifest位于E盘忽略目录`app/build/android-onboarding`，构建产物不入Git。

| 文件（app/build/android-onboarding/artifacts内） | bytes | SHA256 |
|---|---:|---|
| USTC-Assistant-Android-QA4024-x86_64.apk | 293625010 | 6863b9f77f28ee3f3f2b82d199e42442e4cfb13ffd46069c9825b590d3f115fe |
| USTC-Assistant-Android-QA2024-arm64-v8a.apk | 281727148 | 6d50e1fe566d29ec40e4c33e3922f17af3872501d41ca03a352d0150d7fa31b7 |

包名仍为cn.ustcassistant.mobile.qa，版本名1.0.0-qa-a8-setup，schema20/tools-v7/prompt-v15，普通入口lib/main.dart。两包证书SHA256仍为16d3f9867f0a15d4d4ffc877bdd9ec240e92a3fddf6a0a66da857e2888846036，可同签名向上覆盖。未在MuMu或目标机安装本轮新包。

Windows以同一441a68b工程修订执行`flutter build windows --release --config-only --no-pub --target lib/main.dart`，随后用VS18/x64在`app/build/android-onboarding/windows-staging/x64`生成并INSTALL。先检查安装前缀、生成资源清理目标仍在本轮暂存内且祖先无重解析点，未替换原Release或1.00交付。根核验普通入口及唯一USTC工程define、AOT工程/引导/工具/提示词标记、测试入口排除、品牌PNG、既有DLL/模型和许可；37个运行文件的逐项哈希写入`artifacts/windows-staging-manifest.json`，并实际查看EXE提取的图标。完整目录已可交付，但本轮未用它打开正式资料。

现有用户可从“设置 → 首次设置”体验，不通过清数据制造首次状态。学校同步与真实Key仍只在应用内由用户操作，本轮不要求重做既有真实采集或模型能力验收；新引导的用户判断、MatePad及原风险分别保留。

官方隔离模拟器已在名字核对后关闭以释放资源，未停止ADB服务、操作MuMu、安装目标机或读取正式资料。目标机体验、MatePad目录修复效果及原真实麦克风/06:00/通知厂商策略等不由本轮自动检查关闭，A7/A8继续开放；未推送或公开发布。
