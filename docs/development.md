# 开发说明

本文记录仓库现有的开发、检查和公开候选构建入口。`tools/build-public-release.ps1` 可准备 Windows、Android 或双平台 1.0.0 候选；Android 签名由本机初始化脚本管理。它们只生成本地候选，不创建 GitLab Release、不上传附件，也不替代设备和真人验收。Android QA Debug 构建和 Windows 私有打包脚本不能当作公开 Release。

## 工具链

- `app/pubspec.yaml` 声明 Dart SDK `^3.12.2`，依赖锁定在 `app/pubspec.lock`。仓库没有固定 Flutter SDK 发行版。
- Windows 桌面版使用 Microsoft WebView2；工程引用的 NuGet SDK 版本为 `Microsoft.Web.WebView2 1.0.3967.48`，运行时需要已安装 WebView2 Runtime。
- Windows 编译还需预先取得该版本 NuGet SDK。CMake默认从用户的`.nuget/packages/microsoft.web.webview2/1.0.3967.48`读取，其他缓存位置可通过CMake的`USTC_WEBVIEW2_SDK_ROOT`指定；SDK与设备运行时是两项依赖。
- Android 开发还需要 Flutter Android 工具链、Android SDK、JDK 和 Gradle。具体环境参数由本机安装决定；不要把开发机路径写进产品代码或文档示例。

## Windows

以下命令在 Windows 上从仓库根目录执行：

```powershell
Set-Location app
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
flutter run -d windows
```

生成 Windows Release 运行目录的现有命令是：

```powershell
flutter build windows --release --no-pub --target=lib/main.dart
```

该命令仅生成开发用本地构建产物。公开 ZIP 由下文的候选构建入口组装；Windows 包保持未代码签名状态。

## Android QA 开发构建

仓库现有 `tools/android-a0.ps1` 的 `Build` 操作生成 Android x86_64 QA Debug 包，并运行对应的 Manifest 与 lint 检查。正式公开版已选择独立包名 `cn.ustcassistant.mobile`，与 `cn.ustcassistant.mobile.qa` 并存，不自动迁移 QA 用户资料；保留现有 QA 应用及其数据。A0 仍是隔离的 QA 开发入口，不会生成正式 Release。

从仓库根目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/android-a0.ps1 -Action Build
```

脚本提供 `-SdkRoot`、`-FlutterRoot`、`-JavaRoot`、`-GradleHome` 和 `-PubCache` 参数；未传入时采用脚本中的本机默认路径。脚本会为自身进程设置环境，并要求其构建与缓存目录位于非 C 盘。不同机器需要按本地工具安装情况传入这些参数。成功生成的 x86_64 调试 APK 位于 `app/build/app/outputs/flutter-apk/app-x86_64-debug.apk`。

这套 A0 开发流程的模拟器与合成测试使用隔离 QA 身份；不要连接真实学校账号、业务资料或浏览器认证资产。真实登录、验证码和额外学校授权由用户本人操作。

## 正式候选构建

这些命令使用 Windows PowerShell 7（`pwsh`）。先把待发布源码提交，再确认工作区干净；构建脚本会再次核对修订必须等于当前 `HEAD`。将下面的工具目录替换为本机已安装位置；本机构建环境默认在E盘，可传入其他本地固定盘路径。候选构建的临时目录位于仓库`app/build`，因此该入口要求仓库放在非C盘。脚本离线解析依赖，须预先准备锁定依赖及[固定语音资源](../app/resources/speech/README.md)。

```powershell
# 在仓库根目录执行；没有改动时可直接取得提交号。
$revision = (git rev-parse --verify HEAD).Trim()
if (git status --porcelain) { throw '请先提交或处理工作区改动，再构建候选。' }

$flutterRoot = 'D:\Tools\flutter'
$sdkRoot = 'D:\Android\Sdk'
$javaHome = 'D:\Android\Studio\jbr'
$gradleHome = 'D:\Android\Gradle'
$pubCache = 'D:\Android\pub_cache'
$signingDirectory = 'D:\private\android-signing'
```

Android 正式签名材料由脚本在源码仓库外新建目录，密码会在终端安全提示输入；不要把密钥、密码或签名配置加入 Git。首次为当前密钥创建目录：

```powershell
pwsh -NoProfile -File tools/initialize-android-signing.ps1 `
  -SigningDirectory $signingDirectory -JavaHome $javaHome
```

正式签名目录须是源码外的新路径；初始化会生成 `signing.json`、私有密钥库和公开证书，并拒绝覆盖已有目录。密钥库应另行离线备份。Windows-only 构建不需要签名目录：

```powershell
pwsh -NoProfile -File tools/build-public-release.ps1 `
  -Platform Windows -Revision $revision -FlutterRoot $flutterRoot -PubCache $pubCache
```

Android 或双平台构建还需本机 Android SDK、Java、Gradle 和 Pub 缓存，以及初始化生成的签名配置：

```powershell
pwsh -NoProfile -File tools/build-public-release.ps1 `
  -Platform All -Revision $revision -FlutterRoot $flutterRoot `
  -SdkRoot $sdkRoot -JavaHome $javaHome -GradleHome $gradleHome `
  -PubCache $pubCache `
  -SigningConfiguration (Join-Path $signingDirectory 'signing.json')
```

`-Platform` 可选 `Windows`、`Android` 或 `All`。候选位于 `app/build/public-releases`，带修订号并含校验清单；Android 正式包与 QA 包使用不同身份且不迁移数据，Windows 包未代码签名。准备 GitLab Release 本地清单（需同时有同一修订的 Windows 和 Android 候选）：

```powershell
$shortRevision = $revision.Substring(0, 8)
$publicRoot = Join-Path (Get-Location).Path 'app/build/public-releases'
pwsh -NoProfile -File tools/prepare-gitlab-release.ps1 `
  -WindowsPackageDirectory (Join-Path $publicRoot "1.0.0+1-$shortRevision") `
  -AndroidPackageDirectory (Join-Path $publicRoot "android-1.0.0-$shortRevision") `
  -Revision40hex $revision
```

此步骤只生成 `gitlab-1.0.0-<修订前缀>` 本地整理目录和供人工审阅的执行计划；它不登录、不打 tag、不建 Release、不上传，也不修改项目可见性。候选仍须根级复核并经用户确认后才能发布。

## 文档修改

只改文档时，从仓库根目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/check-docs.ps1
git diff --check
```

不要把用户数据库、学校原始响应、密码、Key、签名文件或认证资料放进 Git。需要描述平台或来源行为时，以 `docs/README.md` 导航的现行契约、验收边界和对应来源参考为准；不要从旧档案推导当前支持范围。
