#requires -Version 7.0
[CmdletBinding()]
param([string]$JavaHome)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:checks = 0
$initializer = Join-Path $PSScriptRoot 'initialize-android-signing.ps1'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRootName = 'codex-android-signing-test-' + [guid]::NewGuid().ToString('N')
$testRoot = [IO.Path]::GetFullPath((Join-Path 'E:\' $testRootName))
$driveRoot = [IO.Path]::GetPathRoot($testRoot)
$rootWasCreated = $false
$junctionPath = $null
$junctionTarget = $null
$junctionWasCreated = $false
$passwordEnvironmentName = 'USTC_ANDROID_SIGNING_TEST_' + [guid]::NewGuid().ToString('N')
$syntheticMarkerName = 'USTC_ANDROID_SIGNING_SYNTHETIC_TEST'
$toolEnvironmentName = 'USTC_ANDROID_SIGNING_SETUP_KEYTOOL_PASSWORD'
$oldPasswordEnvironment = [Environment]::GetEnvironmentVariable($passwordEnvironmentName, [EnvironmentVariableTarget]::Process)
$oldSyntheticMarker = [Environment]::GetEnvironmentVariable($syntheticMarkerName, [EnvironmentVariableTarget]::Process)
$oldToolEnvironment = [Environment]::GetEnvironmentVariable($toolEnvironmentName, [EnvironmentVariableTarget]::Process)
$syntheticPassword = $null
$randomBytes = [byte[]]::new(24)
$savedJavaHome = $null
$readHostFunctionPath = 'Function:\global:Read-Host'
$readHostMockWasInstalled = $false

function Assert-Check([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:checks++
}

function Assert-Rejected([scriptblock]$Action, [string]$Message) {
    try {
        & $Action | Out-Null
    } catch {
        $script:checks++
        return
    }
    throw "Assertion failed: expected rejection for $Message."
}

function Get-ArtifactDigest([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-SecureStringEqualsText([Security.SecureString]$Value, [string]$Expected) {
    $pointer = [IntPtr]::Zero
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
        $length = $Value.Length
        if ($length -ne $Expected.Length) { return $false }
        for ($index = 0; $index -lt $length; $index++) {
            $codeUnit = [Runtime.InteropServices.Marshal]::ReadInt16($pointer, $index * 2)
            if ($codeUnit -ne [int][char]$Expected[$index]) { return $false }
        }
        return $true
    } finally {
        if ($pointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        }
    }
}

function Resolve-TestJavaHome([string]$ConfiguredHome) {
    if (-not [string]::IsNullOrWhiteSpace($ConfiguredHome)) {
        return [IO.Path]::GetFullPath($ConfiguredHome)
    }
    $environmentHome = [Environment]::GetEnvironmentVariable('JAVA_HOME', [EnvironmentVariableTarget]::Process)
    if (-not [string]::IsNullOrWhiteSpace($environmentHome)) {
        $candidateHome = ($environmentHome -replace '\p{Cf}', '').Trim().Trim('"')
        if (Test-Path -LiteralPath (Join-Path $candidateHome 'bin/keytool.exe') -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidateHome)
        }
    }
    $command = Get-Command keytool.exe, keytool -ErrorAction Stop |
        Where-Object { $_.CommandType -eq 'Application' -and $_.Source } |
        Select-Object -First 1
    $binDirectory = Split-Path -Parent $command.Source
    return Split-Path -Parent $binDirectory
}

try {
    if (-not $IsWindows) { throw 'Signing setup checks require Windows PowerShell 7.' }
    if (Test-Path -LiteralPath $readHostFunctionPath) {
        throw 'The synthetic prompt check requires an uncustomized global Read-Host function name.'
    }
    if ($driveRoot -ne 'E:\' -or $testRoot -eq $driveRoot -or
        -not $testRoot.StartsWith($driveRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The synthetic test root failed its E-drive absolute-path boundary check.'
    }
    if (([IO.DriveInfo]::new($driveRoot)).DriveType -ne [IO.DriveType]::Fixed) {
        throw 'The E drive is not a local fixed drive for the synthetic test.'
    }
    if (Test-Path -LiteralPath $testRoot) {
        throw 'The GUID-scoped synthetic root already exists; refusing to reuse it.'
    }
    if (-not (Test-Path -LiteralPath $initializer -PathType Leaf)) {
        throw 'The signing initializer script is missing.'
    }
    $savedJavaHome = Resolve-TestJavaHome $JavaHome
    $keytoolPath = Join-Path $savedJavaHome 'bin/keytool.exe'
    if (-not (Test-Path -LiteralPath $keytoolPath -PathType Leaf)) {
        throw 'The selected JavaHome does not contain keytool.exe.'
    }

    [Security.Cryptography.RandomNumberGenerator]::Fill($randomBytes)
    $syntheticPassword = 'SYNTHETIC-' + [Convert]::ToHexString($randomBytes)
    [Environment]::SetEnvironmentVariable(
        $passwordEnvironmentName,
        $syntheticPassword,
        [EnvironmentVariableTarget]::Process
    )
    [Environment]::SetEnvironmentVariable($syntheticMarkerName, '1', [EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable($toolEnvironmentName, 'restore-sentinel', [EnvironmentVariableTarget]::Process)

    [void][IO.Directory]::CreateDirectory($testRoot)
    $rootWasCreated = $true
    $parentAclSddlBefore = (Get-Acl -LiteralPath $testRoot).Sddl

    [Environment]::SetEnvironmentVariable($passwordEnvironmentName, 'too-short', [EnvironmentVariableTarget]::Process)
    $shortPasswordTarget = Join-Path $testRoot 'short-password-signing'
    Assert-Rejected {
        & $initializer -SigningDirectory $shortPasswordTarget -JavaHome $savedJavaHome `
            -PasswordEnvironmentVariableName $passwordEnvironmentName
    } 'a password shorter than 12 characters'
    Assert-Check (-not (Test-Path -LiteralPath $shortPasswordTarget)) 'short-password rejection creates no signing directory'

    $invalidPasswordCases = @(
        @{ Name = 'non-ASCII'; Value = 'SYNTHETIC-测abc' },
        @{ Name = 'control-character'; Value = ('SYNTHETIC-12' + [char]7) },
        @{ Name = 'all-spaces'; Value = '            ' }
    )
    foreach ($invalidCase in $invalidPasswordCases) {
        [Environment]::SetEnvironmentVariable($passwordEnvironmentName, $invalidCase.Value, [EnvironmentVariableTarget]::Process)
        $invalidTarget = Join-Path $testRoot ('invalid-password-' + $invalidCase.Name)
        Assert-Rejected {
            & $initializer -SigningDirectory $invalidTarget -JavaHome $savedJavaHome `
                -PasswordEnvironmentVariableName $passwordEnvironmentName
        } "a $($invalidCase.Name) password"
        Assert-Check (-not (Test-Path -LiteralPath $invalidTarget)) "$($invalidCase.Name) rejection creates no signing directory"
    }
    [Environment]::SetEnvironmentVariable($passwordEnvironmentName, $syntheticPassword, [EnvironmentVariableTarget]::Process)

    $sourceTreeTarget = Join-Path $repositoryRoot ('private/.signing-test-' + [guid]::NewGuid().ToString('N'))
    Assert-Rejected {
        & $initializer -SigningDirectory $sourceTreeTarget -JavaHome $savedJavaHome `
            -PasswordEnvironmentVariableName $passwordEnvironmentName
    } 'a path inside the Git working tree'
    Assert-Check (-not (Test-Path -LiteralPath $sourceTreeTarget)) 'source-tree rejection creates no target'

    $uncTarget = '\\127.0.0.1\C$\android-signing-test-' + [guid]::NewGuid().ToString('N')
    Assert-Rejected {
        & $initializer -SigningDirectory $uncTarget -JavaHome $savedJavaHome `
            -PasswordEnvironmentVariableName $passwordEnvironmentName
    } 'a UNC path'

    $existingDirectory = Join-Path $testRoot 'existing-directory'
    [void][IO.Directory]::CreateDirectory($existingDirectory)
    $existingMarker = Join-Path $existingDirectory 'marker.txt'
    [IO.File]::WriteAllText($existingMarker, 'synthetic-existing-marker', [Text.UTF8Encoding]::new($false))
    $existingMarkerDigest = Get-ArtifactDigest $existingMarker
    Assert-Rejected {
        & $initializer -SigningDirectory $existingDirectory -JavaHome $savedJavaHome `
            -PasswordEnvironmentVariableName $passwordEnvironmentName
    } 'an existing directory'
    Assert-Check ((Get-ArtifactDigest $existingMarker) -ceq $existingMarkerDigest) 'existing directory contents stay unchanged'

    $existingFile = Join-Path $testRoot 'existing-file'
    [IO.File]::WriteAllText($existingFile, 'synthetic-existing-file', [Text.UTF8Encoding]::new($false))
    $existingFileDigest = Get-ArtifactDigest $existingFile
    Assert-Rejected {
        & $initializer -SigningDirectory $existingFile -JavaHome $savedJavaHome `
            -PasswordEnvironmentVariableName $passwordEnvironmentName
    } 'an existing file'
    Assert-Check ((Get-ArtifactDigest $existingFile) -ceq $existingFileDigest) 'existing file stays unchanged'

    $junctionTarget = Join-Path $testRoot 'junction-target'
    $junctionPath = Join-Path $testRoot 'junction'
    [void][IO.Directory]::CreateDirectory($junctionTarget)
    [void](New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget -ErrorAction Stop)
    $junctionWasCreated = $true
    $linkedTargetPath = Join-Path $junctionPath 'nested-signing'
    Assert-Rejected {
        & $initializer -SigningDirectory $linkedTargetPath -JavaHome $savedJavaHome `
            -PasswordEnvironmentVariableName $passwordEnvironmentName
    } 'a reparse-point parent'
    Assert-Check (-not (Test-Path -LiteralPath $linkedTargetPath)) 'reparse rejection creates no linked target'

    $signingDirectory = Join-Path $testRoot 'fresh-signing'
    $setupOutput = (& $initializer -SigningDirectory $signingDirectory `
        -JavaHome $savedJavaHome -PasswordEnvironmentVariableName $passwordEnvironmentName 2>&1 | Out-String)
    Assert-Check (-not $setupOutput.Contains($syntheticPassword)) 'initializer output has no clear synthetic password'
    Assert-Check (
        [Environment]::GetEnvironmentVariable($passwordEnvironmentName, [EnvironmentVariableTarget]::Process) -ceq $syntheticPassword
    ) 'synthetic input environment is restored after initialization'
    Assert-Check (
        [Environment]::GetEnvironmentVariable($toolEnvironmentName, [EnvironmentVariableTarget]::Process) -ceq 'restore-sentinel'
    ) 'temporary keytool environment is restored after initialization'

    $configurationPath = Join-Path $signingDirectory 'signing.json'
    $keystorePath = Join-Path $signingDirectory 'android-release.p12'
    $certificatePath = Join-Path $signingDirectory 'release.cer'
    foreach ($artifact in @($configurationPath, $keystorePath, $certificatePath)) {
        Assert-Check (Test-Path -LiteralPath $artifact -PathType Leaf) "created required artifact $([IO.Path]::GetFileName($artifact))"
    }
    Assert-Check (-not (Test-Path -LiteralPath (Join-Path $signingDirectory '.initializing.lock'))) 'initialization lock is removed after success'
    Assert-Check (@(Get-ChildItem -LiteralPath $signingDirectory -Force).Count -eq 3) 'signing directory contains only the three expected files'

    $signingAcl = Get-Acl -LiteralPath $signingDirectory
    Assert-Check ($signingAcl.AreAccessRulesProtected) 'new signing leaf does not inherit parent ACLs'
    $allowedSids = @(
        [Security.Principal.WindowsIdentity]::GetCurrent().User.Value,
        'S-1-5-18',
        'S-1-5-32-544'
    ) | Select-Object -Unique
    $observedSids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($rule in $signingAcl.Access) {
        $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        Assert-Check ($sid -in $allowedSids) 'signing leaf ACL grants no unexpected SID'
        Assert-Check ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow) 'signing leaf ACL has no deny rules'
        [void]$observedSids.Add($sid)
    }
    foreach ($sid in $allowedSids) {
        Assert-Check ($observedSids.Contains($sid)) "signing leaf ACL includes required SID $sid"
    }
    Assert-Check ((Get-Acl -LiteralPath $testRoot).Sddl -ceq $parentAclSddlBefore) 'signing initialization leaves the parent ACL unchanged'

    $configurationText = [IO.File]::ReadAllText($configurationPath)
    Assert-Check (-not $configurationText.Contains($syntheticPassword)) 'signing.json has no clear synthetic password'
    $configuration = $configurationText | ConvertFrom-Json
    Assert-Check ($configuration.kind -ceq 'ustc-android-release-signing-v1') 'configuration kind is versioned'
    Assert-Check ($configuration.synthetic -ceq $true) 'explicit synthetic environment input is marked synthetic'
    Assert-Check ($configuration.keyAlias -ceq 'ustc-assistant') 'configuration uses the fixed key alias'
    Assert-Check ([IO.Path]::IsPathFullyQualified($configuration.keystoreFile)) 'keystore path in config is absolute'
    Assert-Check ([IO.Path]::IsPathFullyQualified($configuration.publicCertificateFile)) 'certificate path in config is absolute'

    $protectedPassword = ConvertTo-SecureString -String $configuration.passwordProtected
    try {
        Assert-Check (Test-SecureStringEqualsText $protectedPassword $syntheticPassword) 'CurrentUser DPAPI unwrap matches the synthetic input'
    } finally {
        $protectedPassword.Dispose()
    }

    $certificateDigest = Get-ArtifactDigest $certificatePath
    Assert-Check ($configuration.certificateSha256 -ceq $certificateDigest) 'certificate digest matches the DER certificate file'
    Assert-Check ($configuration.certificateSha256 -cmatch '^[0-9a-f]{64}$') 'certificate digest is lowercase SHA-256'
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new([IO.File]::ReadAllBytes($certificatePath))
    try {
        Assert-Check ($certificate.Subject -ceq 'CN=USTC Assistant') 'certificate subject does not claim school affiliation'
        $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($certificate)
        try {
            Assert-Check ($rsa.KeySize -eq 3072) 'certificate public key is RSA 3072'
        } finally {
            if ($rsa) { $rsa.Dispose() }
        }
        Assert-Check ($certificate.SignatureAlgorithm.Value -ceq '1.2.840.113549.1.1.11') 'certificate signature algorithm is SHA256withRSA'
        Assert-Check ($certificate.NotAfter -gt (Get-Date).AddDays(9995)) 'certificate validity is approximately 10000 days'
    } finally {
        $certificate.Dispose()
    }

    $keytoolOutput = (& $keytoolPath -list -v -storetype PKCS12 -keystore $keystorePath `
        -storepass:env $passwordEnvironmentName 2>&1 | Out-String)
    Assert-Check ($LASTEXITCODE -eq 0) 'keytool can reopen the PKCS12 keystore with the synthetic password'
    Assert-Check ($keytoolOutput.Contains('ustc-assistant')) 'keystore has the expected alias'
    Assert-Check ($keytoolOutput -match 'PrivateKeyEntry') 'keystore contains a private key entry'
    Assert-Check (-not $keytoolOutput.Contains($syntheticPassword)) 'keytool round-trip output has no clear synthetic password'

    $promptTestState = [hashtable]::Synchronized(@{ Password = $syntheticPassword; ReadCount = 0 })
    $readHostMock = {
        param([string]$Prompt, [switch]$AsSecureString)
        if (-not $AsSecureString) { throw 'The synthetic prompt mock requires SecureString mode.' }
        $promptTestState.ReadCount++
        return ConvertTo-SecureString -String $promptTestState.Password -AsPlainText -Force
    }.GetNewClosure()
    Set-Item -Path $readHostFunctionPath -Value $readHostMock -Force
    $readHostMockWasInstalled = $true

    $promptSigningDirectory = Join-Path $testRoot 'prompt-signing'
    $promptOutput = (& $initializer -SigningDirectory $promptSigningDirectory -JavaHome $savedJavaHome 2>&1 | Out-String)
    Assert-Check ($promptTestState.ReadCount -eq 2) 'the normal password path reads two SecureString prompts'
    Assert-Check (-not $promptOutput.Contains($syntheticPassword)) 'normal-path initializer output has no clear password'
    $promptConfigurationPath = Join-Path $promptSigningDirectory 'signing.json'
    $promptConfigurationText = [IO.File]::ReadAllText($promptConfigurationPath)
    Assert-Check (-not $promptConfigurationText.Contains($syntheticPassword)) 'normal-path configuration has no clear password'
    $promptConfiguration = $promptConfigurationText | ConvertFrom-Json
    Assert-Check ($promptConfiguration.synthetic -ceq $false) 'Read-Host password input is marked non-synthetic'
    Remove-Item -LiteralPath $readHostFunctionPath -ErrorAction Stop
    $readHostMockWasInstalled = $false

    $artifactPaths = @($configurationPath, $keystorePath, $certificatePath)
    $promptArtifactPaths = @($promptConfigurationPath, (Join-Path $promptSigningDirectory 'android-release.p12'), (Join-Path $promptSigningDirectory 'release.cer'))
    $beforeRepeat = @($artifactPaths | ForEach-Object { Get-ArtifactDigest $_ })
    $promptBeforeRepeat = @($promptArtifactPaths | ForEach-Object { Get-ArtifactDigest $_ })
    Assert-Rejected {
        & $initializer -SigningDirectory $signingDirectory -JavaHome $savedJavaHome `
            -PasswordEnvironmentVariableName $passwordEnvironmentName
    } 'repeated initialization of the existing signing directory'
    $afterRepeat = @($artifactPaths | ForEach-Object { Get-ArtifactDigest $_ })
    Assert-Check (($beforeRepeat -join ',') -ceq ($afterRepeat -join ',')) 'repeated initialization does not change any artifact'
    $promptAfterRepeat = @($promptArtifactPaths | ForEach-Object { Get-ArtifactDigest $_ })
    Assert-Check (($promptBeforeRepeat -join ',') -ceq ($promptAfterRepeat -join ',')) 'repeated env-mode initialization does not change normal-path artifacts'

} finally {
    if ($readHostMockWasInstalled -and (Test-Path -LiteralPath $readHostFunctionPath)) {
        Remove-Item -LiteralPath $readHostFunctionPath -Force
    }
    [Environment]::SetEnvironmentVariable($passwordEnvironmentName, $oldPasswordEnvironment, [EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable($syntheticMarkerName, $oldSyntheticMarker, [EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable($toolEnvironmentName, $oldToolEnvironment, [EnvironmentVariableTarget]::Process)
    [Security.Cryptography.CryptographicOperations]::ZeroMemory($randomBytes)
    $syntheticPassword = $null

    if ($junctionWasCreated -and $junctionPath) {
        $junctionItem = Get-Item -LiteralPath $junctionPath -Force -ErrorAction SilentlyContinue
        if ($junctionItem) {
            if (-not [bool]($junctionItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Synthetic cleanup stopped because the junction path is no longer a reparse point.'
            }
            $resolvedJunctionTarget = [IO.Path]::GetFullPath([string]$junctionItem.Target)
            $expectedJunctionTarget = [IO.Path]::GetFullPath($junctionTarget)
            if ($resolvedJunctionTarget -ine $expectedJunctionTarget -or
                -not $resolvedJunctionTarget.StartsWith($testRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Synthetic cleanup stopped because the junction target left the test root.'
            }
            Remove-Item -LiteralPath $junctionPath -Force
        }
    }

    if ($rootWasCreated -and [IO.Directory]::Exists($testRoot)) {
        $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
        $rootItem = Get-Item -LiteralPath $resolvedTestRoot -Force -ErrorAction Stop
        if ($resolvedTestRoot -cne $testRoot -or $resolvedTestRoot -eq $driveRoot -or
            -not $resolvedTestRoot.StartsWith($driveRoot, [StringComparison]::OrdinalIgnoreCase) -or
            [bool]($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Synthetic cleanup stopped because the owned E-drive test root failed its boundary checks.'
        }
        foreach ($item in Get-ChildItem -LiteralPath $resolvedTestRoot -Force -Recurse) {
            $itemPath = [IO.Path]::GetFullPath($item.FullName)
            if (-not $itemPath.StartsWith($resolvedTestRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
                [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Synthetic cleanup stopped because an unexpected path or reparse point is present below the owned test root.'
            }
        }
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
        if (Test-Path -LiteralPath $resolvedTestRoot) {
            throw 'Synthetic cleanup did not remove the owned E-drive test root.'
        }
        Assert-Check $true 'the owned GUID-scoped E-drive test root is removed'
    }
}

Write-Output "Android signing initializer synthetic checks passed: $script:checks checks."
Write-Output "Synthetic certificate SHA-256: $certificateDigest"
