#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$SigningDirectory,
    [string]$JavaHome,
    [string]$PasswordEnvironmentVariableName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CanonicalLocalDirectory([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -ne $Path.Trim()) {
        throw 'SigningDirectory must be an absolute local directory path.'
    }
    if ($Path.StartsWith('\\') -or $Path.StartsWith('//') -or
        $Path.StartsWith('\\?\') -or $Path.StartsWith('\\.\')) {
        throw 'UNC and device paths are not accepted for signing material.'
    }
    if (-not [IO.Path]::IsPathFullyQualified($Path)) {
        throw 'SigningDirectory must be an absolute local directory path.'
    }

    $fullPath = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($fullPath)
    if ($root -notmatch '^[A-Za-z]:\\$' -or $fullPath.TrimEnd('\', '/') -eq $root.TrimEnd('\', '/')) {
        throw 'SigningDirectory must be below a local drive root.'
    }
    try {
        $drive = [IO.DriveInfo]::new($root)
    } catch {
        throw 'SigningDirectory must use an available local drive.'
    }
    if ($drive.DriveType -ne [IO.DriveType]::Fixed) {
        throw 'SigningDirectory must use a local fixed drive.'
    }
    return $fullPath.TrimEnd('\', '/')
}

function Assert-SafePathAncestors([string]$Path) {
    $fullPath = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($fullPath)
    $relative = $fullPath.Substring($root.Length)
    $parts = @($relative.Split([char[]]@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries))
    $cursor = $root.TrimEnd('\') + '\'

    foreach ($part in $parts) {
        $cursor = [IO.Path]::Combine($cursor, $part)
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) { continue }
        if ([bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'SigningDirectory contains a reparse point.'
        }
        if ($cursor -ne $fullPath -and -not $item.PSIsContainer) {
            throw 'A SigningDirectory parent component is not a directory.'
        }
        $gitMarker = [IO.Path]::Combine($cursor, '.git')
        if (Test-Path -LiteralPath $gitMarker) {
            throw 'SigningDirectory must be outside every Git working tree.'
        }
    }
}

function Assert-TargetDoesNotExist([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -ne $item) {
        throw 'SigningDirectory already exists; initialization never overwrites an existing directory or file.'
    }
}

function Set-NewSigningDirectoryAcl([string]$Path) {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().User
    if ($null -eq $currentUser) { throw 'Could not resolve the current Windows user SID.' }
    $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $administratorsSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $allowedSids = @($currentUser.Value, $systemSid.Value, $administratorsSid.Value)

    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $rights = [Security.AccessControl.FileSystemRights]::FullControl
    foreach ($sid in @($currentUser, $systemSid, $administratorsSid)) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid,
            $rights,
            $inheritance,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl

    $verifiedAcl = Get-Acl -LiteralPath $Path
    $observedSids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($rule in $verifiedAcl.Access) {
        $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        if ($sid -notin $allowedSids -or $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) {
            throw 'The new SigningDirectory ACL contains an unexpected access rule.'
        }
        [void]$observedSids.Add($sid)
    }
    foreach ($sid in $allowedSids) {
        if (-not $observedSids.Contains($sid)) { throw 'The new SigningDirectory ACL could not be verified.' }
    }
    if (-not $verifiedAcl.AreAccessRulesProtected) {
        throw 'The new SigningDirectory ACL still inherits parent access rules.'
    }
}

function Resolve-Keytool([string]$ConfiguredJavaHome) {
    if (-not [string]::IsNullOrWhiteSpace($ConfiguredJavaHome)) {
        $resolvedJdkRoot = [IO.Path]::GetFullPath($ConfiguredJavaHome.Trim().Trim('"'))
        $candidate = [IO.Path]::Combine($resolvedJdkRoot, 'bin', 'keytool.exe')
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw 'JavaHome does not contain bin\keytool.exe.'
        }
        return [IO.Path]::GetFullPath($candidate)
    }

    $environmentHome = [Environment]::GetEnvironmentVariable('JAVA_HOME', [EnvironmentVariableTarget]::Process)
    if (-not [string]::IsNullOrWhiteSpace($environmentHome)) {
        # Ignore accidental Unicode direction-format marks sometimes copied into JAVA_HOME.
        $environmentHome = ($environmentHome -replace '\p{Cf}', '').Trim().Trim('"')
        $candidate = [IO.Path]::Combine($environmentHome, 'bin', 'keytool.exe')
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }

    $command = Get-Command keytool.exe, keytool -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandType -eq 'Application' -and $_.Source } |
        Select-Object -First 1
    if ($null -eq $command) { throw 'JDK keytool.exe was not found in JAVA_HOME or PATH.' }
    return [IO.Path]::GetFullPath($command.Source)
}

function Assert-PasswordPolicy([Security.SecureString]$Value) {
    if ($null -eq $Value -or $Value.Length -lt 12) {
        throw '密码至少需要 12 个字符，仅支持可打印的英文、数字和符号。'
    }

    $pointer = [IntPtr]::Zero
    $containsNonSpace = $false
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
        for ($index = 0; $index -lt $Value.Length; $index++) {
            $codeUnit = [Runtime.InteropServices.Marshal]::ReadInt16($pointer, $index * 2)
            if ($codeUnit -lt 0x20 -or $codeUnit -gt 0x7e) {
                throw '密码仅支持可打印的英文、数字和符号，不能包含中文或控制字符。'
            }
            if ($codeUnit -ne 0x20) { $containsNonSpace = $true }
        }
    } finally {
        if ($pointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        }
    }
    if (-not $containsNonSpace) { throw '密码不能全部由空格组成。' }
}

function Test-SecureStringsEqual([Security.SecureString]$First, [Security.SecureString]$Second) {
    $firstPointer = [IntPtr]::Zero
    $secondPointer = [IntPtr]::Zero
    try {
        $firstPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($First)
        $secondPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Second)
        $firstLength = $First.Length
        $secondLength = $Second.Length
        if ($firstLength -ne $secondLength) { return $false }
        for ($index = 0; $index -lt $firstLength; $index++) {
            $firstCodeUnit = [Runtime.InteropServices.Marshal]::ReadInt16($firstPointer, $index * 2)
            $secondCodeUnit = [Runtime.InteropServices.Marshal]::ReadInt16($secondPointer, $index * 2)
            if ($firstCodeUnit -ne $secondCodeUnit) { return $false }
        }
        return $true
    } finally {
        if ($firstPointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($firstPointer)
        }
        if ($secondPointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secondPointer)
        }
    }
}

function Convert-SecureStringToTemporaryText([Security.SecureString]$Value) {
    $pointer = [IntPtr]::Zero
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    } finally {
        if ($pointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        }
    }
}

function Invoke-Keytool([string]$Executable, [string[]]$Arguments, [string]$Operation) {
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $null = & $Executable @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } catch {
        throw "keytool $Operation failed; details were suppressed."
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    if ($exitCode -ne 0) { throw "keytool $Operation failed; details were suppressed." }
}

if (-not $IsWindows) { throw 'Android signing initialization requires Windows PowerShell 7.' }

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($SigningDirectory)) {
    $repositoryParent = Split-Path -Parent $repositoryRoot
    $SigningDirectory = Join-Path $repositoryParent 'private\android-signing'
}
$signingPath = Get-CanonicalLocalDirectory $SigningDirectory
Assert-SafePathAncestors $signingPath
Assert-TargetDoesNotExist $signingPath

$keytoolPath = Resolve-Keytool $JavaHome

$useEnvironmentInput = -not [string]::IsNullOrWhiteSpace($PasswordEnvironmentVariableName)
$passwordSecure = $null
$confirmationSecure = $null
$providedEnvironmentValue = $null
$providedEnvironmentValueSaved = $null
$providedEnvironmentWasCleared = $false
$toolEnvironmentName = 'USTC_ANDROID_SIGNING_SETUP_KEYTOOL_PASSWORD'
$toolEnvironmentSaved = [Environment]::GetEnvironmentVariable($toolEnvironmentName, [EnvironmentVariableTarget]::Process)
$toolEnvironmentWasChanged = $false
$temporaryPasswordText = $null
$stagingPath = $null
$stagingCreated = $false
$movedToSigningLeaf = $false
$lockPath = $null
$lockStream = $null
$lockCreated = $false
$temporaryConfigurationPath = $null
$temporaryConfigurationCreated = $false

try {
    if ($useEnvironmentInput) {
        if ($PasswordEnvironmentVariableName -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw 'PasswordEnvironmentVariableName must be a simple environment variable name.'
        }
        if ($PasswordEnvironmentVariableName -ieq $toolEnvironmentName) {
            throw 'The input and keytool environment variable names must be different.'
        }
        $syntheticMarker = [Environment]::GetEnvironmentVariable('USTC_ANDROID_SIGNING_SYNTHETIC_TEST', [EnvironmentVariableTarget]::Process)
        if ($syntheticMarker -cne '1') {
            throw 'Environment password input is allowed only for an explicitly marked synthetic test; use secure prompts for real initialization.'
        }
        $providedEnvironmentValue = [Environment]::GetEnvironmentVariable(
            $PasswordEnvironmentVariableName,
            [EnvironmentVariableTarget]::Process
        )
        if ([string]::IsNullOrEmpty($providedEnvironmentValue)) {
            throw 'The requested password environment variable is empty or unavailable.'
        }
        $providedEnvironmentValueSaved = [Environment]::GetEnvironmentVariable(
            $PasswordEnvironmentVariableName,
            [EnvironmentVariableTarget]::Process
        )
        $passwordSecure = ConvertTo-SecureString -String $providedEnvironmentValue -AsPlainText -Force
        $providedEnvironmentValue = $null
        [Environment]::SetEnvironmentVariable(
            $PasswordEnvironmentVariableName,
            $null,
            [EnvironmentVariableTarget]::Process
        )
        $providedEnvironmentWasCleared = $true
    } else {
        $passwordSecure = Read-Host '输入 Android 发布密钥库密码（至少 12 个字符）' -AsSecureString
        $confirmationSecure = Read-Host '再次输入以确认' -AsSecureString
        if ($null -eq $passwordSecure -or $null -eq $confirmationSecure -or
            $passwordSecure.Length -lt 12) {
            throw '密码至少需要 12 个字符，仅支持可打印的英文、数字和符号。'
        }
        if (-not (Test-SecureStringsEqual $passwordSecure $confirmationSecure)) {
            throw '两次输入的密码不一致。'
        }
    }
    Assert-PasswordPolicy $passwordSecure

    $parentPath = Split-Path -Parent $signingPath
    [void][IO.Directory]::CreateDirectory($parentPath)
    Assert-SafePathAncestors $signingPath
    Assert-TargetDoesNotExist $signingPath

    $parentItem = Get-Item -LiteralPath $parentPath -Force -ErrorAction Stop
    if (-not $parentItem.PSIsContainer -or [bool]($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'The signing parent must be a normal local directory.'
    }
    $stagingPath = Join-Path $parentPath ('.android-signing-init-' + [guid]::NewGuid().ToString('N'))
    Assert-TargetDoesNotExist $stagingPath
    [void](New-Item -ItemType Directory -Path $stagingPath -ErrorAction Stop)
    $stagingCreated = $true
    Set-NewSigningDirectoryAcl $stagingPath

    # Atomic same-volume move claims the final name without touching an existing path.
    [IO.Directory]::Move($stagingPath, $signingPath)
    $stagingCreated = $false
    $movedToSigningLeaf = $true
    Assert-SafePathAncestors $signingPath

    $lockPath = Join-Path $signingPath '.initializing.lock'
    $lockStream = [IO.File]::Open(
        $lockPath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None
    )
    $lockCreated = $true

    $keystorePath = Join-Path $signingPath 'android-release.p12'
    $certificatePath = Join-Path $signingPath 'release.cer'
    $configurationPath = Join-Path $signingPath 'signing.json'
    foreach ($outputPath in @($keystorePath, $certificatePath, $configurationPath)) {
        if ((Test-Path -LiteralPath $outputPath) -or
            $null -ne (Get-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue)) {
            throw 'A signing output already exists; refusing to overwrite it.'
        }
    }

    $temporaryPasswordText = Convert-SecureStringToTemporaryText $passwordSecure
    [Environment]::SetEnvironmentVariable(
        $toolEnvironmentName,
        $temporaryPasswordText,
        [EnvironmentVariableTarget]::Process
    )
    $toolEnvironmentWasChanged = $true
    $genArguments = @(
        '-genkeypair', '-noprompt',
        '-alias', 'ustc-assistant',
        '-keyalg', 'RSA', '-keysize', '3072',
        '-sigalg', 'SHA256withRSA',
        '-validity', '10000',
        '-dname', 'CN=USTC Assistant',
        '-storetype', 'PKCS12',
        '-keystore', $keystorePath,
        '-storepass:env', $toolEnvironmentName,
        '-keypass:env', $toolEnvironmentName
    )
    Invoke-Keytool $keytoolPath $genArguments 'key generation'
    if (-not (Test-Path -LiteralPath $keystorePath -PathType Leaf) -or
        (Get-Item -LiteralPath $keystorePath).Length -le 0) {
        throw 'keytool did not create the expected keystore.'
    }

    $exportArguments = @(
        '-exportcert',
        '-alias', 'ustc-assistant',
        '-storetype', 'PKCS12',
        '-keystore', $keystorePath,
        '-storepass:env', $toolEnvironmentName,
        '-file', $certificatePath
    )
    Invoke-Keytool $keytoolPath $exportArguments 'public certificate export'
    if (-not (Test-Path -LiteralPath $certificatePath -PathType Leaf) -or
        (Get-Item -LiteralPath $certificatePath).Length -le 0) {
        throw 'keytool did not create the expected public certificate.'
    }

    $certificateSha256 = (Get-FileHash -LiteralPath $certificatePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($certificateSha256 -notmatch '^[0-9a-f]{64}$') {
        throw 'The public certificate digest could not be verified.'
    }
    $protectedPassword = ConvertFrom-SecureString -SecureString $passwordSecure
    if ([string]::IsNullOrWhiteSpace($protectedPassword)) {
        throw 'CurrentUser DPAPI protection returned an empty value.'
    }

    $configuration = [ordered]@{
        kind = 'ustc-android-release-signing-v1'
        synthetic = [bool]$useEnvironmentInput
        keystoreFile = [IO.Path]::GetFullPath($keystorePath)
        keyAlias = 'ustc-assistant'
        passwordProtected = $protectedPassword
        certificateSha256 = $certificateSha256
        publicCertificateFile = [IO.Path]::GetFullPath($certificatePath)
        createdUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
    }
    $json = $configuration | ConvertTo-Json -Depth 4

    # Do not publish a success configuration until both keytool operations and hashes passed.
    $temporaryConfigurationPath = Join-Path $signingPath ('.signing-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $configurationBytes = [Text.UTF8Encoding]::new($false).GetBytes($json + "`n")
    $configurationStream = [IO.File]::Open(
        $temporaryConfigurationPath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    $temporaryConfigurationCreated = $true
    try {
        $configurationStream.Write($configurationBytes, 0, $configurationBytes.Length)
        $configurationStream.Flush($true)
    } finally {
        $configurationStream.Dispose()
        [Security.Cryptography.CryptographicOperations]::ZeroMemory($configurationBytes)
    }
    [IO.File]::Move($temporaryConfigurationPath, $configurationPath)
    $temporaryConfigurationCreated = $false
    if ($lockStream) { $lockStream.Dispose(); $lockStream = $null }
    if (Test-Path -LiteralPath $lockPath -PathType Leaf) { [IO.File]::Delete($lockPath) }
    $lockCreated = $false

    Write-Output "Android signing initialization complete: $configurationPath"
    Write-Output "Certificate SHA-256: $certificateSha256"
    Write-Output '离线备份 android-release.p12，并保管刚输入的密码；CurrentUser DPAPI 仅便于本机读取，不替代恢复密码。'
} finally {
    if ($lockStream) {
        try { $lockStream.Dispose() } catch { }
    }
    if ($lockCreated -and $lockPath -and (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        try {
            $lockItem = Get-Item -LiteralPath $lockPath -Force -ErrorAction Stop
            if (-not [bool]($lockItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                [IO.File]::Delete($lockPath)
            }
        } catch { }
    }
    if ($temporaryConfigurationCreated -and $temporaryConfigurationPath -and
        (Test-Path -LiteralPath $temporaryConfigurationPath -PathType Leaf)) {
        try {
            $temporaryConfigurationItem = Get-Item -LiteralPath $temporaryConfigurationPath -Force -ErrorAction Stop
            if (-not [bool]($temporaryConfigurationItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                [IO.File]::Delete($temporaryConfigurationPath)
            }
        } catch { }
    }
    if ($toolEnvironmentWasChanged) {
        [Environment]::SetEnvironmentVariable(
            $toolEnvironmentName,
            $toolEnvironmentSaved,
            [EnvironmentVariableTarget]::Process
        )
    }
    if ($providedEnvironmentWasCleared) {
        [Environment]::SetEnvironmentVariable(
            $PasswordEnvironmentVariableName,
            $providedEnvironmentValueSaved,
            [EnvironmentVariableTarget]::Process
        )
    }
    if ($passwordSecure) { $passwordSecure.Dispose() }
    if ($confirmationSecure) { $confirmationSecure.Dispose() }
    $providedEnvironmentValue = $null
    $temporaryPasswordText = $null
    $protectedPassword = $null
    $json = $null

    if ($stagingCreated -and -not $movedToSigningLeaf -and [IO.Directory]::Exists($stagingPath)) {
        try { [IO.Directory]::Delete($stagingPath, $false) } catch { }
    }
}
