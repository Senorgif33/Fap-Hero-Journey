#Requires -Version 5.1
<#
.SYNOPSIS
  Build Erosphere Inferno in-repo, then install generated JSON into the live Journeys pack.

.DESCRIPTION
  1) Runs scaffold_erosphere_inferno.py → writes under
     <repo>/local/journeys/erosphere-inferno/ (journey.json + skill_unlocks.json).
  2) Copies ONLY those generated files into the live pack.
     Never deletes pack media, never creates content/ junctions to v1.

.PARAMETER PackDir
  Live Journeys pack folder (destination for generated JSON only).

.PARAMETER SkipInstall
  Build locally only; do not copy into PackDir.
#>
[CmdletBinding()]
param(
	[string]$PackDir = "E:\E-Stim\Fap.Hero.JOURNEY.v0.6.0.-.Windows.Build\Journeys\Erosphere_Inferno",
	[switch]$SkipInstall
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$BuildDir = Join-Path $RepoRoot "local\journeys\erosphere-inferno"

function Send-ToRecycleBin {
	param([Parameter(Mandatory = $true)][string]$LiteralPath)
	if (-not (Test-Path -LiteralPath $LiteralPath)) { return }
	Add-Type -AssemblyName Microsoft.VisualBasic | Out-Null
	$item = Get-Item -LiteralPath $LiteralPath -Force
	if ($item.PSIsContainer) {
		[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
			$LiteralPath,
			'OnlyErrorDialogs',
			'SendToRecycleBin'
		)
	} else {
		[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
			$LiteralPath,
			'OnlyErrorDialogs',
			'SendToRecycleBin'
		)
	}
}

Write-Host "Building journey.json -> $BuildDir"
python (Join-Path $PSScriptRoot "scaffold_erosphere_inferno.py")
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$builtJourney = Join-Path $BuildDir "journey.json"
$builtUnlocks = Join-Path $BuildDir "skill_unlocks.json"
if (-not (Test-Path -LiteralPath $builtJourney)) {
	Write-Error "Build did not produce journey.json at $builtJourney"
}

if ($SkipInstall) {
	Write-Host "SkipInstall: leaving files in $BuildDir only."
	exit 0
}

if (-not (Test-Path -LiteralPath $PackDir)) {
	New-Item -ItemType Directory -Path $PackDir -Force | Out-Null
}

# Soft-replace existing generated JSON only (never wipe the pack folder / media).
$destJourney = Join-Path $PackDir "journey.json"
$destUnlocks = Join-Path $PackDir "skill_unlocks.json"
if (Test-Path -LiteralPath $destJourney) {
	$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
	$bak = Join-Path $BuildDir "journey.json.pack-backup-$stamp.json"
	Copy-Item -LiteralPath $destJourney -Destination $bak -Force
	Write-Host "Pack journey.json backed up -> $bak"
	Send-ToRecycleBin -LiteralPath $destJourney
}
if (Test-Path -LiteralPath $destUnlocks) {
	Send-ToRecycleBin -LiteralPath $destUnlocks
}

Copy-Item -LiteralPath $builtJourney -Destination $destJourney -Force
Copy-Item -LiteralPath $builtUnlocks -Destination $destUnlocks -Force

Write-Host ""
Write-Host "Installed:"
Write-Host "  $destJourney"
Write-Host "  $destUnlocks"
Write-Host "Pack media left untouched. Refresh Journey Select / reload in Builder."
