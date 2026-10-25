#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$WindowsPackageDirectory,
    [string]$AndroidPackageDirectory,
    [string]$Revision40hex,
    [string]$Repository = 'git.ustc.edu.cn/demo233/107_ustc_assistant'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:WorkspaceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:DefaultOutputRoot = Join-Path $script:WorkspaceRoot 'app\build\public-releases'
$script:DefaultRepository = 'git.ustc.edu.cn/demo233/107_ustc_assistant'
$script:ReleaseVersion = '1.0.0'
$script:WindowsPackageVersion = '1.0.0+1'
$script:WindowsFolderName = 'USTC-Assistant-1.0.0-windows-x64'
$script:AndroidApplicationId = 'cn.ustcassistant.mobile'
$script:AndroidQaApplicationId = 'cn.ustcassistant.mobile.qa'
$script:KnownQaCertificateSha256 = '16d3f9867f0a15d4d4ffc877bdd9ec240e92a3fddf6a0a66da857e2888846036'
$script:AndroidPackageFiles = @(
    'app-arm64-v8a-release.apk'
    'app-x86_64-release.apk'
    'licenses/LICENSE'
    'licenses/NOTICE'
    'licenses/THIRD_PARTY_NOTICES.md'
    'public-1.0.0.md'
    'known-issues.md'
)
$script:AndroidExpectedFiles = @($script:AndroidPackageFiles + @('manifest.json', 'SHA256SUMS.txt'))
$script:GlabReleaseDocs = @(
    'https://docs.gitlab.com/cli/release/create/'
    'https://docs.gitlab.com/user/project/releases/'
)

# Reuse the Windows public package path contract without invoking its packager.
. (Join-Path $PSScriptRoot 'package-windows-private.ps1')

function ConvertTo-CanonicalLocalPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -ne $Path.Trim() -or
        $Path.StartsWith('\\') -or $Path.StartsWith('//') -or
        $Path.StartsWith('\\?\') -or $Path.StartsWith('\\.\') -or
        -not [IO.Path]::IsPathFullyQualified($Path)) {
        throw 'Candidate paths must be absolute local paths.'
    }
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ($root -notmatch '^[A-Za-z]:\\$') { throw 'Candidate paths must use a local fixed drive.' }
    try { $drive = [IO.DriveInfo]::new($root) }
    catch { throw 'Candidate paths must use an available local drive.' }
    if ($drive.DriveType -ne [IO.DriveType]::Fixed) { throw 'Candidate paths must use a local fixed drive.' }
    return $full.TrimEnd('\', '/')
}

function Assert-PathChain([string]$Path, [switch]$RequireLeaf) {
    $full = ConvertTo-CanonicalLocalPath $Path
    $root = [IO.Path]::GetPathRoot($full)
    $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
    if ([bool]($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'A candidate path contains a reparse point.'
    }
    $parts = @($full.Substring($root.Length).Split([char[]]@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries))
    $cursor = $root
    for ($index = 0; $index -lt $parts.Length; $index++) {
        $cursor = Join-Path $cursor $parts[$index]
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            if ($RequireLeaf) { throw 'A required candidate path component is missing.' }
            return $full
        }
        if ([bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'A candidate path contains a reparse point.'
        }
        if ($index -lt ($parts.Length - 1) -and -not $item.PSIsContainer) {
            throw 'A candidate parent component is not a directory.'
        }
    }
    return $full
}

function Assert-ExistingDirectory([string]$Path) {
    $full = Assert-PathChain -Path $Path -RequireLeaf
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) { throw 'A package candidate directory is required.' }
    return $full
}

function Assert-ExistingFile([string]$Path) {
    $full = Assert-PathChain -Path $Path -RequireLeaf
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Length -le 0) { throw 'A non-empty regular candidate file is required.' }
    return $item
}

function Test-PathWithin([string]$Path, [string]$Root) {
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    if ($fullRoot.Length -eq 2 -and $fullRoot[1] -eq ':') { $fullRoot += '\' }
    if ($fullPath.Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $fullPath.StartsWith($fullRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-SafeRelativePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.StartsWith('/') -or $Path.Contains('\') -or $Path.Contains(':')) {
        throw 'A candidate manifest contains an unsafe relative path.'
    }
    foreach ($part in $Path.Split('/')) {
        if ([string]::IsNullOrWhiteSpace($part) -or $part -ceq '.' -or $part -ceq '..') {
            throw 'A candidate manifest contains an unsafe relative path.'
        }
    }
}

function Assert-NoPrivateKeyName([string]$Path) {
    if ($Path -match '(?i)(^|/)(?:[^/]*\.(?:keystore|jks|p12|pfx|pem|key|priv)|signing\.json)$' -or
        $Path -match '(?i)(^|/)[^/]*private.?key[^/]*$') {
        throw 'A candidate contains private-key material or signing configuration.'
    }
}

function Get-Sha256FromStream([IO.Stream]$Stream) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Stream))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-Sha256FromFile([string]$Path) {
    $item = Assert-ExistingFile $Path
    $stream = [IO.File]::OpenRead($item.FullName)
    try { return Get-Sha256FromStream $stream }
    finally { $stream.Dispose() }
}

function Get-TreeFileRecords([string]$Root) {
    $records = [System.Collections.Generic.List[object]]::new()
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $pending.Push($Root)
    while ($pending.Count -gt 0) {
        foreach ($item in (Get-ChildItem -LiteralPath $pending.Pop() -Force)) {
            if ([bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'A candidate tree contains a reparse point.'
            }
            $relative = $item.FullName.Substring($Root.Length + 1).Replace('\', '/')
            Assert-SafeRelativePath $relative
            Assert-NoPrivateKeyName $relative
            if ($item.PSIsContainer) { $pending.Push($item.FullName); continue }
            if ($item.Length -le 0) { throw "A candidate contains an empty file: $relative" }
            $records.Add([pscustomobject][ordered]@{
                path = $relative
                bytes = [long]$item.Length
                sha256 = Get-Sha256FromFile $item.FullName
            })
        }
    }
    return @($records.ToArray() | Sort-Object -Property path)
}

function Assert-ExactPathSet([string[]]$Actual, [string[]]$Expected, [string]$Context) {
    if ($Actual.Count -ne $Expected.Count) { throw "$Context contains an unexpected number of files." }
    $expectedSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in $Expected) { [void]$expectedSet.Add($path) }
    $actualSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in $Actual) {
        if (-not $actualSet.Add($path) -or -not $expectedSet.Contains($path)) {
            throw "$Context contains an unknown or colliding file: $path"
        }
    }
}

function Get-ManifestFileMap([object[]]$Files, [string[]]$ExpectedPaths, [string]$Context) {
    if ($null -eq $Files) { throw "$Context manifest has no file records." }
    if ($Files.Count -ne $ExpectedPaths.Count) { throw "$Context manifest has an unexpected file count." }
    $expected = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in $ExpectedPaths) { [void]$expected.Add($path) }
    $map = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($record in $Files) {
        $path = [string]$record.path
        Assert-SafeRelativePath $path
        Assert-NoPrivateKeyName $path
        $hash = [string]$record.sha256
        if (-not $expected.Contains($path) -or $map.ContainsKey($path) -or
            $hash -notmatch '^[0-9a-f]{64}$' -or [long]$record.bytes -le 0) {
            throw "$Context manifest has an invalid file record: $path"
        }
        $map.Add($path, $record)
    }
    foreach ($path in $expected) {
        if (-not $map.ContainsKey($path)) { throw "$Context manifest is missing a required file: $path" }
    }
    return ,$map
}

function Assert-ManifestMatchesDirectory([string]$Root, [System.Collections.Generic.Dictionary[string, object]]$Map, [string[]]$ExpectedPaths, [string]$Context) {
    $actual = @(Get-TreeFileRecords $Root)
    $allowed = @($ExpectedPaths + @('manifest.json'))
    Assert-ExactPathSet -Actual @($actual.path) -Expected $allowed -Context $Context
    foreach ($record in $actual) {
        if ($record.path -ceq 'manifest.json') { continue }
        $manifestRecord = $Map[$record.path]
        if ([long]$manifestRecord.bytes -ne [long]$record.bytes -or [string]$manifestRecord.sha256 -cne [string]$record.sha256) {
            throw "$Context candidate file differs from its manifest: $($record.path)"
        }
    }
}

function Read-JsonDocument([string]$Path, [string]$Context) {
    $item = Assert-ExistingFile $Path
    try { return (Get-Content -LiteralPath $item.FullName -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop) }
    catch { throw "$Context manifest is not valid JSON." }
}

function Assert-PropertySet([object]$Value, [string[]]$Expected, [string]$Context) {
    $actual = @($Value.PSObject.Properties.Name)
    Assert-ExactPathSet -Actual $actual -Expected $Expected -Context $Context
}

function Get-ZipEntryHash([IO.Compression.ZipArchiveEntry]$Entry) {
    $stream = $Entry.Open()
    try { return Get-Sha256FromStream $stream }
    finally { $stream.Dispose() }
}

function Assert-WindowsZip([string]$ZipPath, [string[]]$ExpectedPaths, [object]$Manifest, [string]$Context) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $item = Assert-ExistingFile $ZipPath
    $archive = [IO.Compression.ZipFile]::OpenRead($item.FullName)
    try {
        $prefix = $script:WindowsFolderName + '/'
        $expectedNames = @($ExpectedPaths + @('manifest.json'))
        $entries = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        $expectedDirectories = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        [void]$expectedDirectories.Add($script:WindowsFolderName)
        foreach ($path in $expectedNames) {
            $parent = [IO.Path]::GetDirectoryName($path.Replace('/', '\'))
            while (-not [string]::IsNullOrEmpty($parent)) {
                [void]$expectedDirectories.Add(($prefix + $parent.Replace('\', '/')))
                $parent = [IO.Path]::GetDirectoryName($parent)
            }
        }
        foreach ($entry in $archive.Entries) {
            $name = [string]$entry.FullName
            if ($name.Contains('\')) { throw "$Context ZIP contains a non-portable entry path." }
            $isDirectory = $name.EndsWith('/')
            $trimmed = if ($isDirectory) { $name.TrimEnd('/') } else { $name }
            Assert-SafeRelativePath $trimmed
            $attributes = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$entry.ExternalAttributes), 0)
            if ((($attributes -shr 16) -band 0xF000) -eq 0xA000) { throw "$Context ZIP contains a symbolic-link entry." }
            if ($isDirectory) {
                if (-not $expectedDirectories.Contains($trimmed)) { throw "$Context ZIP contains an unknown directory entry." }
                continue
            }
            if (-not $trimmed.StartsWith($prefix, [StringComparison]::Ordinal)) { throw "$Context ZIP contains an entry outside its package root." }
            $relative = $trimmed.Substring($prefix.Length)
            Assert-NoPrivateKeyName $relative
            if ($relative -notin $expectedNames -or $entries.ContainsKey($relative)) { throw "$Context ZIP contains an unknown or duplicate file entry." }
            $entries.Add($relative, $entry)
        }
        if ($entries.Count -ne $expectedNames.Count) { throw "$Context ZIP file set differs from its public package manifest." }
        foreach ($path in $expectedNames) {
            if (-not $entries.ContainsKey($path)) { throw "$Context ZIP is missing $path." }
        }
        foreach ($path in $ExpectedPaths) {
            $record = @($Manifest.files | Where-Object { [string]$_.path -ceq $path })[0]
            $entry = $entries[$path]
            if ([long]$entry.Length -ne [long]$record.bytes -or (Get-ZipEntryHash $entry) -cne [string]$record.sha256) {
                throw "$Context ZIP entry differs from its manifest: $path"
            }
        }
        $manifestEntry = $entries['manifest.json']
        $manifestPath = Join-Path (Split-Path -Parent $ZipPath) (Join-Path $script:WindowsFolderName 'manifest.json')
        if ([long]$manifestEntry.Length -ne (Get-Item -LiteralPath $manifestPath).Length -or
            (Get-ZipEntryHash $manifestEntry) -cne (Get-Sha256FromFile $manifestPath)) {
            throw "$Context ZIP manifest differs from the unpacked package manifest."
        }
    }
    finally { $archive.Dispose() }
}

function Assert-WindowsCandidate([string]$Directory, [string]$Revision) {
    $root = Assert-ExistingDirectory $Directory
    $rootItem = Get-Item -LiteralPath $root -Force
    if ($rootItem.Name -cne ("$script:WindowsPackageVersion-$($Revision.Substring(0, 8))") -or
        (Split-Path -Leaf (Split-Path -Parent $root)) -cne 'public-releases') {
        throw 'Windows package directory does not match the public packager output naming contract.'
    }
    $expectedRootNames = @($script:WindowsFolderName, "$script:WindowsFolderName.zip", "$script:WindowsFolderName.zip.sha256")
    $rootChildren = @(Get-ChildItem -LiteralPath $root -Force)
    $childNames = @($rootChildren | ForEach-Object { $_.Name })
    Assert-ExactPathSet -Actual $childNames -Expected $expectedRootNames -Context 'Windows candidate directory'
    foreach ($child in $rootChildren) {
        if ([bool]($child.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Windows candidate contains a reparse point.' }
    }

    $packageRoot = Join-Path $root $script:WindowsFolderName
    $expectedFiles = @(Get-ExpectedPackagePaths -PublicCandidate)
    $manifestPath = Join-Path $packageRoot 'manifest.json'
    $manifest = Read-JsonDocument $manifestPath 'Windows'
    Assert-PropertySet $manifest @('schemaVersion','productName','displayVersion','version','sourceRevision','buildType','entry','dataSchema','publicRelease','agentToolRegistry','persona','pubspecLockSha256','executable','files','artifactStatus','published','windowsCodeSigned','containsUserData','sha256Purpose') 'Windows'
    if ([int]$manifest.schemaVersion -ne 1 -or $manifest.productName -cne 'USTC Assistant' -or
        $manifest.buildType -cne 'release' -or $manifest.entry -cne 'lib/main.dart' -or [int]$manifest.dataSchema -ne 20 -or
        $manifest.agentToolRegistry -cne 'agent-tools-v7' -or $manifest.persona -cne 'ustc-personal-maid-agent-v15' -or
        [string]$manifest.pubspecLockSha256 -notmatch '^[0-9a-f]{64}$' -or
        $manifest.version -cne $script:WindowsPackageVersion -or
        $manifest.displayVersion -cne $script:ReleaseVersion -or $manifest.sourceRevision -cne $Revision -or
        $manifest.publicRelease -ne $true -or $manifest.artifactStatus -cne 'public-candidate' -or
        $manifest.published -ne $false -or $manifest.windowsCodeSigned -ne $false -or
        $manifest.containsUserData -ne $false -or $manifest.sha256Purpose -cne 'integrity-only-not-a-digital-signature') {
        throw 'Windows manifest does not describe this unpublished unsigned 1.0.0 source candidate.'
    }
    if ($manifest.executable.file -cne 'ustc_assistant_m0.exe' -or
        -not [bool]$manifest.executable -or
        $manifest.executable.fileVersion -cne $script:WindowsPackageVersion -or
        $manifest.executable.productVersion -cne $script:WindowsPackageVersion -or
        $manifest.executable.productName -cne 'USTC Assistant') {
        throw 'Windows manifest executable identity or version is inconsistent.'
    }
    Assert-PropertySet $manifest.executable @('file','fileVersion','productVersion','productName') 'Windows executable'
    $map = Get-ManifestFileMap -Files @($manifest.files) -ExpectedPaths $expectedFiles -Context 'Windows'
    Assert-ManifestMatchesDirectory -Root $packageRoot -Map $map -ExpectedPaths $expectedFiles -Context 'Windows package'
    $zipPath = Join-Path $root "$script:WindowsFolderName.zip"
    Assert-WindowsZip -ZipPath $zipPath -ExpectedPaths $expectedFiles -Manifest $manifest -Context 'Windows'
    $zipHash = Get-Sha256FromFile $zipPath
    $sidecarPath = Join-Path $root "$script:WindowsFolderName.zip.sha256"
    $sidecar = [IO.File]::ReadAllText($sidecarPath).Replace("`r`n", "`n")
    $expectedSidecar = $zipHash + '  ' + [IO.Path]::GetFileName($zipPath) + "`n"
    if ($sidecar -cne $expectedSidecar) { throw 'Windows ZIP checksum sidecar does not match its file.' }

    return [pscustomobject]@{
        File = [IO.Path]::GetFileName($zipPath)
        SourcePath = $zipPath
        Bytes = [long](Get-Item -LiteralPath $zipPath).Length
        Sha256 = $zipHash
        Version = [string]$manifest.displayVersion
        CodeSigned = [bool]$manifest.windowsCodeSigned
    }
}

function Assert-AndroidChecksumFile([string]$Root, [string[]]$ExpectedPaths) {
    $checksumPath = Join-Path $Root 'SHA256SUMS.txt'
    [void](Assert-ExistingFile $checksumPath)
    $records = @(Get-TreeFileRecords $Root)
    $expectedToChecksum = @($ExpectedPaths + @('manifest.json'))
    Assert-ExactPathSet -Actual @($records.path | Where-Object { $_ -cne 'SHA256SUMS.txt' }) -Expected $expectedToChecksum -Context 'Android checksum input'
    $expectedLines = @{}
    foreach ($record in $records) {
        if ($record.path -ceq 'SHA256SUMS.txt') { continue }
        $expectedLines[[string]$record.path] = [string]$record.sha256
    }
    $lines = @([IO.File]::ReadAllLines($checksumPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -ne $expectedLines.Count) { throw 'Android SHA256SUMS.txt has an unexpected entry count.' }
    $observed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($line in $lines) {
        if ($line -notmatch '^([0-9a-f]{64})  (.+)$') { throw 'Android SHA256SUMS.txt has an invalid line.' }
        $hash = [string]$Matches[1]
        $path = [string]$Matches[2]
        Assert-SafeRelativePath $path
        if (-not $expectedLines.ContainsKey($path) -or -not $observed.Add($path) -or $expectedLines[$path] -cne $hash) {
            throw 'Android SHA256SUMS.txt does not match its candidate files.'
        }
    }
}

function Assert-AndroidCandidate([string]$Directory, [string]$Revision) {
    $root = Assert-ExistingDirectory $Directory
    $rootItem = Get-Item -LiteralPath $root -Force
    if ($rootItem.Name -cne ("android-$script:ReleaseVersion-$($Revision.Substring(0, 8))") -or
        (Split-Path -Leaf (Split-Path -Parent $root)) -cne 'public-releases') {
        throw 'Android package directory does not match the public packager output naming contract.'
    }
    $records = @(Get-TreeFileRecords $root)
    Assert-ExactPathSet -Actual @($records.path) -Expected $script:AndroidExpectedFiles -Context 'Android candidate directory'
    $manifestPath = Join-Path $root 'manifest.json'
    $manifest = Read-JsonDocument $manifestPath 'Android'
    if ($manifest.productName -cne 'USTC Assistant' -or $manifest.versionName -cne $script:ReleaseVersion -or
        $manifest.sourceRevision -cne $Revision -or $manifest.artifactStatus -cne 'public-candidate' -or
        $manifest.published -ne $false -or $manifest.applicationId -cne $script:AndroidApplicationId) {
        throw 'Android manifest does not describe this unpublished formal 1.0.0 source candidate.'
    }
    $certificate = ([string]$manifest.certificateSha256).ToLowerInvariant()
    if ($certificate -notmatch '^[0-9a-f]{64}$' -or $certificate -ceq $script:KnownQaCertificateSha256) {
        throw 'Android candidate certificate is missing, invalid, or the known QA certificate.'
    }
    if (@($manifest.apks).Count -ne 2) { throw 'Android manifest must list exactly two ABI APKs.' }
    $expectedApks = @{
        'arm64-v8a' = 'app-arm64-v8a-release.apk'
        'x86_64' = 'app-x86_64-release.apk'
    }
    $apkRecords = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($apk in $manifest.apks) {
        $abi = [string]$apk.abi
        if (-not $expectedApks.ContainsKey($abi) -or $apkRecords.ContainsKey($abi) -or
            [string]$apk.file -cne [string]$expectedApks[$abi] -or
            [string]$apk.packageName -cne $script:AndroidApplicationId -or
            [string]$apk.certificateSha256 -cne $certificate -or
            [long]$apk.versionCode -le 0 -or [long]$apk.bytes -le 0 -or
            [string]$apk.sha256 -notmatch '^[0-9a-f]{64}$') {
            throw 'Android ABI manifest record has an unexpected identity, certificate, version, or checksum.'
        }
        $apkRecords.Add($abi, $apk)
    }
    foreach ($abi in $expectedApks.Keys) {
        if (-not $apkRecords.ContainsKey($abi)) { throw "Android manifest is missing ABI $abi." }
    }
    $packageMap = Get-ManifestFileMap -Files @($manifest.files) -ExpectedPaths $script:AndroidPackageFiles -Context 'Android'
    foreach ($record in $records) {
        if ($record.path -ceq 'manifest.json' -or $record.path -ceq 'SHA256SUMS.txt') { continue }
        $listed = $packageMap[$record.path]
        if ([long]$listed.bytes -ne [long]$record.bytes -or [string]$listed.sha256 -cne [string]$record.sha256) {
            throw "Android candidate file differs from its manifest: $($record.path)"
        }
    }
    foreach ($abi in $expectedApks.Keys) {
        $apk = $apkRecords[$abi]
        $apkRecord = $packageMap[[string]$apk.file]
        if ([long]$apkRecord.bytes -ne [long]$apk.bytes -or [string]$apkRecord.sha256 -cne [string]$apk.sha256) {
            throw "Android APK manifest records disagree for ABI $abi."
        }
    }
    Assert-AndroidChecksumFile -Root $root -ExpectedPaths $script:AndroidPackageFiles
    return [pscustomobject]@{
        Version = [string]$manifest.versionName
        PubspecVersion = [string]$manifest.pubspecVersion
        ApplicationId = [string]$manifest.applicationId
        CertificateSha256 = $certificate
        Apks = @($apkRecords.Values | Sort-Object -Property abi)
    }
}

function Get-CanonicalRepository([string]$Path) {
    if ($Path -notmatch '^git\.ustc\.edu\.cn/(?<namespace>[A-Za-z0-9][A-Za-z0-9_.-]*)/(?<project>[A-Za-z0-9][A-Za-z0-9_.-]*)$') {
        throw 'Repository must use git.ustc.edu.cn/namespace/project format.'
    }
    return 'git.ustc.edu.cn/' + $Matches.namespace + '/' + $Matches.project
}

function New-PublicReleaseNotes([string]$Revision, [string]$Repository, [object]$Windows, [object]$Android) {
    $repoUrl = 'https://' + $Repository
    $knownIssues = "$repoUrl/-/blob/$Revision/docs/releases/known-issues.md"
    $sourceUrl = "$repoUrl/-/tree/$Revision"
    $lines = @(
        '# USTC Assistant 1.0.0'
        ''
        '本次提供 Windows 便携版和 Android 正式 APK，全部安装包对应下方同一源码修订。包内候选标记用于追溯，实际发布状态以本页为准。'
        ''
        '## 下载安装'
        ''
        "- Windows x64：下载 ``$($Windows.File)``，完整解压后运行 ``ustc_assistant_m0.exe``。需要 WebView2 Runtime，部分新系统还需微软 Visual C++ 运行库；本版尚未取得 Windows 代码签名。"
        "- Android 手机及可直接安装 APK 的鸿蒙：通常选择 ``app-arm64-v8a-release.apk``，正式包名 ``$($Android.ApplicationId)``。本项目不提供原生鸿蒙 HAP。"
        '- x86_64 模拟器：选择 `app-x86_64-release.apk`。'
        "- Android 签名证书 SHA-256：``$($Android.CertificateSha256)``。"
        '- 文件完整性可用 `SHA256SUMS.txt` 核对；文件摘要不等于 Windows 发布者数字签名。'
        ''
        'Android 正式版与原 `cn.ustcassistant.mobile.qa` 测试版并存，不会覆盖测试版，也不会自动搬迁账号配置、聊天和个人安排。请保留原应用及资料，在正式版重新设置并同步。'
        ''
        '## 首次使用与已知问题'
        ''
        '首次启动可按引导配置学校来源、模型 Key 和各项授权，也可跳过联网接入，先使用本地日程与任务。学校账号及模型 Key 由你在应用中提供，安装包不包含任何私人凭据。学校验证码或额外授权仍需本人完成；应用只读采集，不报名、退选或修改学校记录。'
        ''
        "语音、机型/后台通知和学校接口等保留项见[已知问题]($knownIssues)。打包校验不代替目标机、真实学校和实际业务对应关系验收；已有测试版反馈也不自动成为新正式包的验收结果。"
        ''
        "源码修订：``$Revision``（[查看源码]($sourceUrl)）。原创代码采用 Apache-2.0，第三方依赖、模型和来源材料分别保留原许可，详见随包 ``LICENSE``、``NOTICE`` 和 ``THIRD_PARTY_NOTICES.md``。"
        ''
        '这是独立校园助手项目，不代表学校或模型服务提供方。反馈问题时请提供版本、设备、操作步骤和应用导出的安全日志，不要公开账号、密码、Key 或数据库。'
    )
    return [string]::Join("`n", $lines) + "`n"
}

function Get-OutputAssetRecord([string]$Root, [string]$File, [string]$Role, [string]$Revision, [string]$Version, [string]$CertificateSha256) {
    $path = Join-Path $Root $File
    $item = Assert-ExistingFile $path
    return [ordered]@{
        file = $File
        role = $Role
        bytes = [long]$item.Length
        sha256 = Get-Sha256FromFile $path
        sourceRevision = $Revision
        version = $Version
        certificateSha256 = $CertificateSha256
    }
}

function Write-ReleaseChecksums([string]$Root, [string[]]$Files) {
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $Files) {
        $item = Assert-ExistingFile (Join-Path $Root $file)
        $records.Add([pscustomobject]@{ file = $file; sha256 = Get-Sha256FromFile $item.FullName })
    }
    $sorted = @($records.ToArray() | Sort-Object -Property file)
    $lines = @($sorted | ForEach-Object { ([string]$_.sha256) + '  ' + [string]$_.file })
    [IO.File]::WriteAllText((Join-Path $Root 'SHA256SUMS.txt'), ([string]::Join("`n", $lines) + "`n"), [Text.UTF8Encoding]::new($false))
}

function Assert-OutputTreeSafe([string]$Path) {
    $null = Assert-PathChain -Path $Path -RequireLeaf
    foreach ($item in Get-ChildItem -LiteralPath $Path -Force -Recurse) {
        if ([bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'The assembled release candidate contains a reparse point.' }
    }
}

function Remove-OwnedStage([string]$Path, [string]$Root) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-PathWithin -Path $full -Root $Root) -or
        (Split-Path -Leaf $full) -notmatch '^\.gitlab-release-stage-[0-9a-f]{32}$') {
        throw 'Refusing to remove an unrecognized release staging directory.'
    }
    Assert-OutputTreeSafe $full
    Remove-Item -LiteralPath $full -Recurse -Force
}

function Invoke-GitLabReleasePrepare {
    param(
        [string]$WindowsPackageDirectory,
        [string]$AndroidPackageDirectory,
        [string]$Revision40hex,
        [string]$Repository = $script:DefaultRepository,
        [string]$OutputRoot = $script:DefaultOutputRoot,
        [switch]$AllowExternalSyntheticPaths
    )

    if ($Revision40hex -notmatch '^[0-9a-fA-F]{40}$') { throw 'Revision40hex must be exactly 40 hexadecimal characters.' }
    $revision = $Revision40hex.ToLowerInvariant()
    $repository = Get-CanonicalRepository $Repository
    $windowsRoot = Assert-ExistingDirectory $WindowsPackageDirectory
    $androidRoot = Assert-ExistingDirectory $AndroidPackageDirectory
    $outputRoot = Assert-ExistingDirectory $OutputRoot
    if ((Split-Path -Leaf (Split-Path -Parent $windowsRoot)) -cne 'public-releases' -or
        (Split-Path -Leaf (Split-Path -Parent $androidRoot)) -cne 'public-releases' -or
        (Split-Path -Parent $windowsRoot) -ine (Split-Path -Parent $androidRoot) -or
        (Split-Path -Parent $windowsRoot) -ine $outputRoot) {
        throw 'Windows and Android candidates and output must share the packagers public-releases directory.'
    }
    if (-not $AllowExternalSyntheticPaths -and $outputRoot -ine ([IO.Path]::GetFullPath($script:DefaultOutputRoot).TrimEnd('\', '/'))) {
        throw 'Production candidates must be read from this worktree app/build/public-releases directory.'
    }

    $windows = Assert-WindowsCandidate -Directory $windowsRoot -Revision $revision
    $android = Assert-AndroidCandidate -Directory $androidRoot -Revision $revision
    if ($windows.Version -cne $script:ReleaseVersion -or $android.Version -cne $script:ReleaseVersion) {
        throw 'Windows and Android candidates do not share version 1.0.0.'
    }

    $targetName = 'gitlab-{0}-{1}' -f $script:ReleaseVersion, $revision.Substring(0, 8)
    $target = Join-Path $outputRoot $targetName
    $targetCanonical = ConvertTo-CanonicalLocalPath $target
    if ($targetCanonical -eq $outputRoot -or -not (Test-PathWithin -Path $targetCanonical -Root $outputRoot)) {
        throw 'The combined release output path escaped its public-releases root.'
    }
    if ((Test-Path -LiteralPath $target) -or $null -ne (Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue)) {
        throw 'The combined release output already exists; refusing to overwrite it.'
    }

    $stage = Join-Path $outputRoot ('.gitlab-release-stage-' + [guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $stage) { throw 'The generated release staging path already exists.' }
    [void][IO.Directory]::CreateDirectory($stage)
    $completed = $false
    try {
        $windowsDestination = Join-Path $stage $windows.File
        [IO.File]::Copy($windows.SourcePath, $windowsDestination, $false)
        if ((Get-Sha256FromFile $windowsDestination) -cne $windows.Sha256) { throw 'Copied Windows ZIP failed its integrity check.' }

        $apkArtifacts = [System.Collections.Generic.List[object]]::new()
        foreach ($apk in $android.Apks) {
            $sourcePath = Join-Path $androidRoot ([string]$apk.file)
            $destination = Join-Path $stage ([string]$apk.file)
            [IO.File]::Copy($sourcePath, $destination, $false)
            $sourceHash = Get-Sha256FromFile $sourcePath
            $destinationHash = Get-Sha256FromFile $destination
            if ($destinationHash -cne [string]$apk.sha256 -or $sourceHash -cne $destinationHash) {
                throw 'Copied Android APK failed its integrity check.'
            }
            $apkArtifacts.Add([pscustomobject]@{
                File = [string]$apk.file
                Abi = [string]$apk.abi
                Bytes = [long]$apk.bytes
                Sha256 = [string]$apk.sha256
                CertificateSha256 = [string]$apk.certificateSha256
            })
        }

        $manifestFiles = @(
            Get-OutputAssetRecord -Root $stage -File $windows.File -Role 'windows-x64-portable-zip' `
                -Revision $revision -Version $script:ReleaseVersion -CertificateSha256 ''
        )
        foreach ($apk in ($apkArtifacts | Sort-Object -Property Abi)) {
            $role = if ($apk.Abi -ceq 'arm64-v8a') { 'android-arm64-apk' } else { 'android-x86_64-apk' }
            $manifestFiles += Get-OutputAssetRecord -Root $stage -File $apk.File -Role $role `
                -Revision $revision -Version $script:ReleaseVersion -CertificateSha256 $android.CertificateSha256
        }
        $publicManifest = [ordered]@{
            schemaVersion = 1
            productName = 'USTC Assistant'
            version = $script:ReleaseVersion
            sourceRevision = $revision
            sourceRepository = $repository
            gitTag = 'v1.0.0'
            artifactStatus = 'public-candidate'
            published = $false
            windows = [ordered]@{ displayVersion = $windows.Version; packageVersion = $script:WindowsPackageVersion; codeSigned = $false }
            android = [ordered]@{ applicationId = $android.ApplicationId; previousQaApplicationId = $script:AndroidQaApplicationId; certificateSha256 = $android.CertificateSha256 }
            files = $manifestFiles
            sha256Purpose = 'integrity-only-not-a-digital-signature'
        }
        $manifestPath = Join-Path $stage 'release-manifest.json'
        [IO.File]::WriteAllText($manifestPath, ((ConvertTo-Json -InputObject $publicManifest -Depth 6) + "`n"), [Text.UTF8Encoding]::new($false))

        $releaseNotes = New-PublicReleaseNotes -Revision $revision -Repository $repository -Windows $windows -Android $android
        $notesPath = Join-Path $stage 'release-notes.md'
        [IO.File]::WriteAllText($notesPath, $releaseNotes, [Text.UTF8Encoding]::new($false))

        $publicAssetNames = @($windows.File) + @($apkArtifacts | ForEach-Object { [string]$_.File }) + @('release-manifest.json', 'release-notes.md')
        Write-ReleaseChecksums -Root $stage -Files $publicAssetNames

        $finalAssetPaths = @($publicAssetNames | ForEach-Object { Join-Path $target $_ }) + @(Join-Path $target 'SHA256SUMS.txt')
        $notesFinalPath = Join-Path $target 'release-notes.md'
        $repoUrl = 'https://' + $repository
        $glabArguments = @(
            'release', 'create', 'v1.0.0',
            '--repo', $repoUrl,
            '--ref', $revision,
            '--name', 'USTC Assistant 1.0.0',
            '--notes-file', $notesFinalPath,
            '--package-name', 'release-assets',
            '--use-package-registry',
            '--no-update'
        ) + $finalAssetPaths
        $releasePlan = [ordered]@{
            schemaVersion = 1
            purpose = 'local-execution-plan-only'
            localOnly = $true
            notForUpload = $true
            publicationPerformed = $false
            glabMinimumVersion = '1.58.0'
            repository = $repository
            tag = 'v1.0.0'
            sourceRevision = $revision
            outputDirectory = $target
            command = 'glab'
            argumentVector = $glabArguments
            uploadFiles = $finalAssetPaths
            releaseNotesFile = $notesFinalPath
            credentialsIncluded = $false
            prerequisites = @('Review project visibility and protected-tag permissions before execution.','The project Generic Package Registry must be enabled.','Authenticate glab locally with an authorized account; credentials are not stored in this plan.')
            documents = $script:GlabReleaseDocs
        }
        [IO.File]::WriteAllText((Join-Path $stage 'release-plan.json'), ((ConvertTo-Json -InputObject $releasePlan -Depth 7) + "`n"), [Text.UTF8Encoding]::new($false))

        $expectedOutputFiles = @($publicAssetNames + @('SHA256SUMS.txt', 'release-plan.json'))
        $actualOutputRecords = @(Get-TreeFileRecords $stage)
        Assert-ExactPathSet -Actual @($actualOutputRecords.path) -Expected $expectedOutputFiles -Context 'Combined release output'
        $publicText = [IO.File]::ReadAllText($manifestPath) + [IO.File]::ReadAllText($notesPath) + [IO.File]::ReadAllText((Join-Path $stage 'SHA256SUMS.txt'))
        foreach ($localPath in @($windowsRoot, $androidRoot, $outputRoot, $script:WorkspaceRoot)) {
            if ($publicText.Contains($localPath)) { throw 'Public release metadata contains a local absolute path.' }
        }
        Assert-OutputTreeSafe $stage

        if (Test-Path -LiteralPath $target) { throw 'The combined release output appeared during preparation; refusing to overwrite it.' }
        [IO.Directory]::Move($stage, $target)
        $completed = $true
        Write-Output "Combined public release preparation directory: $target"
        Write-Output "Source revision: $revision"
        Write-Output 'Only the listed release assets are included in the structured glab plan; no tag, release, upload, login, or visibility change was performed.'
    }
    finally {
        if (-not $completed) { Remove-OwnedStage -Path $stage -Root $outputRoot }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-GitLabReleasePrepare -WindowsPackageDirectory $WindowsPackageDirectory `
        -AndroidPackageDirectory $AndroidPackageDirectory -Revision40hex $Revision40hex -Repository $Repository
}
