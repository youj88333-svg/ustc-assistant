[CmdletBinding()]
param([string]$ReleaseDirectory, [string]$Revision)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$sourceDirectory = $ReleaseDirectory
$sourceRevision = $Revision
. (Join-Path $PSScriptRoot 'package-windows-private.ps1')

if ([string]::IsNullOrWhiteSpace($sourceDirectory) -or [string]::IsNullOrWhiteSpace($sourceRevision)) {
  throw 'Usage: package-windows-release.ps1 -ReleaseDirectory <app/build Release path> -Revision <clean 40-hex HEAD revision>'
}

Invoke-WindowsPrivatePackage -Source $sourceDirectory -SourceRevision $sourceRevision -PublicCandidate
