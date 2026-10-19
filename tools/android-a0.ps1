param(
    [ValidateSet('Build', 'Analyze', 'DartTest', 'PrepareDevice', 'Start', 'Stop', 'Test', 'IntegrationTest', 'CheckAcceleration')]
    [string]$Action = 'CheckAcceleration',
    [string]$SdkRoot = 'E:\Android\Sdk',
    [string]$FlutterRoot = 'E:\flutter\flutter',
    [string]$JavaRoot = 'E:\Android\Android Studio\jbr',
    [string]$GradleHome = 'E:\Android\Gradle',
    [string]$PubCache = 'E:\Android\pub_cache',
    [ValidateSet('All', 'Notifications')]
    [string]$TestScope = 'All',
    [ValidateSet(28, 29, 32, 34, 35, 36, 37)]
    [int]$ApiLevel = 36,
    [switch]$CurrentProvider,
    [ValidateSet('A1', 'A2', 'A3', 'A3_Public', 'A4', 'A5', 'A6', 'A7', 'A7_Source', 'UIRefresh')]
    [string]$IntegrationSuite = 'A1',
    [switch]$UnsupportedSourceOnly,
    [switch]$VerifyRetained,
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$BuildRevision
)

$ErrorActionPreference = 'Stop'
$workspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$appRoot = Join-Path $workspaceRoot 'app'
$taskRoot = Join-Path $appRoot 'build/android-a0'
$taskTemp = Join-Path $taskRoot 'temp'
$avdHome = Join-Path $taskRoot 'avd-home'
$avdName = "ustc_android_a0_api$ApiLevel"
$imageApi = $(if ($ApiLevel -eq 37) { '37.0' } else { "$ApiLevel" })
$imageTag = 'google_apis'
$emulatorPort = switch ($ApiLevel) {
    28 { 5590 }; 29 { 5592 }; 32 { 5594 }; 34 { 5588 }; 35 { 5580 }; 36 { 5582 }; 37 { 5584 }
}
if ($CurrentProvider) {
    if ($ApiLevel -ne 37) { throw 'The current-provider probe requires the separate API 37 QA image.' }
    $avdName = 'ustc_android_a2_current_provider'
    $imageApi = '37.2'; $imageTag = 'google_apis_ps16k'; $emulatorPort = 5586
}
$serial = "emulator-$emulatorPort"
$emulatorLog = $(if ($CurrentProvider) { 'current-provider' } else { "api$ApiLevel" })
$adb = Join-Path $SdkRoot 'platform-tools/adb.exe'
$emulator = Join-Path $SdkRoot 'emulator/emulator.exe'
$flutter = Join-Path $FlutterRoot 'bin/flutter.bat'
$environmentValues = @{
    JAVA_HOME = $JavaRoot; ANDROID_HOME = $SdkRoot
    ANDROID_USER_HOME = (Join-Path $taskRoot 'android-user')
    ANDROID_AVD_HOME = $avdHome
    ANDROID_EMULATOR_HOME = (Join-Path $taskRoot 'emulator-home')
    GRADLE_USER_HOME = $GradleHome; PUB_CACHE = $PubCache
    TEMP = $taskTemp; TMP = $taskTemp
    ANDROID_ADB_SERVER_PORT = '5038'; ADB_SERVER_SOCKET = 'tcp:localhost:5038'
    JAVA_TOOL_OPTIONS = "-Djava.io.tmpdir=$taskTemp -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=7897 -Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=7897 -Dhttp.nonProxyHosts=localhost|127.*"
}
$oldEnvironment = @{}
foreach ($environmentName in $environmentValues.Keys) {
    $oldEnvironment[$environmentName] = [Environment]::GetEnvironmentVariable($environmentName, 'Process')
}

function Assert-ExitCode([string]$Operation) {
    if ($LASTEXITCODE -ne 0) { throw "$Operation failed (exit $LASTEXITCODE)." }
}

function Assert-QaEmulator {
    $actualAvd = ((& $adb -P 5038 -s $serial shell getprop ro.boot.qemu.avd_name) -join '').Trim()
    Assert-ExitCode 'QA emulator identity'
    if (-not $actualAvd) {
        $actualAvd = ((& $adb -P 5038 -s $serial shell getprop ro.kernel.qemu.avd_name) -join '').Trim()
        Assert-ExitCode 'Legacy QA emulator identity'
    }
    $consoleName = @(& $adb -P 5038 -s $serial emu avd name)
    Assert-ExitCode 'QA emulator console identity'
    $qemu = ((& $adb -P 5038 -s $serial shell getprop ro.kernel.qemu) -join '').Trim()
    Assert-ExitCode 'QA emulator environment'
    if ($actualAvd -ne $avdName -or $consoleName.Count -lt 2 -or
        $consoleName[0].Trim() -ne $avdName -or $qemu -ne '1') {
        throw 'Unexpected AVD; refusing to operate on it.'
    }
}

try {
    # Only this script process and its children use these paths. User/machine settings are untouched.
    foreach ($directory in @($taskRoot, $taskTemp, $avdHome, $environmentValues.ANDROID_USER_HOME,
            $environmentValues.ANDROID_EMULATOR_HOME, $GradleHome, $PubCache)) {
        if ([IO.Path]::GetPathRoot($directory) -eq 'C:\') {
            throw 'Android A0 large caches and temporary files must be on the configured data drive.'
        }
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    foreach ($environmentName in $environmentValues.Keys) {
        [Environment]::SetEnvironmentVariable($environmentName, $environmentValues[$environmentName], 'Process')
    }
    switch ($Action) {
        'Analyze' {
            Push-Location $appRoot
            try {
                & $flutter analyze --no-pub
                Assert-ExitCode 'Flutter analyzer'
            } finally { Pop-Location }
        }
        'DartTest' {
            Push-Location $appRoot
            try {
                & $flutter test --no-pub --reporter expanded
                Assert-ExitCode 'Shared Dart and widget tests'
            } finally { Pop-Location }
        }
        'CheckAcceleration' {
            & $emulator -accel-check
            Assert-ExitCode 'Android emulator hardware acceleration'
        }
        'Build' {
            Push-Location $appRoot
            try {
                & $flutter pub get --offline
                Assert-ExitCode 'Pinned Flutter dependencies'
                $revisionArguments = @()
                $gradleRevisionArguments = @()
                if ($BuildRevision) {
                    $revisionDefine = "USTC_BUILD_REVISION=$BuildRevision"
                    $revisionArguments = @("--dart-define=$revisionDefine")
                    $encodedDefine = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($revisionDefine))
                    $gradleRevisionArguments = @("-Pdart-defines=$encodedDefine")
                }
                & $flutter build apk --debug --no-pub --target-platform android-x64 --split-per-abi @revisionArguments
                Assert-ExitCode 'Isolated QA APK'
                # Flutter generates Windows drive colons unescaped; this AGP lint requires Properties escaping.
                $localPropertiesPath = Join-Path $appRoot 'android/local.properties'
                $generatedProperties = [IO.File]::ReadAllText($localPropertiesPath)
                $escapedProperties = [regex]::Replace($generatedProperties,
                    '(?m)^((?:sdk\.dir|flutter\.sdk)=)([A-Za-z]):', '$1$2\:')
                if ($escapedProperties -ne $generatedProperties) {
                    [IO.File]::WriteAllText($localPropertiesPath, $escapedProperties, [Text.UTF8Encoding]::new($false))
                }
                Push-Location (Join-Path $appRoot 'android')
                try {
                    # Request both tasks: this Flutter SDK does not register its compile task for AndroidTest alone.
                    & .\gradlew.bat :app:assembleDebug :app:assembleDebugAndroidTest :app:processReleaseMainManifest :app:lintDebug '-Ptarget-platform=android-x64' '-Psplit-per-abi=true' @gradleRevisionArguments --console=plain --quiet
                    Assert-ExitCode 'QA test APK, lint and production manifest'
                } finally { Pop-Location }
            } finally { Pop-Location }
        }
        'PrepareDevice' {
            $imageMetadata = Join-Path $SdkRoot "system-images/android-$imageApi/$imageTag/x86_64/package.xml"
            if (-not (Test-Path -LiteralPath $imageMetadata)) {
                & (Join-Path $SdkRoot 'cmdline-tools/latest/bin/sdkmanager.bat') "--sdk_root=$SdkRoot" --proxy=http --proxy_host=127.0.0.1 --proxy_port=7897 "system-images;android-$imageApi;$imageTag;x86_64"
                Assert-ExitCode 'Official Google system image'
            }
        }
        'Start' {
            & $emulator -accel-check
            Assert-ExitCode 'Hardware acceleration; enable Windows Hypervisor Platform and reboot first'
            $avdPath = Join-Path $avdHome "$avdName.avd"
            if (-not (Test-Path -LiteralPath $avdPath)) {
                'no' | & (Join-Path $SdkRoot 'cmdline-tools/latest/bin/avdmanager.bat') create avd --name $avdName --package "system-images;android-$imageApi;$imageTag;x86_64" --device pixel_7 --path $avdPath
                Assert-ExitCode 'New isolated A0 AVD'
            }
            & $adb -P 5038 start-server
            Assert-ExitCode 'Dedicated QA ADB server'
            $process = Start-Process -FilePath $emulator -ArgumentList @('-avd', $avdName, '-port', $emulatorPort,
                '-accel', 'on', '-gpu', 'swiftshader', '-cores', '2', '-memory', '2048', '-no-window',
                '-no-audio', '-no-boot-anim', '-no-snapshot', '-no-metrics') -WindowStyle Hidden -PassThru `
                -RedirectStandardOutput (Join-Path $taskRoot "emulator-$emulatorLog.stdout.log") `
                -RedirectStandardError (Join-Path $taskRoot "emulator-$emulatorLog.stderr.log")
            Write-Output "Isolated QA emulator started: PID $($process.Id), $serial, ADB 5038."
        }
        'Stop' {
            Assert-QaEmulator
            & $adb -P 5038 -s $serial emu kill
            Assert-ExitCode 'Stop isolated emulator'
            & $adb -P 5038 kill-server
        }
        'Test' {
            & (Join-Path $PSScriptRoot 'test-android-a0.ps1') -SdkRoot $SdkRoot -Serial $serial -ExpectedAvd $avdName -Scope $TestScope
        }
        'IntegrationTest' {
            if ($IntegrationSuite -in @('A7', 'A7_Source') -and $ApiLevel -ne 34) {
                throw 'A7 notification routing seeds only the new independent API34 QA sandbox.'
            }
            Assert-QaEmulator
            $installedMetadata = & $adb -P 5038 -s $serial shell dumpsys package cn.ustcassistant.mobile.qa
            $codeMatch = [regex]::Match(($installedMetadata -join "`n"), 'versionCode=(\d+)')
            if ($codeMatch.Success -and [long]$codeMatch.Groups[1].Value -gt 4010) {
                throw 'QA version is newer; refusing Flutter downgrade/uninstall fallback.'
            }
            $restoreNotificationDenial = $false
            if ($IntegrationSuite -eq 'A5') {
                # A5 tests publication, with permission as an explicit test
                # prerequisite; permission denial is covered separately.
                $restoreNotificationDenial = ($installedMetadata -join "`n") -notmatch 'android.permission.POST_NOTIFICATIONS: granted=true'
                & $adb -P 5038 -s $serial shell pm grant cn.ustcassistant.mobile.qa android.permission.POST_NOTIFICATIONS
                Assert-ExitCode 'Isolated A5 notification prerequisite'
            }
            Push-Location $appRoot
            try {
                $retainedValue = $VerifyRetained.IsPresent.ToString().ToLowerInvariant()
                # Flutter test otherwise uninstalls even after a successful run,
                # which would invalidate the cross-process retention checks.
                $integrationFile = if ($IntegrationSuite -eq 'UIRefresh') {
                    'integration_test/ui_refresh_gallery_test.dart'
                } else {
                    "integration_test/android_$($IntegrationSuite.ToLowerInvariant())_test.dart"
                }
                $galleryValue = ($IntegrationSuite -eq 'UIRefresh').ToString().ToLowerInvariant()
                $gateValue = $UnsupportedSourceOnly.IsPresent.ToString().ToLowerInvariant()
                $routeValue = ($IntegrationSuite -eq 'A7').ToString().ToLowerInvariant()
                & $flutter test $integrationFile -d $serial --no-pub --no-uninstall --reporter expanded "--dart-define=USTC_A1_VERIFY_RETAINED=$retainedValue" "--dart-define=USTC_A2_UNSUPPORTED_SOURCE_ONLY=$gateValue" "--dart-define=USTC_A7_SEED_OS_ROUTE=$routeValue" "--dart-define=USTC_UI_QA=$galleryValue"
                $integrationExitCode = $LASTEXITCODE
                $installedPaths = & $adb -P 5038 -s $serial shell pm path cn.ustcassistant.mobile.qa
                Assert-ExitCode 'QA package retention check'
                if (-not (($installedPaths -join "`n") -match '(?m)^package:')) {
                    throw 'QA package was removed; retention results are invalid.'
                }
                Write-Output "$IntegrationSuite QA package remains installed after the integration runner."
                if ($integrationExitCode -ne 0) { throw "Android $IntegrationSuite integration failed ($integrationExitCode)." }
            } finally {
                Pop-Location
                if ($restoreNotificationDenial) {
                    & $adb -P 5038 -s $serial shell pm revoke cn.ustcassistant.mobile.qa android.permission.POST_NOTIFICATIONS
                    Assert-ExitCode 'Restore isolated A5 notification denial'
                }
            }
        }
    }
} finally {
    foreach ($environmentName in $oldEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($environmentName, $oldEnvironment[$environmentName], 'Process')
    }
}
