#requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$builder = Join-Path $PSScriptRoot 'build-public-release.ps1'
. $builder
$script:checks = 0
$script:testRoot = 'E:\codex-public-release-build-test-' + [guid]::NewGuid().ToString('N')
$script:rootCreated = $false
$script:originalRunner = (Get-Command Invoke-PublicReleaseProcess -CommandType Function).ScriptBlock
$script:gitExecutable = (Get-Command git.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$script:observedCalls = [Collections.Generic.List[object]]::new()
$script:failOperation = ''
$script:omitOutput = $false
$script:syntheticPassword = 'SYNTHETIC-' + [guid]::NewGuid().ToString('N')
$script:fixtureEnvironment = @{}
$script:junction = $null

function Check([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:checks++
}

function Reject([scriptblock]$Action, [string]$Expected, [string]$Message) {
    try { & $Action | Out-Null }
    catch {
        if ($_.Exception.Message -notlike ('*' + $Expected + '*')) { throw "Unexpected rejection for $Message : $($_.Exception.Message)" }
        $script:checks++
        return
    }
    throw "Expected rejection: $Message"
}

function Write-Fixture([string]$Path, [string]$Text = 'synthetic') {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Run-FixtureGit([string[]]$Arguments) {
    return & $script:originalRunner -Executable $script:gitExecutable -Arguments (@('-C', $script:fixtureRepository) + $Arguments) -WorkingDirectory $script:fixtureRepository -Operation 'Synthetic fixture Git' -TimeoutSeconds 30
}

function Write-SigningFixture([hashtable]$Overrides = @{}) {
    $record = [ordered]@{
        kind = 'ustc-android-release-signing-v1'; synthetic = $false
        keystoreFile = $script:fixtureKeystore; keyAlias = 'synthetic-release'
        passwordProtected = $script:protectedSyntheticPassword
        certificateSha256 = $script:fixtureCertificateSha256
        publicCertificateFile = $script:fixtureCertificate
    }
    foreach ($key in $Overrides.Keys) { $record[$key] = $Overrides[$key] }
    Write-Fixture $script:fixtureConfiguration ($record | ConvertTo-Json -Depth 4)
}

function Read-FixtureSigning {
    return Read-PublicReleaseSigning -ConfigurationPath $script:fixtureConfiguration -RepositoryRoot $script:fixtureRepository
}

function Get-FixtureReports {
    $path = Join-Path $script:fixtureRepository 'app/build/release-preparation/reports'
    if (Test-Path -LiteralPath $path) { return @(Get-ChildItem -LiteralPath $path -Filter '*.json' -File) }
    return @()
}

function Install-BuildProcessFixture {
    function script:Invoke-PublicReleaseProcess {
        param([string]$Executable, [string[]]$Arguments = @(), [string]$WorkingDirectory,
            [string]$Operation = 'Native release command', [string]$LogPath,
            [string[]]$Secrets = @(), [int]$TimeoutSeconds = 1800, [int[]]$AllowedExitCodes = @(0))
        if ($Executable -ieq $script:gitExecutable) { return & $script:originalRunner @PSBoundParameters }
        $storePassword = [Environment]::GetEnvironmentVariable('USTC_ANDROID_STORE_PASSWORD', 'Process')
        $keyPassword = [Environment]::GetEnvironmentVariable('USTC_ANDROID_KEY_PASSWORD', 'Process')
        $script:observedCalls.Add([pscustomobject]@{
            Operation = $Operation; Executable = $Executable; Arguments = $Arguments; WorkingDirectory = $WorkingDirectory
            SigningPresent = (-not [string]::IsNullOrEmpty($storePassword))
            SigningMatches = ($storePassword -ceq $script:syntheticPassword -and $keyPassword -ceq $script:syntheticPassword)
            SigningEnvironmentCleared = ([string]::IsNullOrEmpty($storePassword) -and [string]::IsNullOrEmpty($keyPassword) -and [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('USTC_ANDROID_KEYSTORE', 'Process')) -and [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('USTC_ANDROID_KEY_ALIAS', 'Process')))
            GradleOptions = [Environment]::GetEnvironmentVariable('GRADLE_OPTS', 'Process')
            JavaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'Process')
            AndroidHome = [Environment]::GetEnvironmentVariable('ANDROID_HOME', 'Process')
            AndroidSdkRoot = [Environment]::GetEnvironmentVariable('ANDROID_SDK_ROOT', 'Process')
            GradleUserHome = [Environment]::GetEnvironmentVariable('GRADLE_USER_HOME', 'Process')
            PubCache = [Environment]::GetEnvironmentVariable('PUB_CACHE', 'Process')
            Temp = [Environment]::GetEnvironmentVariable('TEMP', 'Process')
        })
        Check (-not (($Arguments -join ' ') -like ('*' + $script:syntheticPassword + '*'))) 'secrets never enter process arguments'
        if ($Operation -ceq $script:failOperation) { throw 'Synthetic build failure.' }
        if ($Operation -ceq 'Windows candidate package' -and -not $script:omitOutput) {
            Write-Fixture (Join-Path $script:fixtureRepository ('app/build/public-releases/1.0.0+1-' + $script:fixtureRevision.Substring(0, 8) + '/USTC-Assistant-1.0.0-windows-x64.zip')) 'synthetic Windows candidate'
        }
        if ($Operation -ceq 'Android candidate package') {
            foreach ($name in @('app-arm64-v8a-release.apk', 'app-x86_64-release.apk')) {
                Write-Fixture (Join-Path $script:fixtureRepository ('app/build/public-releases/android-1.0.0-' + $script:fixtureRevision.Substring(0, 8) + '/' + $name)) 'synthetic Android candidate'
            }
        }
        if ($LogPath) {
            $logText = if ($Operation -ceq 'Android release runtime dependencies') { "releaseRuntimeClasspath - synthetic runtime dependency fixture`n\--- synthetic.example:fixture:1.2.3`n" }
                else { 'synthetic log ' + $(if ($storePassword) { $storePassword } else { 'no signing environment' }) }
            Write-Fixture $LogPath (Protect-PublicReleaseLog $logText $Secrets)
        }
        return [pscustomobject]@{ ExitCode = 0; Stdout = ''; Stderr = '' }
    }
}

try {
    if (-not $IsWindows) { throw 'Synthetic release-builder checks require Windows PowerShell 7.' }
    Check ($script:testRoot -match '^E:\\codex-public-release-build-test-[0-9a-f]{32}$') 'test root is an E-drive GUID directory'
    if (Test-Path -LiteralPath $script:testRoot) { throw 'Refusing to reuse an existing test root.' }
    [void](Resolve-PublicReleaseLocalPath $script:testRoot -OutsideGit)
    [void][IO.Directory]::CreateDirectory($script:testRoot)
    $script:rootCreated = $true
    $script:fixtureRepository = Join-Path $script:testRoot 'source'
    [void][IO.Directory]::CreateDirectory($script:fixtureRepository)
    Write-Fixture (Join-Path $script:fixtureRepository '.gitignore') "app/build/`napp/android/local.properties`n"
    Write-Fixture (Join-Path $script:fixtureRepository 'app/pubspec.yaml') "name: synthetic_release_fixture`nversion: 1.0.0+1`n"
    Write-Fixture (Join-Path $script:fixtureRepository 'app/android/gradlew.bat') '@echo synthetic Gradle wrapper stub'
    foreach ($name in @('prepare-speech-assets.ps1', 'package-windows-release.ps1', 'package-android-release.ps1')) { Write-Fixture (Join-Path $script:fixtureRepository ('tools/' + $name)) '# Synthetic stub; never executes a compiler.' }
    [void](Run-FixtureGit -Arguments @('init', '--quiet'))
    [void](Run-FixtureGit -Arguments @('add', '--all'))
    [void](Run-FixtureGit -Arguments @('-c', 'user.name=Synthetic Fixture', '-c', 'user.email=synthetic@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '--quiet', '-m', 'Synthetic release build fixture'))
    $script:fixtureRevision = (Run-FixtureGit -Arguments @('rev-parse', 'HEAD')).Stdout.Trim()
    $sourceArguments = @{ RepositoryRoot = $script:fixtureRepository; Git = $script:gitExecutable }
    Check ((Assert-PublicReleaseSource @sourceArguments -Revision 'HEAD') -ceq $script:fixtureRevision) 'default HEAD resolves to clean full revision'
    Reject { Assert-PublicReleaseSource @sourceArguments -Revision 'bad' } '40 hexadecimal' 'abbreviated revision'
    Reject { Assert-PublicReleaseSource @sourceArguments -Revision ('0' * 40) } 'equal the current HEAD' 'mismatched revision'
    Write-Fixture (Join-Path $script:fixtureRepository 'untracked-fixture.txt')
    Reject { Assert-PublicReleaseSource @sourceArguments -Revision $script:fixtureRevision } 'must be clean' 'untracked source file'
    [IO.File]::Delete((Join-Path $script:fixtureRepository 'untracked-fixture.txt'))
    [IO.File]::AppendAllText((Join-Path $script:fixtureRepository 'app/pubspec.yaml'), '# dirty')
    Reject { Assert-PublicReleaseSource @sourceArguments -Revision $script:fixtureRevision } 'must be clean' 'modified tracked source'
    Write-Fixture (Join-Path $script:fixtureRepository 'app/pubspec.yaml') "name: synthetic_release_fixture`nversion: 1.0.0+1`n"

    $signingRoot = Join-Path $script:testRoot 'signing-fixture'
    [void][IO.Directory]::CreateDirectory($signingRoot)
    $script:fixtureConfiguration = Join-Path $signingRoot 'signing.json'
    $script:fixtureKeystore = Join-Path $signingRoot 'synthetic.p12'
    $script:fixtureCertificate = Join-Path $signingRoot 'synthetic.cer'
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    try {
        $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=Synthetic Release Builder Test', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(1))
        try {
            [IO.File]::WriteAllBytes($script:fixtureCertificate, $certificate.RawData)
            [IO.File]::WriteAllBytes($script:fixtureKeystore, $certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12, $script:syntheticPassword))
        } finally { $certificate.Dispose() }
    } finally { $rsa.Dispose() }
    $script:fixtureCertificateSha256 = (Get-FileHash -LiteralPath $script:fixtureCertificate -Algorithm SHA256).Hash.ToLowerInvariant()
    $secure = ConvertTo-SecureString $script:syntheticPassword -AsPlainText -Force
    try { $script:protectedSyntheticPassword = ConvertFrom-SecureString $secure } finally { $secure.Dispose() }
    Reject { Read-FixtureSigning } 'missing' 'missing configuration'
    Write-SigningFixture
    $accepted = Read-FixtureSigning
    try { Check ((Convert-PublicReleasePassword $accepted.Password) -ceq $script:syntheticPassword) 'CurrentUser DPAPI decrypts only the synthetic fixture' }
    finally { $accepted.Password.Dispose(); $accepted = $null }
    foreach ($case in @(
        @{ change = @{ synthetic = $true }; error = 'non-synthetic'; label = 'synthetic marker' },
        @{ change = @{ synthetic = 'false' }; error = 'non-synthetic'; label = 'string synthetic marker' },
        @{ change = @{ keyAlias = 'androiddebugkey' }; error = 'non-debug'; label = 'debug alias' },
        @{ change = @{ certificateSha256 = ('0' * 64) }; error = 'does not match'; label = 'certificate digest mismatch' },
        @{ change = @{ certificateSha256 = '16d3f9867f0a15d4d4ffc877bdd9ec240e92a3fddf6a0a66da857e2888846036' }; error = 'non-QA'; label = 'known QA signer' },
        @{ change = @{ passwordProtected = 'invalid-ciphertext' }; error = 'DPAPI'; label = 'invalid DPAPI value' }
    )) {
        Write-SigningFixture $case.change
        Reject { Read-FixtureSigning } $case.error $case.label
    }
    Write-SigningFixture
    $inside = Join-Path $script:fixtureRepository 'app/build/signing.json'
    Write-Fixture $inside ([IO.File]::ReadAllText($script:fixtureConfiguration))
    Reject { Read-PublicReleaseSigning -ConfigurationPath $inside -RepositoryRoot $script:fixtureRepository } 'outside every Git' 'configuration inside source'
    Write-SigningFixture @{ keystoreFile = (Join-Path $script:fixtureRepository 'app/pubspec.yaml') }
    Reject { Read-FixtureSigning } 'outside every Git' 'keystore inside source'
    Write-SigningFixture
    $script:junction = Join-Path $script:testRoot 'signing-junction'
    [void](New-Item -ItemType Junction -Path $script:junction -Target $signingRoot)
    Reject { Read-PublicReleaseSigning -ConfigurationPath (Join-Path $script:junction 'signing.json') -RepositoryRoot $script:fixtureRepository } 'reparse point' 'linked signing ancestor'
    Write-SigningFixture @{ keystoreFile = (Join-Path $script:junction 'synthetic.p12') }
    Reject { Read-FixtureSigning } 'reparse point' 'linked keystore ancestor'
    Write-SigningFixture @{ publicCertificateFile = (Join-Path $script:junction 'synthetic.cer') }
    Reject { Read-FixtureSigning } 'reparse point' 'linked certificate ancestor'
    Write-SigningFixture
    [IO.Directory]::Delete($script:junction); $script:junction = $null
    $emptyKeystore = Join-Path $signingRoot 'empty.p12'
    Write-Fixture $emptyKeystore ''
    Write-SigningFixture @{ keystoreFile = $emptyKeystore }
    Reject { Read-FixtureSigning } 'nonempty PKCS12' 'empty keystore'
    Write-SigningFixture

    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    $nativeFixture = Join-Path $script:testRoot 'native-output.ps1'
    Write-Fixture $nativeFixture @'
[Console]::Out.Write('stdout:' + $env:USTC_PUBLIC_RELEASE_SYNTHETIC_OUTPUT)
[Console]::Out.Write(('x' * 131072))
[Console]::Error.Write(('y' * 131072))
[Console]::Error.Write('stderr:' + $env:USTC_PUBLIC_RELEASE_SYNTHETIC_OUTPUT)
exit 7
'@
    $outputEnvironment = 'USTC_PUBLIC_RELEASE_SYNTHETIC_OUTPUT'
    $script:fixtureEnvironment[$outputEnvironment] = [Environment]::GetEnvironmentVariable($outputEnvironment, 'Process')
    [Environment]::SetEnvironmentVariable($outputEnvironment, $script:syntheticPassword, 'Process')
    $nativeLog = Join-Path $script:testRoot 'native-redacted.log'
    $result = & $script:originalRunner -Executable $pwsh -Arguments @('-NoProfile', '-NonInteractive', '-File', $nativeFixture) -WorkingDirectory $script:testRoot -LogPath $nativeLog -Secrets @($script:syntheticPassword) -AllowedExitCodes @(7) -TimeoutSeconds 30
    Check ($result.ExitCode -eq 7 -and $result.Stdout.Contains('[REDACTED]') -and $result.Stderr.Contains('[REDACTED]')) 'both native pipes are redacted before return'
    Check (-not [IO.File]::ReadAllText($nativeLog).Contains($script:syntheticPassword)) 'plaintext never reaches native log'
    Check ($result.Stdout.Length -gt 131072 -and $result.Stderr.Length -gt 131072) 'both full pipes drain beyond their operating-system buffer sizes'
    Reject { & $script:originalRunner -Executable $pwsh -Arguments @('-NoProfile', '-File', $nativeFixture) -WorkingDirectory $script:testRoot -Secrets @($script:syntheticPassword) -TimeoutSeconds 30 } 'exit 7' 'nonzero native exit'
    $batch = Join-Path $script:testRoot 'tool with spaces.cmd'
    Write-Fixture $batch "@echo off`r`necho %~1`r`nexit /b 0`r`n"
    $batchResult = & $script:originalRunner -Executable $batch -Arguments @('safe argument with spaces') -WorkingDirectory $script:testRoot -TimeoutSeconds 30
    Check ($batchResult.Stdout.Trim() -ceq 'safe argument with spaces') 'safe cmd invocation preserves spaced entry and argument'
    Reject { & $script:originalRunner -Executable $batch -Arguments @('unsafe&argument') -WorkingDirectory $script:testRoot -TimeoutSeconds 30 } 'shell characters' 'batch shell injection'
    Reject { & $script:originalRunner -Executable $batch -Arguments @('unsafe%VARIABLE%') -WorkingDirectory $script:testRoot -TimeoutSeconds 30 } 'shell characters' 'batch variable expansion'
    Check ((Protect-PublicReleaseLog ('a' + $script:syntheticPassword + 'b' + $script:syntheticPassword) @($script:syntheticPassword)) -ceq 'a[REDACTED]b[REDACTED]') 'all exact password occurrences are replaced'
    Check ((Protect-PublicReleaseLog 'first OTHER' @('first', 'OTHER')) -ceq '[REDACTED] [REDACTED]') 'different equal-length secrets are independently redacted'
    $timeoutFixture = Join-Path $script:testRoot 'native-timeout.ps1'
    Write-Fixture $timeoutFixture 'Start-Sleep -Seconds 30'
    Reject { & $script:originalRunner -Executable $pwsh -Arguments @('-NoProfile', '-File', $timeoutFixture) -WorkingDirectory $script:testRoot -TimeoutSeconds 1 } 'bounded process execution' 'bounded stage timeout'

    $fakeFlutterRoot = Join-Path $script:testRoot 'flutter'
    Write-Fixture (Join-Path $fakeFlutterRoot 'bin/flutter.bat') '@echo synthetic compiler stub'
    foreach ($name in @('sdk', 'jdk', 'gradle', 'pub-cache')) { [void][IO.Directory]::CreateDirectory((Join-Path $script:testRoot $name)) }
    $buildArguments = @{
        RepositoryRoot = $script:fixtureRepository; Revision = $script:fixtureRevision
        FlutterRoot = $fakeFlutterRoot; SdkRoot = (Join-Path $script:testRoot 'sdk')
        JavaHome = (Join-Path $script:testRoot 'jdk'); GradleHome = (Join-Path $script:testRoot 'gradle')
        PubCache = (Join-Path $script:testRoot 'pub-cache'); SigningConfiguration = $script:fixtureConfiguration
    }
    foreach ($name in @('JAVA_HOME', 'ANDROID_HOME', 'ANDROID_SDK_ROOT', 'GRADLE_USER_HOME', 'PUB_CACHE', 'TEMP', 'TMP', 'GRADLE_OPTS', 'USTC_ANDROID_KEYSTORE', 'USTC_ANDROID_KEY_ALIAS', 'USTC_ANDROID_STORE_PASSWORD', 'USTC_ANDROID_KEY_PASSWORD')) {
        $script:fixtureEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, ('SYNTHETIC-previous-' + $name), 'Process')
    }
    Install-BuildProcessFixture
    $missingSigningArguments = $buildArguments.Clone()
    $missingSigningArguments.SigningConfiguration = Join-Path $script:testRoot 'missing.json'
    Reject { Invoke-PublicReleaseBuild @missingSigningArguments -Platform Android } 'missing' 'missing production signing gate'
    Check ($script:observedCalls.Count -eq 0) 'missing signing fails before pub, assets or compilation'
    $script:failOperation = 'Signed Android release build'
    Reject { Invoke-PublicReleaseBuild @buildArguments -Platform Android } 'Synthetic build failure' 'Android process failure'
    Check (@(Get-FixtureReports).Count -eq 0) 'failure creates no successful build report'
    foreach ($name in @('JAVA_HOME', 'TEMP', 'TMP', 'GRADLE_OPTS', 'USTC_ANDROID_STORE_PASSWORD', 'USTC_ANDROID_KEY_PASSWORD')) {
        Check ([Environment]::GetEnvironmentVariable($name, 'Process') -ceq ('SYNTHETIC-previous-' + $name)) ('failure restores process environment: ' + $name)
    }
    $script:failOperation = 'Android release runtime dependencies'
    Reject { Invoke-PublicReleaseBuild @buildArguments -Platform Android } 'Synthetic build failure' 'runtime dependency task failure'
    Check (@(Get-FixtureReports).Count -eq 0) 'dependency task failure creates no successful report'
    Check (@($script:observedCalls | Where-Object Operation -ceq 'Android candidate package').Count -eq 0) 'dependency task failure prevents Android packaging'
    $script:failOperation = 'Windows candidate package'
    Reject { Invoke-PublicReleaseBuild @missingSigningArguments -Platform Windows } 'Synthetic build failure' 'Windows packaging failure with no signing configuration'
    Check (@(Get-FixtureReports).Count -eq 0) 'a packaging failure creates no successful report'
    $script:failOperation = ''; $script:omitOutput = $true
    Reject { Invoke-PublicReleaseBuild @missingSigningArguments -Platform Windows } 'file is missing' 'package process success without its fixed output'
    Check (@(Get-FixtureReports).Count -eq 0) 'missing fixed output creates no successful report'
    $script:omitOutput = $false
    $script:failOperation = ''; $script:observedCalls.Clear()
    Write-Fixture (Join-Path $script:fixtureRepository 'app/android/local.properties') "sdk.dir=E:\\SyntheticSdk`nflutter.sdk=E:\\SyntheticFlutter`ncustom=value`n"
    Invoke-PublicReleaseBuild @buildArguments -Platform All | Out-Null
    $calls = $script:observedCalls.ToArray()
    Check ($calls.Count -eq 7) 'All runs pub, asset check, two builds, dependency report and two package stages only'
    $pub = @($calls | Where-Object Operation -ceq 'Offline dependency preparation')[0]
    Check (($pub.Arguments -join ' ') -ceq 'pub get --offline --enforce-lockfile') 'dependency preparation stays offline and lockfile-bound'
    $windows = @($calls | Where-Object Operation -ceq 'Windows release build')[0]
    Check (($windows.Arguments -join ' ') -ceq ('build windows --release --no-pub --target lib/main.dart --dart-define=USTC_BUILD_REVISION=' + $script:fixtureRevision)) 'Windows uses the ordinary release entry with exact revision'
    $android = @($calls | Where-Object Operation -ceq 'Signed Android release build')[0]
    Check (($android.Arguments -join ' ') -ceq ('build apk --release --no-pub --target lib/main.dart --target-platform android-arm64,android-x64 --split-per-abi --build-name=1.0.0 --build-number=1 --dart-define=USTC_BUILD_REVISION=' + $script:fixtureRevision)) 'Android uses only the approved two ABI ordinary-entry release arguments'
    Check ($android.SigningMatches -and @($calls | Where-Object { $_.SigningPresent -and $_.Operation -cne 'Signed Android release build' }).Count -eq 0) 'signing environment exists only during Android compilation'
    Check ($android.GradleOptions.Contains('-Dorg.gradle.daemon=false') -and $android.GradleOptions.Contains('-Dorg.gradle.configuration-cache=false')) 'Gradle daemon and configuration cache are disabled'
    Check ($android.Temp -ceq (Join-Path $script:fixtureRepository 'app/build/release-preparation/temp')) 'temporary files stay in the source-relative non-system build directory'
    $dependencies = @($calls | Where-Object Operation -ceq 'Android release runtime dependencies')[0]
    Check ($dependencies.Executable -ceq (Join-Path $script:fixtureRepository 'app/android/gradlew.bat') -and $dependencies.WorkingDirectory -ceq (Join-Path $script:fixtureRepository 'app/android')) 'dependency task uses only the source Gradle wrapper and Android directory'
    Check (($dependencies.Arguments -join ' ') -ceq '--no-daemon --no-configuration-cache :app:dependencies --configuration releaseRuntimeClasspath') 'dependency task pins the release configuration and disables daemon and configuration cache'
    Check ($dependencies.SigningEnvironmentCleared) 'all four signing environment variables are cleared before dependency inspection'
    Check ([Array]::IndexOf($calls, $dependencies) -gt [Array]::IndexOf($calls, $android)) 'dependency inspection follows the signed release build'
    $packageAndroid = @($calls | Where-Object Operation -ceq 'Android candidate package')[0]
    Check (($packageAndroid.Arguments -join ' ').Contains('-CertificateSha256 ' + $script:fixtureCertificateSha256) -and ($packageAndroid.Arguments -join ' ').Contains('-ExpectedArm64VersionCode 2001 -ExpectedX64VersionCode 4001')) 'Android package verification receives public certificate and exact ABI version codes'
    $properties = [IO.File]::ReadAllText((Join-Path $script:fixtureRepository 'app/android/local.properties'))
    Check ($properties.Contains('sdk.dir=E\:') -and $properties.Contains('flutter.sdk=E\:') -and $properties.Contains('custom=value')) 'only ignored generated drive-colon properties are repaired'
    $reports = @(Get-FixtureReports)
    Check ($reports.Count -eq 1) 'complete success creates one report'
    $reportText = [IO.File]::ReadAllText($reports[0].FullName)
    $report = $reportText | ConvertFrom-Json
    Check ($report.published -eq $false -and $report.sourceClean -eq $true -and $report.sourceRevision -ceq $script:fixtureRevision -and $report.outputs.Count -eq 3) 'report binds all three unpublished candidate artifacts to clean HEAD'
    Check ($report.androidRuntimeDependencies.configuration -ceq 'releaseRuntimeClasspath' -and $report.androidRuntimeDependencies.path -cmatch '^app/build/release-preparation/logs/[0-9a-f]{32}/06-android-release-runtime-dependencies\.txt$') 'successful build report identifies the fixed dependency report by repository-relative path'
    $dependencyReport = Join-Path $script:fixtureRepository $report.androidRuntimeDependencies.path
    Check ($report.androidRuntimeDependencies.sha256 -ceq (Get-FileHash -LiteralPath $dependencyReport -Algorithm SHA256).Hash.ToLowerInvariant() -and $report.androidRuntimeDependencies.bytes -eq (Get-Item -LiteralPath $dependencyReport).Length) 'dependency report digest and length match its actual redacted file'
    Check ([IO.File]::ReadAllText($dependencyReport).Contains('synthetic.example:fixture:1.2.3')) 'dependency report records the synthetic resolved version evidence'
    Check (@($report.stages | Where-Object { $_.name -ceq 'android-release-runtime-dependencies' -and $_.status -ceq 'passed' }).Count -eq 1) 'dependency inspection is a required successful build stage'
    Check (-not $reportText.Contains($script:syntheticPassword) -and -not $reportText.Contains($script:protectedSyntheticPassword) -and -not $reportText.Contains($script:fixtureKeystore)) 'report contains no plaintext, protected password or private signing location'
    foreach ($name in @('JAVA_HOME', 'ANDROID_HOME', 'ANDROID_SDK_ROOT', 'GRADLE_USER_HOME', 'PUB_CACHE', 'TEMP', 'TMP', 'GRADLE_OPTS', 'USTC_ANDROID_KEYSTORE', 'USTC_ANDROID_KEY_ALIAS', 'USTC_ANDROID_STORE_PASSWORD', 'USTC_ANDROID_KEY_PASSWORD')) {
        Check ([Environment]::GetEnvironmentVariable($name, 'Process') -ceq ('SYNTHETIC-previous-' + $name)) ('success restores process environment: ' + $name)
    }
    Reject { Invoke-PublicReleaseBuild @buildArguments -Platform All } 'already exists' 'candidate overwrite'
    Check (@(Get-FixtureReports).Count -eq 1) 'refused overwrite adds no success report'
    Write-Fixture (Join-Path $script:fixtureRepository 'windows-only-fixture.txt') 'Synthetic Windows build without Android tooling.'
    [void](Run-FixtureGit -Arguments @('add', '--all'))
    [void](Run-FixtureGit -Arguments @('-c', 'user.name=Synthetic Fixture', '-c', 'user.email=synthetic@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '--quiet', '-m', 'Synthetic Windows-only fixture'))
    $script:fixtureRevision = (Run-FixtureGit -Arguments @('rev-parse', 'HEAD')).Stdout.Trim()
    $windowsArguments = $buildArguments.Clone()
    $windowsArguments.Revision = $script:fixtureRevision
    $windowsArguments.SdkRoot = Join-Path $script:testRoot 'absent-sdk'
    $windowsArguments.JavaHome = Join-Path $script:testRoot 'absent-jdk'
    $windowsArguments.GradleHome = Join-Path $script:testRoot 'absent-gradle'
    $windowsArguments.SigningConfiguration = Join-Path $script:testRoot 'absent-signing.json'
    $script:observedCalls.Clear()
    Invoke-PublicReleaseBuild @windowsArguments -Platform Windows | Out-Null
    $windowsCalls = $script:observedCalls.ToArray()
    Check ($windowsCalls.Count -eq 4) 'Windows succeeds through pub, assets, build and package with no Android-specific stage'
    Check (-not (Test-Path -LiteralPath $windowsArguments.SdkRoot) -and -not (Test-Path -LiteralPath $windowsArguments.JavaHome) -and -not (Test-Path -LiteralPath $windowsArguments.GradleHome) -and -not (Test-Path -LiteralPath $windowsArguments.SigningConfiguration)) 'Windows never creates or reads its absent Android tool or signing inputs'
    Check (@($windowsCalls | Where-Object { -not $_.SigningEnvironmentCleared }).Count -eq 0) 'Windows clears all signing environment variables before every child process'
    foreach ($call in $windowsCalls) {
        Check ($call.JavaHome -ceq 'SYNTHETIC-previous-JAVA_HOME' -and $call.AndroidHome -ceq 'SYNTHETIC-previous-ANDROID_HOME' -and $call.AndroidSdkRoot -ceq 'SYNTHETIC-previous-ANDROID_SDK_ROOT' -and $call.GradleUserHome -ceq 'SYNTHETIC-previous-GRADLE_USER_HOME' -and $call.GradleOptions -ceq 'SYNTHETIC-previous-GRADLE_OPTS') 'Windows preserves the existing Java, Android and Gradle environment during execution'
        Check ($call.PubCache -ceq $windowsArguments.PubCache -and $call.Temp -ceq (Join-Path $script:fixtureRepository 'app/build/release-preparation/temp')) 'Windows still controls its configured Pub cache and temporary directory'
    }
    $windowsReports = @(Get-FixtureReports | ForEach-Object { [IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json } | Where-Object platform -ceq 'Windows')
    Check ($windowsReports.Count -eq 1 -and $windowsReports[0].outputs.Count -eq 1 -and $null -eq $windowsReports[0].androidCertificateSha256 -and $null -eq $windowsReports[0].androidRuntimeDependencies) 'Windows success reports only its ZIP without Android signing or dependency evidence'
    Check (@(Get-FixtureReports).Count -eq 2) 'Windows success preserves the earlier All build report'
    $allLogs = @(Get-ChildItem -LiteralPath (Join-Path $script:fixtureRepository 'app/build/release-preparation/logs') -File -Recurse)
    foreach ($log in $allLogs) { Check (-not [IO.File]::ReadAllText($log.FullName).Contains($script:syntheticPassword)) 'synthetic stage logs contain no password' }
    Write-Output "PASS: $script:checks synthetic public-release build checks; no real signing configuration or compiler was used."
} catch {
    Write-Host ("Synthetic release-builder check failed after $script:checks checks. " + $_.ScriptStackTrace)
    throw
} finally {
    Set-Item -LiteralPath Function:\Invoke-PublicReleaseProcess -Value $script:originalRunner
    foreach ($name in $script:fixtureEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $script:fixtureEnvironment[$name], 'Process') }
    if ($script:junction -and (Test-Path -LiteralPath $script:junction)) { [IO.Directory]::Delete($script:junction) }
    if ($script:rootCreated -and (Test-Path -LiteralPath $script:testRoot)) {
        $resolved = Resolve-PublicReleaseLocalPath $script:testRoot -RequireDirectory -OutsideGit
        if ($resolved -notmatch '^E:\\codex-public-release-build-test-[0-9a-f]{32}$') { throw 'Refusing cleanup outside the exact synthetic E-drive root.' }
        foreach ($item in @(Get-ChildItem -LiteralPath $resolved -Force -Recurse)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing recursive cleanup through a reparse point.' }
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
    $script:syntheticPassword = $null; $script:protectedSyntheticPassword = $null
    $script:fixtureEnvironment.Clear()
}
