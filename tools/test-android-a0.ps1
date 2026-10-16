param(
    [string]$SdkRoot = 'E:\Android\Sdk',
    [string]$Serial = 'emulator-5580',
    [int]$AdbServerPort = 5038,
    [string]$ExpectedAvd = 'ustc_android_a0_api35',
    [ValidateSet('All', 'Notifications')]
    [string]$Scope = 'All'
)

$ErrorActionPreference = 'Stop'
$adb = Join-Path $SdkRoot 'platform-tools/adb.exe'
$qaPackage = 'cn.ustcassistant.mobile.qa'
$qaActivity = "$qaPackage/cn.ustcassistant.mobile.qa.QaProbeActivity"
$workspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Invoke-QaAdb {
    # A basic function deliberately has no PowerShell common parameters: adb's -w/-W/-e
    # must be forwarded literally rather than resolved as WarningAction/ErrorAction aliases.
    $Arguments = $args
    $result = & $adb -P $AdbServerPort -s $Serial @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Isolated QA adb operation failed: $($Arguments[0])" }
    return ($result -join "`n").Trim()
}

# A device explicitly created for this probe is mandatory. Never target a phone or other AVD.
$allowedTargets = @{
    'emulator-5580' = 'ustc_android_a0_api35'
    'emulator-5582' = 'ustc_android_a0_api36'
    'emulator-5584' = 'ustc_android_a0_api37'
    'emulator-5586' = 'ustc_android_a2_current_provider'
}
if (-not $allowedTargets.ContainsKey($Serial) -or $allowedTargets[$Serial] -ne $ExpectedAvd) {
    throw 'Only the isolated A0 emulator is accepted by this destructive QA runner.'
}
$avdName = Invoke-QaAdb shell getprop ro.boot.qemu.avd_name
$isEmulator = Invoke-QaAdb shell getprop ro.kernel.qemu
if ($avdName -ne $ExpectedAvd -or $isEmulator -ne '1') { throw 'Unexpected test target.' }
$reportRoot = Join-Path $workspaceRoot "app/build/android-a0/reports/$ExpectedAvd"
New-Item -ItemType Directory -Force -Path $reportRoot | Out-Null
$installed = Invoke-QaAdb shell pm path $qaPackage
if (-not $installed.StartsWith('package:')) { throw 'Install the isolated QA APK first.' }

function Invoke-QaProbe {
    param([string]$Command, [string]$ExpectedKind)
    $operation = [Guid]::NewGuid().ToString('N')
    $sequence = [DateTime]::UtcNow.Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)
    # Delete only the fixed synthetic QA report, so an old result cannot satisfy a new operation.
    Invoke-QaAdb shell run-as $qaPackage rm -f files/qa-probe-report.json | Out-Null
    Invoke-QaAdb shell am start -W -n $qaActivity --es qa_command $Command --es qa_operation $operation --el qa_sequence $sequence | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds(65)
    while ([DateTime]::UtcNow -lt $deadline) {
        # Windows PowerShell promotes redirected native stderr to an ErrorRecord.
        # A report not written yet is expected while an asynchronous probe runs.
        $previousErrorPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $raw = & $adb -P $AdbServerPort -s $Serial shell run-as $qaPackage cat files/qa-probe-report.json 2>$null
            $readExitCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previousErrorPreference }
        if ($readExitCode -eq 0 -and $raw) {
            $report = ($raw -join "`n") | ConvertFrom-Json
            if ($report.operation -ne $operation) { Start-Sleep -Milliseconds 200; continue }
            if ($report.kind -ne $ExpectedKind) { throw "Unexpected probe report kind for $Command." }
            $safePath = Join-Path $reportRoot "$Command.json"
            [IO.File]::WriteAllText($safePath, ($report | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
            if (-not $report.success) { throw "Probe $Command rejected: $($report.failure)" }
            return $report
        }
        Start-Sleep -Milliseconds 500
    }
    throw "Probe $Command timed out."
}

function Stop-QaForColdRestart {
    # Allowed only after the fixed emulator/package guards above. This is not a notification test.
    Invoke-QaAdb shell am force-stop $qaPackage | Out-Null
}

function Stop-QaBackgroundProcess {
    Invoke-QaAdb shell input keyevent KEYCODE_HOME | Out-Null
    Start-Sleep -Seconds 2
    Invoke-QaAdb shell am kill $qaPackage | Out-Null
    Start-Sleep -Seconds 1
    $pidResult = & $adb -P $AdbServerPort -s $Serial shell pidof $qaPackage 2>$null
    if ($pidResult) { throw 'QA process is still alive; after-exit proof is unavailable.' }
}

try {
    $instrumentation = Invoke-QaAdb shell am instrument -w -r "$qaPackage.test/androidx.test.runner.AndroidJUnitRunner"
    [IO.File]::WriteAllText((Join-Path $reportRoot 'instrumentation.txt'), $instrumentation, [Text.UTF8Encoding]::new($false))
    if ($instrumentation -notmatch 'OK \([0-9]+ tests?\)') {
        throw 'QA instrumentation did not report success; inspect its isolated report.'
    }
    Stop-QaForColdRestart
    $key = Invoke-QaProbe 'keystore' 'android-keystore-probe-v1'
    $web = $null
    $recovered = $null
    if ($Scope -eq 'All') {
    Stop-QaForColdRestart
    $web = Invoke-QaProbe 'webview' 'android-webview-probe-v1'
    if (-not $web.checks.profileIsolation -or -not $web.checks.firstCleared -or
        -not $web.checks.otherProfileRetained -or -not $web.checks.secondClearCallback) {
        throw 'Browser isolation or per-profile clearing was not demonstrated.'
    }
    Stop-QaForColdRestart
    $cleanup = Invoke-QaProbe 'webview_cleanup' 'android-webview-probe-v1'
    if ($cleanup.checks.deletedProfileCount -ne 2 -or -not $cleanup.checks.registeredProfilesDeleted) {
        throw 'The two revoked QA profiles were not removed on cold restart.'
    }
    Stop-QaForColdRestart
    $prepared = Invoke-QaProbe 'webview_prepare' 'android-webview-probe-v1'
    if (-not $prepared.restartPrepared) { throw 'Browser restart was not prepared.' }
    Stop-QaForColdRestart
    $recovered = Invoke-QaProbe 'webview_verify' 'android-webview-probe-v1'
    if (-not $recovered.checks.restartStorageRecovered) { throw 'Browser restart storage not recovered.' }
    Stop-QaForColdRestart
    Invoke-QaProbe 'webview_cleanup' 'android-webview-probe-v1' | Out-Null
    }

    $capabilities = Invoke-QaProbe 'notification_report' 'android-notification-probe-v1'
    if (-not $capabilities.notificationsEnabled -or -not $capabilities.exactAlarmsAllowed) {
        throw 'Grant notification and exact-alarm access to the isolated QA package first.'
    }
    Invoke-QaProbe 'notification_clear' 'android-notification-probe-v1' | Out-Null
    $scheduled = Invoke-QaProbe 'notification_schedule' 'android-notification-probe-v1'
    if (-not $scheduled.exactUsed) { throw 'The after-exit test requires a real exact alarm.' }
    Stop-QaBackgroundProcess
    Start-Sleep -Seconds 20
    $posted = Invoke-QaProbe 'notification_report' 'android-notification-probe-v1'
    if ($posted.receiverCount -ne 1 -or -not $posted.notificationPosted) {
        throw 'Android did not report the expected notification after QA process exit.'
    }
    [IO.File]::WriteAllText((Join-Path $reportRoot 'notification-after-exit.json'), ($posted | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    Invoke-QaProbe 'notification_clear' 'android-notification-probe-v1' | Out-Null
    Invoke-QaProbe 'notification_schedule' 'android-notification-probe-v1' | Out-Null
    Invoke-QaProbe 'notification_cancel' 'android-notification-probe-v1' | Out-Null
    Stop-QaBackgroundProcess
    Start-Sleep -Seconds 20
    $cancelled = Invoke-QaProbe 'notification_report' 'android-notification-probe-v1'
    if ($cancelled.receiverCount -ne 0 -or $cancelled.notificationPosted) { throw 'Cancelled QA alarm fired.' }
    [IO.File]::WriteAllText((Join-Path $reportRoot 'notification-after-cancel.json'), ($cancelled | ConvertTo-Json), [Text.UTF8Encoding]::new($false))

    $summary = [ordered]@{
        kind = $(if ($Scope -eq 'All') { 'android-a0-run-v1' } else { 'android-a0-notification-run-v1' })
        success = $true; webviewTested = ($Scope -eq 'All')
        api = (Invoke-QaAdb shell getprop ro.build.version.sdk)
        abi = (Invoke-QaAdb shell getprop ro.product.cpu.abi)
        providerVersion = $web.providerVersion
        profileIsolation = $web.checks.profileIsolation
        profileClear = $web.checks.firstCleared
        profileRestart = $recovered.checks.restartStorageRecovered
        keystore = $key.success
        keystoreHardwareBacked = $key.hardwareBacked
        notificationAfterProcessExit = $posted.notificationPosted
        notificationCancelled = (-not $cancelled.notificationPosted)
        realDevice = $false; schoolVerified = $false
    }
    $summaryFilename = $(if ($Scope -eq 'All') { 'summary.json' } else { 'notification-summary.json' })
    [IO.File]::WriteAllText((Join-Path $reportRoot $summaryFilename), ($summary | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    $summary | ConvertTo-Json
} finally {
    # Fixed QA artifacts only; cleanup failure remains visible and never touches a production package.
    try { Invoke-QaProbe 'notification_clear' 'android-notification-probe-v1' | Out-Null }
    catch { Write-Warning 'QA notification cleanup could not be confirmed.' }
}
