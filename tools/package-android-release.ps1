[CmdletBinding()]
param(
    [string]$ApkDirectory,
    [string]$Revision,
    [string]$CertificateSha256,
    [string]$SdkRoot,
    [long]$ExpectedArm64VersionCode,
    [long]$ExpectedX64VersionCode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AndroidReleaseWorkspaceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:AndroidReleaseBuildRoot = Join-Path $script:AndroidReleaseWorkspaceRoot 'app\build'
$script:AndroidReleaseVersionName = '1.0.0'
$script:AndroidReleaseApplicationId = 'cn.ustcassistant.mobile'
$script:AndroidReleaseQaApplicationId = 'cn.ustcassistant.mobile.qa'
$script:AndroidReleaseKnownQaCertificate = '16d3f9867f0a15d4d4ffc877bdd9ec240e92a3fddf6a0a66da857e2888846036'
$script:AndroidReleaseApkNames = [ordered]@{
    'arm64-v8a' = 'app-arm64-v8a-release.apk'
    'x86_64' = 'app-x86_64-release.apk'
}
$script:AndroidReleaseApkSha1Names = [ordered]@{
    'arm64-v8a' = 'app-arm64-v8a-release.apk.sha1'
    'x86_64' = 'app-x86_64-release.apk.sha1'
}
$script:AndroidReleaseProjectAssets = [ordered]@{
    'assets/licenses/project/LICENSE' = 'LICENSE'
    'assets/licenses/project/NOTICE' = 'NOTICE'
    'assets/licenses/project/THIRD_PARTY_NOTICES.md' = 'THIRD_PARTY_NOTICES.md'
    'assets/licenses/project/public-1.0.0.md' = 'docs/releases/public-1.0.0.md'
    'assets/licenses/project/known-issues.md' = 'docs/releases/known-issues.md'
}
$script:AndroidReleaseProjectDocuments = [ordered]@{
    'licenses/LICENSE' = 'assets/licenses/project/LICENSE'
    'licenses/NOTICE' = 'assets/licenses/project/NOTICE'
    'licenses/THIRD_PARTY_NOTICES.md' = 'assets/licenses/project/THIRD_PARTY_NOTICES.md'
    'public-1.0.0.md' = 'assets/licenses/project/public-1.0.0.md'
    'known-issues.md' = 'assets/licenses/project/known-issues.md'
}
$script:AndroidReleaseSpeechDocuments = [ordered]@{
    'NOTICE.txt' = 'app/resources/speech/NOTICE.txt'
    'FUNASR-MODEL-LICENSE.txt' = 'app/resources/speech/FUNASR-MODEL-LICENSE.txt'
    'RECORD-LICENSE.txt' = 'app/resources/speech/RECORD-LICENSE.txt'
    'SHERPA-ONNX-LICENSE.txt' = 'app/resources/speech/SHERPA-ONNX-LICENSE.txt'
    'ONNXRUNTIME-LICENSE.txt' = 'app/resources/speech/ONNXRUNTIME-LICENSE.txt'
}
$script:AndroidReleaseSpeechFiles = @(
    [pscustomobject]@{ Name = 'model.int8.onnx'; Entry = 'assets/flutter_assets/speech/sensevoice/model.int8.onnx'; Bytes = 239233841L; Sha256 = 'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51' }
    [pscustomobject]@{ Name = 'tokens.txt'; Entry = 'assets/flutter_assets/speech/sensevoice/tokens.txt'; Bytes = 315894L; Sha256 = 'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc' }
    [pscustomobject]@{ Name = 'LICENSE'; Entry = 'assets/flutter_assets/speech/sensevoice/LICENSE'; Bytes = 71L; Sha256 = '221c6df10b0931a5629adad671ea48fb7747e034c414b6d2bfa275bc3dd4ea17' }
)
$script:AndroidReleaseForbiddenComponents = @(
    'cn.ustcassistant.mobile.notifications.ReminderOsProbeActivity'
    'cn.ustcassistant.mobile.files.FilesBridgeHostActivity'
    'cn.ustcassistant.mobile.qa.QaProbeActivity'
    'cn.ustcassistant.mobile.qa.QaBrowserParentService'
    'cn.ustcassistant.mobile.qa.QaAlarmReceiver'
    'cn.ustcassistant.mobile.files.SyntheticFilesProvider'
)

function Assert-AndroidReleaseNoReparseAttributes {
    param([IO.FileAttributes]$Attributes, [string]$Context)
    if (($Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Context contains a reparse point."
    }
}

function Assert-AndroidReleasePathChain {
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$RequireLeaf)

    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($root)) { throw 'A path must be fully qualified.' }
    $current = $root
    $rootItem = Get-Item -LiteralPath $current -Force -ErrorAction Stop
    Assert-AndroidReleaseNoReparseAttributes $rootItem.Attributes 'Path ancestor'
    $relative = $full.Substring($root.Length).TrimStart([char[]]@('\', '/'))
    if ([string]::IsNullOrEmpty($relative)) { return $full }

    $parts = $relative.Split([char[]]@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries)
    for ($index = 0; $index -lt $parts.Length; $index++) {
        $current = Join-Path $current $parts[$index]
        if (-not (Test-Path -LiteralPath $current)) {
            if ($RequireLeaf) { throw 'A required path component is missing.' }
            return $full
        }
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        Assert-AndroidReleaseNoReparseAttributes $item.Attributes 'Path component'
        if ($index -lt ($parts.Length - 1) -and -not $item.PSIsContainer) {
            throw 'A parent path component is not a directory.'
        }
    }
    return $full
}

function Test-AndroidReleasePathWithinRoot {
    param([string]$Path, [string]$Root)
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\', '/'))
    if ($fullRoot.Length -eq 2 -and $fullRoot[1] -eq ':') { $fullRoot += '\' }
    if ($fullPath.Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $prefix = $fullRoot.TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
    return $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-AndroidReleaseSafeRelativePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.StartsWith('/') -or
        $Path.Contains('\') -or $Path.Contains(':')) {
        throw 'An archive entry has an unsafe path.'
    }
    foreach ($part in $Path.Split('/')) {
        if ([string]::IsNullOrWhiteSpace($part) -or $part -ceq '.' -or $part -ceq '..') {
            throw 'An archive entry has an unsafe path.'
        }
    }
}

function Assert-CleanAndroidReleaseRevision {
    param([string]$Revision, [string]$HeadRevision, [string[]]$StatusLines)
    if ($Revision -notmatch '^[0-9a-fA-F]{40}$') {
        throw 'Revision must be exactly 40 hexadecimal characters.'
    }
    if ($HeadRevision -notmatch '^[0-9a-fA-F]{40}$' -or
        $HeadRevision.ToLowerInvariant() -cne $Revision.ToLowerInvariant()) {
        throw 'Release packaging requires Revision to match the current HEAD.'
    }
    if ($null -ne $StatusLines -and $StatusLines.Count -gt 0) {
        throw 'Release packaging requires a clean source worktree.'
    }
}

function Get-AndroidReleaseSha256 {
    param([string]$Path, [IO.Stream]$Stream)
    $hasPath = -not [string]::IsNullOrWhiteSpace($Path)
    $hasStream = $null -ne $Stream
    if ($hasPath -eq $hasStream) { throw 'Provide exactly one file path or stream to hash.' }
    $ownsStream = -not $hasStream
    if ($ownsStream) {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.PSIsContainer) { throw 'A file is required for hashing.' }
        Assert-AndroidReleaseNoReparseAttributes $item.Attributes 'Hash input'
        $Stream = [IO.File]::OpenRead($item.FullName)
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Stream))).Replace('-', '').ToLowerInvariant() }
    finally {
        if ($ownsStream) { $Stream.Dispose() }
        $sha.Dispose()
    }
}

function Test-AndroidReleaseStreamContainsAscii {
    param([IO.Stream]$Stream, [string]$Text)
    if ($null -eq $Stream -or [string]::IsNullOrEmpty($Text)) { return $false }
    $needle = [Text.Encoding]::ASCII.GetBytes($Text.ToLowerInvariant())
    $buffer = [byte[]]::new(65536)
    $carry = [byte[]]::new(0)
    try {
        while (($read = $Stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $window = [byte[]]::new($carry.Length + $read)
            if ($carry.Length -gt 0) { [Buffer]::BlockCopy($carry, 0, $window, 0, $carry.Length) }
            [Buffer]::BlockCopy($buffer, 0, $window, $carry.Length, $read)
            for ($start = 0; $start -le ($window.Length - $needle.Length); $start++) {
                $matches = $true
                for ($offset = 0; $offset -lt $needle.Length; $offset++) {
                    $actual = [int]$window[$start + $offset]
                    if ($actual -ge 65 -and $actual -le 90) { $actual += 32 }
                    if ($actual -ne [int]$needle[$offset]) { $matches = $false; break }
                }
                if ($matches) { return $true }
            }
            $carryLength = [Math]::Min($needle.Length - 1, $window.Length)
            $carry = [byte[]]::new($carryLength)
            if ($carryLength -gt 0) {
                [Buffer]::BlockCopy($window, $window.Length - $carryLength, $carry, 0, $carryLength)
            }
        }
    }
    finally { $Stream.Dispose() }
    return $false
}

function Get-AndroidReleaseZipIndex {
    param([IO.Compression.ZipArchive]$Archive)
    if ($null -eq $Archive) { throw 'An open APK archive is required.' }
    $entries = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $Archive.Entries) {
        $name = [string]$entry.FullName
        if ($name.EndsWith('/')) { $name = $name.Substring(0, $name.Length - 1) }
        Assert-AndroidReleaseSafeRelativePath $name
        if ($entries.ContainsKey($name)) { throw 'The APK has duplicate or case-colliding ZIP paths.' }
        $attributes = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$entry.ExternalAttributes), 0)
        $unixFileType = ($attributes -shr 16) -band 0xF000
        if ($unixFileType -eq 0xA000) { throw 'The APK contains a symbolic-link ZIP entry.' }
        if ($name -match '(?i)(^|/)[^/]*\.(?:keystore|jks|p12|pfx|pem|key|priv)$' -or
            $name -match '(?i)(^|/)[^/]*private.?key[^/]*$') {
            throw 'The APK contains a private-key material entry.'
        }
        $entries.Add($name, $entry)
    }
    return ,$entries
}

function Assert-AndroidReleaseAbiLayout {
    param([System.Collections.Generic.Dictionary[string, object]]$Entries, [string]$ExpectedAbi)
    if ($ExpectedAbi -notin @('arm64-v8a', 'x86_64')) { throw 'An unsupported Android ABI was requested.' }
    $libAppPath = "lib/$ExpectedAbi/libapp.so"
    if (-not $Entries.ContainsKey($libAppPath) -or $Entries[$libAppPath].Length -le 0) {
        throw 'The APK does not contain its required ABI libapp.so.'
    }
    $foundLibApp = 0
    foreach ($name in $Entries.Keys) {
        $zipEntry = $Entries[$name]
        if ($zipEntry.FullName.EndsWith('/')) {
            if ($name -ceq 'lib') { continue }
            if ($name -match '^lib/([^/]+)$') {
                if ($Matches[1] -cne $ExpectedAbi) { throw 'The APK contains a native library directory for an unexpected ABI.' }
                continue
            }
            if ($name.StartsWith('lib/', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'The APK contains an unexpected native-library directory.'
            }
            continue
        }
        if ($name -match '^lib/([^/]+)/([^/]+)$') {
            $entryAbi = [string]$Matches[1]
            $libraryName = [string]$Matches[2]
            if ($entryAbi -cne $ExpectedAbi) { throw 'The APK contains a native library for an unexpected ABI.' }
            if ($libraryName -notmatch '\.so$') { throw 'The APK contains an unexpected item under lib/.' }
            if ($libraryName -ceq 'libapp.so') { $foundLibApp++ }
        }
        elseif ($name.StartsWith('lib/', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The APK contains an unexpected native-library path.'
        }
    }
    if ($foundLibApp -ne 1) { throw 'The APK must contain exactly one ABI-specific libapp.so.' }
}

function Assert-AndroidReleaseRequiredEntry {
    param([System.Collections.Generic.Dictionary[string, object]]$Entries, [string]$Path)
    if (-not $Entries.ContainsKey($Path) -or [long]$Entries[$Path].Length -le 0) {
        throw "The APK is missing a required non-empty asset: $Path"
    }
}

function Assert-AndroidReleaseFixedSpeechAssets {
    param([System.Collections.Generic.Dictionary[string, object]]$Entries)
    foreach ($asset in $script:AndroidReleaseSpeechFiles) {
        Assert-AndroidReleaseRequiredEntry $Entries $asset.Entry
        $entry = $Entries[$asset.Entry]
        if ([long]$entry.Length -ne [long]$asset.Bytes) {
            throw "A fixed speech asset has an unexpected length: $($asset.Name)"
        }
        $stream = $entry.Open()
        try { $actualHash = Get-AndroidReleaseSha256 -Stream $stream }
        finally { $stream.Dispose() }
        if ($actualHash -cne [string]$asset.Sha256) {
            throw "A fixed speech asset has an unexpected SHA-256: $($asset.Name)"
        }
    }
}

function Resolve-AndroidReleaseSourceFile {
    param([string]$RelativePath)
    Assert-AndroidReleaseSafeRelativePath $RelativePath
    $path = [IO.Path]::GetFullPath((Join-Path $script:AndroidReleaseWorkspaceRoot $RelativePath.Replace('/', '\')))
    if (-not (Test-AndroidReleasePathWithinRoot -Path $path -Root $script:AndroidReleaseWorkspaceRoot)) {
        throw 'A required source file resolves outside the workspace.'
    }
    [void](Assert-AndroidReleasePathChain -Path $path -RequireLeaf)
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Length -le 0) { throw 'A required public source file is missing or empty.' }
    return $item
}

function Assert-AndroidReleaseCopyOfSourceEntry {
    param(
        [System.Collections.Generic.Dictionary[string, object]]$Entries,
        [string]$EntryPath,
        [string]$SourceRelativePath
    )
    Assert-AndroidReleaseRequiredEntry $Entries $EntryPath
    $source = Resolve-AndroidReleaseSourceFile $SourceRelativePath
    if ([long]$Entries[$EntryPath].Length -ne [long]$source.Length) {
        throw "An embedded notice differs in length from its source: $EntryPath"
    }
    $stream = $Entries[$EntryPath].Open()
    try { $embeddedHash = Get-AndroidReleaseSha256 -Stream $stream }
    finally { $stream.Dispose() }
    $sourceHash = Get-AndroidReleaseSha256 -Path $source.FullName
    if ($embeddedHash -cne $sourceHash) { throw "An embedded notice differs from its source: $EntryPath" }
}

function Assert-AndroidReleaseTextAssets {
    param([System.Collections.Generic.Dictionary[string, object]]$Entries)
    Assert-AndroidReleaseRequiredEntry $Entries 'assets/flutter_assets/NOTICES.Z'
    Assert-AndroidReleaseRequiredEntry $Entries 'assets/licenses/android/NOTICE.txt'
    Assert-AndroidReleaseCopyOfSourceEntry $Entries 'assets/licenses/android/NOTICE.txt' 'app/resources/android/NOTICE.txt'
    Assert-AndroidReleaseRequiredEntry $Entries 'assets/licenses/android/APACHE-2.0.txt'
    Assert-AndroidReleaseCopyOfSourceEntry $Entries 'assets/licenses/android/APACHE-2.0.txt' 'LICENSE'
    foreach ($entryName in $script:AndroidReleaseProjectAssets.Keys) {
        Assert-AndroidReleaseCopyOfSourceEntry $Entries ([string]$entryName) ([string]$script:AndroidReleaseProjectAssets[$entryName])
    }
    foreach ($noticeName in $script:AndroidReleaseSpeechDocuments.Keys) {
        $entryPath = "assets/flutter_assets/speech/licenses/$noticeName"
        Assert-AndroidReleaseCopyOfSourceEntry $Entries $entryPath ([string]$script:AndroidReleaseSpeechDocuments[$noticeName])
    }
}

function Assert-AndroidReleaseNoPrivateKeyEntries {
    param([System.Collections.Generic.Dictionary[string, object]]$Entries)
    foreach ($name in $Entries.Keys) {
        if ($name -match '(?i)(^|/)[^/]*\.(?:keystore|jks|p12|pfx|pem|key|priv)$' -or
            $name -match '(?i)(^|/)[^/]*private.?key[^/]*$') {
            throw 'The APK contains a private-key material entry.'
        }
    }
}

function Test-AndroidReleaseApkArchive {
    param([string]$Path, [string]$ExpectedAbi, [string]$Revision)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Length -le 0) { throw 'A regular APK file is required.' }
    Assert-AndroidReleaseNoReparseAttributes $item.Attributes 'APK input'
    $archive = [IO.Compression.ZipFile]::OpenRead($item.FullName)
    try {
        $entries = Get-AndroidReleaseZipIndex $archive
        Assert-AndroidReleaseNoPrivateKeyEntries $entries
        Assert-AndroidReleaseAbiLayout $entries $ExpectedAbi
        if ($entries.ContainsKey('res/xml/qa_network_security.xml')) {
            throw 'The APK contains the Debug-only QA network configuration.'
        }
        Assert-AndroidReleaseFixedSpeechAssets $entries
        Assert-AndroidReleaseTextAssets $entries
        $revisionPath = "lib/$ExpectedAbi/libapp.so"
        $revisionStream = $entries[$revisionPath].Open()
        try {
            if (-not (Test-AndroidReleaseStreamContainsAscii -Stream $revisionStream -Text $Revision)) {
                throw 'The ABI AOT library does not contain the requested source revision.'
            }
        }
        finally { $revisionStream.Dispose() }
        return [pscustomobject]@{ Path = $item.FullName; Abi = $ExpectedAbi; Bytes = [long]$item.Length }
    }
    finally { $archive.Dispose() }
}

function ConvertFrom-AndroidReleaseAaptValue {
    param([string]$RawValue)
    if ($null -eq $RawValue) { return $null }
    $value = $RawValue.Trim()
    if ($value -match '^(?:\(type\s+[^)]+\)\s*)?"(?<text>[^"]*)"') { return [string]$Matches['text'] }
    if ($value -match '^\(type\s+0x12\)\s*0x0$') { return 'false' }
    if ($value -match '^\(type\s+0x12\)\s*(?:0x1|0xffffffff)$') { return 'true' }
    if ($value -match '^(?:\(type\s+[^)]+\)\s*)?(?<bool>true|false)$') { return [string]$Matches['bool'] }
    if ($value -match '^(?:\(type\s+[^)]+\)\s*)?(?<number>0x[0-9a-fA-F]+|[0-9]+)$') { return [string]$Matches['number'] }
    return $value
}

function Get-AndroidReleaseBadgingFacts {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { throw 'aapt returned empty package metadata.' }
    $packageLines = @([regex]::Matches($Text, "(?m)^package:\s*(?<attrs>.+)$"))
    if ($packageLines.Count -ne 1) { throw 'aapt did not return one unambiguous package record.' }
    $attrs = [string]$packageLines[0].Groups['attrs'].Value
    $name = [regex]::Match($attrs, "(?:^|\s)name='(?<v>[^']+)'\s*")
    $versionCode = [regex]::Match($attrs, "(?:^|\s)versionCode='(?<v>[0-9]+)'\s*")
    $versionName = [regex]::Match($attrs, "(?:^|\s)versionName='(?<v>[^']+)'\s*")
    if (-not $name.Success -or -not $versionCode.Success -or -not $versionName.Success) {
        throw 'aapt package metadata is incomplete or unrecognized.'
    }
    $nativeLines = @([regex]::Matches($Text, "(?m)^native-code:\s*(?<abis>.*)$"))
    if ($nativeLines.Count -ne 1) { throw 'aapt did not return one ABI record.' }
    $abiMatches = [regex]::Matches([string]$nativeLines[0].Groups['abis'].Value, "'([^']+)'")
    if ($abiMatches.Count -ne 1) { throw 'aapt ABI metadata is missing, ambiguous, or contains multiple ABIs.' }
    $launchLines = @([regex]::Matches($Text, "(?m)^launchable-activity:\s*name='(?<name>[^']+)'"))
    if ($launchLines.Count -ne 1) { throw 'aapt did not return one launch activity.' }
    return [pscustomobject]@{
        PackageName = [string]$name.Groups['v'].Value
        VersionCode = [long]$versionCode.Groups['v'].Value
        VersionName = [string]$versionName.Groups['v'].Value
        Abi = [string]$abiMatches[0].Groups[1].Value
        LaunchActivity = [string]$launchLines[0].Groups['name'].Value
        Debuggable = [regex]::IsMatch($Text, '(?m)^application-debuggable\s*$')
    }
}

function Get-AndroidReleaseDirectElementAttributes {
    param([string]$Text, [string]$ElementName)
    $lines = [regex]::Split($Text, "`r`n|`n|`r")
    $elementMatches = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $lines.Length; $index++) {
        $elementPattern = '^\s*E:\s*' + [regex]::Escape($ElementName) + '(?:\s|$|\()'
        if ($lines[$index] -notmatch $elementPattern) { continue }
        $indent = $lines[$index].Length - $lines[$index].TrimStart().Length
        $attributes = @{}
        for ($next = $index + 1; $next -lt $lines.Length; $next++) {
            if ($lines[$next] -match '^\s*E:\s*') { break }
            if ($lines[$next] -match '^\s*A:\s*(?<name>[^\s(=]+)(?:\([^)]*\))?\s*=\s*(?<value>.*)$') {
                $attributes[[string]$Matches['name']] = ConvertFrom-AndroidReleaseAaptValue ([string]$Matches['value'])
            }
        }
        [void]$elementMatches.Add([pscustomobject]@{ Indent = $indent; Attributes = $attributes })
    }
    if ($elementMatches.Count -ne 1) { throw "aapt manifest output did not contain one $ElementName element." }
    return $elementMatches[0].Attributes
}

function Get-AndroidReleaseComponentFacts {
    param([string]$Text)
    $lines = [regex]::Split($Text, "`r`n|`n|`r")
    $components = [System.Collections.Generic.List[object]]::new()
    $current = $null
    foreach ($line in $lines) {
        if ($line -match '^(?<space>\s*)E:\s*(?<tag>activity|activity-alias|service|receiver|provider)(?:\s|$|\()') {
            $indent = [string]$Matches['space'].Length
            if ($null -ne $current) { [void]$components.Add($current) }
            $current = [pscustomobject]@{ Tag = [string]$Matches['tag']; Indent = [int]$indent; Attributes = @{} }
            continue
        }
        if ($null -eq $current) { continue }
        if ($line -match '^(?<space>\s*)E:\s*') {
            $indent = [string]$Matches['space'].Length
            if ($indent -le $current.Indent) {
                [void]$components.Add($current)
                $current = $null
            }
            continue
        }
        if ($line -match '^(?<space>\s*)A:\s*(?<name>[^\s(=]+)(?:\([^)]*\))?\s*=\s*(?<value>.*)$') {
            $attributeIndent = [int]$Matches['space'].Length
            if ($attributeIndent -eq ($current.Indent + 2)) {
                $current.Attributes[[string]$Matches['name']] = ConvertFrom-AndroidReleaseAaptValue ([string]$Matches['value'])
            }
        }
    }
    if ($null -ne $current) { [void]$components.Add($current) }
    return $components.ToArray()
}

function ConvertTo-AndroidReleaseComponentName {
    param([string]$PackageName, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    if ($Name.StartsWith('.')) { return $PackageName + $Name }
    if (-not $Name.Contains('.')) { return $PackageName + '.' + $Name }
    return $Name
}

function Assert-AndroidReleaseManifestBoolean {
    param([hashtable]$Attributes, [string]$Name, [bool]$Expected, [switch]$AbsentMeansFalse)
    $key = 'android:' + $Name
    if (-not $Attributes.ContainsKey($key)) {
        if ($AbsentMeansFalse -and -not $Expected) { return }
        throw "The merged manifest is missing required android:$Name policy."
    }
    $actual = [string]$Attributes[$key]
    $expectedValue = $Expected.ToString().ToLowerInvariant()
    if ($actual -cne $expectedValue) { throw "The merged manifest has an unsafe android:$Name value." }
}

function Assert-AndroidReleaseManifest {
    param([string]$Text, [string]$ExpectedPackageName)
    if ([string]::IsNullOrWhiteSpace($Text)) { throw 'aapt returned empty merged-manifest metadata.' }
    $manifest = Get-AndroidReleaseDirectElementAttributes $Text 'manifest'
    if ([string]$manifest['package'] -cne $ExpectedPackageName) { throw 'The merged manifest has the wrong package name.' }
    $application = Get-AndroidReleaseDirectElementAttributes $Text 'application'
    Assert-AndroidReleaseManifestBoolean $application 'allowBackup' $false
    Assert-AndroidReleaseManifestBoolean $application 'usesCleartextTraffic' $false
    Assert-AndroidReleaseManifestBoolean $application 'debuggable' $false -AbsentMeansFalse
    Assert-AndroidReleaseManifestBoolean $application 'testOnly' $false -AbsentMeansFalse
    if ($application.ContainsKey('android:networkSecurityConfig')) {
        throw 'The release APK contains an unreviewed explicit network security configuration.'
    }
    if ([string]$application['android:name'] -notin @('.SchoolApplication', 'cn.ustcassistant.mobile.SchoolApplication')) {
        throw 'The merged manifest has the wrong application class.'
    }

    $components = @(Get-AndroidReleaseComponentFacts $Text)
    foreach ($forbidden in $script:AndroidReleaseForbiddenComponents) {
        foreach ($component in $components) {
            $actualName = ConvertTo-AndroidReleaseComponentName $ExpectedPackageName ([string]$component.Attributes['android:name'])
            if ($actualName -ceq $forbidden) { throw 'The merged manifest contains a Debug-only QA or probe component.' }
        }
    }
    $required = @(
        [pscustomobject]@{ Tag = 'activity'; Name = '.MainActivity'; Exported = 'true'; Process = '' }
        [pscustomobject]@{ Tag = 'activity'; Name = '.browser.SchoolHostActivity'; Exported = 'false'; Process = ':school_host' }
        [pscustomobject]@{ Tag = 'service'; Name = '.browser.SchoolHostService'; Exported = 'false'; Process = ':school_host' }
        [pscustomobject]@{ Tag = 'receiver'; Name = '.notifications.ReminderAlarmReceiver'; Exported = 'false'; Process = '' }
        [pscustomobject]@{ Tag = 'receiver'; Name = '.notifications.ReminderRestoreReceiver'; Exported = 'false'; Process = '' }
    )
    foreach ($expected in $required) {
        $expectedName = ConvertTo-AndroidReleaseComponentName $ExpectedPackageName ([string]$expected.Name)
        $found = @($components | Where-Object {
            $_.Tag -ceq $expected.Tag -and
            (ConvertTo-AndroidReleaseComponentName $ExpectedPackageName ([string]$_.Attributes['android:name'])) -ceq $expectedName
        })
        if ($found.Count -ne 1) { throw "The merged manifest is missing a required application component: $($expected.Name)" }
        $component = $found[0]
        if ([string]$component.Attributes['android:exported'] -cne [string]$expected.Exported) {
            throw "A required application component has an unexpected exported value: $($expected.Name)"
        }
        if ([string]$component.Attributes['android:process'] -cne [string]$expected.Process) {
            if ($expected.Process -ne '' -or $component.Attributes.ContainsKey('android:process')) {
                throw "A required application component has an unexpected process value: $($expected.Name)"
            }
        }
    }
}

function Assert-AndroidReleaseBadging {
    param(
        [string]$Text,
        [string]$ExpectedAbi,
        [long]$ExpectedVersionCode,
        [string]$ExpectedVersionName = '1.0.0'
    )
    $facts = Get-AndroidReleaseBadgingFacts $Text
    if ($facts.PackageName -ceq $script:AndroidReleaseQaApplicationId -or
        $facts.PackageName -cne $script:AndroidReleaseApplicationId) {
        throw 'The APK package name is not the approved formal Android identity.'
    }
    if ($facts.VersionName -cne $ExpectedVersionName) { throw 'The APK versionName does not match pubspec.yaml.' }
    if ([long]$facts.VersionCode -ne $ExpectedVersionCode) { throw 'The APK versionCode does not match the requested ABI code.' }
    if ($facts.Abi -cne $ExpectedAbi) { throw 'The APK contains the wrong native ABI.' }
    if ($facts.LaunchActivity -notin @('cn.ustcassistant.mobile.MainActivity', '.MainActivity')) {
        throw 'The APK launch activity is not the application MainActivity.'
    }
    if ($facts.Debuggable) { throw 'aapt reports a debuggable APK.' }
    return $facts
}

function ConvertTo-AndroidReleaseCertificateSha256 {
    param([string]$Value)
    if ($Value -match '^[0-9a-fA-F]{64}$') { return $Value.ToLowerInvariant() }
    if ($Value -match '^[0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){31}$') {
        return ($Value -replace ':', '').ToLowerInvariant()
    }
    throw 'A certificate SHA-256 digest must contain exactly 64 hexadecimal digits.'
}

function Get-AndroidReleaseSignerFacts {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text) -or $Text -match '(?im)^DOES NOT VERIFY\s*$') {
        throw 'apksigner did not verify the APK signature.'
    }
    if (-not [regex]::IsMatch($Text, '(?im)^Verifies\s*$')) {
        throw 'apksigner did not confirm APK signature verification.'
    }
    if (-not [regex]::IsMatch($Text, '(?im)^Verified using v2 scheme \(APK Signature Scheme v2\):\s*true\s*$')) {
        throw 'The APK does not have a verified v2 signature.'
    }
    $signerCounts = [regex]::Matches($Text, '(?im)^Number of signers:\s*(\d+)\s*$')
    if ($signerCounts.Count -ne 1 -or [int]$signerCounts[0].Groups[1].Value -ne 1) {
        throw 'The APK must have exactly one signer.'
    }
    $certLines = [regex]::Matches($Text, '(?im)^Signer #1 certificate SHA-256 digest:\s*(?<sha>[0-9a-fA-F: ]+)\s*$')
    if ($certLines.Count -ne 1) { throw 'apksigner did not return one signer certificate digest.' }
    if ([regex]::IsMatch($Text, '(?im)^Signer #2\s')) { throw 'The APK must have exactly one signer.' }
    $certificate = ConvertTo-AndroidReleaseCertificateSha256 ([string]$certLines[0].Groups['sha'].Value)
    return [pscustomobject]@{ CertificateSha256 = $certificate; VerifiedV2 = $true; SignerCount = 1 }
}

function Assert-AndroidReleaseSigner {
    param([string]$Text, [string]$ExpectedCertificateSha256)
    $expected = ConvertTo-AndroidReleaseCertificateSha256 $ExpectedCertificateSha256
    if ($expected -ceq $script:AndroidReleaseKnownQaCertificate) {
        throw 'The known QA signing certificate cannot be used for a public candidate.'
    }
    $facts = Get-AndroidReleaseSignerFacts $Text
    if ($facts.CertificateSha256 -cne $expected) { throw 'The APK signer certificate does not match the requested public certificate.' }
    return $facts
}

function Get-AndroidReleaseAndroidVersion {
    $path = Join-Path $script:AndroidReleaseWorkspaceRoot 'app\pubspec.yaml'
    [void](Assert-AndroidReleasePathChain -Path $path -RequireLeaf)
    $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    $match = [regex]::Match($text, '(?m)^version:\s*(?<name>\d+\.\d+\.\d+)\+(?<build>\d+)\s*$')
    if (-not $match.Success) { throw 'pubspec.yaml must contain an exact name+build version.' }
    if ([string]$match.Groups['name'].Value -cne $script:AndroidReleaseVersionName) {
        throw 'The public Android package helper is pinned to versionName 1.0.0.'
    }
    return [pscustomobject]@{
        VersionName = [string]$match.Groups['name'].Value
        PubspecVersion = [string]$match.Groups['name'].Value + '+' + [string]$match.Groups['build'].Value
        BuildNumber = [long]$match.Groups['build'].Value
    }
}

function Invoke-AndroidReleaseSdkCommand {
    param([string]$ToolPath, [string[]]$Arguments, [string]$Name)
    $output = @(& $ToolPath @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { throw "$Name failed; no candidate package was created." }
    return [string]::Join("`n", @($output | ForEach-Object { $_.ToString() }))
}

function Get-AndroidReleaseSdkTools {
    param([string]$SdkRoot)
    if ([string]::IsNullOrWhiteSpace($SdkRoot) -or -not [IO.Path]::IsPathRooted($SdkRoot)) {
        throw 'SdkRoot must be an absolute Android SDK directory.'
    }
    $sdk = [IO.Path]::GetFullPath($SdkRoot)
    [void](Assert-AndroidReleasePathChain -Path $sdk -RequireLeaf)
    $buildToolsRoot = Join-Path $sdk 'build-tools'
    [void](Assert-AndroidReleasePathChain -Path $buildToolsRoot -RequireLeaf)
    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($directory in (Get-ChildItem -LiteralPath $buildToolsRoot -Directory -Force)) {
        if ($directory.Name -notmatch '^\d+\.\d+(?:\.\d+)?$') { continue }
        Assert-AndroidReleaseNoReparseAttributes $directory.Attributes 'Android SDK build-tools directory'
        $aapt = Join-Path $directory.FullName 'aapt.exe'
        $apksigner = Join-Path $directory.FullName 'apksigner.bat'
        if (-not (Test-Path -LiteralPath $aapt -PathType Leaf) -or -not (Test-Path -LiteralPath $apksigner -PathType Leaf)) { continue }
        [void](Assert-AndroidReleasePathChain -Path $aapt -RequireLeaf)
        [void](Assert-AndroidReleasePathChain -Path $apksigner -RequireLeaf)
        $candidates.Add([pscustomobject]@{ Version = [Version]$directory.Name; Aapt = $aapt; Apksigner = $apksigner })
    }
    if ($candidates.Count -eq 0) { throw 'SdkRoot has no Android build-tools directory containing aapt and apksigner.' }
    $selected = $candidates | Sort-Object -Property Version -Descending | Select-Object -First 1
    return [pscustomobject]@{ Aapt = [string]$selected.Aapt; Apksigner = [string]$selected.Apksigner; BuildToolsVersion = [string]$selected.Version }
}

function Resolve-AndroidReleaseApkDirectory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'ApkDirectory is required.' }
    $candidate = if ([IO.Path]::IsPathRooted($Path)) { [IO.Path]::GetFullPath($Path) } else {
        [IO.Path]::GetFullPath((Join-Path $script:AndroidReleaseWorkspaceRoot $Path))
    }
    if (-not (Test-AndroidReleasePathWithinRoot -Path $candidate -Root $script:AndroidReleaseBuildRoot)) {
        throw 'ApkDirectory must be inside app/build.'
    }
    [void](Assert-AndroidReleasePathChain -Path $candidate -RequireLeaf)
    $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) { throw 'ApkDirectory must be a directory.' }
    return $item.FullName
}

function Get-AndroidReleaseApkInputs {
    param([string]$Directory)
    $items = @(Get-ChildItem -LiteralPath $Directory -Force)
    $apkFiles = @($items | Where-Object { -not $_.PSIsContainer -and $_.Extension -ieq '.apk' })
    if ($apkFiles.Count -ne 2) { throw 'ApkDirectory must contain exactly the two release ABI APKs.' }
    foreach ($item in $items) {
        Assert-AndroidReleaseNoReparseAttributes $item.Attributes 'ApkDirectory entry'
        if ($item.PSIsContainer) { throw 'ApkDirectory may not contain nested directories.' }
        if ($item.Name -cnotin @($script:AndroidReleaseApkNames.Values) -and
            $item.Name -cnotin @($script:AndroidReleaseApkSha1Names.Values) -and
            $item.Name -cne 'output-metadata.json') {
            throw 'ApkDirectory contains an unknown or non-release file.'
        }
        if ($item.Extension -ieq '.apk' -and $item.Name -cnotin @($script:AndroidReleaseApkNames.Values)) {
            throw 'ApkDirectory contains an unexpected APK name.'
        }
    }
    foreach ($abi in $script:AndroidReleaseApkNames.Keys) {
        $expectedName = [string]$script:AndroidReleaseApkNames[$abi]
        $found = @($apkFiles | Where-Object { $_.Name -ceq $expectedName })
        if ($found.Count -ne 1 -or $found[0].Length -le 0) { throw "ApkDirectory is missing $expectedName." }

        $sidecarName = [string]$script:AndroidReleaseApkSha1Names[$abi]
        $sidecars = @($items | Where-Object { $_.Name -ceq $sidecarName })
        if ($sidecars.Count -gt 1) { throw "ApkDirectory contains duplicate sidecars for $expectedName." }
        if ($sidecars.Count -eq 1) {
            Assert-AndroidReleaseApkSha1Sidecar -SidecarPath $sidecars[0].FullName -ApkPath $found[0].FullName
        }
    }
    return $apkFiles
}

function Get-AndroidReleaseSha1 {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer) { throw 'A regular file is required for SHA-1 compatibility checking.' }
    Assert-AndroidReleaseNoReparseAttributes $item.Attributes 'SHA-1 compatibility input'
    $stream = [IO.File]::OpenRead($item.FullName)
    $sha = [Security.Cryptography.SHA1]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $stream.Dispose(); $sha.Dispose() }
}

function Assert-AndroidReleaseApkSha1Sidecar {
    param([string]$SidecarPath, [string]$ApkPath)
    $sidecar = Get-Item -LiteralPath $SidecarPath -Force -ErrorAction Stop
    if ($sidecar.PSIsContainer) { throw 'An APK SHA-1 sidecar must be a regular file.' }
    Assert-AndroidReleaseNoReparseAttributes $sidecar.Attributes 'APK SHA-1 sidecar'
    if ($sidecar.Length -lt 40 -or $sidecar.Length -gt 42) {
        throw 'An APK SHA-1 sidecar must contain exactly 40 hexadecimal characters, optionally followed by one line ending.'
    }
    $bytes = [IO.File]::ReadAllBytes($sidecar.FullName)
    $content = [Text.Encoding]::ASCII.GetString($bytes)
    if ($content -cnotmatch '\A[0-9a-fA-F]{40}(?:\r\n|\n)?\z') {
        throw 'An APK SHA-1 sidecar must contain exactly 40 hexadecimal characters, optionally followed by one line ending.'
    }

    # Flutter's .sha1 sidecar is compatibility metadata only; candidate integrity remains SHA-256.
    $declared = $content.Substring(0, 40).ToLowerInvariant()
    $actual = Get-AndroidReleaseSha1 -Path $ApkPath
    if ($declared -cne $actual) { throw 'An APK SHA-1 sidecar does not match its APK.' }
}

function Assert-AndroidReleaseCandidateTargetAbsent {
    param([string]$Path, [string]$BuildRoot)
    if (-not (Test-AndroidReleasePathWithinRoot -Path $Path -Root $BuildRoot)) {
        throw 'The candidate output path must remain inside app/build.'
    }
    [void](Assert-AndroidReleasePathChain -Path $Path)
    if (Test-Path -LiteralPath $Path) { throw 'The candidate output directory already exists; refusing to overwrite it.' }
}

function Get-AndroidReleaseSourceRevision {
    param([string]$Revision)
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) { throw 'Git is required to bind the candidate to source.' }
    $head = & $git.Source -C $script:AndroidReleaseWorkspaceRoot rev-parse --verify HEAD 2>$null
    $headExit = $LASTEXITCODE
    if ($headExit -ne 0) { throw 'Git could not read the current HEAD revision.' }
    $status = @(& $git.Source -C $script:AndroidReleaseWorkspaceRoot status --porcelain=v1 --untracked-files=all 2>$null)
    $statusExit = $LASTEXITCODE
    if ($statusExit -ne 0) { throw 'Git could not verify the source worktree.' }
    Assert-CleanAndroidReleaseRevision -Revision $Revision -HeadRevision ([string]$head).Trim() -StatusLines $status
    return ([string]$head).Trim().ToLowerInvariant()
}

function Copy-AndroidReleaseZipEntry {
    param([IO.Compression.ZipArchiveEntry]$Entry, [string]$Destination)
    if ($null -eq $Entry) { throw 'A required public document entry is missing.' }
    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void][IO.Directory]::CreateDirectory($parent) }
    [void](Assert-AndroidReleasePathChain -Path $parent -RequireLeaf)
    if (Test-Path -LiteralPath $Destination) { throw 'A candidate payload file already exists.' }
    $input = $Entry.Open()
    $output = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $input.CopyTo($output) }
    finally { $input.Dispose(); $output.Dispose() }
}

function Get-AndroidReleasePackageFileRecords {
    param([string]$Root)
    $records = [System.Collections.Generic.List[object]]::new()
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $pending.Push($Root)
    while ($pending.Count -gt 0) {
        foreach ($item in (Get-ChildItem -LiteralPath $pending.Pop() -Force)) {
            Assert-AndroidReleaseNoReparseAttributes $item.Attributes 'Candidate package tree'
            if ($item.PSIsContainer) { $pending.Push($item.FullName); continue }
            $relative = $item.FullName.Substring($Root.Length + 1).Replace('\', '/')
            Assert-AndroidReleaseSafeRelativePath $relative
            $records.Add([pscustomobject][ordered]@{
                path = $relative
                bytes = [long]$item.Length
                sha256 = Get-AndroidReleaseSha256 -Path $item.FullName
            })
        }
    }
    return @($records.ToArray() | Sort-Object -Property path)
}

function Write-AndroidReleaseManifest {
    param(
        [string]$Root,
        [string]$Revision,
        [string]$CertificateSha256,
        [object]$AndroidVersion,
        [object[]]$Apks,
        [string]$BuildToolsVersion
    )
    $manifest = [ordered]@{
        schemaVersion = 1
        productName = 'USTC Assistant'
        versionName = [string]$AndroidVersion.VersionName
        pubspecVersion = [string]$AndroidVersion.PubspecVersion
        artifactStatus = 'public-candidate'
        published = $false
        sourceRevision = $Revision
        applicationId = $script:AndroidReleaseApplicationId
        certificateSha256 = $CertificateSha256
        buildToolsVersion = $BuildToolsVersion
        apks = @($Apks | Sort-Object -Property abi | ForEach-Object {
            [ordered]@{
                file = [string]$_.File
                abi = [string]$_.Abi
                versionCode = [long]$_.VersionCode
                packageName = $script:AndroidReleaseApplicationId
                certificateSha256 = $CertificateSha256
                bytes = [long]$_.Bytes
                sha256 = [string]$_.Sha256
            }
        })
        files = @((Get-AndroidReleasePackageFileRecords -Root $Root))
        checkLimits = [ordered]@{
            signature = 'apksigner verified v2 and the requested single certificate digest; no trust-store claim'
            package = 'aapt package, version, ABI, merged manifest flags/components and release network policy'
            archive = 'ABI libraries, AOT revision, fixed speech assets and bundled notices/licenses'
            installation = 'not performed'
            realDeviceAcceptance = 'not performed'
            schoolAccess = 'not performed'
            publication = 'not performed'
        }
        sha256Purpose = 'integrity-only-not-a-digital-signature'
    }
    $manifestPath = Join-Path $Root 'manifest.json'
    [IO.File]::WriteAllText($manifestPath, ((ConvertTo-Json -InputObject $manifest -Depth 7) + "`n"), [Text.UTF8Encoding]::new($false))
    return $manifestPath
}

function Write-AndroidReleaseChecksums {
    param([string]$Root)
    $records = Get-AndroidReleasePackageFileRecords -Root $Root
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($record in $records) { $lines.Add(([string]$record.sha256) + '  ' + [string]$record.path) }
    $path = Join-Path $Root 'SHA256SUMS.txt'
    [IO.File]::WriteAllText($path, ([string]::Join("`n", $lines.ToArray()) + "`n"), [Text.UTF8Encoding]::new($false))
    return $path
}

function Remove-AndroidReleaseStage {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return }
    if (-not (Test-AndroidReleasePathWithinRoot -Path $Path -Root $script:AndroidReleaseBuildRoot)) {
        throw 'Refusing to remove a staging path outside app/build.'
    }
    [void](Assert-AndroidReleasePathChain -Path $Path -RequireLeaf)
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer -or $item.Name -notmatch '^\.android-release-stage-[0-9a-f]{32}$') {
        throw 'Refusing to remove an unrecognized staging directory.'
    }
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $pending.Push($item.FullName)
    while ($pending.Count -gt 0) {
        foreach ($child in (Get-ChildItem -LiteralPath $pending.Pop() -Force)) {
            Assert-AndroidReleaseNoReparseAttributes $child.Attributes 'Staging tree'
            if ($child.PSIsContainer) { $pending.Push($child.FullName) }
        }
    }
    Remove-Item -LiteralPath $item.FullName -Recurse -Force
}

function Invoke-AndroidReleasePackage {
    param(
        [string]$ApkDirectory,
        [string]$Revision,
        [string]$CertificateSha256,
        [string]$SdkRoot,
        [long]$ExpectedArm64VersionCode,
        [long]$ExpectedX64VersionCode
    )
    if ($ExpectedArm64VersionCode -le 0 -or $ExpectedX64VersionCode -le 0 -or
        $ExpectedArm64VersionCode -eq $ExpectedX64VersionCode) {
        throw 'Both ABI version codes must be positive and distinct.'
    }
    $certificate = ConvertTo-AndroidReleaseCertificateSha256 $CertificateSha256
    if ($certificate -ceq $script:AndroidReleaseKnownQaCertificate) {
        throw 'The known QA signing certificate cannot be used for a public candidate.'
    }
    $sourceRevision = Get-AndroidReleaseSourceRevision $Revision
    $version = Get-AndroidReleaseAndroidVersion
    $apkRoot = Resolve-AndroidReleaseApkDirectory $ApkDirectory
    $apkInputs = Get-AndroidReleaseApkInputs $apkRoot
    $sdkTools = Get-AndroidReleaseSdkTools $SdkRoot

    $expectedCodes = @{
        'arm64-v8a' = $ExpectedArm64VersionCode
        'x86_64' = $ExpectedX64VersionCode
    }
    $validatedApks = [System.Collections.Generic.List[object]]::new()
    foreach ($abi in $script:AndroidReleaseApkNames.Keys) {
        $apkName = [string]$script:AndroidReleaseApkNames[$abi]
        $apk = @($apkInputs | Where-Object { $_.Name -ceq $apkName })[0]
        $signerOutput = Invoke-AndroidReleaseSdkCommand -ToolPath $sdkTools.Apksigner -Arguments @('verify', '--verbose', '--print-certs', $apk.FullName) -Name 'apksigner verification'
        $signer = Assert-AndroidReleaseSigner -Text $signerOutput -ExpectedCertificateSha256 $certificate
        $badgingOutput = Invoke-AndroidReleaseSdkCommand -ToolPath $sdkTools.Aapt -Arguments @('dump', 'badging', $apk.FullName) -Name 'aapt package inspection'
        $badging = Assert-AndroidReleaseBadging -Text $badgingOutput -ExpectedAbi $abi -ExpectedVersionCode ([long]$expectedCodes[$abi]) -ExpectedVersionName $version.VersionName
        $manifestOutput = Invoke-AndroidReleaseSdkCommand -ToolPath $sdkTools.Aapt -Arguments @('dump', 'xmltree', $apk.FullName, 'AndroidManifest.xml') -Name 'aapt merged-manifest inspection'
        Assert-AndroidReleaseManifest -Text $manifestOutput -ExpectedPackageName $script:AndroidReleaseApplicationId
        $archiveFacts = Test-AndroidReleaseApkArchive -Path $apk.FullName -ExpectedAbi $abi -Revision $sourceRevision
        $validatedApks.Add([pscustomobject]@{
            File = $apkName
            SourcePath = $apk.FullName
            Abi = $abi
            VersionCode = [long]$badging.VersionCode
            VersionName = [string]$badging.VersionName
            CertificateSha256 = [string]$signer.CertificateSha256
            Bytes = [long]$apk.Length
            Sha256 = Get-AndroidReleaseSha256 -Path $apk.FullName
            Archive = $archiveFacts
        })
    }

    $publicRoot = Join-Path $script:AndroidReleaseBuildRoot 'public-releases'
    [void](Assert-AndroidReleasePathChain -Path $publicRoot)
    if (-not (Test-Path -LiteralPath $publicRoot -PathType Container)) {
        [void][IO.Directory]::CreateDirectory($publicRoot)
        [void](Assert-AndroidReleasePathChain -Path $publicRoot -RequireLeaf)
    }
    $candidateName = 'android-{0}-{1}' -f $version.VersionName, $sourceRevision.Substring(0, 8)
    $candidatePath = Join-Path $publicRoot $candidateName
    Assert-AndroidReleaseCandidateTargetAbsent -Path $candidatePath -BuildRoot $script:AndroidReleaseBuildRoot
    $stagePath = Join-Path $script:AndroidReleaseBuildRoot ('.android-release-stage-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($stagePath)
    $completed = $false
    try {
        [void](Assert-AndroidReleasePathChain -Path $stagePath -RequireLeaf)
        foreach ($apk in $validatedApks) {
            $destination = Join-Path $stagePath $apk.File
            $source = Get-Item -LiteralPath $apk.SourcePath -Force -ErrorAction Stop
            if ($source.Length -ne $apk.Bytes -or (Get-AndroidReleaseSha256 -Path $source.FullName) -cne $apk.Sha256) {
                throw 'An APK changed after validation; no candidate package was created.'
            }
            [IO.File]::Copy($source.FullName, $destination, $false)
            if ((Get-AndroidReleaseSha256 -Path $destination) -cne $apk.Sha256) {
                throw 'A copied APK failed its integrity check; no candidate package was created.'
            }
        }
        foreach ($document in $script:AndroidReleaseProjectDocuments.Keys) {
            $entryPath = [string]$script:AndroidReleaseProjectDocuments[$document]
            $abiArchive = [IO.Compression.ZipFile]::OpenRead([string](@($validatedApks | Where-Object { $_.Abi -ceq 'arm64-v8a' })[0].SourcePath))
            try {
                $entry = $abiArchive.GetEntry($entryPath)
                if ($null -eq $entry -or $entry.Length -le 0) { throw "A public Android document is missing: $entryPath" }
                $destination = Join-Path $stagePath ([string]$document.Replace('/', '\'))
                Copy-AndroidReleaseZipEntry -Entry $entry -Destination $destination
            }
            finally { $abiArchive.Dispose() }
        }
        $apkRecords = @($validatedApks | ForEach-Object {
            [pscustomobject]@{
                File = [string]$_.File
                Abi = [string]$_.Abi
                VersionCode = [long]$_.VersionCode
                Bytes = [long]$_.Bytes
                Sha256 = [string]$_.Sha256
            }
        })
        [void](Write-AndroidReleaseManifest -Root $stagePath -Revision $sourceRevision -CertificateSha256 $certificate -AndroidVersion $version -Apks $apkRecords -BuildToolsVersion $sdkTools.BuildToolsVersion)
        [void](Write-AndroidReleaseChecksums -Root $stagePath)
        $expectedFiles = 9
        $actualFiles = @(Get-AndroidReleasePackageFileRecords -Root $stagePath)
        if ($actualFiles.Count -ne $expectedFiles) { throw 'The candidate file set is not the exact expected payload.' }
        Assert-AndroidReleaseCandidateTargetAbsent -Path $candidatePath -BuildRoot $script:AndroidReleaseBuildRoot
        [IO.Directory]::Move($stagePath, $candidatePath)
        $completed = $true
        Write-Output "Android public candidate directory: $candidatePath"
        foreach ($apk in $validatedApks) { Write-Output ("{0} ({1}): SHA-256 {2}" -f $apk.File, $apk.Abi, $apk.Sha256) }
        Write-Output 'Candidate manifest marks published=false. No installation, device acceptance, school access, or publication was performed.'
    }
    finally {
        if (-not $completed -and (Test-Path -LiteralPath $stagePath)) { Remove-AndroidReleaseStage $stagePath }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-AndroidReleasePackage -ApkDirectory $ApkDirectory -Revision $Revision `
        -CertificateSha256 $CertificateSha256 -SdkRoot $SdkRoot `
        -ExpectedArm64VersionCode $ExpectedArm64VersionCode `
        -ExpectedX64VersionCode $ExpectedX64VersionCode
}
