#requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:checks = 0
$script:PrepareScript = Join-Path $PSScriptRoot 'prepare-gitlab-release.ps1'
$script:TestRoot = [IO.Path]::GetFullPath((Join-Path 'E:\' ('codex-gitlab-release-test-' + [guid]::NewGuid().ToString('N'))))
$script:DriveRoot = [IO.Path]::GetPathRoot($script:TestRoot)
$script:RootCreated = $false
$script:JunctionPath = $null
$script:JunctionCreated = $false

function Assert-Check([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:checks++
}

function Assert-Rejected([scriptblock]$Action, [string]$Message) {
    try { & $Action | Out-Null }
    catch { $script:checks++; return }
    throw "Assertion failed: expected rejection for $Message."
}

function Get-TestFileRecord([string]$Root, [string]$RelativePath) {
    $path = Join-Path $Root $RelativePath.Replace('/', '\')
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    return [pscustomobject][ordered]@{
        path = $RelativePath
        bytes = [long]$item.Length
        sha256 = Get-Sha256FromFile $path
    }
}

function Write-TestTextFile([string]$Root, [string]$RelativePath, [string]$Text) {
    $path = Join-Path $Root $RelativePath.Replace('/', '\')
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void][IO.Directory]::CreateDirectory($parent) }
    [IO.File]::WriteAllText($path, $Text, [Text.UTF8Encoding]::new($false))
}

function New-SyntheticCandidates {
    param(
        [Parameter(Mandatory = $true)][string]$ScenarioRoot,
        [string]$CertificateSha256 = ('ab' * 32),
        [switch]$OmitX64
    )
    $revision = 'a' * 40
    $publicRoot = Join-Path $ScenarioRoot 'app\build\public-releases'
    $windowsRoot = Join-Path $publicRoot ("1.0.0+1-$($revision.Substring(0, 8))")
    $androidRoot = Join-Path $publicRoot ("android-1.0.0-$($revision.Substring(0, 8))")
    $windowsPackage = Join-Path $windowsRoot $script:WindowsFolderName
    [void][IO.Directory]::CreateDirectory($windowsPackage)

    $windowsPaths = @(Get-ExpectedPackagePaths -PublicCandidate)
    foreach ($relativePath in $windowsPaths) {
        Write-TestTextFile -Root $windowsPackage -RelativePath $relativePath -Text ("synthetic-public-file:$relativePath`n")
    }
    $windowsFiles = @(Get-TreeFileRecords $windowsPackage)
    $windowsExecutable = [ordered]@{
        file = 'ustc_assistant_m0.exe'
        fileVersion = '1.0.0+1'
        productVersion = '1.0.0+1'
        productName = 'USTC Assistant'
    }
    $windowsManifest = [ordered]@{
        schemaVersion = 1
        productName = 'USTC Assistant'
        displayVersion = '1.0.0'
        version = '1.0.0+1'
        sourceRevision = $revision
        buildType = 'release'
        entry = 'lib/main.dart'
        dataSchema = 20
        publicRelease = $true
        agentToolRegistry = 'agent-tools-v7'
        persona = 'ustc-personal-maid-agent-v15'
        pubspecLockSha256 = 'cd' * 32
        executable = $windowsExecutable
        files = $windowsFiles
        artifactStatus = 'public-candidate'
        published = $false
        windowsCodeSigned = $false
        containsUserData = $false
        sha256Purpose = 'integrity-only-not-a-digital-signature'
    }
    $windowsManifestPath = Join-Path $windowsPackage 'manifest.json'
    [IO.File]::WriteAllText($windowsManifestPath, ((ConvertTo-Json -InputObject $windowsManifest -Depth 5) + "`n"), [Text.UTF8Encoding]::new($false))
    $windowsZip = Join-Path $windowsRoot "$script:WindowsFolderName.zip"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($windowsPackage, $windowsZip, [IO.Compression.CompressionLevel]::Optimal, $true)
    $windowsZipHash = Get-Sha256FromFile $windowsZip
    [IO.File]::WriteAllText(($windowsZip + '.sha256'), ($windowsZipHash + '  ' + [IO.Path]::GetFileName($windowsZip) + "`n"), [Text.UTF8Encoding]::new($false))

    [void][IO.Directory]::CreateDirectory($androidRoot)
    $androidApkPaths = @('app-arm64-v8a-release.apk', 'app-x86_64-release.apk')
    $androidPayloadPaths = @($script:AndroidPackageFiles)
    $apkSpecs = @(
        [pscustomobject]@{ File = 'app-arm64-v8a-release.apk'; Abi = 'arm64-v8a'; Content = 'synthetic-arm64-apk' }
        [pscustomobject]@{ File = 'app-x86_64-release.apk'; Abi = 'x86_64'; Content = 'synthetic-x64-apk' }
    )
    foreach ($apk in $apkSpecs) {
        if ($OmitX64 -and $apk.Abi -ceq 'x86_64') { continue }
        Write-TestTextFile -Root $androidRoot -RelativePath $apk.File -Text ($apk.Content + "`n")
    }
    foreach ($relativePath in ($script:AndroidPackageFiles | Where-Object { $_ -notin $androidApkPaths })) {
        Write-TestTextFile -Root $androidRoot -RelativePath $relativePath -Text ("synthetic-document:$relativePath`n")
    }
    $androidFiles = @(Get-TreeFileRecords $androidRoot)
    $androidApks = @(
        foreach ($spec in $apkSpecs) {
            $path = Join-Path $androidRoot $spec.File
            if ($OmitX64 -and $spec.Abi -ceq 'x86_64') {
                $bytes = [Text.UTF8Encoding]::new($false).GetBytes($spec.Content + "`n")
                $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
                $length = $bytes.Length
            } else {
                $record = Get-TestFileRecord -Root $androidRoot -RelativePath $spec.File
                $hash = $record.sha256
                $length = $record.bytes
            }
            [ordered]@{
                file = $spec.File
                abi = $spec.Abi
                versionCode = if ($spec.Abi -ceq 'arm64-v8a') { 10001 } else { 10002 }
                packageName = 'cn.ustcassistant.mobile'
                certificateSha256 = $CertificateSha256.ToLowerInvariant()
                bytes = [long]$length
                sha256 = $hash
            }
        }
    )
    $androidManifest = [ordered]@{
        schemaVersion = 1
        productName = 'USTC Assistant'
        versionName = '1.0.0'
        pubspecVersion = '1.0.0+1'
        artifactStatus = 'public-candidate'
        published = $false
        sourceRevision = $revision
        applicationId = 'cn.ustcassistant.mobile'
        certificateSha256 = $CertificateSha256.ToLowerInvariant()
        buildToolsVersion = 'synthetic'
        apks = $androidApks
        files = $androidFiles
        checkLimits = [ordered]@{
            signature = 'synthetic fixture'
            installation = 'not performed'
            realDeviceAcceptance = 'not performed'
            schoolAccess = 'not performed'
            publication = 'not performed'
        }
        sha256Purpose = 'integrity-only-not-a-digital-signature'
    }
    $androidManifestPath = Join-Path $androidRoot 'manifest.json'
    [IO.File]::WriteAllText($androidManifestPath, ((ConvertTo-Json -InputObject $androidManifest -Depth 7) + "`n"), [Text.UTF8Encoding]::new($false))
    $sumFiles = @($androidFiles.path) + @('manifest.json')
    Write-ReleaseChecksums -Root $androidRoot -Files $sumFiles

    return [pscustomobject]@{
        Revision = $revision
        PublicRoot = $publicRoot
        WindowsRoot = $windowsRoot
        AndroidRoot = $androidRoot
        WindowsZip = $windowsZip
        AndroidArm64 = Join-Path $androidRoot 'app-arm64-v8a-release.apk'
        AndroidX64 = Join-Path $androidRoot 'app-x86_64-release.apk'
        OutputRoot = $publicRoot
    }
}

try {
    if (-not $IsWindows) { throw 'GitLab release preparation tests require Windows PowerShell 7.' }
    if ($script:DriveRoot -cne 'E:\' -or $script:TestRoot -eq $script:DriveRoot -or
        -not $script:TestRoot.StartsWith($script:DriveRoot, [StringComparison]::OrdinalIgnoreCase) -or
        ([IO.DriveInfo]::new($script:DriveRoot)).DriveType -ne [IO.DriveType]::Fixed) {
        throw 'The synthetic test root failed its E-drive fixed-root boundary check.'
    }
    if (Test-Path -LiteralPath $script:TestRoot) { throw 'The GUID-scoped synthetic root already exists; refusing to reuse it.' }
    . $script:PrepareScript

    $successRoot = Join-Path $script:TestRoot 'success'
    [void][IO.Directory]::CreateDirectory($successRoot)
    $script:RootCreated = $true
    $success = New-SyntheticCandidates -ScenarioRoot $successRoot
    $resultOutput = Invoke-GitLabReleasePrepare -WindowsPackageDirectory $success.WindowsRoot `
        -AndroidPackageDirectory $success.AndroidRoot -Revision40hex $success.Revision `
        -OutputRoot $success.OutputRoot -AllowExternalSyntheticPaths | Out-String
    $target = Join-Path $success.OutputRoot ("gitlab-1.0.0-$($success.Revision.Substring(0, 8))")
    Assert-Check (Test-Path -LiteralPath $target -PathType Container) 'combined release output was created'

    $expectedOutputFiles = @(
        $script:WindowsFolderName + '.zip'
        'app-arm64-v8a-release.apk'
        'app-x86_64-release.apk'
        'SHA256SUMS.txt'
        'release-manifest.json'
        'release-notes.md'
        'release-plan.json'
    )
    $actualOutput = @(Get-TreeFileRecords $target)
    Assert-ExactPathSet -Actual @($actualOutput.path) -Expected $expectedOutputFiles -Context 'Synthetic combined output'
    Assert-Check ($actualOutput.Count -eq 7) 'combined release directory contains exactly seven files'
    Assert-Check ((Test-Path -LiteralPath (Join-Path $target 'app-arm64-v8a-release.apk')) -and
        (Test-Path -LiteralPath (Join-Path $target 'app-x86_64-release.apk'))) 'both Android APKs are copied'
    Assert-Check (Test-Path -LiteralPath (Join-Path $target ($script:WindowsFolderName + '.zip'))) 'only the Windows ZIP is copied'
    Assert-Check (-not (Test-Path -LiteralPath (Join-Path $target $script:WindowsFolderName))) 'the extracted Windows runtime directory is not copied'
    Assert-Check (-not (Test-Path -LiteralPath (Join-Path $target 'signing.json'))) 'no signing configuration is copied'
    Assert-Check (-not (Test-Path -LiteralPath (Join-Path $target 'android-release.p12'))) 'no private keystore is copied'

    $manifestPath = Join-Path $target 'release-manifest.json'
    $manifestText = [IO.File]::ReadAllText($manifestPath)
    $releaseManifest = $manifestText | ConvertFrom-Json
    Assert-Check ($releaseManifest.sourceRevision -ceq $success.Revision) 'combined manifest is bound to the source revision'
    Assert-Check ($releaseManifest.version -ceq '1.0.0' -and $releaseManifest.published -ceq $false) 'combined manifest is version 1.0.0 and unpublished'
    Assert-Check ($releaseManifest.android.applicationId -ceq 'cn.ustcassistant.mobile') 'combined manifest uses the formal Android identity'
    Assert-Check ($releaseManifest.android.certificateSha256 -cne $script:KnownQaCertificateSha256) 'combined manifest does not use the QA certificate'
    Assert-Check (@($releaseManifest.files).Count -eq 3) 'combined public manifest records only the three installers'
    foreach ($file in $releaseManifest.files) {
        Assert-Check (-not ([string]$file.file).Contains('\') -and -not ([string]$file.file).Contains(':')) 'public file manifest contains names, not local paths'
        $actual = Get-Item -LiteralPath (Join-Path $target ([string]$file.file))
        Assert-Check ([long]$actual.Length -eq [long]$file.bytes -and (Get-Sha256FromFile $actual.FullName) -ceq [string]$file.sha256) 'public file size and checksum match'
    }
    $notesText = [IO.File]::ReadAllText((Join-Path $target 'release-notes.md'))
    Assert-Check ($notesText.Contains('尚未取得 Windows 代码签名') -and $notesText.Contains('不会覆盖测试版') -and $notesText.Contains('不会自动搬迁')) 'release notes state Windows and Android identity limits'
    Assert-Check ($notesText.Contains($success.Revision) -and $notesText.Contains('known-issues.md')) 'release notes identify source and known issues'
    Assert-Check ($notesText.Contains('原创代码采用 Apache-2.0') -and $notesText.Contains('第三方依赖、模型和来源材料分别保留原许可')) 'release notes preserve original-code and third-party license distinction'

    $planPath = Join-Path $target 'release-plan.json'
    $plan = [IO.File]::ReadAllText($planPath) | ConvertFrom-Json
    Assert-Check ($plan.localOnly -ceq $true -and $plan.notForUpload -ceq $true -and $plan.publicationPerformed -ceq $false) 'release plan is explicitly local-only and does not claim publication'
    Assert-Check ($plan.glabMinimumVersion -ceq '1.58.0') 'plan records the documented minimum glab release version'
    Assert-Check ($plan.tag -ceq 'v1.0.0' -and $plan.repository -ceq $script:DefaultRepository) 'plan targets the selected project and tag'
    Assert-Check ($plan.repository -match '^git\.ustc\.edu\.cn/[^/]+/[^/]+$') 'plan project uses the canonical school GitLab namespace/project form'
    Assert-Check (@($plan.uploadFiles).Count -eq 6) 'plan selects only three installers, manifest, checksum, and release notes'
    Assert-Check (@($plan.argumentVector) -contains '--use-package-registry') 'plan uses Generic Package Registry assets'
    Assert-Check (@($plan.argumentVector) -contains '--no-update') 'plan refuses to update an existing release'
    Assert-Check (-not (@($plan.argumentVector) -contains $planPath)) 'local release-plan.json is not a release upload asset'
    Assert-Check (-not $resultOutput.Contains('glab release create')) 'preparation does not execute or echo a glab command'

    Assert-Rejected {
        Invoke-GitLabReleasePrepare -WindowsPackageDirectory $success.WindowsRoot `
            -AndroidPackageDirectory $success.AndroidRoot -Revision40hex $success.Revision -OutputRoot $success.OutputRoot
    } 'external synthetic paths without the test-only allow switch'

    $publicText = $manifestText + $notesText + [IO.File]::ReadAllText((Join-Path $target 'SHA256SUMS.txt'))
    foreach ($localPath in @($success.WindowsRoot, $success.AndroidRoot, $success.OutputRoot, $script:WorkspaceRoot)) {
        Assert-Check (-not $publicText.Contains($localPath)) 'public manifest, notes, and checksums contain no local absolute path'
    }
    $combinedSums = @([IO.File]::ReadAllLines((Join-Path $target 'SHA256SUMS.txt')) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Assert-Check ($combinedSums.Count -eq 5) 'combined checksum file covers the three installers, manifest, and notes'

    $successHashes = @(Get-TreeFileRecords $target | ForEach-Object { $_.path + ':' + $_.sha256 })
    Assert-Rejected {
        Invoke-GitLabReleasePrepare -WindowsPackageDirectory $success.WindowsRoot `
            -AndroidPackageDirectory $success.AndroidRoot -Revision40hex $success.Revision `
            -OutputRoot $success.OutputRoot -AllowExternalSyntheticPaths
    } 'an existing combined output directory'
    Assert-Check ((@(Get-TreeFileRecords $target | ForEach-Object { $_.path + ':' + $_.sha256 }) -join ',') -ceq ($successHashes -join ',')) 'output collision leaves all files unchanged'

    $missingRoot = Join-Path $script:TestRoot 'missing-file'
    [void][IO.Directory]::CreateDirectory($missingRoot)
    $missing = New-SyntheticCandidates -ScenarioRoot $missingRoot -OmitX64
    Assert-Rejected {
        Invoke-GitLabReleasePrepare -WindowsPackageDirectory $missing.WindowsRoot `
            -AndroidPackageDirectory $missing.AndroidRoot -Revision40hex $missing.Revision `
            -OutputRoot $missing.OutputRoot -AllowExternalSyntheticPaths
    } 'a missing ABI APK'
    Assert-Check (-not (Test-Path -LiteralPath (Join-Path $missing.OutputRoot ("gitlab-1.0.0-$($missing.Revision.Substring(0, 8))")))) 'missing file creates no combined output'

    $wrongRevision = ('b' * 40)
    Assert-Rejected {
        Invoke-GitLabReleasePrepare -WindowsPackageDirectory $success.WindowsRoot `
            -AndroidPackageDirectory $success.AndroidRoot -Revision40hex $wrongRevision `
            -OutputRoot $success.OutputRoot -AllowExternalSyntheticPaths
    } 'a revision that differs from both candidates'

    $qaRoot = Join-Path $script:TestRoot 'qa-certificate'
    [void][IO.Directory]::CreateDirectory($qaRoot)
    $qa = New-SyntheticCandidates -ScenarioRoot $qaRoot -CertificateSha256 $script:KnownQaCertificateSha256
    Assert-Rejected {
        Invoke-GitLabReleasePrepare -WindowsPackageDirectory $qa.WindowsRoot `
            -AndroidPackageDirectory $qa.AndroidRoot -Revision40hex $qa.Revision `
            -OutputRoot $qa.OutputRoot -AllowExternalSyntheticPaths
    } 'the known QA certificate'

    $tamperedRoot = Join-Path $script:TestRoot 'tampered'
    [void][IO.Directory]::CreateDirectory($tamperedRoot)
    $tampered = New-SyntheticCandidates -ScenarioRoot $tamperedRoot
    [IO.File]::AppendAllText($tampered.AndroidArm64, 'tampered')
    Assert-Rejected {
        Invoke-GitLabReleasePrepare -WindowsPackageDirectory $tampered.WindowsRoot `
            -AndroidPackageDirectory $tampered.AndroidRoot -Revision40hex $tampered.Revision `
            -OutputRoot $tampered.OutputRoot -AllowExternalSyntheticPaths
    } 'a modified APK that no longer matches its candidate manifest'

    $privateRoot = Join-Path $script:TestRoot 'private-extra'
    [void][IO.Directory]::CreateDirectory($privateRoot)
    $privateExtra = New-SyntheticCandidates -ScenarioRoot $privateRoot
    [IO.File]::WriteAllText((Join-Path $privateExtra.AndroidRoot 'android-release.p12'), 'synthetic-private-material')
    Assert-Rejected {
        Invoke-GitLabReleasePrepare -WindowsPackageDirectory $privateExtra.WindowsRoot `
            -AndroidPackageDirectory $privateExtra.AndroidRoot -Revision40hex $privateExtra.Revision `
            -OutputRoot $privateExtra.OutputRoot -AllowExternalSyntheticPaths
    } 'an extra private signing file'

    $unknownRoot = Join-Path $script:TestRoot 'unknown-extra'
    [void][IO.Directory]::CreateDirectory($unknownRoot)
    $unknownExtra = New-SyntheticCandidates -ScenarioRoot $unknownRoot
    [IO.File]::WriteAllText((Join-Path $unknownExtra.WindowsRoot 'local-build.log'), 'synthetic log')
    Assert-Rejected {
        Invoke-GitLabReleasePrepare -WindowsPackageDirectory $unknownExtra.WindowsRoot `
            -AndroidPackageDirectory $unknownExtra.AndroidRoot -Revision40hex $unknownExtra.Revision `
            -OutputRoot $unknownExtra.OutputRoot -AllowExternalSyntheticPaths
    } 'an extra unknown build artifact'

    Assert-Rejected {
        Invoke-GitLabReleasePrepare -WindowsPackageDirectory $success.WindowsRoot `
            -AndroidPackageDirectory $success.AndroidRoot -Revision40hex $success.Revision `
            -Repository 'gitlab.com/example/assistant' -OutputRoot $success.OutputRoot -AllowExternalSyntheticPaths
    } 'a repository outside the allowed GitLab host'

    $script:JunctionPath = Join-Path $script:TestRoot 'junction'
    [void](New-Item -ItemType Junction -Path $script:JunctionPath -Target $success.PublicRoot -ErrorAction Stop)
    $script:JunctionCreated = $true
    $junctionWindows = Join-Path $script:JunctionPath (Split-Path -Leaf $success.WindowsRoot)
    Assert-Rejected {
        Invoke-GitLabReleasePrepare -WindowsPackageDirectory $junctionWindows `
            -AndroidPackageDirectory $success.AndroidRoot -Revision40hex $success.Revision `
            -OutputRoot $success.OutputRoot -AllowExternalSyntheticPaths
    } 'a candidate directory reached through a junction'

} finally {
    if ($script:JunctionCreated -and $script:JunctionPath) {
        $junctionItem = Get-Item -LiteralPath $script:JunctionPath -Force -ErrorAction SilentlyContinue
        if ($junctionItem) {
            if (-not [bool]($junctionItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Synthetic cleanup stopped because the junction path is no longer a reparse point.'
            }
            $resolvedTarget = [IO.Path]::GetFullPath([string]$junctionItem.Target)
            if ($resolvedTarget -ine [IO.Path]::GetFullPath($success.PublicRoot) -or
                -not $resolvedTarget.StartsWith($script:TestRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Synthetic cleanup stopped because the junction target left the owned test root.'
            }
            Remove-Item -LiteralPath $script:JunctionPath -Force
        }
    }
    if ($script:RootCreated -and [IO.Directory]::Exists($script:TestRoot)) {
        $resolvedRoot = [IO.Path]::GetFullPath($script:TestRoot)
        $rootItem = Get-Item -LiteralPath $resolvedRoot -Force -ErrorAction Stop
        if ($resolvedRoot -cne $script:TestRoot -or $resolvedRoot -eq $script:DriveRoot -or
            -not $resolvedRoot.StartsWith($script:DriveRoot, [StringComparison]::OrdinalIgnoreCase) -or
            [bool]($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Synthetic cleanup stopped because the owned E-drive root failed its boundary checks.'
        }
        foreach ($item in Get-ChildItem -LiteralPath $resolvedRoot -Force -Recurse) {
            $itemPath = [IO.Path]::GetFullPath($item.FullName)
            if (-not $itemPath.StartsWith($resolvedRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
                [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Synthetic cleanup stopped because an unexpected path or reparse point is below its owned root.'
            }
        }
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
        if (Test-Path -LiteralPath $resolvedRoot) { throw 'Synthetic cleanup did not remove its owned E-drive root.' }
        Assert-Check $true 'the owned GUID-scoped E-drive test root is removed'
    }
}

Write-Output "GitLab release plan synthetic checks passed: $script:checks checks."
