param([string]$SdkRoot = 'E:\Android\Sdk')
$ErrorActionPreference = 'Stop'
$workspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$reportRoot = Join-Path $workspaceRoot 'app/build/android-a5/reports/os-api36'
New-Item -ItemType Directory -Force -Path $reportRoot | Out-Null
$adb = Join-Path $SdkRoot 'platform-tools/adb.exe'
$serial = 'emulator-5582'
$qaPackage = 'cn.ustcassistant.mobile.qa'
function Invoke-QaAdb {
    $output = & $adb -P 5038 -s $serial @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "A5 QA ADB command failed ($LASTEXITCODE): $($args -join ' ') :: $(($output -join ' ').Trim())" }
    return ($output -join "`n").Trim()
}
if ((Invoke-QaAdb shell getprop ro.boot.qemu.avd_name) -ne 'ustc_android_a0_api36' -or
    (Invoke-QaAdb shell getprop ro.kernel.qemu) -ne '1') { throw 'A5 only accepts the isolated API36 AVD.' }
if (-not (Invoke-QaAdb shell pm path $qaPackage).StartsWith('package:')) { throw 'A5 QA APK is not installed.' }

function Invoke-Probe([string]$Operation, [string]$ReportName) {
    $run = [Guid]::NewGuid().ToString('N')
    Invoke-QaAdb shell am start -W -n "$qaPackage/cn.ustcassistant.mobile.notifications.ReminderOsProbeActivity" --es operation $Operation --es run $run | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds(40)
    do {
        $priorErrorAction = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $raw = & $adb -P 5038 -s $serial shell run-as $qaPackage cat files/a5-os-reminder-report.json 2>$null
            $readCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $priorErrorAction }
        if ($readCode -eq 0 -and $raw) {
            $report = ($raw -join "`n") | ConvertFrom-Json
            if ($report.run -eq $run) {
                [IO.File]::WriteAllText((Join-Path $reportRoot "$ReportName.json"), ($report | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
                if (-not $report.success) { throw "A5 $Operation failed: $($report.failure)" }
                return $report
            }
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "A5 $Operation timed out."
}
function Stop-QaBackground {
    Invoke-QaAdb shell input keyevent KEYCODE_HOME | Out-Null
    Start-Sleep -Seconds 2
    Invoke-QaAdb shell am kill $qaPackage | Out-Null
    Start-Sleep -Seconds 1
    $pidText = & $adb -P 5038 -s $serial shell pidof $qaPackage 2>$null
    if ($pidText) { throw 'QA process remains alive; no after-exit proof.' }
}

# These grants concern only the isolated synthetic QA identity. Never change
# system/global permissions or production package state.
Invoke-QaAdb shell pm grant $qaPackage android.permission.POST_NOTIFICATIONS | Out-Null
Invoke-QaAdb shell appops set $qaPackage SCHEDULE_EXACT_ALARM allow | Out-Null
try {
    $registered = Invoke-Probe 'schedule' 'registered'
    if ($registered.pending -ne 1 -or -not $registered.entryExact) { throw 'Exact registration was not demonstrated.' }
    Stop-QaBackground
    Start-Sleep -Seconds 21
    $afterExit = Invoke-Probe 'report' 'after-exit'
    if ($afterExit.delivered -ne 1 -or $afterExit.active -ne 1) { throw 'After-exit OS delivery failed.' }
    $removed = Invoke-Probe 'cancel' 'cancel-displayed'
    if ($removed.entries -ne 0 -or $removed.active -ne 0) { throw 'Displayed cancellation failed.' }
    Invoke-Probe 'schedule' 'before-cancel' | Out-Null
    Invoke-Probe 'cancel' 'cancel-pending' | Out-Null
    Stop-QaBackground
    Start-Sleep -Seconds 21
    $afterCancel = Invoke-Probe 'report' 'after-cancel'
    if ($afterCancel.delivered -ne 0 -or $afterCancel.active -ne 0) { throw 'Cancelled alarm delivered.' }
    Invoke-Probe 'schedule' 'before-block' | Out-Null
    Invoke-Probe 'block' 'blocked' | Out-Null
    Stop-QaBackground
    Invoke-Probe 'restore' 'blocked-restore' | Out-Null
    Stop-QaBackground
    Start-Sleep -Seconds 21
    $blocked = Invoke-Probe 'report' 'after-block'
    if (-not $blocked.blocked -or $blocked.delivered -ne 0 -or $blocked.active -ne 0) { throw 'Blocked receiver delivered.' }
    Invoke-Probe 'clear' 'clear-blocked' | Out-Null
    Invoke-QaAdb shell pm revoke $qaPackage android.permission.POST_NOTIFICATIONS | Out-Null
    $disabled = Invoke-Probe 'report' 'notifications-disabled'
    if ($disabled.notifications) { throw 'Notification revocation was not observed.' }
    Invoke-QaAdb shell pm grant $qaPackage android.permission.POST_NOTIFICATIONS | Out-Null
    Invoke-QaAdb shell appops set $qaPackage SCHEDULE_EXACT_ALARM deny | Out-Null
    $inexact = Invoke-Probe 'schedule' 'inexact-registration'
    if ($inexact.exact -or $inexact.entryExact -or $inexact.pending -ne 1) { throw 'Inexact fallback was not demonstrated.' }
    Invoke-Probe 'clear' 'clear-inexact' | Out-Null
    Invoke-QaAdb shell appops set $qaPackage SCHEDULE_EXACT_ALARM allow | Out-Null

    Invoke-Probe 'schedule-reboot' 'before-reboot' | Out-Null
    $bootStart = [DateTime]::UtcNow
    $oldBoot = Invoke-QaAdb shell cat /proc/sys/kernel/random/boot_id
    # ADB can report a transport error as the requested reboot disconnects.
    # Success is proved by a changed boot ID and completed boot, not exit code.
    $priorErrorAction = $ErrorActionPreference
    try { $ErrorActionPreference = 'Continue'; & $adb -P 5038 -s $serial reboot 2>&1 | Out-Null }
    finally { $ErrorActionPreference = $priorErrorAction }
    $deadline = [DateTime]::UtcNow.AddSeconds(110)
    do {
        $priorErrorAction = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $bootComplete = & $adb -P 5038 -s $serial shell getprop sys.boot_completed 2>$null
            $newBoot = & $adb -P 5038 -s $serial shell cat /proc/sys/kernel/random/boot_id 2>$null
            $bootReadCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $priorErrorAction }
        if ($bootReadCode -eq 0 -and ($bootComplete -join '').Trim() -eq '1' -and
            ($newBoot -join '').Trim() -ne $oldBoot) { break }
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Isolated AVD reboot did not finish with a new boot ID.' }
        Start-Sleep -Seconds 1
    } while ($true)
    if ((Invoke-QaAdb shell getprop ro.boot.qemu.avd_name) -ne 'ustc_android_a0_api36') { throw 'Unexpected AVD after reboot.' }
    $restored = Invoke-Probe 'report' 'after-reboot-registration'
    if ($restored.pending -ne 1 -or $restored.blocked) { throw 'Boot receiver did not restore registration.' }
    while (([DateTime]::UtcNow - $bootStart).TotalSeconds -lt 123) { Start-Sleep -Seconds 2 }
    $afterReboot = Invoke-Probe 'report' 'after-reboot-delivery'
    if ($afterReboot.delivered -ne 1 -or $afterReboot.active -ne 1) { throw 'Restored OS alarm did not deliver.' }
    Write-Output 'A5 OS checks passed: exit, cancel, block, permissions, inexact registration, reboot delivery.'
} finally {
    Invoke-QaAdb shell pm grant $qaPackage android.permission.POST_NOTIFICATIONS | Out-Null
    Invoke-QaAdb shell appops set $qaPackage SCHEDULE_EXACT_ALARM allow | Out-Null
    Invoke-Probe 'clear' 'final-clear' | Out-Null
}
