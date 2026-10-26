param(
    [string]$IpaPath,
    [string]$ExpectedRevision,
    [string]$ReportPath,
    [string]$PythonPath
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($IpaPath) -or [string]::IsNullOrWhiteSpace($ExpectedRevision)) {
    [Console]::Error.WriteLine('i0 verification failed: invalid_arguments')
    exit 2
}

$verifierPath = Join-Path $PSScriptRoot 'ios-i0\verify_package.py'
if (-not (Test-Path -LiteralPath $verifierPath -PathType Leaf)) {
    [Console]::Error.WriteLine('i0 verification failed: verifier_unavailable')
    exit 2
}

$selectedPython = $PythonPath
if ([string]::IsNullOrWhiteSpace($selectedPython)) {
    $basic310Python = 'E:\conda\envs\basic310\python.exe'
    if (Test-Path -LiteralPath $basic310Python -PathType Leaf) {
        $selectedPython = $basic310Python
    }
    else {
        $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
        if ($null -ne $pythonCommand -and (Test-Path -LiteralPath $pythonCommand.Source -PathType Leaf)) {
            $selectedPython = $pythonCommand.Source
        }
    }
}

if ([string]::IsNullOrWhiteSpace($selectedPython) -or -not (Test-Path -LiteralPath $selectedPython -PathType Leaf)) {
    [Console]::Error.WriteLine('i0 verification failed: python_runtime_unavailable')
    exit 2
}

$nativeArguments = @(
    $verifierPath,
    '--ipa', $IpaPath,
    '--expected-revision', $ExpectedRevision
)
if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
    $nativeArguments += @('--report', $ReportPath)
}

& $selectedPython @nativeArguments
$nativeExitCode = $LASTEXITCODE
if ($null -eq $nativeExitCode) {
    [Console]::Error.WriteLine('i0 verification failed: python_invocation_failed')
    exit 2
}
exit $nativeExitCode
