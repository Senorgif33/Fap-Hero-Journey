#Requires -Version 5.1
<#
.SYNOPSIS
  Scaffold Erosphere Inferno into the live Windows build Journeys pack.

.DESCRIPTION
  Runs the Python graph generator into
  E:\E-Stim\...\Journeys\Erosphere_Inferno, and junctions content/ to
  E:\CYOA-Erosphere\v1 when that media root exists.
#>
[CmdletBinding()]
param(
	[string]$V1Dir = "E:\CYOA-Erosphere\v1",
	[string]$OutDir = "E:\E-Stim\Fap.Hero.JOURNEY.v0.6.0.-.Windows.Build\Journeys\Erosphere_Inferno"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $OutDir)) {
	New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

Write-Host "Generating journey.json -> $OutDir"
python (Join-Path $PSScriptRoot "scaffold_erosphere_inferno.py")
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if (-not (Test-Path -LiteralPath $V1Dir)) {
	Write-Warning "V1 media dir not found: $V1Dir - create content/ manually or re-run with -V1Dir"
} else {
	$content = Join-Path $OutDir "content"
	$isJunction = $false
	if (Test-Path -LiteralPath $content) {
		$attrs = (Get-Item -LiteralPath $content -Force).Attributes.ToString()
		$isJunction = $attrs -match "ReparsePoint"
		if ($isJunction) {
			cmd /c "rmdir `"$content`""
			if ($LASTEXITCODE -ne 0) {
				Write-Error "Failed to remove existing content junction"
			}
		} else {
			Write-Host "Keeping existing content/ directory (not a junction): $content"
		}
	}
	if (-not (Test-Path -LiteralPath $content)) {
		Write-Host "Creating content/ junction -> $V1Dir"
		cmd /c "mklink /J `"$content`" `"$V1Dir`""
		if ($LASTEXITCODE -ne 0) {
			Write-Error "Failed to create content junction"
		}
	}
}

Write-Host ""
Write-Host "Done: $OutDir"
Write-Host "Refresh Journey Select to pick up Erosphere Inferno."
