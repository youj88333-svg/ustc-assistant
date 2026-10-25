#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Windows', 'Android', 'All')][string]$Platform = 'All',
    [string]$Revision = 'HEAD',
    [string]$FlutterRoot = 'E:\flutter\flutter',
    [string]$SdkRoot = 'E:\Android\Sdk',
    [string]$JavaHome = 'E:\Android\Android Studio\jbr',
    [string]$GradleHome = 'E:\Android\Gradle',
    [string]$PubCache = 'E:\Android\pub_cache',
    [string]$SigningConfiguration
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Dot-sourcing defines functions only. Tests use an isolated synthetic repository;
# the production entry point has no switches that bypass source or signing gates.
function Resolve-PublicReleaseLocalPath {
    param([string]$Path, [switch]$RequireFile, [switch]$RequireDirectory, [switch]$OutsideGit)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -cne $Path.Trim() -or
        $Path -notmatch '^[A-Za-z]:[\\/]' -or $Path.Substring(2).Contains(':') -or
        $Path.IndexOfAny([char[]]@([char]0, [char]10, [char]13)) -ge 0) {
        throw 'A fully qualified local drive path is required.'
    }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $driveRoot = [IO.Path]::GetPathRoot($full)
    if (([IO.DriveInfo]::new($driveRoot)).DriveType -ne [IO.DriveType]::Fixed) {
        throw 'Release preparation paths must use a local fixed drive.'
    }
    $cursor = $driveRoot
    $components = @($full.Substring($driveRoot.Length).Split([char[]]@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries))
    foreach ($component in @('') + $components) {
        if ($component) { $cursor = [IO.Path]::Combine($cursor, $component) }
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
        if ($null -ne $item) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'A release preparation path contains a reparse point.' }
            if ($cursor -ine $full -and -not $item.PSIsContainer) { throw 'A release preparation parent is not a directory.' }
        }
        if ($OutsideGit -and (Test-Path -LiteralPath (Join-Path $cursor '.git'))) {
            throw 'Signing material must be outside every Git working tree.'
        }
    }
    if ($RequireFile -and -not (Test-Path -LiteralPath $full -PathType Leaf)) { throw 'A required release preparation file is missing.' }
    if ($RequireDirectory -and -not (Test-Path -LiteralPath $full -PathType Container)) { throw 'A required release preparation directory is missing.' }
    return $full
}

function Protect-PublicReleaseLog {
    param([AllowEmptyString()][string]$Text, [AllowEmptyCollection()][string[]]$Secrets = @())
    $safe = $Text
    foreach ($secret in @($Secrets | Where-Object { -not [string]::IsNullOrEmpty($_) } | Sort-Object -Property Length -Descending)) {
        $safe = $safe.Replace($secret, '[REDACTED]')
    }
    return $safe
}

function Assert-PublicReleaseBatchArgument {
    param([string]$Value)
    # cmd.exe expands these even inside quotes. No input to a batch command may contain them.
    if ($null -eq $Value -or $Value -match '["&|<>^()%!`\x00-\x1f\x7f]') {
        throw 'A batch tool path or argument contains unsupported shell characters.'
    }
}

function Invoke-PublicReleaseProcess {
    param(
        [string]$Executable, [string[]]$Arguments = @(), [string]$WorkingDirectory,
        [string]$Operation = 'Native release command', [string]$LogPath,
        [string[]]$Secrets = @(), [ValidateRange(1, 1800)][int]$TimeoutSeconds = 1800,
        [int[]]$AllowedExitCodes = @(0)
    )
    $process = [Diagnostics.Process]::new()
    $started = $false
    $rawOut = $null; $rawError = $null
    try {
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.WorkingDirectory = $WorkingDirectory
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        if ([IO.Path]::GetExtension($Executable) -iin @('.bat', '.cmd')) {
            Assert-PublicReleaseBatchArgument $Executable
            foreach ($argument in $Arguments) { Assert-PublicReleaseBatchArgument $argument }
            $info.FileName = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
            # CALL avoids cmd's special stripping of a quoted executable at the
            # start of /c. ArgumentList quotes spaces; validation forbids expansion.
            foreach ($argument in @('/d', '/s', '/c', 'call', $Executable) + $Arguments) { [void]$info.ArgumentList.Add($argument) }
        } else {
            $info.FileName = $Executable
            foreach ($argument in $Arguments) { [void]$info.ArgumentList.Add($argument) }
        }
        $process.StartInfo = $info
        try {
            if (-not $process.Start()) { throw 'Process did not start.' }
            $started = $true
            # Both pipes drain concurrently, including commands with large stderr output.
            $outTask = $process.StandardOutput.ReadToEndAsync()
            $errorTask = $process.StandardError.ReadToEndAsync()
            $exited = $process.WaitForExit($TimeoutSeconds * 1000)
            if (-not $exited) {
                try { $process.Kill($true) } catch { }
                [void]$process.WaitForExit(10000)
                throw 'Release command timed out.'
            }
            $drained = [Threading.Tasks.Task]::WhenAll([Threading.Tasks.Task[]]@($outTask, $errorTask))
            if (-not $drained.Wait(10000)) { throw 'Release command pipes did not close.' }
            $rawOut = $outTask.GetAwaiter().GetResult()
            $rawError = $errorTask.GetAwaiter().GetResult()
            $safeOut = Protect-PublicReleaseLog -Text $rawOut -Secrets $Secrets
            $safeError = Protect-PublicReleaseLog -Text $rawError -Secrets $Secrets
            $exitCode = $process.ExitCode
        } catch {
            # Never forward a native/PowerShell exception containing command or environment data.
            throw "$Operation could not complete within its bounded process execution."
        }
        if ($LogPath) {
            $log = Resolve-PublicReleaseLocalPath $LogPath
            [IO.File]::WriteAllText($log, ($safeOut + $safeError), [Text.UTF8Encoding]::new($false))
        }
        if ($AllowedExitCodes -notcontains $exitCode) { throw "$Operation failed (exit $exitCode); inspect its redacted stage log." }
        return [pscustomobject]@{ ExitCode = $exitCode; Stdout = $safeOut; Stderr = $safeError }
    } finally {
        if ($null -ne $process.StartInfo) {
            foreach ($name in @('USTC_ANDROID_KEYSTORE', 'USTC_ANDROID_KEY_ALIAS', 'USTC_ANDROID_STORE_PASSWORD', 'USTC_ANDROID_KEY_PASSWORD')) {
                [void]$process.StartInfo.Environment.Remove($name)
            }
        }
        if ($started) {
            try { if (-not $process.HasExited) { $process.Kill($true) } } catch { }
        }
        $process.Dispose()
        $rawOut = $null; $rawError = $null; $Secrets = $null
        $outTask = $null; $errorTask = $null; $drained = $null; $info = $null; $process = $null
    }
}

function Assert-PublicReleaseSource {
    param([string]$RepositoryRoot, [string]$Revision, [string]$Git)
    $common = @{ Executable = $Git; WorkingDirectory = $RepositoryRoot; TimeoutSeconds = 30 }
    $top = (Invoke-PublicReleaseProcess @common -Arguments @('-C', $RepositoryRoot, 'rev-parse', '--show-toplevel') -Operation 'Git worktree identity').Stdout.Trim()
    if ([IO.Path]::GetFullPath($top).TrimEnd('\', '/') -ine $RepositoryRoot.TrimEnd('\', '/')) { throw 'The source must be the requested Git working tree root.' }
    $head = (Invoke-PublicReleaseProcess @common -Arguments @('-C', $RepositoryRoot, 'rev-parse', '--verify', 'HEAD') -Operation 'Git HEAD').Stdout.Trim().ToLowerInvariant()
    if ($Revision -ceq 'HEAD') { $Revision = $head }
    if ($Revision -notmatch '^[0-9a-fA-F]{40}$') { throw 'Revision must be HEAD or exactly 40 hexadecimal characters.' }
    if ($Revision.ToLowerInvariant() -cne $head) { throw 'Revision must equal the current HEAD.' }
    $status = (Invoke-PublicReleaseProcess @common -Arguments @('-C', $RepositoryRoot, 'status', '--porcelain=v1', '--untracked-files=all', '--ignore-submodules=none') -Operation 'Git clean-source gate').Stdout
    if (-not [string]::IsNullOrWhiteSpace($status)) { throw 'The Git working tree must be clean; review generated or source changes before rebuilding.' }
    return $head
}

function Read-PublicReleaseSigning {
    param([string]$ConfigurationPath, [string]$RepositoryRoot)
    $configuration = $null; $json = $null; $password = $null; $passed = $false
    try {
        $path = Resolve-PublicReleaseLocalPath $ConfigurationPath -RequireFile -OutsideGit
        if ($path.StartsWith($RepositoryRoot.TrimEnd('\', '/') + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Signing material must be outside the source working tree.'
        }
        try {
            $json = [IO.File]::ReadAllText($path)
            $configuration = ConvertFrom-Json -InputObject $json -AsHashtable
        } catch { throw 'The Android signing configuration is invalid; its contents were suppressed.' }
        if ($configuration -isnot [Collections.IDictionary]) { throw 'The Android signing configuration must be an object.' }
        foreach ($field in @('kind', 'synthetic', 'keystoreFile', 'keyAlias', 'passwordProtected', 'certificateSha256', 'publicCertificateFile')) {
            if (-not $configuration.Contains($field)) { throw 'The Android signing configuration is missing a required field.' }
        }
        if ($configuration.kind -cne 'ustc-android-release-signing-v1' -or
            $configuration.synthetic -isnot [bool] -or $configuration.synthetic -ne $false) {
            throw 'A non-synthetic ustc-android-release-signing-v1 configuration is required.'
        }
        foreach ($field in @('keystoreFile', 'keyAlias', 'passwordProtected', 'certificateSha256', 'publicCertificateFile')) {
            if ($configuration[$field] -isnot [string] -or [string]::IsNullOrWhiteSpace($configuration[$field])) { throw 'The Android signing configuration contains an invalid field.' }
        }
        if ($configuration.keyAlias -ieq 'androiddebugkey' -or $configuration.keyAlias -match '[\x00-\x1f\x7f]') { throw 'A non-debug Android key alias is required.' }
        if ($configuration.certificateSha256 -cnotmatch '^[0-9a-f]{64}$' -or
            $configuration.certificateSha256 -ceq '16d3f9867f0a15d4d4ffc877bdd9ec240e92a3fddf6a0a66da857e2888846036') {
            throw 'A lowercase non-QA signing certificate SHA-256 is required.'
        }
        $keystore = Resolve-PublicReleaseLocalPath $configuration.keystoreFile -RequireFile -OutsideGit
        $certificatePath = Resolve-PublicReleaseLocalPath $configuration.publicCertificateFile -RequireFile -OutsideGit
        if ([IO.Path]::GetExtension($keystore) -iin @('.p12', '.pfx') -and (Get-Item -LiteralPath $keystore).Length -gt 0) { }
        else { throw 'A nonempty PKCS12 keystore file is required.' }
        $certificateBytes = [IO.File]::ReadAllBytes($certificatePath)
        try {
            $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certificateBytes)
            try {
                if ([Convert]::ToHexString($certificate.RawData) -cne [Convert]::ToHexString($certificateBytes)) { throw 'The public certificate must contain a single DER certificate.' }
            } finally { $certificate.Dispose() }
        } catch { throw 'The public signing certificate is not a valid DER certificate.' }
        $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($certificateBytes)).ToLowerInvariant()
        if ($digest -cne $configuration.certificateSha256) { throw 'The public certificate does not match the configured SHA-256.' }
        try { $password = ConvertTo-SecureString -String $configuration.passwordProtected -ErrorAction Stop }
        catch { throw 'CurrentUser DPAPI could not decrypt the Android signing password; details were suppressed.' }
        if ($password.Length -le 0) { throw 'The Android signing password must not be empty.' }
        $passed = $true
        return [pscustomobject]@{ KeystoreFile = $keystore; KeyAlias = $configuration.keyAlias; CertificateSha256 = $digest; Password = $password }
    } finally {
        if (-not $passed -and $null -ne $password) { $password.Dispose() }
        $json = $null; $configuration = $null; $password = $null
    }
}

function Convert-PublicReleasePassword {
    param([Security.SecureString]$Password)
    $pointer = [IntPtr]::Zero
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    } finally {
        if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    }
}

function Repair-PublicReleaseLocalProperties {
    param([string]$RepositoryRoot, [string]$Git)
    $path = Join-Path $RepositoryRoot 'app/android/local.properties'
    if (-not (Test-Path -LiteralPath $path)) { return }
    $path = Resolve-PublicReleaseLocalPath $path -RequireFile
    [void](Invoke-PublicReleaseProcess -Executable $Git -Arguments @('-C', $RepositoryRoot, 'check-ignore', '--quiet', '--', 'app/android/local.properties') -WorkingDirectory $RepositoryRoot -Operation 'Generated Android properties ignore gate' -TimeoutSeconds 30)
    $text = [IO.File]::ReadAllText($path)
    $escaped = [regex]::Replace($text, '(?m)^((?:sdk\.dir|flutter\.sdk)=)([A-Za-z]):', '$1$2\:')
    if ($escaped -cne $text) { [IO.File]::WriteAllText($path, $escaped, [Text.UTF8Encoding]::new($false)) }
}

function Invoke-PublicReleaseBuild {
    param(
        [string]$RepositoryRoot, [ValidateSet('Windows', 'Android', 'All')][string]$Platform = 'All', [string]$Revision = 'HEAD',
        [string]$FlutterRoot = 'E:\flutter\flutter', [string]$SdkRoot = 'E:\Android\Sdk',
        [string]$JavaHome = 'E:\Android\Android Studio\jbr', [string]$GradleHome = 'E:\Android\Gradle',
        [string]$PubCache = 'E:\Android\pub_cache', [string]$SigningConfiguration
    )
    if (-not $IsWindows) { throw 'The public release builder requires Windows PowerShell 7.' }
    $repository = Resolve-PublicReleaseLocalPath $RepositoryRoot -RequireDirectory
    $git = (Get-Command git.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $sourceRevision = Assert-PublicReleaseSource -RepositoryRoot $repository -Revision $Revision -Git $git
    $app = Resolve-PublicReleaseLocalPath (Join-Path $repository 'app') -RequireDirectory
    if ([IO.File]::ReadAllText((Join-Path $app 'pubspec.yaml')) -notmatch '(?m)^version:\s*1\.0\.0\+1\s*$') { throw 'The public release builder is pinned to engineering version 1.0.0+1.' }
    $flutter = Resolve-PublicReleaseLocalPath (Join-Path $FlutterRoot 'bin/flutter.bat') -RequireFile
    Assert-PublicReleaseBatchArgument $flutter
    $shell = Resolve-PublicReleaseLocalPath (Join-Path $PSHOME 'pwsh.exe') -RequireFile
    $taskRoot = Resolve-PublicReleaseLocalPath (Join-Path $app 'build/release-preparation')
    $taskTemp = Resolve-PublicReleaseLocalPath (Join-Path $taskRoot 'temp')
    if ([IO.Path]::GetPathRoot($taskTemp) -ieq 'C:\') { throw 'Release preparation temporary files must use a local fixed drive other than C:.' }
    $publicRoot = Resolve-PublicReleaseLocalPath (Join-Path $app 'build/public-releases')
    $outputs = [Collections.Generic.List[object]]::new()
    $windowsDirectory = Join-Path $publicRoot ('1.0.0+1-' + $sourceRevision.Substring(0, 8))
    $androidDirectory = Join-Path $publicRoot ('android-1.0.0-' + $sourceRevision.Substring(0, 8))
    foreach ($candidate in @($(if ($Platform -in @('Windows', 'All')) { $windowsDirectory }), $(if ($Platform -in @('Android', 'All')) { $androidDirectory }))) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { throw 'A candidate output already exists; existing releases are never overwritten.' }
    }
    $signing = $null; $passwordText = $null; $androidRuntimeDependencies = $null
    $savedEnvironment = @{}; $environmentChanged = $false
    $stages = [Collections.Generic.List[object]]::new()
    $environmentValues = @{
        PUB_CACHE = (Resolve-PublicReleaseLocalPath $PubCache)
        TEMP = $taskTemp; TMP = $taskTemp
        USTC_ANDROID_KEYSTORE = $null; USTC_ANDROID_KEY_ALIAS = $null
        USTC_ANDROID_STORE_PASSWORD = $null; USTC_ANDROID_KEY_PASSWORD = $null
    }
    if ($Platform -in @('Android', 'All')) {
        $environmentValues.JAVA_HOME = Resolve-PublicReleaseLocalPath $JavaHome -RequireDirectory
        $environmentValues.ANDROID_HOME = Resolve-PublicReleaseLocalPath $SdkRoot -RequireDirectory
        $environmentValues.ANDROID_SDK_ROOT = $environmentValues.ANDROID_HOME
        $environmentValues.GRADLE_USER_HOME = Resolve-PublicReleaseLocalPath $GradleHome
        $environmentValues.GRADLE_OPTS = (([Environment]::GetEnvironmentVariable('GRADLE_OPTS', 'Process') + ' -Dorg.gradle.daemon=false -Dorg.gradle.configuration-cache=false -Djava.io.tmpdir="' + $taskTemp + '"').Trim())
    }
    try {
        if ($Platform -in @('Android', 'All')) {
            if ([string]::IsNullOrWhiteSpace($SigningConfiguration)) { $SigningConfiguration = Join-Path (Split-Path -Parent $repository) 'private/android-signing/signing.json' }
            $signing = Read-PublicReleaseSigning -ConfigurationPath $SigningConfiguration -RepositoryRoot $repository
        }
        foreach ($name in $environmentValues.Keys) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
        $environmentChanged = $true
        foreach ($name in $environmentValues.Keys) { [Environment]::SetEnvironmentVariable($name, $environmentValues[$name], 'Process') }
        $cacheDirectories = @($taskTemp, $environmentValues.PUB_CACHE)
        if ($environmentValues.ContainsKey('GRADLE_USER_HOME')) { $cacheDirectories += $environmentValues.GRADLE_USER_HOME }
        foreach ($directory in $cacheDirectories) { [void][IO.Directory]::CreateDirectory($directory) }
        $runRoot = Join-Path $taskRoot ('logs/' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory((Resolve-PublicReleaseLocalPath $runRoot))
        $common = @{ WorkingDirectory = $app }
        [void](Invoke-PublicReleaseProcess @common -Executable $flutter -Arguments @('pub', 'get', '--offline', '--enforce-lockfile') -Operation 'Offline dependency preparation' -LogPath (Join-Path $runRoot '01-pub-get.log'))
        $stages.Add([pscustomobject]@{ name = 'offline-pub-get'; status = 'passed' })
        $speech = Resolve-PublicReleaseLocalPath (Join-Path $repository 'tools/prepare-speech-assets.ps1') -RequireFile
        $powershellArguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File')
        [void](Invoke-PublicReleaseProcess @common -Executable $shell -Arguments ($powershellArguments + @($speech, '-Check')) -Operation 'Fixed speech asset check' -LogPath (Join-Path $runRoot '02-speech-check.log'))
        $stages.Add([pscustomobject]@{ name = 'fixed-speech-assets'; status = 'passed' })
        [void](Assert-PublicReleaseSource -RepositoryRoot $repository -Revision $sourceRevision -Git $git)
        if ($Platform -in @('Windows', 'All')) {
            # --pub also regenerates release plugin registrants; --no-pub can
            # retain integration-test registrations after a native test run.
            [void](Invoke-PublicReleaseProcess @common -Executable $flutter -Arguments @('build', 'windows', '--release', '--pub', '--target', 'lib/main.dart', "--dart-define=USTC_BUILD_REVISION=$sourceRevision") -Operation 'Windows release build' -LogPath (Join-Path $runRoot '03-windows-build.log'))
            [void](Assert-PublicReleaseSource -RepositoryRoot $repository -Revision $sourceRevision -Git $git)
            $packager = Resolve-PublicReleaseLocalPath (Join-Path $repository 'tools/package-windows-release.ps1') -RequireFile
            [void](Invoke-PublicReleaseProcess @common -Executable $shell -Arguments ($powershellArguments + @($packager, '-ReleaseDirectory', (Join-Path $app 'build/windows/x64/runner/Release'), '-Revision', $sourceRevision)) -Operation 'Windows candidate package' -LogPath (Join-Path $runRoot '04-windows-package.log'))
            $outputs.Add([pscustomobject]@{ platform = 'windows-x64'; path = (Join-Path $windowsDirectory 'USTC-Assistant-1.0.0-windows-x64.zip') })
            $stages.Add([pscustomobject]@{ name = 'windows-build-and-package'; status = 'passed' })
        }
        if ($Platform -in @('Android', 'All')) {
            Repair-PublicReleaseLocalProperties -RepositoryRoot $repository -Git $git
            try {
                $passwordText = Convert-PublicReleasePassword $signing.Password
                [Environment]::SetEnvironmentVariable('USTC_ANDROID_KEYSTORE', $signing.KeystoreFile, 'Process')
                [Environment]::SetEnvironmentVariable('USTC_ANDROID_KEY_ALIAS', $signing.KeyAlias, 'Process')
                [Environment]::SetEnvironmentVariable('USTC_ANDROID_STORE_PASSWORD', $passwordText, 'Process')
                [Environment]::SetEnvironmentVariable('USTC_ANDROID_KEY_PASSWORD', $passwordText, 'Process')
                [void](Invoke-PublicReleaseProcess @common -Executable $flutter -Arguments @('build', 'apk', '--release', '--pub', '--target', 'lib/main.dart', '--target-platform', 'android-arm64,android-x64', '--split-per-abi', '--build-name=1.0.0', '--build-number=1', "--dart-define=USTC_BUILD_REVISION=$sourceRevision") -Operation 'Signed Android release build' -Secrets @($passwordText) -LogPath (Join-Path $runRoot '05-android-build.log'))
            } finally {
                foreach ($name in @('USTC_ANDROID_KEYSTORE', 'USTC_ANDROID_KEY_ALIAS', 'USTC_ANDROID_STORE_PASSWORD', 'USTC_ANDROID_KEY_PASSWORD')) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
                $passwordText = $null
                if ($null -ne $signing) { $signing.Password.Dispose() }
            }
            Repair-PublicReleaseLocalProperties -RepositoryRoot $repository -Git $git
            $androidRoot = Resolve-PublicReleaseLocalPath (Join-Path $app 'android') -RequireDirectory
            $gradlew = Resolve-PublicReleaseLocalPath (Join-Path $androidRoot 'gradlew.bat') -RequireFile
            $dependencyReportPath = Resolve-PublicReleaseLocalPath (Join-Path $runRoot '06-android-release-runtime-dependencies.txt')
            # Signing variables have been cleared and the password lease disposed.
            # This separate non-daemon task records the resolved release graph only.
            [void](Invoke-PublicReleaseProcess -Executable $gradlew -Arguments @('--no-daemon', '--no-configuration-cache', ':app:dependencies', '--configuration', 'releaseRuntimeClasspath') -WorkingDirectory $androidRoot -Operation 'Android release runtime dependencies' -LogPath $dependencyReportPath)
            [void](Resolve-PublicReleaseLocalPath $dependencyReportPath -RequireFile)
            if ((Get-Item -LiteralPath $dependencyReportPath).Length -le 0) { throw 'The Android release runtime dependency report is empty.' }
            $androidRuntimeDependencies = [ordered]@{
                configuration = 'releaseRuntimeClasspath'
                path = [IO.Path]::GetRelativePath($repository, $dependencyReportPath).Replace('\', '/')
                sha256 = (Get-FileHash -LiteralPath $dependencyReportPath -Algorithm SHA256).Hash.ToLowerInvariant()
                bytes = (Get-Item -LiteralPath $dependencyReportPath).Length
                status = 'generated'
            }
            $stages.Add([pscustomobject]@{ name = 'android-release-runtime-dependencies'; status = 'passed' })
            [void](Assert-PublicReleaseSource -RepositoryRoot $repository -Revision $sourceRevision -Git $git)
            $packager = Resolve-PublicReleaseLocalPath (Join-Path $repository 'tools/package-android-release.ps1') -RequireFile
            [void](Invoke-PublicReleaseProcess @common -Executable $shell -Arguments ($powershellArguments + @($packager, '-ApkDirectory', (Join-Path $app 'build/app/outputs/flutter-apk'), '-Revision', $sourceRevision, '-CertificateSha256', $signing.CertificateSha256, '-SdkRoot', $environmentValues.ANDROID_HOME, '-ExpectedArm64VersionCode', '2001', '-ExpectedX64VersionCode', '4001')) -Operation 'Android candidate package' -LogPath (Join-Path $runRoot '07-android-package.log'))
            $outputs.Add([pscustomobject]@{ platform = 'android-arm64'; path = (Join-Path $androidDirectory 'app-arm64-v8a-release.apk') })
            $outputs.Add([pscustomobject]@{ platform = 'android-x86_64'; path = (Join-Path $androidDirectory 'app-x86_64-release.apk') })
            $stages.Add([pscustomobject]@{ name = 'android-build-and-package'; status = 'passed' })
        }
        [void](Assert-PublicReleaseSource -RepositoryRoot $repository -Revision $sourceRevision -Git $git)
        $outputRecords = @($outputs | ForEach-Object {
            $path = Resolve-PublicReleaseLocalPath $_.path -RequireFile
            if ((Get-Item -LiteralPath $path).Length -le 0) { throw 'A packaged release artifact is empty.' }
            [ordered]@{ platform = $_.platform; path = [IO.Path]::GetRelativePath($repository, $path).Replace('\', '/'); bytes = (Get-Item -LiteralPath $path).Length; sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant(); status = 'packaged-candidate' }
        })
        $report = [ordered]@{
            kind = 'ustc-public-release-build-v1'; artifactStatus = 'public-candidate'; published = $false
            sourceRevision = $sourceRevision; sourceClean = $true; version = '1.0.0+1'; platform = $Platform
            androidCertificateSha256 = $(if ($null -ne $signing) { $signing.CertificateSha256 } else { $null })
            androidRuntimeDependencies = $androidRuntimeDependencies
            stages = @($stages); outputs = $outputRecords
            verification = 'Build and package checks only; device acceptance and publication are separate.'
        }
        $reportRoot = Resolve-PublicReleaseLocalPath (Join-Path $taskRoot 'reports')
        [void][IO.Directory]::CreateDirectory($reportRoot)
        $reportPath = Join-Path $reportRoot ('build-' + $Platform.ToLowerInvariant() + '-' + $sourceRevision + '-' + [guid]::NewGuid().ToString('N') + '.json')
        $temporaryReport = Join-Path $reportRoot ('.report-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            $stream = [IO.File]::Open($temporaryReport, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($report | ConvertTo-Json -Depth 8) + "`n")
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush($true)
            } finally { $stream.Dispose() }
            [IO.File]::Move($temporaryReport, $reportPath)
        } finally {
            if (Test-Path -LiteralPath $temporaryReport -PathType Leaf) { [IO.File]::Delete($temporaryReport) }
        }
        Write-Output "Public candidate build completed: $reportPath"
        Write-Output 'No publication, installation, or real-device acceptance was performed.'
    } finally {
        if ($environmentChanged) {
            foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process') }
        }
        if ($null -ne $signing) { $signing.Password.Dispose() }
        $passwordText = $null; $signing = $null; $savedEnvironment.Clear()
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-PublicReleaseBuild -RepositoryRoot (Join-Path $PSScriptRoot '..') -Platform $Platform -Revision $Revision `
        -FlutterRoot $FlutterRoot -SdkRoot $SdkRoot -JavaHome $JavaHome -GradleHome $GradleHome `
        -PubCache $PubCache -SigningConfiguration $SigningConfiguration
}
