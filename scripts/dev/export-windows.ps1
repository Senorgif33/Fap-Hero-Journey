#Requires -Version 5.1
<#
.SYNOPSIS
  Export a Windows Desktop release build into builds/windows/ (no GitHub upload).

.DESCRIPTION
  Uses vendored Godot 4.6.3 .NET when present. Ensures export_presets.cfg exists
  (copied from export_presets.cfg.example if missing), sets export_path under
  builds/windows/, then runs --export-release.

  Requires .NET export templates for the matching Godot version
  (Editor → Manage Export Templates, or install the .tpz for 4.6.3 mono).

.EXAMPLE
  .\scripts\dev\export-windows.ps1
#>
[CmdletBinding()]
param(
	[string]$GodotBin = "",
	[string]$PresetName = "Windows Desktop",
	[switch]$SkipZip
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
Set-Location $RepoRoot

function Get-ProjectVersion {
	$project = Join-Path $RepoRoot "project.godot"
	foreach ($line in Get-Content -LiteralPath $project) {
		if ($line -match '^\s*config/version="([^"]+)"') {
			return $Matches[1]
		}
	}
	return "0.0.0"
}

function Resolve-DefaultGodot {
	$preferredConsole = Join-Path $RepoRoot "Godot_v4.6.3-stable_mono_win64\Godot_v4.6.3-stable_mono_win64_console.exe"
	$preferredGui = Join-Path $RepoRoot "Godot_v4.6.3-stable_mono_win64\Godot_v4.6.3-stable_mono_win64.exe"
	foreach ($c in @($preferredConsole, $preferredGui)) {
		if (Test-Path -LiteralPath $c) {
			return (Resolve-Path -LiteralPath $c).Path
		}
	}
	$found = Get-ChildItem -Path $RepoRoot -Directory -Filter "Godot_v*_mono_*" -ErrorAction SilentlyContinue |
		ForEach-Object {
			@(
				(Get-ChildItem -Path $_.FullName -Filter "*_console.exe" -File -EA SilentlyContinue),
				(Get-ChildItem -Path $_.FullName -Filter "Godot_v*_mono_*.exe" -File -EA SilentlyContinue |
					Where-Object { $_.Name -notlike "*_console.exe" })
			)
		} |
		Where-Object { $_ } |
		Select-Object -First 1
	if ($found) { return $found.FullName }
	return $null
}

if (-not $GodotBin) {
	if ($env:GODOT_BIN -and (Test-Path -LiteralPath $env:GODOT_BIN)) {
		$GodotBin = $env:GODOT_BIN
	} else {
		$GodotBin = Resolve-DefaultGodot
	}
}
if (-not $GodotBin -or -not (Test-Path -LiteralPath $GodotBin)) {
	Write-Error "Godot binary not found. Set GODOT_BIN or place Godot_v4.6.3-stable_mono_win64/ in the repo."
}
$GodotBin = (Resolve-Path -LiteralPath $GodotBin).Path
$env:GODOT_BIN = $GodotBin

$version = Get-ProjectVersion
$outDir = Join-Path $RepoRoot "builds\windows"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$exeName = "Fap Hero Journey.exe"
$exportPathRel = "builds/windows/$exeName"
$exportPathAbs = Join-Path $outDir $exeName

$presetsPath = Join-Path $RepoRoot "export_presets.cfg"
$examplePath = Join-Path $RepoRoot "export_presets.cfg.example"
if (-not (Test-Path -LiteralPath $presetsPath)) {
	if (-not (Test-Path -LiteralPath $examplePath)) {
		Write-Error "Missing export_presets.cfg and export_presets.cfg.example"
	}
	Copy-Item -LiteralPath $examplePath -Destination $presetsPath
	Write-Host "Created export_presets.cfg from example."
}

# Patch Windows Desktop export_path + product_version in the local (gitignored) presets file.
$raw = Get-Content -LiteralPath $presetsPath -Raw
if ($raw -notmatch '(?m)^name="Windows Desktop"') {
	Write-Error "export_presets.cfg has no preset named 'Windows Desktop'."
}
# Replace first export_path after Windows Desktop preset header (preset.0 in example).
$raw = [regex]::Replace(
	$raw,
	'(?ms)(name="Windows Desktop".*?^export_path=")([^"]*)(")',
	{ param($m) $m.Groups[1].Value + $exportPathRel + $m.Groups[3].Value },
	1
)
$raw = [regex]::Replace(
	$raw,
	'(?m)^(application/product_version=")([^"]*)(")',
	{ param($m) $m.Groups[1].Value + $version + $m.Groups[3].Value },
	1
)
Set-Content -LiteralPath $presetsPath -Value $raw -NoNewline

Write-Host "Exporting '$PresetName' → $exportPathAbs (version $version)"
Write-Host "Using: $GodotBin"
Write-Host "Note: Godot .NET export templates for this editor version must be installed."

& $GodotBin --headless --path "$RepoRoot" --export-release "$PresetName" "$exportPathAbs"
$code = $LASTEXITCODE
if ($code -ne 0) {
	Write-Error "Godot export failed with exit code $code. Install matching .NET export templates if missing."
}
if (-not (Test-Path -LiteralPath $exportPathAbs)) {
	Write-Error "Export reported success but exe not found: $exportPathAbs"
}

Write-Host "Exported: $exportPathAbs"

if (-not $SkipZip) {
	$zipName = "Fap Hero JOURNEY v$version - Windows Build.zip"
	$zipPath = Join-Path $RepoRoot "builds\$zipName"
	if (Test-Path -LiteralPath $zipPath) {
		Remove-Item -LiteralPath $zipPath -Force
	}
	Compress-Archive -Path (Join-Path $outDir "*") -DestinationPath $zipPath
	Write-Host "Zip (updater-style name): $zipPath"
}

Write-Host "Done."
exit 0
