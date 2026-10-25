#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$ScannerPath,
    [string[]]$Revisions = @('HEAD'),
    [string]$ReportDirectory,
    [switch]$RequireClean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$workspaceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $ReportDirectory) { $ReportDirectory = Join-Path $workspaceRoot 'app/build/release-preparation/audit' }
$reportRoot = [IO.Path]::GetFullPath($ReportDirectory)
$buildRoot = [IO.Path]::GetFullPath((Join-Path $workspaceRoot 'app/build')).TrimEnd('\', '/')
if (-not $reportRoot.StartsWith($buildRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Audit reports must stay under the ignored application build directory.'
}
$cursor = $reportRoot
while ($cursor.Length -ge $workspaceRoot.Length) {
    if ((Test-Path -LiteralPath $cursor) -and
        ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Audit report path contains a reparse point.'
    }
    if ($cursor -eq $workspaceRoot) { break }
    $cursor = [IO.Path]::GetDirectoryName($cursor)
}
if (-not $ScannerPath) {
    $installedScanner = Get-Command gitleaks -ErrorAction SilentlyContinue
    if ($installedScanner) { $ScannerPath = $installedScanner.Source }
    else { $ScannerPath = Join-Path $workspaceRoot 'app/build/release-preparation/tools/gitleaks-8.30.1/gitleaks.exe' }
}
$scanner = [IO.Path]::GetFullPath($ScannerPath)
if (-not (Test-Path -LiteralPath $scanner -PathType Leaf)) { throw 'Install the pinned Gitleaks 8.30.1 scanner first.' }
if ((Get-Item -LiteralPath $scanner -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Scanner executable must be a regular file.' }

function Invoke-AuditProcess([string]$Executable, [string[]]$Arguments, [int]$TimeoutSeconds = 330) {
    $start = [Diagnostics.ProcessStartInfo]::new($Executable)
    $start.WorkingDirectory = $workspaceRoot
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            throw 'The scoped audit process timed out.'
        }
        return [pscustomobject]@{exitCode=$process.ExitCode;stdout=$stdoutTask.GetAwaiter().GetResult();stderr=$stderrTask.GetAwaiter().GetResult()}
    } finally { $process.Dispose() }
}

$gitExecutable = (Get-Command git -ErrorAction Stop).Source
$status = Invoke-AuditProcess $gitExecutable @('--no-optional-locks','status','--porcelain=v1')
if ($status.exitCode -ne 0 -or $status.stderr) { throw 'Cannot check the source worktree.' }
if ($RequireClean -and $status.stdout) { throw 'The publication audit requires a clean committed worktree.' }
$version = Invoke-AuditProcess $scanner @('version')
if ($version.exitCode -ne 0 -or $version.stderr -or $version.stdout.Trim() -cne '8.30.1') {
    throw 'This audit is pinned to Gitleaks 8.30.1.'
}
$resolved = [Collections.Generic.List[object]]::new()
foreach ($revision in $Revisions) {
    if ($revision -notmatch '^[A-Za-z0-9][A-Za-z0-9_./-]*$' -or $revision.Contains('..')) { throw 'Invalid audit revision.' }
    $check = Invoke-AuditProcess $gitExecutable @('rev-parse','--verify','--end-of-options',($revision + '^{commit}'))
    if ($check.exitCode -ne 0 -or $check.stderr -or $check.stdout.Trim() -notmatch '^[0-9a-f]{40}$') { throw 'Cannot resolve an audit revision.' }
    $resolved.Add([pscustomobject]@{ref=$revision;commit=$check.stdout.Trim()})
}
if ($resolved.Count -eq 0) { throw 'Select at least one revision; private local stash/checkpoints are not scanned implicitly.' }
[void][IO.Directory]::CreateDirectory($reportRoot)
$rulesPath = Join-Path $reportRoot 'builtin-rules.toml'
[IO.File]::WriteAllText($rulesPath,"[extend]`nuseDefault = true`n",[Text.UTF8Encoding]::new($false))
$reportPath = Join-Path $reportRoot ('source-audit-' + [guid]::NewGuid().ToString('N') + '.json')
$logOptions = '--no-textconv --no-ext-diff --full-history ' + ($resolved.commit -join ' ')
$scan = Invoke-AuditProcess $scanner @(
    'git',$workspaceRoot,'--log-opts',$logOptions,'--config',$rulesPath,
    '--gitleaks-ignore-path',(Join-Path $workspaceRoot '.gitleaksignore'),
    '--redact=100','--no-banner','--log-level','error','--timeout','300',
    '--report-format','template','--report-template',(Join-Path $PSScriptRoot 'gitleaks-safe-report.tmpl'),
    '--report-path',$reportPath
)
# Gitleaks may return zero even if its nested Git process fails. Never call that
# a clean scan. No unfiltered stdout/stderr or match values are saved or emitted.
if ($scan.stderr -or $scan.stdout -or $scan.exitCode -notin @(0,1) -or -not (Test-Path -LiteralPath $reportPath)) {
    throw 'The scanner or nested Git process failed; no passing audit was recorded.'
}
$findings = @(Get-Content -Raw -LiteralPath $reportPath | ConvertFrom-Json)
$summary = [ordered]@{
    kind='public-source-audit-v1';scanner='8.30.1';revisions=$resolved.ToArray()
    findings=$findings.Count;reportFile=[IO.Path]::GetFileName($reportPath)
    workingTreeIncluded=$false;worktreeDirty=[bool]$status.stdout
    externalGitFiltersDisabled=$true;reportHasMatchOrSecretFields=$false
    observedUtc=[DateTime]::UtcNow.ToString('o')
}
$summary | ConvertTo-Json -Depth 5
if ($scan.exitCode -ne 0 -or $findings.Count -ne 0) { throw 'Review the safe finding locations before publication.' }
