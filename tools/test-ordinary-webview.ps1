param(
    [string]$SdkRoot = 'E:\Android\Sdk',
    [ValidateSet('emulator-5590', 'emulator-5592', 'emulator-5594', 'emulator-5588', 'emulator-5586')]
    [string]$Serial = 'emulator-5590',
    [string]$ExpectedAvd = '',
    [ValidateRange(1, 65535)]
    [int]$AdbServerPort = 5038,
    [switch]$OrdinaryOnly
)

$ErrorActionPreference = 'Stop'
$workspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$adb = Join-Path $SdkRoot 'platform-tools/adb.exe'
$qaPackage = 'cn.ustcassistant.mobile.qa'
$runner = "$qaPackage.test/androidx.test.runner.AndroidJUnitRunner"
$allowedTargets = @{
    'emulator-5590' = [pscustomobject]@{ Avd = 'ustc_android_a0_api28'; Api = 28 }
    'emulator-5592' = [pscustomobject]@{ Avd = 'ustc_android_a0_api29'; Api = 29 }
    'emulator-5594' = [pscustomobject]@{ Avd = 'ustc_android_a0_api32'; Api = 32 }
    'emulator-5588' = [pscustomobject]@{ Avd = 'ustc_android_a0_api34'; Api = 34 }
    'emulator-5586' = [pscustomobject]@{ Avd = 'ustc_android_a2_current_provider'; Api = 37 }
}

if (-not (Test-Path -LiteralPath $adb -PathType Leaf)) {
    throw "Android adb was not found at the configured SDK root: $adb"
}

$target = $allowedTargets[$Serial]
if ($null -eq $target) {
    throw 'Only the five fixed isolated Android emulators are accepted.'
}
if ([string]::IsNullOrWhiteSpace($ExpectedAvd)) {
    $ExpectedAvd = $target.Avd
} elseif ($ExpectedAvd -cne $target.Avd) {
    throw 'The requested serial and expected AVD do not match the fixed whitelist.'
}

function Invoke-QaAdbCapture {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $previousErrorPreference = $ErrorActionPreference
    try {
        # Windows PowerShell can surface redirected native stderr as ErrorRecord objects.
        $ErrorActionPreference = 'Continue'
        $raw = & $adb -P "$AdbServerPort" -s $Serial @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorPreference
    }

    $lines = @($raw | ForEach-Object { [string]$_ })
    $text = [string]::Join([Environment]::NewLine, $lines)
    return [pscustomobject]@{ Text = $text.Trim(); ExitCode = [int]$exitCode }
}

function Invoke-QaAdbText {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $capture = Invoke-QaAdbCapture -Arguments $Arguments
    if ($capture.ExitCode -ne 0) {
        throw "Read-only QA adb command failed ($($capture.ExitCode)): $($Arguments -join ' ')"
    }
    return $capture.Text
}

function Get-CurrentWebViewProvider {
    param([Parameter(Mandatory = $true)][string]$DumpsysText)

    $providerPattern = '^\s*Current WebView package(?:\s+\(name,\s*version\))?\s*:\s*\(?\s*(?<name>[A-Za-z0-9][A-Za-z0-9._-]*)\s*,\s*(?<version>[A-Za-z0-9][A-Za-z0-9.+_-]*)\s*\)?\s*$'
    foreach ($line in ($DumpsysText -split "`r?`n")) {
        if ($line -match $providerPattern) {
            return [pscustomobject]@{
                Name = $Matches['name']
                Version = $Matches['version']
            }
        }
    }
    throw 'Could not parse the current WebView provider name and version from dumpsys webviewupdate.'
}

$actualAvd = Invoke-QaAdbText -Arguments @('shell', 'getprop', 'ro.boot.qemu.avd_name')
if ([string]::IsNullOrWhiteSpace($actualAvd)) {
    $actualAvd = Invoke-QaAdbText -Arguments @('shell', 'getprop', 'ro.kernel.qemu.avd_name')
}
$consoleIdentity = (Invoke-QaAdbText -Arguments @('emu', 'avd', 'name')) -split "`r?`n"
$isEmulator = Invoke-QaAdbText -Arguments @('shell', 'getprop', 'ro.kernel.qemu')
if ($actualAvd -cne $ExpectedAvd -or $isEmulator -cne '1' -or
    $consoleIdentity.Count -lt 2 -or $consoleIdentity[0].Trim() -cne $ExpectedAvd) {
    throw 'The connected target is not the whitelisted independent emulator.'
}

$installedPackage = Invoke-QaAdbText -Arguments @('shell', 'pm', 'path', $qaPackage)
if (-not $installedPackage.StartsWith('package:', [StringComparison]::Ordinal)) {
    throw 'The retained QA package must already be installed; this script never installs or removes packages.'
}

$apiText = Invoke-QaAdbText -Arguments @('shell', 'getprop', 'ro.build.version.sdk')
$api = 0
if (-not [int]::TryParse($apiText, [Globalization.NumberStyles]::Integer,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$api) -or $api -ne $target.Api) {
    throw "The connected emulator API level does not match the whitelist (expected $($target.Api))."
}
$abi = Invoke-QaAdbText -Arguments @('shell', 'getprop', 'ro.product.cpu.abi')
if ([string]::IsNullOrWhiteSpace($abi)) {
    throw 'The connected emulator did not report a primary ABI.'
}
$provider = Get-CurrentWebViewProvider -DumpsysText (Invoke-QaAdbText -Arguments @('shell', 'dumpsys', 'webviewupdate'))

$reportRoot = Join-Path $workspaceRoot "app/build/android-webview2/reports/$ExpectedAvd"
New-Item -ItemType Directory -Force -Path $reportRoot | Out-Null
$nativePath = Join-Path $reportRoot 'native.txt'
$summaryPath = Join-Path $reportRoot 'summary.json'

$instrumentArguments = @('shell', 'am', 'instrument', '-w', '-r')
$selectedTestClasses = @()
if ($OrdinaryOnly) {
    $selectedTestClasses = @(
        'cn.ustcassistant.mobile.qa.OrdinaryBrowserProtocolTest',
        'cn.ustcassistant.mobile.qa.OrdinaryPartitionLedgerTest',
        'cn.ustcassistant.mobile.qa.OrdinaryHostIsolationTest',
        'cn.ustcassistant.mobile.qa.A2ProviderTest',
        'cn.ustcassistant.mobile.qa.A2YoungTransportTest'
    )
    $instrumentArguments += @('-e', 'class', ($selectedTestClasses -join ','))
}
$instrumentArguments += $runner

$instrumentation = Invoke-QaAdbCapture -Arguments $instrumentArguments
$nativeText = $instrumentation.Text
[IO.File]::WriteAllText($nativePath, $nativeText + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))

$passed = 0
$skipped = 0
$failed = 0
$statusCodeCounts = [ordered]@{
    completed0 = 0
    ignoredMinus3 = 0
    assumptionFailureMinus4 = 0
    errorMinus1 = 0
    assertionFailureMinus2 = 0
    otherNegative = 0
}
$statusCodeMatches = [regex]::Matches($nativeText, '(?m)^\s*INSTRUMENTATION_STATUS_CODE:\s*(-?\d+)\s*$')
foreach ($statusMatch in $statusCodeMatches) {
    $statusCode = [int]$statusMatch.Groups[1].Value
    switch ($statusCode) {
        0 {
            $passed++
            $statusCodeCounts.completed0++
        }
        -3 {
            $skipped++
            $statusCodeCounts.ignoredMinus3++
        }
        -4 {
            $skipped++
            $statusCodeCounts.assumptionFailureMinus4++
        }
        -1 {
            $failed++
            $statusCodeCounts.errorMinus1++
        }
        -2 {
            $failed++
            $statusCodeCounts.assertionFailureMinus2++
        }
        default {
            if ($statusCode -lt 0) {
                $failed++
                $statusCodeCounts.otherNegative++
            }
        }
    }
}

$instrumentationCodeMatches = [regex]::Matches($nativeText, '(?m)^\s*INSTRUMENTATION_CODE:\s*(-?\d+)\s*$')
$finalInstrumentationCode = $null
if ($instrumentationCodeMatches.Count -gt 0) {
    $finalInstrumentationCode = [int]$instrumentationCodeMatches[$instrumentationCodeMatches.Count - 1].Groups[1].Value
}
$failureMarkers = [ordered]@{
    failuresBanner = ($nativeText -match '(?i)FAILURES!!!')
    instrumentationFailed = ($nativeText -match '(?i)INSTRUMENTATION_FAILED')
    instrumentationAborted = ($nativeText -match '(?i)INSTRUMENTATION_ABORTED')
    processCrash = ($nativeText -match '(?i)(Process crashed|FATAL EXCEPTION)')
}
$reportedTestSummary = $null
if ($nativeText -match '(?m)^\s*(OK\s+\(\d+\s+tests?\)|FAILURES!!!)\s*$') {
    $reportedTestSummary = $Matches[1]
}
$statusEvents = $passed + $skipped + $failed
$success = ($instrumentation.ExitCode -eq 0 -and
    $finalInstrumentationCode -eq -1 -and
    $statusEvents -gt 0 -and
    $passed -gt 0 -and
    $failed -eq 0 -and
    -not $failureMarkers.failuresBanner -and
    -not $failureMarkers.instrumentationFailed -and
    -not $failureMarkers.instrumentationAborted -and
    -not $failureMarkers.processCrash)

$summary = [ordered]@{
    kind = 'android-ordinary-webview-instrumentation-v1'
    success = $success
    avd = $ExpectedAvd
    serial = $Serial
    api = $api
    abi = $abi
    webViewProviderName = $provider.Name
    webViewProviderVersion = $provider.Version
    ordinaryOnly = [bool]$OrdinaryOnly
    selectedTestClasses = $selectedTestClasses
    nativeCounts = [ordered]@{
        passed = $passed
        skipped = $skipped
        failed = $failed
        statusEvents = $statusEvents
        statusCodes = $statusCodeCounts
    }
    instrumentationExitCode = $instrumentation.ExitCode
    instrumentationCode = $finalInstrumentationCode
    reportedTestSummary = $reportedTestSummary
    failureMarkers = $failureMarkers
    syntheticOnly = $true
    realDevice = $false
    realSchool = $false
    report = 'native.txt'
}
$summaryJson = $summary | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText($summaryPath, $summaryJson + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
Write-Output $summaryJson

if (-not $success) {
    throw "Ordinary WebView instrumentation did not pass. Inspect the synthetic report: $nativePath"
}
