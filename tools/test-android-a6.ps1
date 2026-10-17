[CmdletBinding()]
param([string]$SdkRoot = 'E:\Android\Sdk')

# Fixed local TTS fixture only. ADB 5038 and the retained isolated QA app only.
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$adb = Join-Path $SdkRoot 'platform-tools/adb.exe'
$serial = 'emulator-5582'
$qa = 'cn.ustcassistant.mobile.qa'
$reports = Join-Path $workspace 'app/build/android-a6/reports'
New-Item -ItemType Directory -Force -Path $reports | Out-Null
function Invoke-QaAdb {
    # Windows PowerShell turns adb's successful progress-on-stderr into an
    # ErrorRecord when redirected. Judge the native exit code explicitly.
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $result = & $adb -P 5038 -s $serial @args 2>&1
        $nativeExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    if ($nativeExit -ne 0) { throw "A6 QA ADB failed: $($result -join ' ')" }
    return ($result -join "`n").Trim()
}
if ((Invoke-QaAdb shell getprop ro.boot.qemu.avd_name) -ne 'ustc_android_a0_api36') {
    throw 'A6 requires its isolated API36 AVD.'
}
if ((Invoke-QaAdb shell run-as $qa pwd) -ne "/data/user/0/$qa") {
    throw 'A6 refuses an unknown application data root.'
}
$wav = Join-Path $workspace 'app/build/m58-probe/synthetic.wav'
if (-not (Test-Path -LiteralPath $wav)) {
    & (Join-Path $PSScriptRoot 'prepare-synthetic-speech.ps1')
}
if ((Get-Item -LiteralPath $wav).Length -gt 1000000) { throw 'Unexpected synthetic WAV size.' }
$deviceTemporary = '/data/local/tmp/ustc-a6-synthetic.wav'
$privateFixture = 'no_backup/ustc_assistant_v1/a6-synthetic.wav'
try {
    Invoke-QaAdb push $wav $deviceTemporary | Out-Null
    Invoke-QaAdb shell run-as $qa mkdir -p no_backup/ustc_assistant_v1 | Out-Null
    Invoke-QaAdb shell run-as $qa cp $deviceTemporary $privateFixture | Out-Null
    & (Join-Path $PSScriptRoot 'android-a0.ps1') -Action IntegrationTest -IntegrationSuite A6
    if ($LASTEXITCODE -ne 0) { throw 'A6 Android synthetic integration failed.' }
} finally {
    # Only these fixed synthetic files; no business roots, caches or profiles.
    Invoke-QaAdb shell run-as $qa rm -f $privateFixture | Out-Null
    Invoke-QaAdb shell rm -f $deviceTemporary | Out-Null
}
