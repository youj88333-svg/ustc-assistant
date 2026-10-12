[CmdletBinding()]
param(
    [string]$Root
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}

if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    [Console]::Error.WriteLine('[FAIL] workspace root does not exist')
    exit 1
}

$script:RootFull = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
$rootChars = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
$script:RootFull = $script:RootFull.TrimEnd($rootChars)
if ($script:RootFull.Length -eq 2 -and $script:RootFull[1] -eq ':') {
    $script:RootFull += [System.IO.Path]::DirectorySeparatorChar
}
$script:RootPrefix = $script:RootFull
if (-not $script:RootPrefix.EndsWith([string][System.IO.Path]::DirectorySeparatorChar)) {
    $script:RootPrefix += [System.IO.Path]::DirectorySeparatorChar
}
$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:PathComparison = [System.StringComparison]::OrdinalIgnoreCase
$script:LocalLinkCount = 0

function Get-RepoRelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full.Equals($script:RootFull, $script:PathComparison)) {
        return ''
    }
    if ($full.StartsWith($script:RootPrefix, $script:PathComparison)) {
        return $full.Substring($script:RootPrefix.Length).Replace('\', '/')
    }
    return $null
}

function Add-CheckFailure {
    param(
        [string]$Path,
        [int]$Line,
        [string]$Message
    )

    $location = $Path
    if ($Line -gt 0) {
        $location = '{0}:{1}' -f $Path, $Line
    }
    [void]$script:Failures.Add(('{0}: {1}' -f $location, $Message))
}

function Test-ExcludedDirectoryName {
    param([string]$Name)

    return $Name -match '^(?i:tmp|runtime|build)$'
}

function Add-MarkdownTree {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$RelativeDirectory,
        [Parameter(Mandatory = $true)][System.Collections.Generic.List[System.IO.FileInfo]]$Files,
        [switch]$ExcludeArchive
    )

    try {
        $children = @(Get-ChildItem -LiteralPath $Directory -Force -ErrorAction Stop)
    }
    catch {
        Add-CheckFailure -Path $RelativeDirectory -Line 0 -Message 'unable to enumerate Markdown files'
        return
    }

    foreach ($child in $children) {
        $relative = if ([string]::IsNullOrEmpty($RelativeDirectory)) {
            $child.Name
        }
        else {
            '{0}/{1}' -f $RelativeDirectory, $child.Name
        }

        if ($child.PSIsContainer) {
            if (Test-ExcludedDirectoryName -Name $child.Name) {
                continue
            }
            if ($ExcludeArchive -and $relative -ieq 'docs/archive') {
                continue
            }
            if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                Add-CheckFailure -Path $relative -Line 0 -Message 'refusing to follow a reparse point while scanning Markdown'
                continue
            }
            Add-MarkdownTree -Directory $child.FullName -RelativeDirectory $relative -Files $Files -ExcludeArchive:$ExcludeArchive
            continue
        }

        if ($child.Extension -ine '.md') {
            continue
        }
        if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Add-CheckFailure -Path $relative -Line 0 -Message 'refusing to read a reparse point as Markdown'
            continue
        }
        [void]$Files.Add($child)
    }
}

function Add-ExactMarkdownFile {
    param(
        [string]$RelativePath,
        [System.Collections.Generic.List[System.IO.FileInfo]]$Files
    )

    $full = Join-Path $script:RootFull ($RelativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        return
    }
    if (Test-PathContainsReparsePoint -Path $full) {
        Add-CheckFailure -Path $RelativePath -Line 0 -Message 'refusing to read through a reparse point as Markdown'
        return
    }
    $item = Get-Item -LiteralPath $full -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Add-CheckFailure -Path $RelativePath -Line 0 -Message 'refusing to read a reparse point as Markdown'
        return
    }
    [void]$Files.Add([System.IO.FileInfo]$item)
}

function Get-MaskedMarkdown {
    param([string]$Text)

    $lines = [System.Text.RegularExpressions.Regex]::Split($Text, "`r`n|`n|`r")
    $output = [System.Collections.Generic.List[string]]::new()
    $fenceCharacter = ''
    $fenceLength = 0

    foreach ($line in $lines) {
        if ([string]::IsNullOrEmpty($fenceCharacter)) {
            $opening = [System.Text.RegularExpressions.Regex]::Match($line, '^ {0,3}(?<fence>`{3,}|~{3,})')
            if ($opening.Success) {
                $fenceCharacter = $opening.Groups['fence'].Value.Substring(0, 1)
                $fenceLength = $opening.Groups['fence'].Value.Length
                [void]$output.Add('')
                continue
            }
            [void]$output.Add($line)
            continue
        }

        $closePattern = '^ {0,3}' + [System.Text.RegularExpressions.Regex]::Escape($fenceCharacter) + '{' + $fenceLength + ',}\s*$'
        [void]$output.Add('')
        if ([System.Text.RegularExpressions.Regex]::IsMatch($line, $closePattern)) {
            $fenceCharacter = ''
            $fenceLength = 0
        }
    }

    return [string]::Join("`n", $output.ToArray())
}

function Mask-InlineCode {
    param([string]$Text)

    $lines = [System.Text.RegularExpressions.Regex]::Split($Text, "`r`n|`n|`r")
    for ($index = 0; $index -lt $lines.Length; $index++) {
        if ($lines[$index].IndexOf('`') -lt 0) {
            continue
        }
        $lines[$index] = [System.Text.RegularExpressions.Regex]::Replace(
            $lines[$index],
            '(?<ticks>`+)(?<code>.*?)(\k<ticks>)',
            [System.Text.RegularExpressions.MatchEvaluator]{
                param($match)
                $value = $match.Value
                return [System.Text.RegularExpressions.Regex]::Replace($value, '[^\r\n]', ' ')
            }
        )
    }
    return [string]::Join("`n", $lines)
}

function Get-LineNumberAtOffset {
    param(
        [int]$Offset,
        [System.Collections.Generic.List[int]]$LineStarts
    )

    $low = 0
    $high = $LineStarts.Count - 1
    while ($low -le $high) {
        $middle = [int][Math]::Floor(($low + $high) / 2)
        if ($LineStarts[$middle] -le $Offset) {
            $low = $middle + 1
        }
        else {
            $high = $middle - 1
        }
    }
    return $high + 1
}

function Get-LineStarts {
    param([string]$Text)

    $starts = [System.Collections.Generic.List[int]]::new()
    [void]$starts.Add(0)
    for ($index = 0; $index -lt $Text.Length; $index++) {
        if ($Text[$index] -eq "`n") {
            [void]$starts.Add($index + 1)
        }
    }
    return ,$starts
}

function Get-InlineMarkdownLinks {
    param([string]$Text)

    $links = [System.Collections.Generic.List[object]]::new()
    $pattern = '(?<!\\)(?<image>!)?\[(?:\\.|[^\]\\])*\]\(\s*(?<destination><(?:\\.|[^>\\])*?>|(?:\\.|[^()\s]|(?:\([^()\s]*\)))*)' +
        '(?:\s+(?:"(?:\\.|[^"\\])*"|''(?:\\.|[^''\\])*''|\((?:\\.|[^)\\])*\)))?\s*\)'
    foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($Text, $pattern)) {
        $destination = $match.Groups['destination'].Value
        if ($destination.StartsWith('<') -and $destination.EndsWith('>')) {
            $destination = $destination.Substring(1, $destination.Length - 2)
        }
        [void]$links.Add([pscustomobject]@{
            Offset = $match.Index
            Destination = $destination
            IsImage = $match.Groups['image'].Success
        })
    }
    return ,$links
}

function ConvertTo-MarkdownSlug {
    param([string]$Heading)

    $value = [System.Text.RegularExpressions.Regex]::Replace($Heading, '!\[([^\]]*)\]\([^)]*\)', '$1')
    $value = [System.Text.RegularExpressions.Regex]::Replace($value, '\[([^\]]+)\]\([^)]*\)', '$1')
    $value = [System.Text.RegularExpressions.Regex]::Replace($value, '<[^>]*>', '')
    $value = [System.Net.WebUtility]::HtmlDecode($value)
    $value = $value.Replace('`', '')
    $value = $value.ToLowerInvariant()
    $value = [System.Text.RegularExpressions.Regex]::Replace($value, '\s+', '-')
    $value = [System.Text.RegularExpressions.Regex]::Replace($value, '[^\p{L}\p{N}\p{M}\p{Pc}-]', '')
    return $value.Trim('-')
}

function Get-DocumentAnchors {
    param(
        [string]$Path,
        [string]$Text,
        [switch]$CheckDuplicateAnchors
    )

    $anchors = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $masked = Get-MaskedMarkdown -Text $Text
    $inlineMasked = Mask-InlineCode -Text $masked
    $lines = [System.Text.RegularExpressions.Regex]::Split($masked, "`r`n|`n|`r")
    $usedSlugs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    for ($index = 0; $index -lt $lines.Length; $index++) {
        $atx = [System.Text.RegularExpressions.Regex]::Match($lines[$index], '^ {0,3}#{1,6}(?:\s+|$)(?<heading>.*)$')
        $heading = $null
        if ($atx.Success) {
            $heading = [System.Text.RegularExpressions.Regex]::Replace($atx.Groups['heading'].Value, '\s+#+\s*$', '')
        }
        elseif ($index + 1 -lt $lines.Length -and -not [string]::IsNullOrWhiteSpace($lines[$index]) -and [System.Text.RegularExpressions.Regex]::IsMatch($lines[$index + 1], '^ {0,3}(?:=+|-+)\s*$')) {
            $heading = $lines[$index]
        }

        if ($null -ne $heading) {
            $baseSlug = ConvertTo-MarkdownSlug -Heading $heading
            if (-not [string]::IsNullOrWhiteSpace($baseSlug)) {
                $candidate = $baseSlug
                $suffix = 0
                while (-not $usedSlugs.Add($candidate)) {
                    $suffix++
                    $candidate = '{0}-{1}' -f $baseSlug, $suffix
                }
                if (-not $anchors.Add($candidate)) {
                    if ($CheckDuplicateAnchors) {
                        Add-CheckFailure -Path $Path -Line ($index + 1) -Message 'duplicate generated heading anchor'
                    }
                }
            }
        }
    }

    $explicitPattern = '(?is)<a\b[^>]*\bid\s*=\s*(?:"(?<double>[^"]*)"|''(?<single>[^'']*)''|(?<plain>[^\s>]+))[^>]*>'
    $lineStarts = Get-LineStarts -Text $inlineMasked
    foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($inlineMasked, $explicitPattern)) {
        $id = if ($match.Groups['double'].Success) {
            $match.Groups['double'].Value
        }
        elseif ($match.Groups['single'].Success) {
            $match.Groups['single'].Value
        }
        else {
            $match.Groups['plain'].Value
        }
        if ([string]::IsNullOrWhiteSpace($id)) {
            continue
        }
        $lineNumber = Get-LineNumberAtOffset -Offset $match.Index -LineStarts $lineStarts
        if (-not $anchors.Add($id)) {
            if ($CheckDuplicateAnchors) {
                Add-CheckFailure -Path $Path -Line $lineNumber -Message 'duplicate anchor id'
            }
        }
    }

    return ,$anchors
}

function ConvertFrom-MarkdownDestination {
    param([string]$Destination)

    $value = [System.Net.WebUtility]::HtmlDecode($Destination)
    $builder = [System.Text.StringBuilder]::new()
    for ($index = 0; $index -lt $value.Length; $index++) {
        if ($value[$index] -eq '\' -and $index + 1 -lt $value.Length) {
            $index++
        }
        [void]$builder.Append($value[$index])
    }
    try {
        return [System.Uri]::UnescapeDataString($builder.ToString())
    }
    catch {
        return $builder.ToString()
    }
}

function Get-LinkTargetPath {
    param(
        [string]$Destination,
        [string]$SourcePath,
        [ref]$Fragment
    )

    $decoded = ConvertFrom-MarkdownDestination -Destination $Destination
    $fragmentValue = ''
    $hashIndex = $decoded.IndexOf('#')
    if ($hashIndex -ge 0) {
        $fragmentValue = $decoded.Substring($hashIndex + 1)
        $decoded = $decoded.Substring(0, $hashIndex)
    }
    $queryIndex = $decoded.IndexOf('?')
    if ($queryIndex -ge 0) {
        $decoded = $decoded.Substring(0, $queryIndex)
    }
    if ($fragmentValue -match '^(?<anchor>.*):\d+$') {
        $fragmentValue = $Matches['anchor']
    }
    $Fragment.Value = $fragmentValue

    if ([string]::IsNullOrEmpty($decoded)) {
        return [System.IO.Path]::GetFullPath($SourcePath)
    }

    if ($decoded -match '^[A-Za-z]:[\\/]') {
        $target = [System.IO.Path]::GetFullPath($decoded)
    }
    elseif ($decoded.StartsWith('/')) {
        $target = [System.IO.Path]::GetFullPath((Join-Path $script:RootFull $decoded.TrimStart('/')))
    }
    else {
        $sourceDirectory = [System.IO.Path]::GetDirectoryName($SourcePath)
        $target = [System.IO.Path]::GetFullPath((Join-Path $sourceDirectory ($decoded.Replace('/', [System.IO.Path]::DirectorySeparatorChar))))
    }

    if ($target -match '^(?<file>.+\.[^\\/]+):\d+$') {
        $target = [System.IO.Path]::GetFullPath($Matches['file'])
    }
    return $target
}

function Test-IsExternalDestination {
    param([string]$Destination)

    $value = (ConvertFrom-MarkdownDestination -Destination $Destination).Trim()
    if ($value -match '^[A-Za-z]:[\\/]') {
        return $false
    }
    return $value -match '^(?i)(?:[A-Za-z][A-Za-z0-9+.-]*:|//)'
}

function Test-PathContainsReparsePoint {
    param([string]$Path)

    $relative = Get-RepoRelativePath -Path $Path
    if ($null -eq $relative) {
        return $true
    }
    if ([string]::IsNullOrEmpty($relative)) {
        return $false
    }
    $cursor = $script:RootFull
    foreach ($segment in $relative.Split('/')) {
        $cursor = Join-Path $cursor $segment
        if (-not (Test-Path -LiteralPath $cursor)) {
            continue
        }
        try {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        }
        catch {
            return $true
        }
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $true
        }
    }
    return $false
}

function Resolve-ManifestRelativePath {
    param([string]$RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [System.IO.Path]::IsPathRooted($RelativePath)) {
        return $null
    }
    $full = [System.IO.Path]::GetFullPath((Join-Path $script:RootFull ($RelativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))))
    if ($null -eq (Get-RepoRelativePath -Path $full)) {
        return $null
    }
    if (Test-PathContainsReparsePoint -Path $full) {
        return $null
    }
    return $full
}

function Test-ArchiveManifest {
    $manifestRelative = 'docs/archive/2026-10-11-before-reorganization/manifest.json'
    $manifestPath = Resolve-ManifestRelativePath -RelativePath $manifestRelative
    if ($null -eq $manifestPath) {
        if (Test-Path -LiteralPath (Join-Path $script:RootFull $manifestRelative)) {
            Add-CheckFailure -Path $manifestRelative -Line 0 -Message 'manifest path leaves the workspace or crosses a reparse point'
            return
        }
        return
    }
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return
    }

    try {
        $manifestText = [System.IO.File]::ReadAllText($manifestPath)
        $manifest = ConvertFrom-Json -InputObject $manifestText -ErrorAction Stop
    }
    catch {
        Add-CheckFailure -Path $manifestRelative -Line 0 -Message 'manifest is not valid JSON'
        return
    }

    if ($manifest.schema -ne 1 -or $null -eq $manifest.entries) {
        Add-CheckFailure -Path $manifestRelative -Line 0 -Message 'manifest schema or entries are invalid'
        return
    }

    $entryIndex = 0
    foreach ($entry in @($manifest.entries)) {
        $entryIndex++
        $source = [string]$entry.source
        $archive = [string]$entry.archive
        $expectedHash = [string]$entry.sha256
        $location = '{0} (entry {1})' -f $manifestRelative, $entryIndex
        if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($archive) -or $expectedHash -notmatch '^[0-9a-fA-F]{64}$') {
            Add-CheckFailure -Path $location -Line 0 -Message 'entry fields are invalid'
            continue
        }
        if ($source -notmatch '\.md$' -or $archive -notmatch '^docs/archive/2026-10-11-before-reorganization/.+\.md$') {
            Add-CheckFailure -Path $location -Line 0 -Message 'entry must refer to a Markdown source and archived Markdown file'
            continue
        }
        $sourcePath = Resolve-ManifestRelativePath -RelativePath $source
        $archivePath = Resolve-ManifestRelativePath -RelativePath $archive
        if ($null -eq $sourcePath -or $null -eq $archivePath) {
            Add-CheckFailure -Path $location -Line 0 -Message 'entry path leaves the workspace or crosses a reparse point'
            continue
        }
        if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
            Add-CheckFailure -Path $archive -Line 0 -Message 'archived Markdown file is missing'
            continue
        }
        try {
            $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256 -ErrorAction Stop).Hash
        }
        catch {
            Add-CheckFailure -Path $archive -Line 0 -Message 'unable to hash archived Markdown file'
            continue
        }
        if (-not $actualHash.Equals($expectedHash, [System.StringComparison]::OrdinalIgnoreCase)) {
            Add-CheckFailure -Path $archive -Line 0 -Message 'archive SHA256 does not match manifest'
        }
    }
}

$markdownFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
Add-ExactMarkdownFile -RelativePath 'README.md' -Files $markdownFiles
Add-ExactMarkdownFile -RelativePath 'AGENTS.md' -Files $markdownFiles
Add-ExactMarkdownFile -RelativePath 'app/README.md' -Files $markdownFiles
Add-ExactMarkdownFile -RelativePath 'docs/archive/README.md' -Files $markdownFiles

$docsDirectory = Join-Path $script:RootFull 'docs'
if (Test-Path -LiteralPath $docsDirectory -PathType Container) {
    if (Test-PathContainsReparsePoint -Path $docsDirectory) {
        Add-CheckFailure -Path 'docs' -Line 0 -Message 'refusing to follow a reparse point while scanning Markdown'
    }
    else {
        Add-MarkdownTree -Directory $docsDirectory -RelativeDirectory 'docs' -Files $markdownFiles -ExcludeArchive
    }
}
foreach ($additionalMarkdownTree in @('verification', 'knowledge')) {
    $additionalMarkdownDirectory = Join-Path $script:RootFull $additionalMarkdownTree
    if (Test-Path -LiteralPath $additionalMarkdownDirectory -PathType Container) {
        if (Test-PathContainsReparsePoint -Path $additionalMarkdownDirectory) {
            Add-CheckFailure -Path $additionalMarkdownTree -Line 0 -Message 'refusing to follow a reparse point while scanning Markdown'
        }
        else {
            Add-MarkdownTree -Directory $additionalMarkdownDirectory -RelativeDirectory $additionalMarkdownTree -Files $markdownFiles
        }
    }
}

$anchorIndex = @{}
$scannedPaths = @{}
$documentTexts = @{}
foreach ($file in $markdownFiles) {
    $fullPath = [System.IO.Path]::GetFullPath($file.FullName)
    $relativePath = Get-RepoRelativePath -Path $fullPath
    try {
        $text = [System.IO.File]::ReadAllText($fullPath)
    }
    catch {
        Add-CheckFailure -Path $relativePath -Line 0 -Message 'unable to read Markdown file'
        continue
    }
    $documentTexts[$fullPath] = $text
    $anchorIndex[$fullPath] = Get-DocumentAnchors -Path $relativePath -Text $text -CheckDuplicateAnchors
    $scannedPaths[$fullPath] = $true
}

foreach ($file in $markdownFiles) {
    $fullPath = [System.IO.Path]::GetFullPath($file.FullName)
    if (-not $scannedPaths.ContainsKey($fullPath)) {
        continue
    }
    $relativePath = Get-RepoRelativePath -Path $fullPath
    if (-not $documentTexts.ContainsKey($fullPath)) {
        continue
    }
    $text = $documentTexts[$fullPath]
    $masked = Get-MaskedMarkdown -Text $text
    $linkText = Mask-InlineCode -Text $masked
    $lineStarts = Get-LineStarts -Text $linkText
    $links = Get-InlineMarkdownLinks -Text $linkText
    foreach ($link in $links) {
        $destination = [string]$link.Destination
        if ([string]::IsNullOrWhiteSpace($destination) -or (Test-IsExternalDestination -Destination $destination)) {
            continue
        }
        $script:LocalLinkCount++
        $line = Get-LineNumberAtOffset -Offset $link.Offset -LineStarts $lineStarts
        $fragment = ''
        try {
            $targetPath = Get-LinkTargetPath -Destination $destination -SourcePath $fullPath -Fragment ([ref]$fragment)
        }
        catch {
            Add-CheckFailure -Path $relativePath -Line $line -Message 'local link target is invalid'
            continue
        }
        $hasMarkdownFragment = -not [string]::IsNullOrEmpty($fragment) -and [System.IO.Path]::GetExtension($targetPath) -ieq '.md'
        $targetRelative = $null
        if ($hasMarkdownFragment) {
            $targetRelative = Get-RepoRelativePath -Path $targetPath
            if ($null -eq $targetRelative) {
                Add-CheckFailure -Path $relativePath -Line $line -Message 'Markdown fragment target leaves the workspace'
                continue
            }
            if (Test-PathContainsReparsePoint -Path $targetPath) {
                Add-CheckFailure -Path $relativePath -Line $line -Message 'Markdown fragment target crosses a reparse point'
                continue
            }
            $excludedSegment = $false
            foreach ($segment in $targetRelative.Split('/')) {
                if (Test-ExcludedDirectoryName -Name $segment) {
                    $excludedSegment = $true
                    break
                }
            }
            if ($excludedSegment) {
                Add-CheckFailure -Path $relativePath -Line $line -Message 'Markdown fragment target is in an excluded runtime/build/tmp path'
                continue
            }
        }
        if (-not (Test-Path -LiteralPath $targetPath)) {
            Add-CheckFailure -Path $relativePath -Line $line -Message 'local link target does not exist'
            continue
        }
        if ($hasMarkdownFragment -and -not $anchorIndex.ContainsKey($targetPath)) {
            if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
                Add-CheckFailure -Path $relativePath -Line $line -Message 'Markdown fragment target is not a regular file'
                continue
            }
            try {
                $targetText = [System.IO.File]::ReadAllText($targetPath)
            }
            catch {
                Add-CheckFailure -Path $relativePath -Line $line -Message 'unable to read Markdown fragment target'
                continue
            }
            $anchorIndex[$targetPath] = Get-DocumentAnchors -Path $targetRelative -Text $targetText
        }
        if ($hasMarkdownFragment -and -not $anchorIndex[$targetPath].Contains($fragment)) {
                Add-CheckFailure -Path $relativePath -Line $line -Message ('Markdown anchor does not exist in target: #{0}' -f $fragment)
        }
    }
}

Test-ArchiveManifest

if ($script:Failures.Count -gt 0) {
    foreach ($failure in $script:Failures) {
        [Console]::Error.WriteLine('[FAIL] {0}' -f $failure)
    }
    [Console]::Error.WriteLine('Documentation check failed: {0} issue(s).' -f $script:Failures.Count)
    exit 1
}

[Console]::Out.WriteLine(('Documentation check passed: {0} Markdown file(s), {1} local link(s), archive manifest checked when present.' -f $markdownFiles.Count, $script:LocalLinkCount))
exit 0
