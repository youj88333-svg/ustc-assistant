[CmdletBinding()]
param([string]$ReleaseDirectory, [string]$Revision)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:WorkspaceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:BuildRoot = Join-Path $script:WorkspaceRoot 'app\build'
$script:Version = '1.0.0+1'
$script:DisplayVersion = '1.00'
$script:ProductName = 'USTC Assistant'
$script:ExecutableName = 'ustc_assistant_m0.exe'
$script:PublicDisplayVersion = '1.0.0'
$script:IgnoredBuildFile = 'notification_native.lib'
$script:BrandAsset = 'data/flutter_assets/assets/branding/ustc_assistant_icon_concept_v1.png'
$script:BrandSha256 = 'a89623e9364cd95fe916ff0764407bf45ac11932a7eafc14bda47cb5175bbd7c'
$script:Documents = [ordered]@{
  'windows-1.00.md' = 'docs/releases/windows-1.00.md'
  'windows-1.00-known-issues.md' = 'docs/releases/windows-1.00-known-issues.md'
}
$script:PublicDocuments = [ordered]@{
  'LICENSE' = 'LICENSE'
  'NOTICE' = 'NOTICE'
  'THIRD_PARTY_NOTICES.md' = 'THIRD_PARTY_NOTICES.md'
  'docs/releases/public-1.0.0.md' = 'docs/releases/public-1.0.0.md'
  'docs/releases/known-issues.md' = 'docs/releases/known-issues.md'
}

function Get-ExpectedReleasePaths {
  return @(
    'ustc_assistant_m0.exe', 'file_selector_windows_plugin.dll', 'flutter_windows.dll', 'onnxruntime.dll',
    'record_windows_plugin.dll', 'sherpa-onnx-c-api.dll', 'sqlite3.dll', 'ustc_directory_win.dll',
    'data/app.so', 'data/icudtl.dat', 'data/flutter_assets/AssetManifest.bin', 'data/flutter_assets/FontManifest.json',
    'data/flutter_assets/NativeAssetsManifest.json', 'data/flutter_assets/NOTICES.Z',
    'data/flutter_assets/assets/branding/ustc_assistant_icon_concept_v1.png',
    'data/flutter_assets/assets/knowledge/catalog.json', 'data/flutter_assets/assets/knowledge/finance-business-index.md',
    'data/flutter_assets/assets/knowledge/finance-student-activities.md', 'data/flutter_assets/assets/knowledge/teach-adjustment.md',
    'data/flutter_assets/assets/knowledge/teach-certificates.md', 'data/flutter_assets/assets/knowledge/teach-deferred-exam.md',
    'data/flutter_assets/assets/knowledge/teach-selection.md', 'data/flutter_assets/assets/knowledge/teach-withdrawal.md',
    'data/flutter_assets/fonts/MaterialIcons-Regular.otf', 'data/flutter_assets/shaders/ink_sparkle.frag',
    'data/flutter_assets/shaders/stretch_effect.frag', 'data/speech/sensevoice/FUNASR-MODEL-LICENSE.txt',
    'data/speech/sensevoice/LICENSE', 'data/speech/sensevoice/model.int8.onnx', 'data/speech/sensevoice/NOTICE.txt',
    'data/speech/sensevoice/ONNXRUNTIME-LICENSE.txt', 'data/speech/sensevoice/RECORD-LICENSE.txt',
    'data/speech/sensevoice/SHERPA-ONNX-LICENSE.txt', 'data/speech/sensevoice/tokens.txt',
    'data/licenses/webview2/LICENSE.txt', 'data/licenses/webview2/NOTICE.txt'
  )
}

function Assert-NoReparseAttributes {
  param([IO.FileAttributes]$Attributes, [string]$Context)
  if (($Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Context contains a reparse point." }
}

function Get-TreeFiles {
  param([string]$Root)
  $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
  $rootItem = Get-Item -LiteralPath $rootPath
  if (-not $rootItem.PSIsContainer) { throw "Expected a directory: $rootPath" }
  Assert-NoReparseAttributes $rootItem.Attributes 'Source/package tree'
  $pending = [System.Collections.Generic.Stack[string]]::new(); $pending.Push($rootPath)
  $files = [System.Collections.Generic.List[object]]::new()
  while ($pending.Count -gt 0) {
    foreach ($item in (Get-ChildItem -LiteralPath $pending.Pop() -Force)) {
      Assert-NoReparseAttributes $item.Attributes 'Source/package tree'
      if ($item.PSIsContainer) { $pending.Push($item.FullName); continue }
      $relative = $item.FullName.Substring($rootPath.Length + 1).Replace('\', '/')
      $files.Add([pscustomobject]@{ RelativePath = $relative; Item = $item })
    }
  }
  return $files.ToArray()
}

function Assert-SafeRelativePath {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or $Path.StartsWith('/') -or $Path.Contains('\') -or $Path.Contains(':')) { throw "Unsafe package path: $Path" }
  foreach ($part in $Path.Split('/')) {
    if ([string]::IsNullOrWhiteSpace($part) -or $part -ceq '.' -or $part -ceq '..') { throw "Unsafe package path: $Path" }
  }
}

function Get-ExpectedPackagePaths {
  param([switch]$PublicCandidate)
  $paths = [System.Collections.Generic.List[string]]::new()
  foreach ($path in (Get-ExpectedReleasePaths)) { $paths.Add($path) }
  $documents = if ($PublicCandidate) { $script:PublicDocuments } else { $script:Documents }
  foreach ($path in $documents.Keys) { $paths.Add([string]$path) }
  return $paths.ToArray()
}

function Resolve-PublicDocument {
  param([string]$Root, [string]$RelativePath)
  Assert-SafeRelativePath $RelativePath
  $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
  if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) { throw "Expected a public source directory: $rootPath" }
  $rootItem = Get-Item -LiteralPath $rootPath
  if (-not $rootItem.PSIsContainer) { throw "Expected a public source directory: $rootPath" }
  Assert-NoReparseAttributes $rootItem.Attributes 'Public source tree'
  $fullPath = [IO.Path]::GetFullPath((Join-Path $rootPath $RelativePath.Replace('/', '\')))
  $prefix = $rootPath + [IO.Path]::DirectorySeparatorChar
  if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Public source path escapes workspace: $RelativePath"
  }
  $current = $rootPath
  $parts = $RelativePath.Split('/')
  for ($index = 0; $index -lt $parts.Count; $index++) {
    $current = Join-Path $current $parts[$index]
    if (-not (Test-Path -LiteralPath $current)) { throw "Required public source path is missing: $RelativePath" }
    $item = Get-Item -LiteralPath $current -ErrorAction Stop
    Assert-NoReparseAttributes $item.Attributes 'Public source tree'
    if ($index -lt ($parts.Count - 1) -and -not $item.PSIsContainer) {
      throw "Public source parent is not a directory: $RelativePath"
    }
  }
  if ($item.PSIsContainer) { throw "Expected a public source file: $RelativePath" }
  if ($item.Length -le 0) { throw "Public source file is empty: $RelativePath" }
  return $item
}

function Get-PublicPackageDocuments {
  param([string]$Root = $script:WorkspaceRoot)
  $documents = [System.Collections.Generic.List[object]]::new()
  foreach ($destination in $script:PublicDocuments.Keys) {
    $source = [string]$script:PublicDocuments[$destination]
    $item = Resolve-PublicDocument -Root $Root -RelativePath $source
    $documents.Add([pscustomobject]@{ Name = $destination; PackagePath = $destination; Item = $item })
  }
  return $documents.ToArray()
}

function Assert-CleanSourceRevision {
  param([string]$Revision, [string]$HeadRevision, [string[]]$StatusLines)
  if ($Revision -notmatch '^[0-9a-fA-F]{40}$') { throw 'Revision must be exactly 40 hexadecimal characters.' }
  if ($HeadRevision -notmatch '^[0-9a-fA-F]{40}$' -or
      $HeadRevision.ToLowerInvariant() -cne $Revision.ToLowerInvariant()) {
    throw 'Public candidate Revision must identify the current HEAD.'
  }
  if ($null -ne $StatusLines -and $StatusLines.Count -gt 0) {
    throw 'Public candidate packaging requires a clean source worktree.'
  }
}

function Assert-AotRevision {
  param([string]$Path, [string]$Revision)
  if ($Revision -notmatch '^[0-9a-fA-F]{40}$') { throw 'Revision must be exactly 40 hexadecimal characters.' }
  $item = Get-Item -LiteralPath $Path -ErrorAction Stop
  if ($item.PSIsContainer) { throw 'AOT snapshot must be a file.' }
  Assert-NoReparseAttributes $item.Attributes 'AOT snapshot'
  $needle = [Text.Encoding]::ASCII.GetBytes($Revision.ToLowerInvariant())
  $stream = [IO.File]::OpenRead($item.FullName)
  $buffer = [byte[]]::new(65536)
  $carry = [byte[]]::new(0)
  $found = $false
  try {
    while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
      $window = [byte[]]::new($carry.Length + $read)
      if ($carry.Length -gt 0) { [Buffer]::BlockCopy($carry, 0, $window, 0, $carry.Length) }
      [Buffer]::BlockCopy($buffer, 0, $window, $carry.Length, $read)
      for ($start = 0; $start -le ($window.Length - $needle.Length); $start++) {
        $matches = $true
        for ($offset = 0; $offset -lt $needle.Length; $offset++) {
          $actualByte = [int]$window[$start + $offset]
          if ($actualByte -ge 65 -and $actualByte -le 90) { $actualByte += 32 }
          if ($actualByte -ne [int]$needle[$offset]) { $matches = $false; break }
        }
        if ($matches) { $found = $true; break }
      }
      if ($found) { break }
      $carryLength = [Math]::Min($needle.Length - 1, $window.Length)
      $carry = [byte[]]::new($carryLength)
      if ($carryLength -gt 0) { [Buffer]::BlockCopy($window, $window.Length - $carryLength, $carry, 0, $carryLength) }
    }
  } finally { $stream.Dispose() }
  if (-not $found) { throw 'AOT snapshot does not contain the requested USTC_BUILD_REVISION.' }
}

function Assert-PublicSourceRevision {
  param([string]$Revision)
  $git = Get-Command git -ErrorAction SilentlyContinue
  if ($null -eq $git) { throw 'Git is required to bind a public candidate to a clean source revision.' }
  $head = & $git.Source -C $script:WorkspaceRoot rev-parse --verify HEAD 2>$null
  $headExitCode = $LASTEXITCODE
  if ($headExitCode -ne 0) { throw 'Could not resolve the public candidate source HEAD.' }
  $status = @(& $git.Source -C $script:WorkspaceRoot status --porcelain=v1 --untracked-files=all 2>$null)
  $statusExitCode = $LASTEXITCODE
  if ($statusExitCode -ne 0) { throw 'Could not verify the public candidate source worktree.' }
  Assert-CleanSourceRevision -Revision $Revision -HeadRevision ([string]$head).Trim() -StatusLines $status
}

function Get-ValidatedReleaseFiles {
  param([string]$Root)
  $expected = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($path in (Get-ExpectedReleasePaths)) { [void]$expected.Add($path) }
  $found = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $result = [System.Collections.Generic.List[object]]::new()
  foreach ($entry in (Get-TreeFiles $Root)) {
    if ($entry.RelativePath -ceq $script:IgnoredBuildFile) { continue }
    if (-not $expected.Contains($entry.RelativePath)) { throw "Unexpected or non-allowlisted release file: $($entry.RelativePath)" }
    if ($entry.Item.Length -le 0) { throw "Required release file is empty: $($entry.RelativePath)" }
    [void]$found.Add($entry.RelativePath); $result.Add($entry)
  }
  $missing = @($expected | Where-Object { -not $found.Contains($_) })
  if ($missing.Count) { throw ('Required release files are missing: ' + ($missing -join ', ')) }
  return $result.ToArray()
}

function Get-ReleaseVersion {
  $pubspec = [IO.File]::ReadAllText((Join-Path $script:WorkspaceRoot 'app\pubspec.yaml'), [Text.Encoding]::UTF8)
  $match = [regex]::Match($pubspec, '(?m)^version:[ \t]*([0-9]+\.[0-9]+\.[0-9]+\+[0-9]+)[ \t]*(?:#.*)?\r?$')
  if (-not $match.Success) { throw 'Could not read app/pubspec.yaml version.' }
  $pubspecVersion = $match.Groups[1].Value
  if ($pubspecVersion -cne $script:Version) { throw "pubspec.yaml must set version $script:Version." }
  $dart = [IO.File]::ReadAllText((Join-Path $script:WorkspaceRoot 'app\lib\core\application_version.dart'), [Text.Encoding]::UTF8)
  $match = [regex]::Match($dart, "(?m)^const applicationVersion = '([^']+)';\r?$")
  if (-not $match.Success -or $match.Groups[1].Value -cne $pubspecVersion) { throw 'Dart applicationVersion must match pubspec.yaml.' }
  return $pubspecVersion
}

function Get-Sha256 {
  param([string]$Path, [IO.Stream]$Stream)
  $hasPath = -not [string]::IsNullOrWhiteSpace($Path)
  $hasStream = $null -ne $Stream
  if ($hasPath -eq $hasStream) { throw 'Provide exactly one file path or stream to hash.' }
  $ownsStream = -not $hasStream
  if ($ownsStream) { $Stream = [IO.File]::OpenRead($Path) }
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($Stream))).Replace('-', '').ToLowerInvariant() }
  finally { if ($ownsStream) { $Stream.Dispose() }; $sha.Dispose() }
}

function Assert-SpeechAssets {
  param([string]$Root)
  $source = Join-Path $script:WorkspaceRoot 'app\resources\speech'
  $notice = [IO.File]::ReadAllText((Join-Path $source 'NOTICE.txt'), [Text.Encoding]::UTF8)
  $model = [regex]::Match($notice, '(?m)^Model SHA-256:[ \t]*([0-9a-fA-F]{64})[ \t]*\r?$')
  $tokens = [regex]::Match($notice, '(?m)^Tokens SHA-256:[ \t]*([0-9a-fA-F]{64})[ \t]*\r?$')
  if (-not $model.Success -or -not $tokens.Success) { throw 'Speech NOTICE lacks reviewed asset hashes.' }
  foreach ($name in @('NOTICE.txt', 'FUNASR-MODEL-LICENSE.txt', 'RECORD-LICENSE.txt', 'SHERPA-ONNX-LICENSE.txt', 'ONNXRUNTIME-LICENSE.txt')) {
    if ((Get-Sha256 (Join-Path $source $name)) -cne (Get-Sha256 (Join-Path $Root ("data\speech\sensevoice\" + $name)))) { throw "Speech notice/license differs from reviewed source: $name" }
  }
  foreach ($asset in @(@{ Name = 'model.int8.onnx'; Hash = $model.Groups[1].Value }, @{ Name = 'tokens.txt'; Hash = $tokens.Groups[1].Value })) {
    if ((Get-Sha256 (Join-Path $Root ("data\speech\sensevoice\" + $asset.Name))) -cne $asset.Hash.ToLowerInvariant()) { throw "Speech asset hash differs from NOTICE: $($asset.Name)" }
  }
}

function Assert-BrandAsset {
  param([string]$Root)
  $path = Join-Path $Root $script:BrandAsset
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Approved brand asset is missing.' }
  if ((Get-Sha256 $path) -cne $script:BrandSha256) { throw 'Brand asset differs from the approved icon.' }
}

function Assert-ExecutableMetadata {
  param([string]$Path, [string]$Version)
  $info = (Get-Item -LiteralPath $Path).VersionInfo
  if ($info.ProductVersion -cne $Version -or $info.FileVersion -cne $Version -or $info.ProductName -cne $script:ProductName) {
    throw "EXE must have ProductName '$script:ProductName' and FileVersion/ProductVersion '$Version'; found '$($info.ProductName)' / '$($info.FileVersion)' / '$($info.ProductVersion)'."
  }
}

function Get-PackageFileRecords {
  param([string]$Root)
  $records = [System.Collections.Generic.List[object]]::new()
  foreach ($entry in (Get-TreeFiles $Root)) {
    Assert-SafeRelativePath $entry.RelativePath
    if ($entry.RelativePath -ceq 'manifest.json') { continue }
    $records.Add([pscustomobject][ordered]@{ path = $entry.RelativePath; bytes = [long]$entry.Item.Length; sha256 = Get-Sha256 $entry.Item.FullName })
  }
  return @($records.ToArray() | Sort-Object -Property path)
}

function Write-PackageManifest {
  param([string]$Root, [object[]]$Files, [string]$Revision, [object]$ExeInfo, [switch]$PublicCandidate)
  $displayVersion = if ($PublicCandidate) { $script:PublicDisplayVersion } else { $script:DisplayVersion }
  $manifest = [ordered]@{
    schemaVersion = 1; productName = $script:ProductName; displayVersion = $displayVersion
    version = $script:Version; sourceRevision = $Revision.ToLowerInvariant()
    buildType = 'release'; entry = 'lib/main.dart'; dataSchema = 20; publicRelease = [bool]$PublicCandidate
    agentToolRegistry = 'agent-tools-v7'; persona = 'ustc-personal-maid-agent-v15'
    pubspecLockSha256 = Get-Sha256 (Join-Path $script:WorkspaceRoot 'app\pubspec.lock')
    executable = [ordered]@{ file = $script:ExecutableName; fileVersion = $ExeInfo.FileVersion; productVersion = $ExeInfo.ProductVersion; productName = $ExeInfo.ProductName }
    files = @($Files)
  }
  if ($PublicCandidate) {
    $manifest['artifactStatus'] = 'public-candidate'
    $manifest['published'] = $false
    $manifest['windowsCodeSigned'] = $false
    $manifest['containsUserData'] = $false
    $manifest['sha256Purpose'] = 'integrity-only-not-a-digital-signature'
  }
  $path = Join-Path $Root 'manifest.json'
  [IO.File]::WriteAllText($path, ((ConvertTo-Json -InputObject $manifest -Depth 5) + "`n"), [Text.UTF8Encoding]::new($false))
  return [pscustomobject]@{ Bytes = (Get-Item -LiteralPath $path).Length; Sha256 = Get-Sha256 $path }
}

function Assert-ZipMatchesManifest {
  param([string]$ZipPath, [string]$Folder, [string]$Revision, [string[]]$Expected,
        [long]$ManifestBytes, [string]$ManifestHash, [switch]$PublicCandidate)
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
  try {
    $prefix = $Folder + '/'; $entries = [System.Collections.Generic.Dictionary[string, IO.Compression.ZipArchiveEntry]]::new([StringComparer]::Ordinal)
    foreach ($entry in $zip.Entries) {
      $name = $entry.FullName.Replace('\', '/')
      if ($name.EndsWith('/')) {
        if ($name -ne $prefix) { if (-not $name.StartsWith($prefix, [StringComparison]::Ordinal)) { throw "ZIP entry outside package root: $name" }; Assert-SafeRelativePath $name.Substring($prefix.Length).TrimEnd('/') }
        continue
      }
      if (-not $name.StartsWith($prefix, [StringComparison]::Ordinal)) { throw "ZIP entry outside package root: $name" }
      $relative = $name.Substring($prefix.Length); Assert-SafeRelativePath $relative
      if ($entries.ContainsKey($relative)) { throw "Duplicate ZIP entry: $relative" }
      $entries.Add($relative, $entry)
    }
    if (-not $entries.ContainsKey('manifest.json')) { throw 'ZIP is missing manifest.json.' }
    $manifestEntry = $entries['manifest.json']
    if ([long]$manifestEntry.Length -ne $ManifestBytes) { throw 'ZIP manifest length differs from copied manifest.' }
    $stream = $manifestEntry.Open()
    try { $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true); $json = $reader.ReadToEnd(); $reader.Dispose() }
    finally { $stream.Dispose() }
    $stream = $manifestEntry.Open(); try { $hash = Get-Sha256 -Stream $stream } finally { $stream.Dispose() }
    if ($hash -cne $ManifestHash) { throw 'ZIP manifest hash differs from copied manifest.' }
    $manifest = ConvertFrom-Json -InputObject $json
    $expectedDisplayVersion = if ($PublicCandidate) { $script:PublicDisplayVersion } else { $script:DisplayVersion }
    if ($manifest.version -cne $script:Version -or $manifest.displayVersion -cne $expectedDisplayVersion -or $manifest.sourceRevision -cne $Revision -or
        $manifest.productName -cne $script:ProductName -or $manifest.executable.file -cne $script:ExecutableName -or
        $manifest.executable.fileVersion -cne $script:Version -or
        $manifest.executable.productVersion -cne $script:Version -or $manifest.executable.productName -cne $script:ProductName) { throw 'ZIP manifest identity/version is inconsistent.' }
    if ($PublicCandidate -and ($manifest.publicRelease -ne $true -or
        $manifest.artifactStatus -cne 'public-candidate' -or $manifest.published -ne $false -or
        $manifest.windowsCodeSigned -ne $false -or $manifest.containsUserData -ne $false -or
        $manifest.sha256Purpose -cne 'integrity-only-not-a-digital-signature')) {
      throw 'ZIP manifest does not identify an unpublished unsigned public candidate.'
    }
    $wanted = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in $Expected) { [void]$wanted.Add($path) }
    $listed = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($file in $manifest.files) {
      $path = [string]$file.path; Assert-SafeRelativePath $path
      if (-not $wanted.Contains($path) -or $listed.ContainsKey($path) -or [string]$file.sha256 -notmatch '^[0-9a-f]{64}$' -or [long]$file.bytes -lt 1) { throw "Invalid manifest file record: $path" }
      $listed.Add($path, $file)
    }
    if ($listed.Count -ne $wanted.Count -or $entries.Count -ne ($wanted.Count + 1)) { throw 'ZIP entries do not match fixed payload and manifest.' }
    foreach ($path in $wanted) {
      if (-not $listed.ContainsKey($path) -or -not $entries.ContainsKey($path)) { throw "ZIP is missing required file: $path" }
      $entry = $entries[$path]; $record = $listed[$path]
      if ([long]$entry.Length -ne [long]$record.bytes) { throw "ZIP length differs from manifest: $path" }
      $stream = $entry.Open(); try { $hash = Get-Sha256 -Stream $stream } finally { $stream.Dispose() }
      if ($hash -cne [string]$record.sha256) { throw "ZIP hash differs from manifest: $path" }
    }
  }
  finally { $zip.Dispose() }
}

function Resolve-ReleaseDirectory {
  param([string]$Path)
  $build = [IO.Path]::GetFullPath($script:BuildRoot).TrimEnd('\', '/'); $prefix = $build + [IO.Path]::DirectorySeparatorChar
  Assert-NoReparseAttributes (Get-Item (Join-Path $script:WorkspaceRoot 'app')).Attributes 'app directory'
  Assert-NoReparseAttributes (Get-Item $build).Attributes 'app/build directory'
  $candidate = [IO.Path]::GetFullPath($Path)
  if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $candidate -PathType Container)) { throw 'ReleaseDirectory must resolve inside this worktree app/build.' }
  $current = $build
  foreach ($part in $candidate.Substring($prefix.Length).Split([IO.Path]::DirectorySeparatorChar)) { $current = Join-Path $current $part; Assert-NoReparseAttributes (Get-Item $current).Attributes 'ReleaseDirectory path' }
  $resolved = (Resolve-Path $candidate).Path.TrimEnd('\', '/')
  if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'ReleaseDirectory must resolve strictly inside app/build.' }
  return $resolved
}

function Invoke-WindowsPrivatePackage {
  param([string]$Source, [string]$SourceRevision, [switch]$PublicCandidate)
  if ($SourceRevision -notmatch '^[0-9a-fA-F]{40}$') { throw 'Revision must be exactly 40 hexadecimal characters.' }
  if ($PublicCandidate) { Assert-PublicSourceRevision $SourceRevision }
  $revision = $SourceRevision.ToLowerInvariant(); $version = Get-ReleaseVersion; $release = Resolve-ReleaseDirectory $Source
  $files = @(Get-ValidatedReleaseFiles $release); Assert-SpeechAssets $release; Assert-BrandAsset $release
  Assert-ExecutableMetadata (Join-Path $release $script:ExecutableName) $version
  if ($PublicCandidate) { Assert-AotRevision -Path (Join-Path $release 'data\app.so') -Revision $revision }
  $docs = [System.Collections.Generic.List[object]]::new()
  if ($PublicCandidate) {
    foreach ($doc in (Get-PublicPackageDocuments)) { $docs.Add($doc) }
  } else {
    foreach ($name in $script:Documents.Keys) {
      $path = Join-Path $script:WorkspaceRoot $script:Documents[$name]
      if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required release document missing: $($script:Documents[$name])" }
      $item = Get-Item $path; Assert-NoReparseAttributes $item.Attributes 'Release document'
      if ($item.Length -le 0) { throw "Release document is empty: $name" }
      $docs.Add([pscustomobject]@{ Name = $name; PackagePath = $name; Item = $item })
    }
  }

  $parentName = if ($PublicCandidate) { 'public-releases' } else { 'private-releases' }
  $parent = Join-Path $script:BuildRoot $parentName
  if (Test-Path $parent) { $item = Get-Item $parent; if (-not $item.PSIsContainer) { throw "$parentName is not a directory." }; Assert-NoReparseAttributes $item.Attributes 'Output parent' }
  else { [void][IO.Directory]::CreateDirectory($parent) }
  $parent = (Resolve-Path $parent).Path; Assert-NoReparseAttributes (Get-Item $parent).Attributes 'Output parent'
  $output = Join-Path $parent ($version + '-' + $revision.Substring(0, 8))
  if (Test-Path $output) { throw "Refusing to overwrite existing output: $output" }
  [void][IO.Directory]::CreateDirectory($output)
  $folder = if ($PublicCandidate) { 'USTC-Assistant-1.0.0-windows-x64' } else { 'USTC-Assistant-1.00-windows-x64' }
  $package = Join-Path $output $folder
  [void][IO.Directory]::CreateDirectory($package)
  foreach ($entry in $files) {
    $destination = Join-Path $package $entry.RelativePath.Replace('/', '\')
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
    Copy-Item -LiteralPath $entry.Item.FullName -Destination $destination
  }
  foreach ($doc in $docs) {
    $destination = Join-Path $package $doc.PackagePath.Replace('/', '\')
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
    Copy-Item -LiteralPath $doc.Item.FullName -Destination $destination
  }
  Assert-SpeechAssets $package; Assert-BrandAsset $package; Assert-ExecutableMetadata (Join-Path $package $script:ExecutableName) $version
  $expected = @(Get-ExpectedPackagePaths -PublicCandidate:$PublicCandidate); $records = @(Get-PackageFileRecords $package)
  if ($records.Count -ne $expected.Count) { throw 'Copied package file count differs from fixed payload.' }
  foreach ($record in $records) { if ($expected -cnotcontains $record.path) { throw "Unexpected copied package file: $($record.path)" } }
  $exeInfo = (Get-Item (Join-Path $package $script:ExecutableName)).VersionInfo
  $manifest = Write-PackageManifest $package $records $revision $exeInfo -PublicCandidate:$PublicCandidate
  $zip = Join-Path $output ($folder + '.zip')
  if (Test-Path $zip) { throw "Refusing to overwrite ZIP: $zip" }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [IO.Compression.ZipFile]::CreateFromDirectory($package, $zip, [IO.Compression.CompressionLevel]::Optimal, $true)
  Assert-ZipMatchesManifest $zip $folder $revision $expected $manifest.Bytes $manifest.Sha256 -PublicCandidate:$PublicCandidate
  $zipHash = Get-Sha256 $zip
  [IO.File]::WriteAllText(($zip + '.sha256'), ($zipHash + '  ' + [IO.Path]::GetFileName($zip) + "`n"), [Text.UTF8Encoding]::new($false))
  Write-Output "Package directory: $package"; Write-Output "ZIP: $zip"; Write-Output "ZIP SHA-256: $zipHash"
}

if ($MyInvocation.InvocationName -ne '.') {
  if ([string]::IsNullOrWhiteSpace($ReleaseDirectory) -or [string]::IsNullOrWhiteSpace($Revision)) { throw 'Usage: package-windows-private.ps1 -ReleaseDirectory <app/build Release path> -Revision <40-hex revision>' }
  Invoke-WindowsPrivatePackage $ReleaseDirectory $Revision
}
