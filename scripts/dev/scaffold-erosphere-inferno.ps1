#Requires -Version 5.1
<#
.SYNOPSIS
  Scaffold Erosphere Inferno under local/journeys/erosphere-inferno/ (gitignored).

.DESCRIPTION
  Runs the Python graph generator, junctions content/ to E:\CYOA-Erosphere\v1,
  and optionally junctions the pack into an existing Journeys catalogue folder
  so you do not need to change Journey Storage Location.
#>
[CmdletBinding()]
param(
	[string]$V1Dir = "E:\CYOA-Erosphere\v1",
	[string]$OutDir = "",
	# Existing catalogue root (keeps VENUE / Zenless in place). Empty = skip install link.
	[string]$InstallIntoJourneys = "E:\E-Stim\Fap.Hero.JOURNEY.v0.6.0.-.Windows.Build\Journeys"
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
if (-not $OutDir) {
	$OutDir = Join-Path $RepoRoot "local\journeys\erosphere-inferno"
}

Write-Host "Generating journey.json..."
python (Join-Path $PSScriptRoot "scaffold_erosphere_inferno.py")
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if (-not (Test-Path -LiteralPath $V1Dir)) {
	Write-Warning "V1 media dir not found: $V1Dir - create content/ manually or re-run with -V1Dir"
} else {
	$content = Join-Path $OutDir "content"
	if (Test-Path -LiteralPath $content) {
		cmd /c "rmdir `"$content`"" 2>$null | Out-Null
		if (Test-Path -LiteralPath $content) {
			Remove-Item -LiteralPath $content -Recurse -Force
		}
	}
	Write-Host "Creating content/ junction -> $V1Dir"
	cmd /c "mklink /J `"$content`" `"$V1Dir`""
	if ($LASTEXITCODE -ne 0) {
		Write-Error "Failed to create content junction"
	}
}

if ($InstallIntoJourneys -and (Test-Path -LiteralPath $InstallIntoJourneys)) {
	$link = Join-Path $InstallIntoJourneys "erosphere-inferno"
	if (Test-Path -LiteralPath $link) {
		Write-Host "Catalogue link already present: $link"
	} else {
		Write-Host "Linking into existing Journeys catalogue: $link"
		cmd /c "mklink /J `"$link`" `"$OutDir`""
		if ($LASTEXITCODE -ne 0) {
			Write-Error "Failed to junction into $InstallIntoJourneys"
		}
	}
} elseif ($InstallIntoJourneys) {
	Write-Warning "InstallIntoJourneys not found: $InstallIntoJourneys"
}

Write-Host ""
Write-Host "Done: $OutDir"
Write-Host "Keep Journey Storage as-is. Refresh Journey Select to see Erosphere Inferno."
