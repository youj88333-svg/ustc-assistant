[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# H1 synthetic-only probe for the approved maintenance handoff algorithm.
# Design basis: docs/README.md; docs/architecture/07-constitution.md;
# docs/architecture/09-contracts.md (K-04/K-06); docs/architecture/12-cross-cutting.md;
# docs/quality/13-risks-and-acceptance.md; docs/workflow.md; and
# docs/milestones/maintenance-handoff/plan.md (H1).
# This script creates a fresh Git fixture only under app/build, never contacts
# a remote, never reads the real E:\107 repository or another worktree, and
# removes only its own GUID root after validating that cleanup boundary.

$script:WorkspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:BuildRoot = Join-Path $script:WorkspaceRoot 'app/build'
$script:TempRoot = $null
$script:TempRootCreated = $false

function Get-FullPath {
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
}

function Test-PathPrefix {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    $normalizedPath = Get-FullPath $Path
    $normalizedRoot = Get-FullPath $Root
    $prefix = $normalizedRoot + [System.IO.Path]::DirectorySeparatorChar
    return $normalizedPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoReparseFromWorkspace {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = Get-FullPath $Path
    $workspace = Get-FullPath $script:WorkspaceRoot
    if (-not ($fullPath.Equals($workspace, [System.StringComparison]::OrdinalIgnoreCase) -or (Test-PathPrefix -Path $fullPath -Root $workspace))) {
        throw "Path is outside this checkout: $fullPath"
    }

    $relative = [System.IO.Path]::GetRelativePath($workspace, $fullPath)
    $cursor = $workspace
    $segments = @()
    if ($relative -ne '.') {
        $segments = @($relative -split '[\\/]')
    }

    $candidates = @($workspace)
    foreach ($segment in $segments) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.') {
            continue
        }
        $cursor = Join-Path $cursor $segment
        $candidates += $cursor
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            $item = Get-Item -LiteralPath $candidate -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing a path with a reparse-point ancestor: $candidate"
            }
        }
    }
}

function Assert-InTempRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowRoot
    )

    if ([string]::IsNullOrWhiteSpace($script:TempRoot)) {
        throw 'The synthetic GUID root has not been initialized.'
    }

    $fullPath = Get-FullPath $Path
    $root = Get-FullPath $script:TempRoot
    if ($fullPath.Equals($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        if ($AllowRoot) {
            Assert-NoReparseFromWorkspace $fullPath
            return
        }
        throw "Path must be strictly inside the synthetic GUID root: $fullPath"
    }

    if (-not (Test-PathPrefix -Path $fullPath -Root $root)) {
        throw "Path escapes the synthetic GUID root: $fullPath"
    }
    Assert-NoReparseFromWorkspace $fullPath
}

function Assert-NoReparseTree {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowRoot
    )

    Assert-InTempRoot -Path $Path -AllowRoot:$AllowRoot
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Expected a directory for the bounded recursive operation: $Path"
    }
    foreach ($item in Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction Stop) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing a recursive operation over a tree containing a reparse point: $($item.FullName)"
        }
    }
}

function Invoke-GitRaw {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    Assert-InTempRoot $Directory
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw "Git working directory does not exist: $Directory"
    }
    $output = @(& git -C $Directory @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $output
    }
}

function Invoke-Git {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $result = Invoke-GitRaw -Directory $Directory -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        $detail = [string]::Join("`n", [string[]]$result.Output)
        throw "git -C `"$Directory`" $($Arguments -join ' ') failed with exit $($result.ExitCode).`n$detail"
    }
    return [string[]]$result.Output
}

function Assert-GitFailure {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Reason
    )

    $result = Invoke-GitRaw -Directory $Directory -Arguments $Arguments
    if ($result.ExitCode -eq 0) {
        throw "Expected Git to reject $Reason, but it exited successfully: $($Arguments -join ' ')"
    }
    $detail = [string]::Join("`n", [string[]]$result.Output)
    Write-Output "EXPECTED REJECTION ($Reason): exit $($result.ExitCode) $detail"
}

function Assert-OperationRejected {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$ExpectedMessage,
        [Parameter(Mandatory)][string]$Reason
    )

    $rejected = $false
    $message = ''
    try {
        & $Action
    }
    catch {
        $rejected = $true
        $message = $_.Exception.Message
    }
    if (-not $rejected) {
        throw "Expected the operation to reject $Reason, but it completed."
    }
    if (-not $message.Contains($ExpectedMessage, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "The operation rejected $Reason for an unexpected reason: $message"
    }
    Write-Output "EXPECTED REJECTION ($Reason): $message"
}

function Assert-SequenceEqual {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Expected,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Actual,
        [Parameter(Mandatory)][string]$Description
    )

    $expectedJson = ConvertTo-Json -InputObject @($Expected) -Compress -Depth 8
    $actualJson = ConvertTo-Json -InputObject @($Actual) -Compress -Depth 8
    if ($expectedJson -cne $actualJson) {
        throw "$Description mismatch. Expected $expectedJson; got $actualJson"
    }
}

function Assert-MapEqual {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Expected,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Actual,
        [Parameter(Mandatory)][string]$Description
    )

    $expectedKeys = @($Expected.Keys | Sort-Object)
    $actualKeys = @($Actual.Keys | Sort-Object)
    Assert-SequenceEqual -Expected $expectedKeys -Actual $actualKeys -Description "$Description keys"
    foreach ($key in $expectedKeys) {
        if ([string]$Expected[$key] -cne [string]$Actual[$key]) {
            throw "$Description mismatch at '$key': expected '$($Expected[$key])', got '$($Actual[$key])'."
        }
    }
}

function Get-StatusMap {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string[]]$Paths
    )

    $arguments = @('status', '--porcelain=v1', '--untracked-files=all', '--ignored=matching', '--') + $Paths
    $lines = @(Invoke-Git -Directory $Directory -Arguments $arguments)
    $map = @{}
    foreach ($line in $lines) {
        if ($line.Length -lt 4) {
            throw "Unexpected short porcelain status row: '$line'"
        }
        $code = $line.Substring(0, 2)
        $path = $line.Substring(3)
        if ($map.ContainsKey($path)) {
            throw "Duplicate porcelain status path: $path"
        }
        $map[$path] = $code
    }
    return $map
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    Assert-InTempRoot $Path
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-PathSnapshot {
    param([Parameter(Mandatory)][string]$Path)

    Assert-InTempRoot $Path
    $root = Get-FullPath $Path
    $item = Get-Item -LiteralPath $root -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to snapshot a reparse point: $root"
    }
    if (-not $item.PSIsContainer) {
        return ,@("F|$($item.Name)|$(Get-FileSha256 $root)")
    }

    $rows = @('D|.')
    $children = @(Get-ChildItem -LiteralPath $root -Force -Recurse -ErrorAction Stop | Sort-Object FullName)
    foreach ($child in $children) {
        if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to snapshot a tree containing a reparse point: $($child.FullName)"
        }
        $relative = [System.IO.Path]::GetRelativePath($root, $child.FullName).Replace('\', '/')
        if ($relative -eq '.git') {
            continue
        }
        if ($child.PSIsContainer) {
            $rows += "D|$relative"
        }
        else {
            $rows += "F|$relative|$(Get-FileSha256 $child.FullName)"
        }
    }
    return ,([string[]]$rows)
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )

    Assert-InTempRoot $Path
    $parent = Split-Path -Parent $Path
    Assert-InTempRoot $parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Assert-DestinationAbsent {
    param([Parameter(Mandatory)][string]$Destination)

    Assert-InTempRoot $Destination
    if (Test-Path -LiteralPath $Destination) {
        throw "Destination already exists; refusing to overwrite or nest into it: $Destination"
    }
}

function Move-ExactPath {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    Assert-InTempRoot $Source
    Assert-InTempRoot $Destination
    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Move source does not exist: $Source"
    }
    Assert-DestinationAbsent $Destination
    Move-Item -LiteralPath $Source -Destination $Destination -ErrorAction Stop
}

function Get-CanonicalGitCommonDir {
    param([Parameter(Mandatory)][string]$Directory)

    $value = @(Invoke-Git -Directory $Directory -Arguments @('rev-parse', '--path-format=absolute', '--git-common-dir'))
    if ($value.Count -ne 1) {
        throw "Expected one git-common-dir result for $Directory; got $($value.Count)."
    }
    return Get-FullPath $value[0]
}

function Assert-WorktreePointer {
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][string]$ExpectedCommonDir
    )

    Assert-InTempRoot $WorktreePath
    $pointer = Join-Path $WorktreePath '.git'
    if (-not (Test-Path -LiteralPath $pointer -PathType Leaf)) {
        throw "Expected a linked worktree .git file: $pointer"
    }
    $line = (Get-Content -LiteralPath $pointer -Raw).Trim()
    if (-not $line.StartsWith('gitdir: ', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Malformed linked-worktree pointer at ${pointer}: $line"
    }
    $targetText = $line.Substring(8)
    $target = if ([System.IO.Path]::IsPathRooted($targetText)) { $targetText } else { Join-Path $WorktreePath $targetText }
    $target = Get-FullPath $target
    $expectedRoot = Get-FullPath (Join-Path $ExpectedCommonDir 'worktrees')
    if (-not (Test-PathPrefix -Path $target -Root $expectedRoot)) {
        throw "Linked-worktree pointer escapes the common Git metadata: $pointer -> $target"
    }
    if (-not (Test-Path -LiteralPath $target -PathType Container)) {
        throw "Linked-worktree administrative directory is missing: $target"
    }
}

function Assert-PathInsideGitRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$GitRoot
    )

    $fullPath = Get-FullPath $Path
    $root = Get-FullPath $GitRoot
    if (-not (Test-PathPrefix -Path $fullPath -Root $root)) {
        throw "Path is not strictly inside the tested Git root: $fullPath"
    }
}

function Assert-RefAncestor {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Ancestor,
        [Parameter(Mandatory)][string]$Descendant,
        [Parameter(Mandatory)][string]$Description
    )

    $result = Invoke-GitRaw -Directory $Directory -Arguments @('merge-base', '--is-ancestor', $Ancestor, $Descendant)
    if ($result.ExitCode -ne 0) {
        throw "Expected $Description to be an ancestor; git merge-base exited $($result.ExitCode): $([string]::Join("`n", [string[]]$result.Output))"
    }
}

try {
    if (-not (Test-Path -LiteralPath $script:WorkspaceRoot -PathType Container)) {
        throw "Workspace root is unavailable: $script:WorkspaceRoot"
    }
    Assert-NoReparseFromWorkspace $script:BuildRoot
    if (-not (Test-Path -LiteralPath $script:BuildRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $script:BuildRoot | Out-Null
    }

    $guid = [Guid]::NewGuid().ToString('N')
    $script:TempRoot = Join-Path $script:BuildRoot "_maintenance-layout-$guid"
    Assert-InTempRoot -Path $script:TempRoot -AllowRoot
    if (Test-Path -LiteralPath $script:TempRoot) {
        throw "Fresh GUID test root unexpectedly exists: $script:TempRoot"
    }
    New-Item -ItemType Directory -Path $script:TempRoot -ErrorAction Stop | Out-Null
    $script:TempRootCreated = $true

    $boundaryRoot = Join-Path $script:TempRoot 'boundary-probes'
    New-Item -ItemType Directory -Path $boundaryRoot -ErrorAction Stop | Out-Null
    $collisionSource = Join-Path $boundaryRoot 'source.txt'
    $collisionDestination = Join-Path $boundaryRoot 'destination.txt'
    Write-Utf8File -Path $collisionSource -Content "source must remain intact`n"
    Write-Utf8File -Path $collisionDestination -Content "destination must not be overwritten`n"
    $sourceHashBeforeCollision = Get-FileSha256 $collisionSource
    $destinationHashBeforeCollision = Get-FileSha256 $collisionDestination
    Assert-OperationRejected -Action { Move-ExactPath -Source $collisionSource -Destination $collisionDestination } -ExpectedMessage 'Destination already exists' -Reason 'an existing destination'
    if ((Get-FileSha256 $collisionSource) -cne $sourceHashBeforeCollision -or (Get-FileSha256 $collisionDestination) -cne $destinationHashBeforeCollision) {
        throw 'Existing-destination rejection changed the source or destination content.'
    }
    $outsideProbe = Join-Path $script:WorkspaceRoot 'app'
    Assert-OperationRejected -Action { Assert-InTempRoot -Path $outsideProbe } -ExpectedMessage 'Path escapes the synthetic GUID root' -Reason 'a path outside the GUID root'
    Write-Output 'PASS existing destination was not overwritten; out-of-root path was rejected'

    $container = Join-Path $script:TempRoot 'container'
    $main = Join-Path $container 'main'
    $archiveRoot = Join-Path $container 'archive'
    $finalWorktreesRoot = Join-Path $container 'worktrees'
    $abandonedPath = Join-Path $container '.worktrees/abandoned'
    $rewritePath = Join-Path $container '.worktrees/rewrite'
    $archiveCompetition = Join-Path $archiveRoot 'competition'
    $archiveAbandoned = Join-Path $archiveRoot 'abandoned'
    $rewriteFinal = Join-Path $finalWorktreesRoot 'rewrite'
    $hooksRoot = Join-Path $script:TempRoot 'empty-hooks'

    foreach ($directory in @($container, $main, $archiveRoot, $finalWorktreesRoot, (Join-Path $container 'backups'), (Join-Path $container 'releases'), (Join-Path $container '.worktrees'), $hooksRoot)) {
        Assert-InTempRoot $directory
        New-Item -ItemType Directory -Path $directory -ErrorAction Stop | Out-Null
    }

    $init = Invoke-GitRaw -Directory $container -Arguments @('init', '--initial-branch=main')
    if ($init.ExitCode -ne 0) {
        throw "Synthetic git init failed with exit $($init.ExitCode): $([string]::Join("`n", [string[]]$init.Output))"
    }
    Invoke-Git -Directory $container -Arguments @('config', 'user.name', 'Synthetic Maintenance Handoff') | Out-Null
    Invoke-Git -Directory $container -Arguments @('config', 'user.email', 'synthetic-maintenance@example.invalid') | Out-Null
    Invoke-Git -Directory $container -Arguments @('config', 'core.hooksPath', $hooksRoot) | Out-Null
    Invoke-Git -Directory $container -Arguments @('config', 'commit.gpgsign', 'false') | Out-Null
    Invoke-Git -Directory $container -Arguments @('config', 'core.autocrlf', 'false') | Out-Null

    Write-Utf8File -Path (Join-Path $container '.gitignore') -Content "/ignored.txt`n/.worktrees/`n/main/`n/archive/`n/worktrees/`n/backups/`n/releases/`n"
    Write-Utf8File -Path (Join-Path $container 'tracked.txt') -Content "old-main baseline`n"
    Write-Utf8File -Path (Join-Path $container 'legacy-assets/notes.txt') -Content "synthetic old top-level directory`n"
    Invoke-Git -Directory $container -Arguments @('add', '--', '.gitignore', 'tracked.txt', 'legacy-assets/notes.txt') | Out-Null
    Invoke-Git -Directory $container -Arguments @('commit', '-m', 'Synthetic old main baseline') | Out-Null
    $oldMainCommit = @(Invoke-Git -Directory $container -Arguments @('rev-parse', 'refs/heads/main'))[0].Trim()

    Invoke-Git -Directory $container -Arguments @('branch', 'abandoned', 'refs/heads/main') | Out-Null
    Invoke-Git -Directory $container -Arguments @('worktree', 'add', $abandonedPath, 'abandoned') | Out-Null
    Write-Utf8File -Path (Join-Path $abandonedPath 'abandoned-only.txt') -Content "abandoned branch committed payload`n"
    Invoke-Git -Directory $abandonedPath -Arguments @('add', '--', 'abandoned-only.txt') | Out-Null
    Invoke-Git -Directory $abandonedPath -Arguments @('commit', '-m', 'Synthetic abandoned branch') | Out-Null
    Write-Utf8File -Path (Join-Path $abandonedPath 'abandoned-only.txt') -Content "dirty abandoned branch modification`n"
    Write-Utf8File -Path (Join-Path $abandonedPath 'abandoned-untracked.txt') -Content "dirty abandoned branch untracked sentinel`n"
    $abandonedCommitBefore = @(Invoke-Git -Directory $abandonedPath -Arguments @('rev-parse', 'HEAD'))[0].Trim()
    $abandonedStatusBefore = Get-StatusMap -Directory $abandonedPath -Paths @('abandoned-only.txt', 'abandoned-untracked.txt')
    Assert-MapEqual -Expected @{ 'abandoned-only.txt' = ' M'; 'abandoned-untracked.txt' = '??' } -Actual $abandonedStatusBefore -Description 'Abandoned linked worktree status before relocation'
    $abandonedSnapshotBefore = Get-PathSnapshot -Path $abandonedPath

    Invoke-Git -Directory $container -Arguments @('worktree', 'add', '--detach', $rewritePath, 'refs/heads/main') | Out-Null
    Write-Utf8File -Path (Join-Path $rewritePath 'synthetic-orphan-scrap.txt') -Content "must be cleared with the rewrite worktree only`n"
    Invoke-Git -Directory $rewritePath -Arguments @('switch', '--orphan', 'rewrite-root') | Out-Null
    Assert-NoReparseTree $rewritePath
    Invoke-Git -Directory $rewritePath -Arguments @('clean', '-fdx', '--', '.') | Out-Null
    foreach ($oldFile in @('tracked.txt', '.gitignore', 'legacy-assets/notes.txt', 'synthetic-orphan-scrap.txt')) {
        if (Test-Path -LiteralPath (Join-Path $rewritePath $oldFile)) {
            throw "The orphan rewrite worktree retained synthetic old content: $oldFile"
        }
    }
    Write-Utf8File -Path (Join-Path $rewritePath 'README.md') -Content "synthetic rewritten project root`n"
    Write-Utf8File -Path (Join-Path $rewritePath 'rewrite-payload.txt') -Content "new main tree sentinel`n"
    Invoke-Git -Directory $rewritePath -Arguments @('add', '--all') | Out-Null
    Invoke-Git -Directory $rewritePath -Arguments @('commit', '-m', 'Synthetic independent rewrite root') | Out-Null
    $rewriteHead = @(Invoke-Git -Directory $rewritePath -Arguments @('rev-parse', 'HEAD'))[0].Trim()
    $rewriteTree = @(Invoke-Git -Directory $rewritePath -Arguments @('rev-parse', 'HEAD^{tree}'))[0].Trim()
    $rewriteParents = @((@(Invoke-Git -Directory $rewritePath -Arguments @('rev-list', '--parents', '-n', '1', 'HEAD'))[0]).Trim() -split ' ')
    if ($rewriteParents.Count -ne 1) {
        throw "Expected the rewrite history to be an independent root; got parents $($rewriteParents -join ', ')."
    }
    $rewriteStatusBefore = Get-StatusMap -Directory $rewritePath -Paths @('README.md', 'rewrite-payload.txt')
    Assert-MapEqual -Expected @{} -Actual $rewriteStatusBefore -Description 'Rewrite linked worktree status before relocation'
    $rewritePayloadBefore = @{
        'README.md'           = Get-FileSha256 (Join-Path $rewritePath 'README.md')
        'rewrite-payload.txt' = Get-FileSha256 (Join-Path $rewritePath 'rewrite-payload.txt')
    }

    Write-Utf8File -Path (Join-Path $container 'tracked.txt') -Content "dirty old main tracked modification`n"
    Write-Utf8File -Path (Join-Path $container 'untracked.txt') -Content "old main untracked sentinel`n"
    Write-Utf8File -Path (Join-Path $container 'ignored.txt') -Content "old main ignored sentinel`n"
    $mainStatusBefore = Get-StatusMap -Directory $container -Paths @('tracked.txt', 'untracked.txt', 'ignored.txt')
    $expectedMainStatus = @{ 'ignored.txt' = '!!'; 'tracked.txt' = ' M'; 'untracked.txt' = '??' }
    Assert-MapEqual -Expected $expectedMainStatus -Actual $mainStatusBefore -Description 'Dirty old main sentinel status before relocation'
    $mainSentinelHashes = @{
        '.gitignore' = Get-FileSha256 (Join-Path $container '.gitignore')
        'tracked.txt' = Get-FileSha256 (Join-Path $container 'tracked.txt')
        'untracked.txt' = Get-FileSha256 (Join-Path $container 'untracked.txt')
        'ignored.txt' = Get-FileSha256 (Join-Path $container 'ignored.txt')
    }

    $archiveAdd = Invoke-GitRaw -Directory $container -Arguments @('worktree', 'add', '--no-checkout', '-b', 'archive/competition', $archiveCompetition, 'refs/heads/main')
    if ($archiveAdd.ExitCode -ne 0) {
        throw "Could not pre-create archive/competition linked worktree: $([string]::Join("`n", [string[]]$archiveAdd.Output))"
    }
    Invoke-Git -Directory $archiveCompetition -Arguments @('read-tree', $oldMainCommit) | Out-Null

    $excludedRootEntries = @('.git', '.worktrees', 'main', 'archive', 'worktrees', 'backups', 'releases')
    $rootInventory = @(
        Get-ChildItem -LiteralPath $container -Force |
            Where-Object { $excludedRootEntries -notcontains $_.Name } |
            Sort-Object Name
    )
    $expectedInventory = @('.gitignore', 'ignored.txt', 'legacy-assets', 'tracked.txt', 'untracked.txt')
    Assert-SequenceEqual -Expected $expectedInventory -Actual @($rootInventory | ForEach-Object { $_.Name }) -Description 'Original container top-level inventory'
    $rootSnapshots = @{}
    $rootMovePairs = @()
    foreach ($entry in $rootInventory) {
        $source = Get-FullPath $entry.FullName
        if (-not (Get-FullPath (Split-Path -Parent $source)).Equals((Get-FullPath $container), [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Original top-level source is not an immediate child of the synthetic container: $source"
        }
        if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to move a synthetic root entry that is a reparse point: $source"
        }
        $destination = Join-Path $archiveCompetition $entry.Name
        Assert-DestinationAbsent $destination
        $rootSnapshots[$entry.Name] = Get-PathSnapshot $source
        $rootMovePairs += [pscustomobject]@{ Source = $source; Destination = $destination; Name = $entry.Name }
    }
    foreach ($pair in $rootMovePairs) {
        Move-ExactPath -Source $pair.Source -Destination $pair.Destination
        Assert-SequenceEqual -Expected $rootSnapshots[$pair.Name] -Actual (Get-PathSnapshot $pair.Destination) -Description "Moved content for $($pair.Name)"
    }

    $mainGitDir = Join-Path $main '.git'
    Move-ExactPath -Source (Join-Path $container '.git') -Destination $mainGitDir
    Invoke-Git -Directory $main -Arguments (@('worktree', 'repair', $archiveCompetition, $abandonedPath, $rewritePath)) | Out-Null

    $migrationCommitLines = @(Invoke-Git -Directory $main -Arguments @('commit-tree', $rewriteTree, '-p', $oldMainCommit, '-p', $rewriteHead, '-m', 'Synthetic maintenance migration'))
    if ($migrationCommitLines.Count -ne 1) {
        throw "Expected one migration commit id; got $($migrationCommitLines.Count)."
    }
    $migrationCommit = $migrationCommitLines[0].Trim()
    $migrationTree = @(Invoke-Git -Directory $main -Arguments @('rev-parse', "$migrationCommit^{tree}"))[0].Trim()
    if ($migrationTree -cne $rewriteTree) {
        throw "Migration tree $migrationTree differs from rewrite tree $rewriteTree."
    }
    $migrationParents = @((@(Invoke-Git -Directory $main -Arguments @('rev-list', '--parents', '-n', '1', $migrationCommit))[0]).Trim() -split ' ' | Select-Object -Skip 1)
    Assert-SequenceEqual -Expected @($oldMainCommit, $rewriteHead) -Actual $migrationParents -Description 'Migration commit parent order'

    Assert-GitFailure -Directory $main -Arguments @('update-ref', 'refs/heads/main', $migrationCommit, $rewriteHead) -Reason 'a stale compare-and-swap expectation'
    $mainRefBeforeRealCas = @(Invoke-Git -Directory $main -Arguments @('rev-parse', 'refs/heads/main'))[0].Trim()
    if ($mainRefBeforeRealCas -cne $oldMainCommit) {
        throw "Rejected stale CAS changed main unexpectedly: $mainRefBeforeRealCas"
    }
    Invoke-Git -Directory $main -Arguments @('update-ref', 'refs/heads/main', $migrationCommit, $oldMainCommit) | Out-Null
    Assert-RefAncestor -Directory $main -Ancestor $oldMainCommit -Descendant $migrationCommit -Description 'original main commit'
    Assert-RefAncestor -Directory $main -Ancestor $rewriteHead -Descendant $migrationCommit -Description 'rewrite commit'

    Invoke-Git -Directory $main -Arguments @('read-tree', $migrationCommit) | Out-Null
    Invoke-Git -Directory $main -Arguments @('checkout-index', '--all') | Out-Null
    $materializedTree = @(Invoke-Git -Directory $main -Arguments @('write-tree'))[0].Trim()
    if ($materializedTree -cne $rewriteTree) {
        throw "Materialized main index tree $materializedTree differs from rewrite tree $rewriteTree."
    }
    $mainStatusAfterMaterialize = @(Invoke-Git -Directory $main -Arguments @('status', '--porcelain=v1', '--untracked-files=all'))
    Assert-SequenceEqual -Expected @() -Actual $mainStatusAfterMaterialize -Description 'New main cleanliness after checkout-index'

    Move-ExactPath -Source $abandonedPath -Destination $archiveAbandoned
    Move-ExactPath -Source $rewritePath -Destination $rewriteFinal
    Invoke-Git -Directory $main -Arguments (@('worktree', 'repair', $archiveCompetition, $archiveAbandoned, $rewriteFinal)) | Out-Null

    $abandonedCommitAfter = @(Invoke-Git -Directory $archiveAbandoned -Arguments @('rev-parse', 'HEAD'))[0].Trim()
    if ($abandonedCommitAfter -cne $abandonedCommitBefore) {
        throw "Abandoned branch head changed across relocation: $abandonedCommitBefore -> $abandonedCommitAfter"
    }
    $abandonedStatusAfter = Get-StatusMap -Directory $archiveAbandoned -Paths @('abandoned-only.txt', 'abandoned-untracked.txt')
    Assert-MapEqual -Expected $abandonedStatusBefore -Actual $abandonedStatusAfter -Description 'Abandoned linked worktree status after relocation'
    Assert-SequenceEqual -Expected $abandonedSnapshotBefore -Actual (Get-PathSnapshot $archiveAbandoned) -Description 'Abandoned linked worktree content after relocation'

    $rewriteHeadAfter = @(Invoke-Git -Directory $rewriteFinal -Arguments @('rev-parse', 'HEAD'))[0].Trim()
    if ($rewriteHeadAfter -cne $rewriteHead) {
        throw "Rewrite worktree head changed across relocation: $rewriteHead -> $rewriteHeadAfter"
    }
    $rewriteStatusAfter = Get-StatusMap -Directory $rewriteFinal -Paths @('README.md', 'rewrite-payload.txt')
    Assert-MapEqual -Expected $rewriteStatusBefore -Actual $rewriteStatusAfter -Description 'Rewrite linked worktree status after relocation'
    foreach ($path in $rewritePayloadBefore.Keys) {
        $actualHash = Get-FileSha256 (Join-Path $rewriteFinal $path)
        if ($actualHash -cne $rewritePayloadBefore[$path]) {
            throw "Rewrite payload changed across relocation: $path"
        }
    }

    $archiveStatusAfter = Get-StatusMap -Directory $archiveCompetition -Paths @('tracked.txt', 'untracked.txt', 'ignored.txt')
    Assert-MapEqual -Expected $mainStatusBefore -Actual $archiveStatusAfter -Description 'Archived original main status'
    foreach ($path in $mainSentinelHashes.Keys) {
        $actualHash = Get-FileSha256 (Join-Path $archiveCompetition $path)
        if ($actualHash -cne $mainSentinelHashes[$path]) {
            throw "Archived original main content changed: $path"
        }
    }
    foreach ($name in $rootSnapshots.Keys) {
        Assert-SequenceEqual -Expected $rootSnapshots[$name] -Actual (Get-PathSnapshot (Join-Path $archiveCompetition $name)) -Description "Archived original root entry $name"
    }

    $mainHeadAfter = @(Invoke-Git -Directory $main -Arguments @('rev-parse', 'HEAD'))[0].Trim()
    $mainRefAfter = @(Invoke-Git -Directory $main -Arguments @('rev-parse', 'refs/heads/main'))[0].Trim()
    if ($mainHeadAfter -cne $migrationCommit -or $mainRefAfter -cne $migrationCommit) {
        throw "Main HEAD/ref do not point to the migration commit: HEAD=$mainHeadAfter ref=$mainRefAfter expected=$migrationCommit"
    }
    $mainHeadTreeAfter = @(Invoke-Git -Directory $main -Arguments @('rev-parse', 'HEAD^{tree}'))[0].Trim()
    if ($mainHeadTreeAfter -cne $rewriteTree) {
        throw "Final main tree $mainHeadTreeAfter differs from rewrite tree $rewriteTree."
    }
    $finalMainStatus = @(Invoke-Git -Directory $main -Arguments @('status', '--porcelain=v1', '--untracked-files=all'))
    Assert-SequenceEqual -Expected @() -Actual $finalMainStatus -Description 'Final main cleanliness'

    $expectedWorktrees = @($main, $archiveCompetition, $archiveAbandoned, $rewriteFinal | ForEach-Object { Get-FullPath $_ } | Sort-Object)
    $worktreeRows = @(Invoke-Git -Directory $main -Arguments @('worktree', 'list', '--porcelain'))
    $actualWorktrees = @($worktreeRows | Where-Object { $_.StartsWith('worktree ', [System.StringComparison]::Ordinal) } | ForEach-Object { Get-FullPath $_.Substring(9) } | Sort-Object)
    Assert-SequenceEqual -Expected $expectedWorktrees -Actual $actualWorktrees -Description 'Registered linked worktree paths'

    if (Test-Path -LiteralPath (Join-Path $container '.git')) {
        throw "The synthetic container still has a .git entry: $(Join-Path $container '.git')"
    }
    if (-not (Test-Path -LiteralPath $mainGitDir -PathType Container)) {
        throw "The main worktree does not own the shared .git directory: $mainGitDir"
    }
    if ((Get-Item -LiteralPath $mainGitDir -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "The shared main .git directory is a reparse point: $mainGitDir"
    }

    foreach ($worktree in @($archiveCompetition, $archiveAbandoned, $rewriteFinal)) {
        $commonDir = Get-CanonicalGitCommonDir $worktree
        if ($commonDir -cne (Get-FullPath $mainGitDir)) {
            throw "Git common dir diverged: $worktree -> $commonDir, expected $(Get-FullPath $mainGitDir)"
        }
        Assert-WorktreePointer -WorktreePath $worktree -ExpectedCommonDir $mainGitDir
        $topLevel = @(Invoke-Git -Directory $worktree -Arguments @('rev-parse', '--show-toplevel'))[0].Trim()
        if ((Get-FullPath $topLevel) -cne (Get-FullPath $worktree)) {
            throw "Git resolved an unexpected worktree root for ${worktree}: $topLevel"
        }
    }
    $mainCommonDir = Get-CanonicalGitCommonDir $main
    if ($mainCommonDir -cne (Get-FullPath $mainGitDir)) {
        throw "Primary worktree common dir is not main/.git: $mainCommonDir"
    }

    foreach ($directory in @($main, $archiveCompetition, $archiveAbandoned, $rewriteFinal, $finalWorktreesRoot, (Join-Path $container 'backups'), (Join-Path $container 'releases'))) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            throw "Expected final layout directory is missing: $directory"
        }
    }

    $fsck = @(Invoke-Git -Directory $main -Arguments @('fsck', '--full', '--no-reflogs', '--no-progress'))
    Write-Output "PASS git fsck --full --no-reflogs --no-progress ($($fsck.Count) output lines)"
    Write-Output "PASS stale CAS rejected; main advanced by compare-and-swap to $migrationCommit"
    Write-Output "PASS migration tree equals rewrite tree $rewriteTree; both original and rewrite commits are ancestors"
    Write-Output "PASS archive/competition preserved tracked, untracked, and ignored sentinels: $([string]::Join('; ', @($archiveStatusAfter.Keys | Sort-Object | ForEach-Object { "$($_)=$($archiveStatusAfter[$_])" })))"
    Write-Output "PASS abandoned linked state retained at $archiveAbandoned; rewrite linked retained at $rewriteFinal"
    Write-Output "PASS all four worktrees resolve the same common Git directory: $(Get-FullPath $mainGitDir)"
    Write-Output "PASS synthetic container has no .git; only the GUID fixture will be removed: $script:TempRoot"
}
finally {
    if ($script:TempRootCreated -and (Test-Path -LiteralPath $script:TempRoot)) {
        $resolvedRoot = Get-FullPath (Resolve-Path -LiteralPath $script:TempRoot).Path
        $expectedRoot = Get-FullPath $script:TempRoot
        if (-not $resolvedRoot.Equals($expectedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Cleanup root resolved somewhere unexpected: $resolvedRoot"
        }
        Assert-InTempRoot -Path $resolvedRoot -AllowRoot
        $parent = Get-FullPath (Split-Path -Parent $resolvedRoot)
        if ($parent -cne (Get-FullPath $script:BuildRoot)) {
            throw "Refusing cleanup because the GUID root is not a direct child of app/build: $resolvedRoot"
        }
        Assert-NoReparseTree -Path $resolvedRoot -AllowRoot
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force -ErrorAction Stop
        Write-Output "CLEANED only verified GUID root: $resolvedRoot"
    }
}
