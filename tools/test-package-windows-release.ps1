$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'package-windows-private.ps1')

$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$build = Join-Path $workspace 'app\build'
if (-not (Test-Path -LiteralPath $build -PathType Container)) { throw 'app/build must exist for synthetic checks.' }
$temp = Join-Path $build ('_public-package-test-' + [guid]::NewGuid().ToString('N'))
$script:checks = 0

function Check([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "Assertion failed: $Message" }; $script:checks++
}
function Throws([scriptblock]$Action, [string]$Pattern, [string]$Message) {
  try { & $Action } catch { if ($_.Exception.Message -match $Pattern) { $script:checks++; return }; throw }
  throw "Assertion failed: $Message; expected rejection."
}
function Write-SyntheticFile([string]$Root, [string]$RelativePath, [string]$Contents = 'synthetic public package fixture') {
  $path = Join-Path $Root $RelativePath.Replace('/', '\')
  [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
  [IO.File]::WriteAllText($path, $Contents, [Text.UTF8Encoding]::new($false))
  return $path
}

try {
  [void][IO.Directory]::CreateDirectory($temp)
  Check ((Get-ReleaseVersion) -ceq '1.0.0+1') 'public candidate pins the approved engineering version'
  $runtimePaths = @(Get-ExpectedReleasePaths)
  $packagePaths = @(Get-ExpectedPackagePaths -PublicCandidate)
  Check ($runtimePaths.Count -eq 36) 'the existing runtime allowlist remains fixed'
  Check ($packagePaths.Count -eq 41 -and $packagePaths -ccontains 'LICENSE' -and
    $packagePaths -ccontains 'docs/releases/public-1.0.0.md' -and
    $packagePaths -ccontains 'docs/releases/known-issues.md' -and
    $packagePaths -cnotcontains 'windows-1.00.md') 'public package allowlist adds only its five notices and release notes'

  Throws { Assert-NoReparseAttributes ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint) 'fixture' } 'reparse point' 'reject reparse attributes'
  Throws { Assert-SafeRelativePath '../outside' } 'Unsafe package path' 'reject archive traversal'
  $revision = '0123456789abcdef0123456789abcdef01234567'
  Assert-CleanSourceRevision -Revision $revision -HeadRevision $revision -StatusLines @()
  Check $true 'accept an exact clean HEAD revision'
  Throws { Assert-CleanSourceRevision -Revision $revision -HeadRevision ('f' * 40) -StatusLines @() } 'current HEAD' 'reject a revision that does not match HEAD'
  Throws { Assert-CleanSourceRevision -Revision $revision -HeadRevision $revision -StatusLines @(' M README.md') } 'clean source worktree' 'reject a dirty source worktree'
  Throws { Assert-CleanSourceRevision -Revision 'abc' -HeadRevision $revision -StatusLines @() } '40 hexadecimal' 'reject a malformed source revision'
  Throws { & (Join-Path $PSScriptRoot 'package-windows-release.ps1') -ReleaseDirectory 'synthetic-release' -Revision 'bad' } '40 hexadecimal' 'route the public wrapper through shared revision validation'

  $release = Join-Path $temp 'windows\x64\runner\Release'
  foreach ($relative in $runtimePaths) { [void](Write-SyntheticFile $release $relative "synthetic:$relative") }
  $aot = Join-Path $release 'data\app.so'
  [IO.File]::WriteAllText($aot, (('x' * 65530) + $revision.ToUpperInvariant() + 'y'), [Text.Encoding]::ASCII)
  Assert-AotRevision -Path $aot -Revision $revision
  Check $true 'accept the requested revision marker in the AOT snapshot'
  Throws { Assert-AotRevision -Path $aot -Revision ('f' * 40) } 'does not contain' 'reject an AOT snapshot from another revision'
  $release = Resolve-ReleaseDirectory $release
  Check (@(Get-ValidatedReleaseFiles $release).Count -eq 36) 'accept the exact synthetic runtime payload'
  $missing = Join-Path $release 'data\icudtl.dat'; Remove-Item -LiteralPath $missing
  Throws { Get-ValidatedReleaseFiles $release } 'Required release files are missing' 'reject a missing runtime file'
  [IO.File]::WriteAllText($missing, '')
  Throws { Get-ValidatedReleaseFiles $release } 'Required release file is empty' 'reject an empty runtime file'
  [IO.File]::WriteAllText($missing, 'synthetic:icudtl.dat')
  $extra = Write-SyntheticFile $release 'unexpected.txt' 'synthetic extra'
  Throws { Get-ValidatedReleaseFiles $release } 'non-allowlisted' 'reject an extra runtime file'
  Remove-Item -LiteralPath $extra
  Throws { Resolve-ReleaseDirectory $PSScriptRoot } 'inside this worktree app/build' 'reject a release tree outside app/build'

  $documentsRoot = Join-Path $temp 'synthetic-workspace'
  [void][IO.Directory]::CreateDirectory($documentsRoot)
  foreach ($relative in $script:PublicDocuments.Values) { [void](Write-SyntheticFile $documentsRoot $relative "synthetic-doc:$relative") }
  $documents = @(Get-PublicPackageDocuments -Root $documentsRoot)
  Check ($documents.Count -eq 5 -and $documents[3].PackagePath -ceq 'docs/releases/public-1.0.0.md' -and
    $documents[4].PackagePath -ceq 'docs/releases/known-issues.md') 'preflight the five public documents at their package paths'
  $notice = Join-Path $documentsRoot 'NOTICE'
  Remove-Item -LiteralPath $notice
  Throws { Get-PublicPackageDocuments -Root $documentsRoot } 'Required public source path is missing' 'reject a missing public notice before output creation'
  [IO.File]::WriteAllText($notice, '')
  Throws { Get-PublicPackageDocuments -Root $documentsRoot } 'empty' 'reject an empty public notice before output creation'
  [IO.File]::WriteAllText($notice, 'synthetic notice')

  $folder = 'USTC-Assistant-1.0.0-windows-x64'
  $package = Join-Path $temp $folder
  foreach ($relative in $runtimePaths) {
    $destination = Write-SyntheticFile $package $relative "synthetic:$relative"
    if ($relative -ceq $script:BrandAsset) {
      Copy-Item -LiteralPath (Join-Path $workspace 'app\assets\branding\ustc_assistant_icon_concept_v1.png') -Destination $destination -Force
    }
  }
  foreach ($doc in $documents) { [void](Write-SyntheticFile $package $doc.PackagePath "synthetic-doc:$($doc.PackagePath)") }
  $records = @(Get-PackageFileRecords $package)
  Check ($records.Count -eq 41 -and @($records | Where-Object { $_.path -ceq 'LICENSE' }).Count -eq 1) 'record only allowlisted runtime files and public notices'
  $exe = [pscustomobject]@{ FileVersion = '1.0.0+1'; ProductVersion = '1.0.0+1'; ProductName = 'USTC Assistant' }
  $manifest = Write-PackageManifest $package $records $revision $exe -PublicCandidate
  $metadata = Get-Content -LiteralPath (Join-Path $package 'manifest.json') -Raw | ConvertFrom-Json
  Check ($metadata.displayVersion -ceq '1.0.0' -and $metadata.version -ceq '1.0.0+1' -and
    $metadata.publicRelease -eq $true -and $metadata.artifactStatus -ceq 'public-candidate' -and
    $metadata.published -eq $false -and $metadata.windowsCodeSigned -eq $false -and
    $metadata.containsUserData -eq $false -and
    $metadata.sha256Purpose -ceq 'integrity-only-not-a-digital-signature') 'manifest states candidate, publication, signature, data and hash semantics'

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = Join-Path $temp 'synthetic-public.zip'
  [IO.Compression.ZipFile]::CreateFromDirectory($package, $zip, [IO.Compression.CompressionLevel]::Optimal, $true)
  Assert-ZipMatchesManifest $zip $folder $revision $packagePaths $manifest.Bytes $manifest.Sha256 -PublicCandidate
  Check $true 'verify public ZIP manifest, entry allowlist, lengths and hashes'
  $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Update)
  try {
    @($archive.Entries | Where-Object { $_.FullName.Replace('\', '/') -ceq ($folder + '/LICENSE') })[0].Delete()
    $entry = $archive.CreateEntry($folder + '/LICENSE'); $stream = $entry.Open()
    try { $bytes = [Text.Encoding]::UTF8.GetBytes('different-doc:LICENSE'); $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
  } finally { $archive.Dispose() }
  Throws { Assert-ZipMatchesManifest $zip $folder $revision $packagePaths $manifest.Bytes $manifest.Sha256 -PublicCandidate } 'ZIP hash differs from manifest' 'reject altered public payload'
  $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Update)
  try { [void]$archive.CreateEntry($folder + '/unexpected.txt') } finally { $archive.Dispose() }
  Throws { Assert-ZipMatchesManifest $zip $folder $revision $packagePaths $manifest.Bytes $manifest.Sha256 -PublicCandidate } 'do not match fixed payload' 'reject an extra public ZIP entry'
  Write-Output "PASS: $script:checks synthetic Windows public-package checks"
}
finally {
  if (Test-Path -LiteralPath $temp) {
    $root = (Resolve-Path -LiteralPath $build).Path.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $resolved = (Resolve-Path -LiteralPath $temp).Path.TrimEnd('\', '/')
    if (-not $resolved.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notmatch '^_public-package-test-[0-9a-f]{32}$') { throw 'Refusing to remove outside the synthetic app/build fixture.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
  }
}
