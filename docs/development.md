# 开发说明

本文说明常规开发检查和维护者候选构建入口。`tools/build-public-release.ps1` 可准备 Windows、Android 或双平台 1.0.0 候选；Android 签名由本机初始化脚本管理。候选构建不创建或上传 Release，也不替代设备和真实服务验证。Android QA Debug 构建不能当作公开 Release。

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

Android 开发还可用 Flutter 生成 QA Debug 包。正式公开版包名 `cn.ustcassistant.mobile` 与 QA 包名 `cn.ustcassistant.mobile.qa` 并存，不自动迁移 QA 用户资料；保留现有 QA 应用及其数据。

从仓库根目录运行：

```powershell
flutter build apk --debug
```

自动检查使用合成输入和 QA 身份，不访问真实学校账号、用户业务资料或浏览器认证资产。真实登录、验证码和额外学校授权由用户本人操作。


## 正式候选构建

这些命令使用 Windows PowerShell 7（`pwsh`）。先提交候选源码并确认工作区干净；构建脚本会核对修订必须等于当前 `HEAD`。将下面的环境变量设置为本机工具安装位置；候选输出位于仓库的 `app/build`。脚本离线解析依赖，须预先准备锁定依赖，并运行[固定语音资源准备脚本](../tools/prepare-speech-assets.ps1)取得模型及随包许可。

```powershell
# 在仓库根目录执行；没有改动时可直接取得提交号。
$revision = (git rev-parse --verify HEAD).Trim()
if (git status --porcelain) { throw '请先提交或处理工作区改动，再构建候选。' }

$flutterRoot = $env:FLUTTER_ROOT
$sdkRoot = $env:ANDROID_SDK_ROOT
$javaHome = $env:JAVA_HOME
$gradleHome = $env:GRADLE_USER_HOME
$pubCache = $env:PUB_CACHE
$signingDirectory = Read-Host 'Signing directory outside the source tree'
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

`-Platform` 可选 `Windows`、`Android` 或 `All`。脚本先离线核对锁定依赖，随后保留Flutter标准构建的`--pub`阶段，以重新生成对应Release的插件注册；不要手工删除或修改测试插件注册代码。构建若改变受控源码或锁文件会拒绝继续打包。候选位于 `app/build/public-releases`，带修订号并含校验清单；Android 正式包与 QA 包使用不同身份且不迁移数据，Windows 包未代码签名。准备 GitLab Release 本地清单（需同时有同一修订的 Windows 和 Android 候选）：

```powershell
$shortRevision = $revision.Substring(0, 8)
$publicRoot = Join-Path (Get-Location).Path 'app/build/public-releases'
pwsh -NoProfile -File tools/prepare-gitlab-release.ps1 `
  -WindowsPackageDirectory (Join-Path $publicRoot "1.0.0+1-$shortRevision") `
  -AndroidPackageDirectory (Join-Path $publicRoot "android-1.0.0-$shortRevision") `
  -Revision40hex $revision
```

此步骤只生成 `gitlab-1.0.0-<修订前缀>` 本地整理目录和供人工审阅的执行计划；它不登录、不打 tag、不建 Release、不上传，也不修改项目可见性。发布者应先核对安装包、源码修订、签名和校验和，确认后再发布。

## 文档修改

只改文档时，从仓库根目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/check-docs.ps1
git diff --check
```

不要把用户数据库、学校原始响应、密码、Key、签名文件或认证资料放进 Git。需要描述平台或来源行为时，以 `docs/README.md` 导航的现行契约、验收边界和对应来源参考为准；不要从历史版本推导当前支持范围。
