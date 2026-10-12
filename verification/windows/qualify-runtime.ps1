param(
    [Parameter(Mandatory=$true)][string]$EvidencePath,
    [string]$BrowserExecutableFolder,
    [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')][string]$ExpectedRuntimeVersion
)
$ErrorActionPreference = 'Stop'
if ([bool]$BrowserExecutableFolder -ne [bool]$ExpectedRuntimeVersion) { throw 'Candidate folder and ExpectedRuntimeVersion must be supplied together.' }
$EvidencePath = [IO.Path]::GetFullPath($EvidencePath)
if (-not $EvidencePath.StartsWith($PSScriptRoot + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Qualification evidence must remain inside verification/windows.' }
if (Test-Path -LiteralPath $EvidencePath) { throw 'Qualification requires a new evidence path.' }
$prefix = [IO.Path]::Combine([IO.Path]::GetDirectoryName($EvidencePath),[IO.Path]::GetFileNameWithoutExtension($EvidencePath))
# A version number never qualifies an engine. Exercise the known regression
# first, then initial documents and both five-context native network suites.
$stages = @('connection-allowlist-minimal-navigation','connection-allowlist-minimal','connection-allowlist')
foreach ($stage in $stages) { if (Test-Path -LiteralPath ($prefix + '-' + $stage + '.json')) { throw 'Qualification child evidence must also be new.' } }
$report = [ordered]@{
    utc = [DateTime]::UtcNow.ToString('o')
    qualified = $false
    scope = 'Synthetic loopback runtime regression gate only; not V-02 closure, school login or M0 approval.'
    runtime = $null
    sourceSha256 = [ordered]@{}
    stages = @()
}
foreach ($name in @('WindowsProbe.cs','run.ps1','qualify-runtime.ps1')) { $report.sourceSha256[$name] = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name) -Algorithm SHA256).Hash.ToLowerInvariant() }
$blocked = $false
foreach ($stage in $stages) {
    if ($blocked) { $report.stages += [ordered]@{variant=$stage;status='not_run';reason='Earlier native regression or evidence validation failed.'}; continue }
    $childPath = $prefix + '-' + $stage + '.json'
    $arguments = @{Variant=$stage;EvidencePath=$childPath}
    if ($BrowserExecutableFolder) { $arguments.BrowserExecutableFolder=$BrowserExecutableFolder; $arguments.ExpectedRuntimeVersion=$ExpectedRuntimeVersion }
    try {
        & (Join-Path $PSScriptRoot 'run.ps1') @arguments | Out-Null
        $childExit = $LASTEXITCODE
        $evidence = Get-Content -LiteralPath $childPath -Raw | ConvertFrom-Json
        $checks = @($evidence.checks)
        $failures = @($checks | Where-Object {$_.status -eq 'fail'})
        $versionMatches = $evidence.runtime -and (-not $report.runtime -or $report.runtime -eq $evidence.runtime)
        if (-not $report.runtime) { $report.runtime = $evidence.runtime }
        # Require actual positive execution, policy and cleanup evidence. Empty
        # or incomplete output must fail even when it has no explicit failures.
        $required = if ($stage.StartsWith('connection-allowlist-minimal')) {
            $navigated = $stage.EndsWith('-navigation')
            $modes = if ($navigated) {@('calMinimalNavigateReference','calMinimalNavigate','calMinimalNavigateRestart','calDirectNavigate','calDirectNavigateRestart')} else {@('calMinimalReference','calMinimal','calMinimalRestart','calDirect','calDirectRestart')}
            @('CAL_minimal_cleanup') + @($modes | ForEach-Object { 'CAL_minimal_RTC_' + $_; 'CAL_minimal_receipt_' + $_; 'DNR_policy_ready_' + $_; 'close_and_drain_' + $_; if ($navigated) {'CAL_minimal_second_navigation_' + $_} })
        } else {
            # Every browser child must finish, with positive reference receipts
            # and guarded receipts; the underlying suites validate each channel.
            @('CAL_UDF_cleanup','CAL_HTTPS_UDF_cleanup','CAL_HTTPS_fixture_shutdown')
        }
        $complete = $true
        foreach ($id in $required) { if (@($checks | Where-Object {$_.id -eq $id -and $_.status -eq 'pass'}).Count -ne 1) {$complete=$false} }
        if (-not $stage.StartsWith('connection-allowlist-minimal')) {
            foreach ($context in @('main','frame','srcdoc','aboutblank','blob')) {
                foreach ($mode in @('calReference','cal','calRestart')) {
                    $ids = @()
                    $ids += 'CAL_http_' + $mode + '_' + $context + '_case_' + $context
                    $ids += 'DNR_policy_ready_' + $mode + '_case_' + $context
                    $ids += 'close_and_drain_' + $mode + '_case_' + $context
                    foreach ($channel in @('stun','turn','wt')) {$ids += 'CAL_attempt_' + $mode + '_' + $context + '_' + $channel + '_case_' + $context; $ids += 'CAL_receipt_' + $mode + '_' + $context + '_' + $channel}
                    foreach ($kind in @('dedicated','shared','service')) { $ids += 'CAL_worker_guard_' + $mode + '_' + $context + '_' + $kind + '_case_' + $context }
                    $ids += 'CAL_HTTPS_receipts_' + $mode + '_' + $context
                    foreach ($key in @('GET','WT_attempt','WT_outcome')) {$ids += 'CAL_HTTPS_' + $key + '_' + $mode + '_' + $context + '_https_case_' + $context}
                    $ids += 'DNR_policy_ready_' + $mode + '_https_case_' + $context
                    $ids += 'close_and_drain_' + $mode + '_https_case_' + $context
                    foreach ($id in $ids) {if (@($checks | Where-Object {$_.id -eq $id -and $_.status -eq 'pass'}).Count -ne 1) {$complete=$false}}
                }
            }
        }
        $passed = $childExit -eq 0 -and $failures.Count -eq 0 -and $complete -and $versionMatches -and $evidence.deletePending -eq $false
        $report.stages += [ordered]@{variant=$stage;status=$(if($passed){'pass'}else{'fail'});exitCode=$childExit;evidence=[IO.Path]::GetFileName($childPath);sha256=(Get-FileHash -LiteralPath $childPath -Algorithm SHA256).Hash.ToLowerInvariant();failureCount=$failures.Count;requiredEvidenceComplete=$complete;runtimeConsistent=[bool]$versionMatches;deletePending=$evidence.deletePending}
        if (-not $passed) {$blocked=$true}
    } catch {
        $report.stages += [ordered]@{variant=$stage;status='fail';exceptionType=$_.Exception.GetType().FullName}
        $blocked=$true
    }
}
$report.qualified = -not $blocked -and @($report.stages | Where-Object {$_.status -eq 'pass'}).Count -eq $stages.Count
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $EvidencePath -Encoding UTF8
Get-Content -LiteralPath $EvidencePath
if (-not $report.qualified) {exit 1}
exit 0
