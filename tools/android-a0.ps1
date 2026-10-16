param(
    [ValidateSet('Build', 'PrepareDevice', 'Start', 'Stop', 'Test', 'CheckAcceleration')]
    [string]$Action = 'CheckAcceleration',
    [string]$SdkRoot = 'E:\Android\Sdk',
    [string]$FlutterRoot = 'E:\flutter\flutter',
    [string]$JavaRoot = 'E:\Android\Android Studio\jbr',
    [string]$GradleHome = 'E:\Android\Gradle',
    [string]$PubCache = 'E:\Android\pub_cache',
    [ValidateSet('All', 'Notifications')]
    [string]$TestScope = 'All',
    [ValidateSet(35, 36)]
    [int]$ApiLevel = 35
)

$ErrorActionPreference = 'Stop'
$workspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$appRoot = Join-Path $workspaceRoot 'app'
$taskRoot = Join-Path $appRoot 'build/android-a0'
$taskTemp = Join-Path $taskRoot 'temp'
$avdHome = Join-Path $taskRoot 'avd-home'
$avdName = "ustc_android_a0_api$ApiLevel"
$emulatorPort = $(if ($ApiLevel -eq 35) { 5580 } else { 5582 })
$serial = "emulator-$emulatorPort"
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
        'CheckAcceleration' {
            & $emulator -accel-check
            Assert-ExitCode 'Android emulator hardware acceleration'
        }
        'Build' {
            Push-Location $appRoot
            try {
                & $flutter pub get --offline
                Assert-ExitCode 'Pinned Flutter dependencies'
                & $flutter build apk --debug --no-pub --target-platform android-x64 --split-per-abi
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
                    & .\gradlew.bat :app:assembleDebug :app:assembleDebugAndroidTest :app:processReleaseMainManifest :app:lintDebug '-Ptarget-platform=android-x64' '-Psplit-per-abi=true' --console=plain --quiet
                    Assert-ExitCode 'QA test APK, lint and production manifest'
                } finally { Pop-Location }
            } finally { Pop-Location }
        }
        'PrepareDevice' {
            $imageMetadata = Join-Path $SdkRoot "system-images/android-$ApiLevel/google_apis/x86_64/package.xml"
            if (-not (Test-Path -LiteralPath $imageMetadata)) {
                & (Join-Path $SdkRoot 'cmdline-tools/latest/bin/sdkmanager.bat') "--sdk_root=$SdkRoot" --proxy=http --proxy_host=127.0.0.1 --proxy_port=7897 "system-images;android-$ApiLevel;google_apis;x86_64"
                Assert-ExitCode 'Official Google system image'
            }
        }
        'Start' {
            & $emulator -accel-check
            Assert-ExitCode 'Hardware acceleration; enable Windows Hypervisor Platform and reboot first'
            $avdPath = Join-Path $avdHome "$avdName.avd"
            if (-not (Test-Path -LiteralPath $avdPath)) {
                'no' | & (Join-Path $SdkRoot 'cmdline-tools/latest/bin/avdmanager.bat') create avd --name $avdName --package "system-images;android-$ApiLevel;google_apis;x86_64" --device pixel_7 --path $avdPath
                Assert-ExitCode 'New isolated A0 AVD'
            }
            & $adb -P 5038 start-server
            Assert-ExitCode 'Dedicated QA ADB server'
            $process = Start-Process -FilePath $emulator -ArgumentList @('-avd', $avdName, '-port', $emulatorPort,
                '-accel', 'on', '-gpu', 'swiftshader', '-cores', '2', '-memory', '2048', '-no-window',
                '-no-audio', '-no-boot-anim', '-no-snapshot', '-no-metrics') -WindowStyle Hidden -PassThru `
                -RedirectStandardOutput (Join-Path $taskRoot "emulator-api$ApiLevel.stdout.log") `
                -RedirectStandardError (Join-Path $taskRoot "emulator-api$ApiLevel.stderr.log")
            Write-Output "Isolated QA emulator started: PID $($process.Id), $serial, ADB 5038."
        }
        'Stop' {
            $actualAvd = & $adb -P 5038 -s $serial shell getprop ro.boot.qemu.avd_name 2>$null
            Assert-ExitCode 'QA emulator identity check'
            if (($actualAvd -join '').Trim() -ne $avdName) { throw 'Unexpected AVD; refusing to stop it.' }
            & $adb -P 5038 -s $serial emu kill
            Assert-ExitCode 'Stop isolated emulator'
            & $adb -P 5038 kill-server
        }
        'Test' {
            & (Join-Path $PSScriptRoot 'test-android-a0.ps1') -SdkRoot $SdkRoot -Serial $serial -ExpectedAvd $avdName -Scope $TestScope
        }
    }
} finally {
    foreach ($environmentName in $oldEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($environmentName, $oldEnvironment[$environmentName], 'Process')
    }
}
