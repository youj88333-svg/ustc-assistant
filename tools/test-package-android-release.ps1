[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'package-android-release.ps1')

$script:AndroidReleaseTestChecks = 0
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$buildRoot = [IO.Path]::GetFullPath((Join-Path $workspace 'app\build'))
$buildRootExisted = Test-Path -LiteralPath $buildRoot -PathType Container
$testRoot = Join-Path $buildRoot ('.android-release-test-' + [guid]::NewGuid().ToString('N'))

function Assert-AndroidReleaseTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:AndroidReleaseTestChecks++
}

function Assert-AndroidReleaseTestThrows {
    param([scriptblock]$Action, [string]$Pattern, [string]$Message)
    try { & $Action }
    catch {
        if ($_.Exception.Message -match $Pattern) { $script:AndroidReleaseTestChecks++; return }
        throw
    }
    throw "Assertion failed: $Message; expected the operation to fail."
}

function Add-AndroidReleaseSyntheticZipEntry {
    param([IO.Compression.ZipArchive]$Archive, [string]$Name, [string]$Contents = 'synthetic fixture')
    $entry = $Archive.CreateEntry($Name)
    $stream = $entry.Open()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Contents)
        $stream.Write($bytes, 0, $bytes.Length)
    }
    finally { $stream.Dispose() }
}

function New-AndroidReleaseSyntheticZip {
    param([string]$Path, [string[]]$Entries)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($entryName in $Entries) { Add-AndroidReleaseSyntheticZipEntry $archive $entryName }
    }
    finally { $archive.Dispose() }
}

function New-AndroidReleaseSyntheticManifest {
    param([string]$ApplicationFlags = '', [string[]]$ExtraComponents = @())
    $lines = @(
        'E: manifest (line=2)'
        '  A: package="cn.ustcassistant.mobile" (Raw: "cn.ustcassistant.mobile")'
        '  E: application (line=6)'
        '    A: android:name(0x01010003)=".SchoolApplication" (Raw: ".SchoolApplication")'
        '    A: android:allowBackup(0x01010280)=false'
        '    A: android:usesCleartextTraffic(0x010104ec)=false'
        '    A: android:debuggable(0x0101000f)=false'
        $ApplicationFlags
        '    E: activity (line=20)'
        '      A: android:name(0x01010003)=".MainActivity" (Raw: ".MainActivity")'
        '      A: android:exported(0x01010010)=true'
        '      E: intent-filter (line=22)'
        '        E: action (line=23)'
        '          A: android:name(0x01010003)="android.intent.action.MAIN" (Raw: "android.intent.action.MAIN")'
        '    E: activity (line=40)'
        '      A: android:name(0x01010003)=".browser.SchoolHostActivity" (Raw: ".browser.SchoolHostActivity")'
        '      A: android:exported(0x01010010)=false'
        '      A: android:process(0x01010011)=":school_host" (Raw: ":school_host")'
        '    E: service (line=60)'
        '      A: android:name(0x01010003)=".browser.SchoolHostService" (Raw: ".browser.SchoolHostService")'
        '      A: android:exported(0x01010010)=false'
        '      A: android:process(0x01010011)=":school_host" (Raw: ":school_host")'
        '    E: receiver (line=80)'
        '      A: android:name(0x01010003)=".notifications.ReminderAlarmReceiver" (Raw: ".notifications.ReminderAlarmReceiver")'
        '      A: android:exported(0x01010010)=false'
        '    E: receiver (line=90)'
        '      A: android:name(0x01010003)=".notifications.ReminderRestoreReceiver" (Raw: ".notifications.ReminderRestoreReceiver")'
        '      A: android:exported(0x01010010)=false'
        $ExtraComponents
        '  E: uses-sdk (line=100)'
    )
    return [string]::Join("`n", @($lines | Where-Object { -not [string]::IsNullOrEmpty($_) }))
}

function Remove-AndroidReleaseSyntheticTree {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (-not (Test-AndroidReleasePathWithinRoot -Path $Path -Root $buildRoot) -or
        (Split-Path -Leaf $Path) -notmatch '^\.android-release-test-[0-9a-f]{32}$') {
        throw 'Refusing to remove an unexpected synthetic test directory.'
    }
    [void](Assert-AndroidReleasePathChain -Path $Path -RequireLeaf)
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        foreach ($item in (Get-ChildItem -LiteralPath $stack.Pop() -Force)) {
            Assert-AndroidReleaseNoReparseAttributes $item.Attributes 'Synthetic test tree'
            if ($item.PSIsContainer) { $stack.Push($item.FullName) }
        }
    }
    Remove-Item -LiteralPath $Path -Recurse -Force
}

try {
    if (-not $buildRootExisted) { [void][IO.Directory]::CreateDirectory($buildRoot) }
    [void](Assert-AndroidReleasePathChain -Path $buildRoot -RequireLeaf)
    [void][IO.Directory]::CreateDirectory($testRoot)

    $revision = '0123456789abcdef0123456789abcdef01234567'
    Assert-CleanAndroidReleaseRevision -Revision $revision -HeadRevision $revision -StatusLines @()
    Assert-AndroidReleaseTest $true 'accept an exact clean source revision'
    Assert-AndroidReleaseTestThrows { Assert-CleanAndroidReleaseRevision -Revision $revision -HeadRevision ('f' * 40) -StatusLines @() } 'current HEAD' 'reject a non-HEAD revision'
    Assert-AndroidReleaseTestThrows { Assert-CleanAndroidReleaseRevision -Revision $revision -HeadRevision $revision -StatusLines @(' M README.md') } 'clean source worktree' 'reject a dirty source tree'
    Assert-AndroidReleaseTestThrows { Assert-CleanAndroidReleaseRevision -Revision 'bad' -HeadRevision $revision -StatusLines @() } '40 hexadecimal' 'reject a malformed revision'

    $armBadging = @'
package: name='cn.ustcassistant.mobile' versionCode='2400001' versionName='1.0.0' platformBuildVersionName='16'
native-code: 'arm64-v8a'
launchable-activity: name='cn.ustcassistant.mobile.MainActivity' label='' icon=''
'@
    $x64Badging = $armBadging.Replace('2400001', '2404001').Replace('arm64-v8a', 'x86_64')
    Assert-AndroidReleaseBadging -Text $armBadging -ExpectedAbi 'arm64-v8a' -ExpectedVersionCode 2400001 | Out-Null
    Assert-AndroidReleaseBadging -Text $x64Badging -ExpectedAbi 'x86_64' -ExpectedVersionCode 2404001 | Out-Null
    Assert-AndroidReleaseTest $true 'parse formal package, version and per-ABI metadata'
    Assert-AndroidReleaseTestThrows { Assert-AndroidReleaseBadging -Text $armBadging.Replace('cn.ustcassistant.mobile', 'cn.ustcassistant.mobile.qa') -ExpectedAbi 'arm64-v8a' -ExpectedVersionCode 2400001 } 'formal Android identity' 'reject the QA package id'
    Assert-AndroidReleaseTestThrows { Assert-AndroidReleaseBadging -Text $armBadging.Replace("versionName='1.0.0'", "versionName='1.0.0-qa'") -ExpectedAbi 'arm64-v8a' -ExpectedVersionCode 2400001 } 'versionName' 'reject a QA version name'
    Assert-AndroidReleaseTestThrows { Assert-AndroidReleaseBadging -Text $armBadging.Replace('2400001', '3') -ExpectedAbi 'arm64-v8a' -ExpectedVersionCode 2400001 } 'versionCode' 'reject a wrong version code'
    Assert-AndroidReleaseTestThrows { Assert-AndroidReleaseBadging -Text $armBadging.Replace('arm64-v8a', 'x86_64') -ExpectedAbi 'arm64-v8a' -ExpectedVersionCode 2400001 } 'wrong native ABI' 'reject an ABI mismatch'
    Assert-AndroidReleaseTestThrows { Get-AndroidReleaseBadgingFacts $armBadging.Replace("native-code: 'arm64-v8a'", "native-code: 'arm64-v8a' 'x86_64'") } 'multiple ABIs' 'reject a multi-ABI APK'

    $certificate = 'a' * 64
    $signerOutput = @"
Verifies
Verified using v1 scheme (JAR signing): false
Verified using v2 scheme (APK Signature Scheme v2): true
Verified using v3 scheme (APK Signature Scheme v3): false
Number of signers: 1
Signer #1 certificate DN: CN=synthetic test certificate
Signer #1 certificate SHA-256 digest: $certificate
"@
    Assert-AndroidReleaseSigner -Text $signerOutput -ExpectedCertificateSha256 $certificate | Out-Null
    $colonCertificate = [string]::Join(':', @([regex]::Matches($certificate, '.{2}') | ForEach-Object { $_.Value }))
    Assert-AndroidReleaseSigner -Text $signerOutput.Replace($certificate, $colonCertificate) -ExpectedCertificateSha256 $certificate | Out-Null
    Assert-AndroidReleaseTest $true 'accept only the synthetic pinned single signer with verified v2 signature'
    Assert-AndroidReleaseTestThrows { Assert-AndroidReleaseSigner -Text $signerOutput -ExpectedCertificateSha256 $script:AndroidReleaseKnownQaCertificate } 'known QA' 'reject the known QA certificate'
    Assert-AndroidReleaseTestThrows { Assert-AndroidReleaseSigner -Text $signerOutput -ExpectedCertificateSha256 ('b' * 64) } 'does not match' 'reject an unexpected certificate digest'
    Assert-AndroidReleaseTestThrows { Get-AndroidReleaseSignerFacts $signerOutput.Replace('v2): true', 'v2): false') } 'v2 signature' 'reject a missing v2 signature'
    Assert-AndroidReleaseTestThrows { Get-AndroidReleaseSignerFacts $signerOutput.Replace('Number of signers: 1', 'Number of signers: 2') } 'exactly one signer' 'reject multiple signers'
    Assert-AndroidReleaseTestThrows { ConvertTo-AndroidReleaseCertificateSha256 (($certificate + 'not-a-digest')) } '64 hexadecimal' 'reject malformed certificate input'

    $manifest = New-AndroidReleaseSyntheticManifest
    Assert-AndroidReleaseManifest -Text $manifest -ExpectedPackageName 'cn.ustcassistant.mobile'
    Assert-AndroidReleaseManifest -Text $manifest.Replace('android:debuggable(0x0101000f)=false', 'android:debuggable(0x0101000f)=(type 0x12)0x0') -ExpectedPackageName 'cn.ustcassistant.mobile'
    Assert-AndroidReleaseTest $true 'accept the main app components and safe release manifest flags'
    Assert-AndroidReleaseTestThrows { Assert-AndroidReleaseManifest -Text $manifest.Replace('allowBackup(0x01010280)=false', 'allowBackup(0x01010280)=true') -ExpectedPackageName 'cn.ustcassistant.mobile' } 'allowBackup' 'reject backup-enabled manifest'
    Assert-AndroidReleaseTestThrows { Assert-AndroidReleaseManifest -Text $manifest.Replace('usesCleartextTraffic(0x010104ec)=false', 'usesCleartextTraffic(0x010104ec)=true') -ExpectedPackageName 'cn.ustcassistant.mobile' } 'usesCleartextTraffic' 'reject cleartext traffic'
    Assert-AndroidReleaseTestThrows { Assert-AndroidReleaseManifest -Text $manifest.Replace('android:debuggable(0x0101000f)=false', 'android:debuggable(0x0101000f)=true') -ExpectedPackageName 'cn.ustcassistant.mobile' } 'debuggable' 'reject a debuggable manifest'
    Assert-AndroidReleaseTestThrows { Assert-AndroidReleaseManifest -Text (New-AndroidReleaseSyntheticManifest -ApplicationFlags '    A: android:testOnly(0x01010272)=true') -ExpectedPackageName 'cn.ustcassistant.mobile' } 'testOnly' 'reject testOnly manifest'
    Assert-AndroidReleaseTestThrows { Assert-AndroidReleaseManifest -Text (New-AndroidReleaseSyntheticManifest -ApplicationFlags '    A: android:networkSecurityConfig(0x01010527)=@0x7f060001') -ExpectedPackageName 'cn.ustcassistant.mobile' } 'network security configuration' 'reject an unreviewed network security override'
    Assert-AndroidReleaseTestThrows { Assert-AndroidReleaseManifest -Text (New-AndroidReleaseSyntheticManifest -ExtraComponents @('    E: activity (line=111)', '      A: android:name(0x01010003)=".qa.QaProbeActivity"')) -ExpectedPackageName 'cn.ustcassistant.mobile' } 'Debug-only QA' 'reject explicit QA probe components'
    Assert-AndroidReleaseTestThrows { Assert-AndroidReleaseManifest -Text $manifest.Replace('android:allowBackup(0x01010280)=false', 'android:allowBackup(0x01010280)=true') -ExpectedPackageName 'cn.ustcassistant.mobile.qa' } 'wrong package name' 'reject a QA manifest package'

    $validZip = Join-Path $testRoot 'valid-abi.zip'
    New-AndroidReleaseSyntheticZip -Path $validZip -Entries @(
        'lib/'
        'lib/arm64-v8a/'
        'lib/arm64-v8a/libapp.so'
        'lib/arm64-v8a/libflutter.so'
        'assets/flutter_assets/assets/ustc/jw_probe.js'
    )
    $validArchive = [IO.Compression.ZipFile]::OpenRead($validZip)
    try {
        $entries = Get-AndroidReleaseZipIndex $validArchive
        Assert-AndroidReleaseAbiLayout $entries 'arm64-v8a'
        Assert-AndroidReleaseTest ($entries.ContainsKey('assets/flutter_assets/assets/ustc/jw_probe.js')) 'preserve the fixed production jw_probe.js asset'
    }
    finally { $validArchive.Dispose() }

    $wrongAbiZip = Join-Path $testRoot 'wrong-abi.zip'
    New-AndroidReleaseSyntheticZip -Path $wrongAbiZip -Entries @('lib/arm64-v8a/libapp.so', 'lib/x86_64/libforeign.so')
    $wrongAbiArchive = [IO.Compression.ZipFile]::OpenRead($wrongAbiZip)
    try { Assert-AndroidReleaseTestThrows { Assert-AndroidReleaseAbiLayout (Get-AndroidReleaseZipIndex $wrongAbiArchive) 'arm64-v8a' } 'unexpected ABI' 'reject a foreign native ABI' }
    finally { $wrongAbiArchive.Dispose() }

    $privateZip = Join-Path $testRoot 'private-key.zip'
    New-AndroidReleaseSyntheticZip -Path $privateZip -Entries @('lib/arm64-v8a/libapp.so', 'assets/release.p12')
    $privateArchive = [IO.Compression.ZipFile]::OpenRead($privateZip)
    try { Assert-AndroidReleaseTestThrows { Get-AndroidReleaseZipIndex $privateArchive } 'private-key material' 'reject an embedded private-key file' }
    finally { $privateArchive.Dispose() }

    $traversalZip = Join-Path $testRoot 'traversal.zip'
    New-AndroidReleaseSyntheticZip -Path $traversalZip -Entries @('../escape.txt')
    $traversalArchive = [IO.Compression.ZipFile]::OpenRead($traversalZip)
    try { Assert-AndroidReleaseTestThrows { Get-AndroidReleaseZipIndex $traversalArchive } 'unsafe path' 'reject ZIP traversal' }
    finally { $traversalArchive.Dispose() }

    $duplicateZip = Join-Path $testRoot 'duplicate.zip'
    New-AndroidReleaseSyntheticZip -Path $duplicateZip -Entries @('lib/arm64-v8a/libapp.so', 'LIB/ARM64-V8A/LIBAPP.SO')
    $duplicateArchive = [IO.Compression.ZipFile]::OpenRead($duplicateZip)
    try { Assert-AndroidReleaseTestThrows { Get-AndroidReleaseZipIndex $duplicateArchive } 'duplicate or case-colliding' 'reject duplicate case-insensitive ZIP names' }
    finally { $duplicateArchive.Dispose() }

    $revisionBytes = [Text.Encoding]::ASCII.GetBytes(('x' * 65530) + $revision + 'y')
    $revisionStream = [IO.MemoryStream]::new($revisionBytes)
    Assert-AndroidReleaseTest (Test-AndroidReleaseStreamContainsAscii -Stream $revisionStream -Text $revision) 'find the AOT revision across a streaming buffer boundary'
    $wrongRevisionStream = [IO.MemoryStream]::new([Text.Encoding]::ASCII.GetBytes('synthetic AOT data'))
    Assert-AndroidReleaseTest (-not (Test-AndroidReleaseStreamContainsAscii -Stream $wrongRevisionStream -Text $revision)) 'reject a missing AOT revision'

    $inputDirectory = Join-Path $testRoot 'apk-inputs'
    [void][IO.Directory]::CreateDirectory($inputDirectory)
    [IO.File]::WriteAllText((Join-Path $inputDirectory 'app-arm64-v8a-release.apk'), 'synthetic input')
    [IO.File]::WriteAllText((Join-Path $inputDirectory 'app-x86_64-release.apk'), 'synthetic input')
    [IO.File]::WriteAllText((Join-Path $inputDirectory 'output-metadata.json'), '{}')
    Assert-AndroidReleaseTest ((Get-AndroidReleaseApkInputs $inputDirectory).Count -eq 2) 'accept exactly the two split release APK names'

    foreach ($apkName in $script:AndroidReleaseApkNames.Values) {
        $apkPath = Join-Path $inputDirectory ([string]$apkName)
        $sidecarName = ([string]$apkName) + '.sha1'
        [IO.File]::WriteAllText((Join-Path $inputDirectory $sidecarName), ((Get-AndroidReleaseSha1 -Path $apkPath) + "`r`n"), [Text.Encoding]::ASCII)
    }
    Assert-AndroidReleaseTest ((Get-AndroidReleaseApkInputs $inputDirectory).Count -eq 2) 'accept exact Flutter SHA-1 sidecars that match each APK'

    $armSidecar = Join-Path $inputDirectory ([string]$script:AndroidReleaseApkSha1Names['arm64-v8a'])
    [IO.File]::WriteAllText($armSidecar, (('0' * 40) + "`n"), [Text.Encoding]::ASCII)
    Assert-AndroidReleaseTestThrows { Get-AndroidReleaseApkInputs $inputDirectory } 'does not match its APK' 'reject a SHA-1 sidecar with the wrong digest'
    [IO.File]::WriteAllText($armSidecar, ('g' * 40), [Text.Encoding]::ASCII)
    Assert-AndroidReleaseTestThrows { Get-AndroidReleaseApkInputs $inputDirectory } '40 hexadecimal characters' 'reject a malformed SHA-1 sidecar'
    Remove-Item -LiteralPath $armSidecar -Force
    [void][IO.Directory]::CreateDirectory($armSidecar)
    Assert-AndroidReleaseTestThrows { Get-AndroidReleaseApkInputs $inputDirectory } 'nested directories' 'reject a non-file SHA-1 sidecar'
    Remove-Item -LiteralPath $armSidecar -Force
    [IO.File]::WriteAllText($armSidecar, ((Get-AndroidReleaseSha1 -Path (Join-Path $inputDirectory 'app-arm64-v8a-release.apk')) + "`n"), [Text.Encoding]::ASCII)

    [IO.File]::WriteAllText((Join-Path $inputDirectory 'unexpected.sha1'), 'synthetic')
    Assert-AndroidReleaseTestThrows { Get-AndroidReleaseApkInputs $inputDirectory } 'unknown or non-release file' 'reject an unknown SHA-1 sidecar name'
    Remove-Item -LiteralPath (Join-Path $inputDirectory 'unexpected.sha1') -Force

    [IO.File]::WriteAllText((Join-Path $inputDirectory 'app-debug.apk'), 'synthetic QA input')
    Assert-AndroidReleaseTestThrows { Get-AndroidReleaseApkInputs $inputDirectory } 'exactly the two release ABI APKs|unexpected APK name' 'reject an extra debug APK'

    $candidateTarget = Join-Path $testRoot 'candidate-absent'
    Assert-AndroidReleaseCandidateTargetAbsent -Path $candidateTarget -BuildRoot $buildRoot
    [void][IO.Directory]::CreateDirectory($candidateTarget)
    Assert-AndroidReleaseTestThrows { Assert-AndroidReleaseCandidateTargetAbsent -Path $candidateTarget -BuildRoot $buildRoot } 'already exists' 'refuse to overwrite an existing candidate'

    $noOutputRevision = 'deadbeef'
    $publicRoot = Join-Path $buildRoot 'public-releases'
    $wouldBeCandidate = Join-Path $publicRoot ('android-1.0.0-' + $noOutputRevision)
    Assert-AndroidReleaseTestThrows {
        Invoke-AndroidReleasePackage -ApkDirectory $inputDirectory -Revision ('f' * 40) `
            -CertificateSha256 $script:AndroidReleaseKnownQaCertificate -SdkRoot 'not-an-sdk' `
            -ExpectedArm64VersionCode 1 -ExpectedX64VersionCode 2
    } 'known QA' 'reject production packaging with the known QA certificate before creating output'
    Assert-AndroidReleaseTest (-not (Test-Path -LiteralPath $wouldBeCandidate)) 'do not create a candidate on a validation failure'

    $version = Get-AndroidReleaseAndroidVersion
    Assert-AndroidReleaseTest ($version.VersionName -ceq '1.0.0' -and $version.PubspecVersion -ceq '1.0.0+1') 'bind the candidate versionName to pubspec.yaml'
    Assert-AndroidReleaseTestThrows { Assert-AndroidReleaseSafeRelativePath '../outside' } 'unsafe path' 'reject unsafe relative output paths'
    Assert-AndroidReleaseTestThrows { Assert-AndroidReleaseNoReparseAttributes ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint) 'fixture' } 'reparse point' 'reject synthetic reparse attributes'

    Write-Output ("Android release packager synthetic checks passed: {0}." -f $script:AndroidReleaseTestChecks)
    Write-Output 'Only synthetic ZIP entries and command outputs were checked; no APK signature, model archive, build, installation, or real-device claim was exercised.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-AndroidReleaseSyntheticTree $testRoot }
    if (-not $buildRootExisted -and (Test-Path -LiteralPath $buildRoot -PathType Container) -and
        @(Get-ChildItem -LiteralPath $buildRoot -Force).Count -eq 0) {
        Remove-Item -LiteralPath $buildRoot -Force
    }
}
