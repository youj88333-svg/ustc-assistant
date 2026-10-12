param(
    [switch]$CompileOnly,
    [ValidateSet('all','dnr','worker-guard','connection-allowlist','connection-allowlist-minimal','connection-allowlist-minimal-navigation','connection-allowlist-https')][string]$Variant = 'all',
    [string]$EvidencePath,
    [string]$BrowserExecutableFolder,
    [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')][string]$ExpectedRuntimeVersion
)
$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$runtime = Join-Path $workspace 'verification\.runtime\windows'
$bin = Join-Path $runtime 'bin'
if ($BrowserExecutableFolder) {
    if (-not $ExpectedRuntimeVersion) { throw 'An isolated candidate requires ExpectedRuntimeVersion.' }
    $BrowserExecutableFolder = (Resolve-Path -LiteralPath $BrowserExecutableFolder).Path.TrimEnd('\')
    $candidateRoot = [IO.Path]::GetFullPath((Join-Path $workspace 'verification\.runtime\engine-candidates'))
    if (-not $BrowserExecutableFolder.StartsWith($candidateRoot + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Candidate runtime must be inside verification/.runtime/engine-candidates.' }
    $cursor = Get-Item -LiteralPath $BrowserExecutableFolder
    while ($cursor) {
        if ($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Candidate runtime ancestors must not be reparse points.' }
        $cursor = $cursor.Parent
    }
    $executables = @('msedgewebview2.exe','msedge.exe') | ForEach-Object { Join-Path $BrowserExecutableFolder $_ } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
    if (-not $executables) { throw 'Candidate folder has no runtime executable.' }
    foreach ($binary in @($executables) + @(Join-Path $BrowserExecutableFolder 'msedge.dll')) {
        $item = Get-Item -LiteralPath $binary
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Candidate binaries must not be reparse points.' }
        $signature = Get-AuthenticodeSignature -LiteralPath $binary
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') { throw 'Candidate binaries require valid Microsoft Authenticode signatures.' }
        if ($item.VersionInfo.ProductVersion.Split(' ')[0] -ne $ExpectedRuntimeVersion) { throw 'Candidate binary version mismatch.' }
    }
} elseif ($ExpectedRuntimeVersion) { throw 'ExpectedRuntimeVersion requires an isolated candidate folder.' }
New-Item -ItemType Directory -Force -Path $bin | Out-Null
$sdk = Join-Path $env:USERPROFILE '.nuget\packages\microsoft.web.webview2\1.0.3967.48'
foreach ($name in @('Microsoft.Web.WebView2.Core.dll','Microsoft.Web.WebView2.WinForms.dll')) {
    Copy-Item -LiteralPath (Join-Path $sdk "lib\net462\$name") -Destination $bin -Force
}
Copy-Item -LiteralPath (Join-Path $sdk 'runtimes\win-x64\native\WebView2Loader.dll') -Destination $bin -Force
$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $csc /nologo /target:exe /platform:x64 /langversion:5 /out:"$bin\WindowsProbe.exe" /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Security.dll /r:System.Web.Extensions.dll /r:"$bin\Microsoft.Web.WebView2.Core.dll" /r:"$bin\Microsoft.Web.WebView2.WinForms.dll" "$PSScriptRoot\WindowsProbe.cs"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if ($CompileOnly) { exit 0 }
if (-not $EvidencePath) {
    $EvidencePath = Join-Path $PSScriptRoot $(if ($Variant -eq 'dnr') {'evidence-dnr.json'} elseif ($Variant -eq 'worker-guard') {'evidence-worker-guard.json'} elseif ($Variant.StartsWith('connection-allowlist')) {'evidence-' + $Variant + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json'} else {'evidence.json'})
}
$EvidencePath = [IO.Path]::GetFullPath($EvidencePath)
if (-not ($EvidencePath.StartsWith($PSScriptRoot + '\',[StringComparison]::OrdinalIgnoreCase) -or $EvidencePath.StartsWith($runtime + '\',[StringComparison]::OrdinalIgnoreCase))) {
    throw 'EvidencePath must remain inside verification/windows or verification/.runtime/windows.'
}
if ($Variant.StartsWith('connection-allowlist') -and (Test-Path -LiteralPath $EvidencePath)) { throw 'Connection allowlist evidence must use a new path; previous runs are preserved.' }
$mode = if ($Variant -eq 'dnr') {'dnr-suite'} elseif ($Variant -eq 'worker-guard') {'worker-guard-suite'} elseif ($Variant -eq 'connection-allowlist') {'connection-allowlist-suite'} elseif ($Variant -eq 'connection-allowlist-minimal') {'connection-allowlist-minimal-suite'} elseif ($Variant -eq 'connection-allowlist-minimal-navigation') {'connection-allowlist-minimal-navigation-suite'} elseif ($Variant -eq 'connection-allowlist-https') {'connection-allowlist-https-suite'} else {'suite'}
$runRoot = Join-Path $runtime ('run-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runRoot | Out-Null
# Candidate selection affects only this helper and its descendants; no system
# installation or persistent WEBVIEW2/browser/proxy setting is changed.
$start = New-Object Diagnostics.ProcessStartInfo
$start.FileName = Join-Path $bin 'WindowsProbe.exe'
$start.Arguments = $mode + ' "' + $runRoot + '" "' + $EvidencePath + '"'
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
$start.EnvironmentVariables.Remove('DESIGN_RESET_BROWSER_EXECUTABLE_FOLDER')
$start.EnvironmentVariables.Remove('DESIGN_RESET_EXPECTED_RUNTIME_VERSION')
if ($BrowserExecutableFolder) {
    $start.EnvironmentVariables['DESIGN_RESET_BROWSER_EXECUTABLE_FOLDER'] = $BrowserExecutableFolder
    $start.EnvironmentVariables['DESIGN_RESET_EXPECTED_RUNTIME_VERSION'] = $ExpectedRuntimeVersion
}
$proc = [Diagnostics.Process]::Start($start)
$suiteTimeout = if ($Variant -eq 'connection-allowlist') {300000} else {150000}
if (-not $proc.WaitForExit($suiteTimeout)) { $proc.Kill(); throw 'Local suite timeout; retained runtime for recovery.' }
Get-Content -LiteralPath $EvidencePath
exit $proc.ExitCode
