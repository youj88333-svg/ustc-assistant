[CmdletBinding()]
param([switch]$Check)

# Development-only: compile the reviewed whitelist, with no network or OCR.
$ErrorActionPreference = 'Stop'
$m3Repo = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$m3Prefix = $m3Repo.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
$m3Utf8 = New-Object Text.UTF8Encoding($false, $true)
$m3Sha = [Security.Cryptography.SHA256]::Create()

function Get-M3Digest([byte[]]$Bytes) {
    return ([BitConverter]::ToString($m3Sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()
}
function Get-M3Path([string]$Relative) {
    $full = [IO.Path]::GetFullPath((Join-Path $m3Repo $Relative))
    if (-not $full.StartsWith($m3Prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'knowledge path escapes workspace'
    }
    $cursor = $full
    while ($cursor.Length -ge $m3Repo.Length) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'knowledge compiler refuses reparse paths'
            }
        }
        if ($cursor -eq $m3Repo) { break }
        $cursor = Split-Path -Parent $cursor
    }
    return $full
}
function Set-M3Generated([string]$Relative, [string]$Text) {
    $path = Get-M3Path $Relative
    $bytes = $m3Utf8.GetBytes($Text)
    if ($Check) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-M3Digest ([IO.File]::ReadAllBytes($path))) -ne (Get-M3Digest $bytes)) {
            throw ('generated knowledge differs: ' + $Relative)
        }
    } else {
        [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
        [IO.File]::WriteAllBytes($path, $bytes)
    }
}

try {
    $catalogPath = Get-M3Path 'knowledge/catalog-v1.json'
    $catalog = [IO.File]::ReadAllText($catalogPath,$m3Utf8) | ConvertFrom-Json
    if ($catalog.version -ne 'knowledge-edition-v1' -or
        $catalog.key -notmatch '^[a-z0-9-]{1,80}$' -or
        $catalog.applicability -ne 'unknown' -or
        $catalog.materials.Count -lt 1 -or $catalog.materials.Count -gt 256) {
        throw 'invalid reviewed knowledge catalog'
    }
    $seen = @{}
    $runtime = @()
    foreach ($item in $catalog.materials) {
        if ($item.key -notmatch '^[a-z0-9-]{1,80}$' -or $seen.ContainsKey($item.key) -or
            $item.draft -notmatch '^curated/(teach|finance)/[a-z0-9-]+\.md$' -or
            $item.draftSha256 -notmatch '^[0-9a-f]{64}$' -or
            $item.sourceDigest -notmatch '^[0-9a-f]{64}$' -or
            @('image-bytes','decoded-html-utf8') -notcontains $item.sourceDigestKind) {
            throw 'invalid material identity or reviewed source'
        }
        $seen[$item.key] = $true
        $draftPath = Get-M3Path ('knowledge/' + $item.draft)
        $draftBytes = [IO.File]::ReadAllBytes($draftPath)
        if ((Get-M3Digest $draftBytes) -ne $item.draftSha256) {
            throw ('draft changed after content review: ' + $item.key)
        }
        $draft = $m3Utf8.GetString($draftBytes).Replace("`r`n","`n").Replace("`r","`n").TrimStart([char]0xfeff)
        $headings = [regex]::Matches($draft,'(?m)^## (.+)$')
        $parts = @{}
        for ($i = 0; $i -lt $headings.Count; $i++) {
            $heading = $headings[$i].Groups[1].Value.Trim()
            if ($parts.ContainsKey($heading)) { throw 'ambiguous material heading' }
            $end = $draft.Length
            if ($i+1 -lt $headings.Count) { $end = $headings[$i+1].Index }
            $parts[$heading] = $draft.Substring($headings[$i].Index,$end-$headings[$i].Index).Trim()
        }
        if ($item.sections.Count -eq 0 -or $item.sections.Count -gt 256) { throw 'invalid selected sections' }
        $body = '# ' + $item.title + "`n`n"
        $selected = @()
        foreach ($heading in $item.sections) {
            if (-not $parts.ContainsKey($heading) -or $selected -contains $heading) {
                throw 'reviewed section is absent or repeated'
            }
            $selected += $heading
            $body += $parts[$heading] + "`n`n"
        }
        $body = $body.TrimEnd() + "`n"
        $bodyBytes = $m3Utf8.GetBytes($body)
        if ($bodyBytes.Length -gt 262144) { throw 'material exceeds runtime budget' }
        $assetPath = 'assets/knowledge/' + $item.key + '.md'
        $row = [ordered]@{
            key=$item.key; title=$item.title; provider=$item.provider; topic=$item.topic;
            audience=$item.audience; sourceVersion=$item.sourceVersion;
            articleUrl=$item.articleUrl; materialUrl=$item.materialUrl;
            sourceDigest=$item.sourceDigest; sourceDigestKind=$item.sourceDigestKind;
            coveredScope=$item.coveredScope; reviewVersion=$catalog.reviewVersion;
            publishedOn=$item.publishedOn; updatedOn=$item.updatedOn;
            observedOn=$catalog.observedOn; applicability='unknown'; quality='reviewedContent';
            bodyAsset=$assetPath; markdownDigest=(Get-M3Digest $bodyBytes)
        }
        $runtime += $row
        Set-M3Generated ('app/' + $assetPath) $body
    }
    $assetCatalog = [ordered]@{
        version=$catalog.version; key=$catalog.key; materials=@($runtime)
    }
    $assetText = ($assetCatalog | ConvertTo-Json -Depth 10).Replace("`r`n","`n") + "`n"
    $digest = Get-M3Digest ($m3Utf8.GetBytes($assetText))
    Set-M3Generated 'app/assets/knowledge/catalog.json' $assetText
    $keys = ($runtime | ForEach-Object { "    '$($_.key)'," }) -join "`n"
    $identity = @"
// GENERATED by tools/prepare-knowledge-assets.ps1 from the reviewed catalog.
// Do not hand-edit; runtime receives this identity and no caller-selected path.
import '../core/knowledge_contract.dart';

const bundledKnowledgeIdentity = KnowledgeEditionIdentity(
  key: '$($catalog.key)',
  catalogDigest: '$digest',
  materialKeys: [
$keys
  ],
);
"@
    Set-M3Generated 'app/lib/data/bundled_knowledge_identity.dart' ($identity.Replace("`r`n","`n") + "`n")
    [Console]::WriteLine(('[PASS] reviewed knowledge: {0} materials; {1}' -f $runtime.Count, $(if ($Check) {'assets match'} else {'assets generated'})))
} finally {
    $m3Sha.Dispose()
}
