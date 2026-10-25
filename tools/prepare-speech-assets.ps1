[CmdletBinding()]
param([switch]$Check)

$ErrorActionPreference = 'Stop'
$workspace = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$buildRoot = Join-Path $workspace 'app/build'
$modelRoot = Join-Path $buildRoot 'speech_models/sensevoice'
$downloadRoot = Join-Path $buildRoot 'm58-model-download'
$archive = Join-Path $downloadRoot 'sensevoice-int8-2024-07-17.tar.bz2'
$archiveSha = '7d1efa2138a65b0b488df37f8b89e3d91a60676e416f515b952358d83dfd347e'
$sourceUrl = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2'
$files = @(
    @{ Name = 'model.int8.onnx'; Bytes = 239233841; Sha = 'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51' },
    @{ Name = 'tokens.txt'; Bytes = 315894; Sha = 'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc' },
    @{ Name = 'LICENSE'; Bytes = 71; Sha = '221c6df10b0931a5629adad671ea48fb7747e034c414b6d2bfa275bc3dd4ea17' }
)

function Assert-PlainBuildPath([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    $prefix = [System.IO.Path]::GetFullPath($buildRoot).TrimEnd('\', '/') + '\'
    if (-not ($full.Equals($prefix.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase))) {
        throw 'Speech asset path leaves the application build directory.'
    }
    $cursor = $full
    while ($cursor -and $cursor.Length -ge $workspace.Length) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                throw 'Speech asset path contains a reparse point.'
            }
        }
        if ($cursor.Equals($workspace, [System.StringComparison]::OrdinalIgnoreCase)) { break }
        $cursor = Split-Path -Parent $cursor
    }
    return $full
}

function Assert-File([string]$Path, [long]$Bytes, [string]$Sha) {
    $plain = Assert-PlainBuildPath $Path
    if (-not (Test-Path -LiteralPath $plain -PathType Leaf) -or
        (Get-Item -LiteralPath $plain).Length -ne $Bytes -or
        (Get-FileHash -LiteralPath $plain -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Sha) {
        throw 'Fixed speech asset is absent or does not match its recorded checksum.'
    }
}

$ready = $true
foreach ($asset in $files) {
    try { Assert-File (Join-Path $modelRoot $asset.Name) $asset.Bytes $asset.Sha }
    catch { $ready = $false; break }
}
if ($Check -and -not $ready) { throw 'Prepare the fixed speech assets before building a speech-enabled release.' }
if (-not $ready) {
    [void](Assert-PlainBuildPath $downloadRoot)
    New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
        $partial = Assert-PlainBuildPath ($archive + '.partial')
        & curl.exe --fail --location --silent --show-error --output $partial $sourceUrl
        if ($LASTEXITCODE -ne 0) { throw 'Public speech model download failed.' }
        Assert-File $partial 163002883 $archiveSha
        Move-Item -LiteralPath $partial -Destination (Assert-PlainBuildPath $archive)
    }
    Assert-File $archive 163002883 $archiveSha
    $staging = Assert-PlainBuildPath (Join-Path $buildRoot ('speech-staging-' + [guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $staging | Out-Null
    try {
        # Only these exact archive entries are extracted. No example recordings.
        & tar.exe -xjf $archive -C $staging --strip-components=1 `
            'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17/model.int8.onnx' `
            'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17/tokens.txt' `
            'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17/LICENSE'
        if ($LASTEXITCODE -ne 0) { throw 'Fixed speech asset extraction failed.' }
        foreach ($asset in $files) { Assert-File (Join-Path $staging $asset.Name) $asset.Bytes $asset.Sha }
        [void](Assert-PlainBuildPath $modelRoot)
        New-Item -ItemType Directory -Path $modelRoot -Force | Out-Null
        foreach ($asset in $files) {
            Copy-Item -LiteralPath (Join-Path $staging $asset.Name) -Destination (Assert-PlainBuildPath (Join-Path $modelRoot $asset.Name))
        }
    } finally {
        # Remove only known, plain staging files, after resolving the target.
        foreach ($asset in $files) {
            $target = Assert-PlainBuildPath (Join-Path $staging $asset.Name)
            if (Test-Path -LiteralPath $target -PathType Leaf) { Remove-Item -LiteralPath $target }
        }
        $target = Assert-PlainBuildPath $staging
        if ((Get-ChildItem -LiteralPath $target -Force | Measure-Object).Count -eq 0) { Remove-Item -LiteralPath $target }
    }
}
foreach ($asset in $files) { Assert-File (Join-Path $modelRoot $asset.Name) $asset.Bytes $asset.Sha }
foreach ($notice in @('NOTICE.txt', 'FUNASR-MODEL-LICENSE.txt', 'RECORD-LICENSE.txt', 'SHERPA-ONNX-LICENSE.txt', 'ONNXRUNTIME-LICENSE.txt')) {
    if (-not (Test-Path -LiteralPath (Join-Path $workspace ('app/resources/speech/' + $notice)) -PathType Leaf)) {
        throw 'Speech distribution notice or license is absent.'
    }
}
Write-Output 'Speech assets verified: SenseVoice INT8 2024-07-17, 3 fixed files, no user audio.'
