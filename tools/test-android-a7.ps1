param(
    [string]$SdkRoot = 'E:\Android\Sdk',
    [ValidateSet(34, 37)]
    [int]$ApiLevel = 34,
    [switch]$LowBattery
)

# A7 / architecture 07-12, quality13 and workflow15. Synthetic QA only.
# Never accepts an arbitrary serial or a MuMu instance containing user data.
$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$reports = Join-Path $workspace "app/build/android-a7/reports/api$ApiLevel"
New-Item -ItemType Directory -Force -Path $reports | Out-Null
$adb = Join-Path $SdkRoot 'platform-tools/adb.exe'
$serial = $(if ($ApiLevel -eq 34) { 'emulator-5588' } else { 'emulator-5586' })
$expectedAvd = $(if ($ApiLevel -eq 34) { 'ustc_android_a0_api34' } else { 'ustc_android_a2_current_provider' })
$qa = 'cn.ustcassistant.mobile.qa'
function Invoke-QaAdb {
    $prior = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $adb -P 5038 -s $serial @args 2>&1
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prior }
    if ($code -ne 0) { throw "A7 isolated QA command failed ($code): $($args[0]) $($args[1])" }
    return ($output -join "`n").Trim()
}
if ((Invoke-QaAdb shell getprop ro.boot.qemu.avd_name) -ne $expectedAvd -or
    (Invoke-QaAdb shell getprop ro.kernel.qemu) -ne '1') {
    throw 'A7 requires the fixed independent official AVD.'
}
if (-not (Invoke-QaAdb shell pm path $qa).StartsWith('package:')) { throw 'Install the retained QA package first.' }

function Save-Json([string]$Name, $Value) {
    [IO.File]::WriteAllText((Join-Path $reports "$Name.json"),
        ($Value | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}
function Invoke-Probe([string]$Operation, [string]$Name) {
    $run = [Guid]::NewGuid().ToString('N')
    Invoke-QaAdb shell am start -W -n "$qa/cn.ustcassistant.mobile.notifications.ReminderOsProbeActivity" --es operation $Operation --es run $run | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $prior = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $raw = & $adb -P 5038 -s $serial shell run-as $qa cat files/a5-os-reminder-report.json 2>$null
            $code = $LASTEXITCODE
        } finally { $ErrorActionPreference = $prior }
        if ($code -eq 0 -and $raw) {
            $value = ($raw -join "`n") | ConvertFrom-Json
            if ($value.run -eq $run) {
                Save-Json $Name $value
                if (-not $value.success) { throw "A7 $Operation rejected: $($value.failure)" }
                return $value
            }
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "A7 $Operation timed out."
}
function Assert-Empty($Value, [string]$Context) {
    if ($Value.entries -ne 0 -or $Value.active -ne 0) { throw "A7 stale reminder survived $Context." }
}

$metadata = Invoke-QaAdb shell dumpsys package $qa
$notificationWasGranted = $metadata -match 'android.permission.POST_NOTIFICATIONS: granted=true'
$exactWasAllowed = (Invoke-QaAdb shell cmd appops get $qa SCHEDULE_EXACT_ALARM) -match ': allow'
$forcedIdle = $false
$batteryOverridden = $false
$oldPowerSave = $null
try {
    Save-Json 'environment' ([ordered]@{
        kind = 'android-a7-environment-v1'; avd = $expectedAvd
        android = (Invoke-QaAdb shell getprop ro.build.version.release)
        api = (Invoke-QaAdb shell getprop ro.build.version.sdk)
        abi = (Invoke-QaAdb shell getprop ro.product.cpu.abilist)
        pageBytes = (Invoke-QaAdb shell getconf PAGE_SIZE)
        webView = ((Invoke-QaAdb shell dumpsys webviewupdate) -split "`n" | Where-Object { $_ -match 'Current WebView package' }) -join ''
        realDevice = $false; realSchool = $false; realModel = $false; realMicrophone = $false
    })
    Invoke-QaAdb shell pm grant $qa android.permission.POST_NOTIFICATIONS | Out-Null
    Invoke-QaAdb shell appops set $qa SCHEDULE_EXACT_ALARM allow | Out-Null
    Invoke-Probe 'clear' 'initial-clear' | Out-Null
    if ($LowBattery) {
        $oldPowerSave = Invoke-QaAdb shell settings get global low_power
        if ($oldPowerSave -notin @('0', '1')) { throw 'Unknown emulator power-save state.' }
        $batteryOverridden = $true
        Invoke-QaAdb shell dumpsys battery unplug | Out-Null
        Invoke-QaAdb shell dumpsys battery set level 10 | Out-Null
        Invoke-QaAdb shell cmd power set-mode 1 | Out-Null
        if ((Invoke-QaAdb shell dumpsys battery) -notmatch 'level: 10' -or
            (Invoke-QaAdb shell settings get global low_power) -ne '1') {
            throw 'Emulator low battery and power saver were not observed.'
        }
        Save-Json 'power-state' ([ordered]@{ simulatedBattery = 10; emulatorPowerSaver = $true; realDevice = $false })
    }

    # Run idle first to avoid consuming this UID's allow-while-idle quota in
    # another scenario. No battery-optimization allowlist is added.
    Invoke-Probe 'schedule' 'idle-before' | Out-Null
    Invoke-QaAdb shell input keyevent KEYCODE_HOME | Out-Null
    Invoke-QaAdb shell am kill $qa | Out-Null
    $idle = Invoke-QaAdb shell dumpsys deviceidle force-idle deep
    $forcedIdle = $true
    if ($idle -notmatch 'IDLE') { throw 'Deep idle could not be demonstrated.' }
    Save-Json 'idle-state' ([ordered]@{ forcedDeepIdle = $true; result = $idle; realDevice = $false })
    Start-Sleep -Seconds 21
    Invoke-QaAdb shell dumpsys deviceidle unforce | Out-Null
    $forcedIdle = $false
    $afterIdle = Invoke-Probe 'report' 'idle-delivered'
    if ($afterIdle.delivered -ne 1 -or $afterIdle.active -ne 1) { throw 'Deep-idle exact alarm did not deliver.' }
    Invoke-Probe 'clear' 'clear-idle' | Out-Null

    # Force-stop suppresses this package. Android15+ additionally cancels its
    # PendingIntents. This check proves explicit reopening/reconciliation,
    # not an independent OS-queue cancellation on every Android version.
    Invoke-Probe 'schedule' 'future-before-force-stop' | Out-Null
    Invoke-QaAdb shell am force-stop $qa | Out-Null
    $stopped = (Invoke-QaAdb shell dumpsys package $qa) -match 'stopped=true'
    if (-not $stopped) { throw 'Force-stop was not observed; this is not force-stop evidence.' }
    $restored = Invoke-Probe 'initialize' 'future-after-explicit-reopen'
    if ($restored.pending -ne 1) { throw 'Reopening did not restore the future registration.' }
    Start-Sleep -Seconds 21
    $delivered = Invoke-Probe 'report' 'future-delivered-once'
    if ($delivered.delivered -ne 1 -or $delivered.active -ne 1) { throw 'Restored future reminder did not deliver.' }
    Invoke-Probe 'clear' 'clear-future' | Out-Null

    # A due time elapsed while force-stopped is not a promise to notify later.
    # Check while stopped, then explicitly reopen: expired mirror is removed.
    Invoke-Probe 'schedule' 'expired-before-force-stop' | Out-Null
    Invoke-QaAdb shell am force-stop $qa | Out-Null
    Start-Sleep -Seconds 21
    if ((Invoke-QaAdb shell dumpsys package $qa) -notmatch 'stopped=true') { throw 'The package unexpectedly left force-stop.' }
    $expired = Invoke-Probe 'initialize' 'expired-after-explicit-reopen'
    Assert-Empty $expired 'force-stop expiry'

    Save-Json 'summary' ([ordered]@{
        kind = 'android-a7-system-boundaries-v1'; success = $true
        forceStopObserved = $true; futureValidAfterExplicitReopen = $true
        expiredNotReplayed = $true; exactDeliveredInEmulatorDeepIdle = $true
        simulatedLowBatteryAndPowerSaver = $LowBattery.IsPresent
        realDevice = $false; muMuTouched = $false
    })
    Write-Output "A7 API$ApiLevel system boundaries passed: force-stop/reopen, expiry and emulator deep idle."
} finally {
    if ($forcedIdle) { Invoke-QaAdb shell dumpsys deviceidle unforce | Out-Null }
    if ($batteryOverridden) {
        Invoke-QaAdb shell cmd power set-mode $oldPowerSave | Out-Null
        Invoke-QaAdb shell dumpsys battery reset | Out-Null
    }
    Invoke-Probe 'clear' 'final-clear' | Out-Null
    if (-not $notificationWasGranted) { Invoke-QaAdb shell pm revoke $qa android.permission.POST_NOTIFICATIONS | Out-Null }
    if (-not $exactWasAllowed) { Invoke-QaAdb shell appops set $qa SCHEDULE_EXACT_ALARM default | Out-Null }
}
