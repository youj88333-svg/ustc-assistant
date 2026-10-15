$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'package-windows-private.ps1')

$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$build = Join-Path $workspace 'app\build'
if (-not (Test-Path -LiteralPath $build -PathType Container)) { throw 'app/build must exist for synthetic checks.' }
$temp = Join-Path $build ('_private-package-test-' + [guid]::NewGuid().ToString('N'))
$script:checks = 0

function Check([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "Assertion failed: $Message" }; $script:checks++
}
function Throws([scriptblock]$Action, [string]$Pattern, [string]$Message) {
  try { & $Action } catch { if ($_.Exception.Message -match $Pattern) { $script:checks++; return }; throw }
  throw "Assertion failed: $Message; expected rejection."
}

try {
  [void][IO.Directory]::CreateDirectory($temp)
  Check ((Get-ReleaseVersion) -ceq '1.0.0+1') 'pubspec and Dart application version agree'
  Check (@(Get-ExpectedReleasePaths).Count -eq 33) 'fixed runtime allowlist contains 33 files'
  Throws { Assert-NoReparseAttributes ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint) 'fixture' } 'reparse point' 'reject reparse attributes'
  Throws { Assert-SafeRelativePath '../outside' } 'Unsafe package path' 'reject archive traversal'

  $release = Join-Path $temp 'windows\x64\runner\Release'
  foreach ($relative in (Get-ExpectedReleasePaths)) {
    $path = Join-Path $release $relative.Replace('/', '\')
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    [IO.File]::WriteAllText($path, "synthetic:$relative")
  }
  [IO.File]::WriteAllText((Join-Path $release 'notification_native.lib'), 'build-only')
  $release = Resolve-ReleaseDirectory $release
  $files = @(Get-ValidatedReleaseFiles $release)
  Check ($files.Count -eq 33) 'accept exact runtime file list and exclude notification_native.lib'
  $unknown = Join-Path $release 'extra.txt'; [IO.File]::WriteAllText($unknown, 'fixture')
  Throws { Get-ValidatedReleaseFiles $release } 'non-allowlisted' 'reject unknown release file'
  Remove-Item -LiteralPath $unknown
  $database = Join-Path $release 'jw.sqlite'; [IO.File]::WriteAllText($database, 'fixture')
  Throws { Get-ValidatedReleaseFiles $release } 'non-allowlisted' 'reject business database as unknown'
  Remove-Item -LiteralPath $database
  Throws { Resolve-ReleaseDirectory $PSScriptRoot } 'inside this worktree app/build' 'reject source outside app/build'

  $notice = [IO.File]::ReadAllText((Join-Path $workspace 'app\resources\speech\NOTICE.txt'), [Text.Encoding]::UTF8)
  $model = [regex]::Match($notice, '(?m)^Model SHA-256:[ \t]*([0-9a-fA-F]{64})[ \t]*$').Groups[1].Value
  $tokens = [regex]::Match($notice, '(?m)^Tokens SHA-256:[ \t]*([0-9a-fA-F]{64})[ \t]*$').Groups[1].Value
  Check ($model -ceq 'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51') 'read reviewed model hash'
  Check ($tokens -ceq 'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc') 'read reviewed tokens hash'

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $folder = 'USTC-Assistant-1.00-windows-x64'; $package = Join-Path $temp $folder
  [void][IO.Directory]::CreateDirectory((Join-Path $package 'nested'))
  [IO.File]::WriteAllText((Join-Path $package 'readme.md'), 'synthetic handoff note')
  [IO.File]::WriteAllText((Join-Path $package 'nested\asset.bin'), 'synthetic asset')
  $records = @(Get-PackageFileRecords $package)
  $exe = [pscustomobject]@{ FileVersion = '1.0.0+1'; ProductVersion = '1.0.0+1'; ProductName = 'USTC Assistant' }
  $revision = '0123456789abcdef0123456789abcdef01234567'
  $manifest = Write-PackageManifest $package $records $revision $exe
  $zip = Join-Path $temp 'synthetic.zip'
  [IO.Compression.ZipFile]::CreateFromDirectory($package, $zip, [IO.Compression.CompressionLevel]::Optimal, $true)
  Assert-ZipMatchesManifest $zip $folder $revision @('readme.md', 'nested/asset.bin') $manifest.Bytes $manifest.Sha256
  Check $true 'verify ZIP manifest, payload sizes and hashes'
  $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Update)
  try {
    @($archive.Entries | Where-Object { $_.FullName.Replace('\', '/') -ceq ($folder + '/readme.md') })[0].Delete()
    $entry = $archive.CreateEntry($folder + '/readme.md'); $stream = $entry.Open()
    try { $bytes = [Text.Encoding]::UTF8.GetBytes('xynthetic handoff note'); $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
  } finally { $archive.Dispose() }
  Throws { Assert-ZipMatchesManifest $zip $folder $revision @('readme.md', 'nested/asset.bin') $manifest.Bytes $manifest.Sha256 } 'ZIP hash differs from manifest' 'reject altered ZIP payload'
  $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Update)
  try { [void]$archive.CreateEntry($folder + '/unexpected.txt') } finally { $archive.Dispose() }
  Throws { Assert-ZipMatchesManifest $zip $folder $revision @('readme.md', 'nested/asset.bin') $manifest.Bytes $manifest.Sha256 } 'do not match fixed payload' 'reject extra ZIP entry'
  Write-Output "PASS: $script:checks synthetic packaging checks"
}
finally {
  if (Test-Path -LiteralPath $temp) {
    $root = (Resolve-Path -LiteralPath $build).Path.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $resolved = (Resolve-Path -LiteralPath $temp).Path.TrimEnd('\', '/')
    if (-not $resolved.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notmatch '^_private-package-test-[0-9a-f]{32}$') { throw 'Refusing to remove outside the synthetic app/build fixture.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
  }
}
