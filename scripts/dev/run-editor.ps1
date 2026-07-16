#Requires -Version 5.1
<#
.SYNOPSIS
  Open this project in the vendored Godot 4.6.3 .NET editor (no export).

.EXAMPLE
  .\scripts\dev\run-editor.ps1
#>
[CmdletBinding()]
param(
	[string]$GodotBin = ""
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$ScriptSw = [System.Diagnostics.Stopwatch]::StartNew()

# #region agent log
function Write-AgentLog {
	param([string]$HypothesisId, [string]$Location, [string]$Message, [hashtable]$Data = @{})
	$payload = [ordered]@{
		sessionId    = "1afe81"
		runId        = "pre-fix"
		hypothesisId = $HypothesisId
		location     = $Location
		message      = $Message
		data         = $Data
		timestamp    = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
	} | ConvertTo-Json -Compress
	Add-Content -LiteralPath (Join-Path $RepoRoot "debug-1afe81.log") -Value $payload -ErrorAction SilentlyContinue
}
Write-AgentLog -HypothesisId "B" -Location "run-editor.ps1:start" -Message "run-editor started" -Data @{
	repoRoot = "$RepoRoot"
}
# #endregion

function Resolve-DefaultGodotEditor {
	$preferred = Join-Path $RepoRoot "Godot_v4.6.3-stable_mono_win64\Godot_v4.6.3-stable_mono_win64.exe"
	if (Test-Path -LiteralPath $preferred) {
		return (Resolve-Path -LiteralPath $preferred).Path
	}
	$found = Get-ChildItem -Path $RepoRoot -Directory -Filter "Godot_v*_mono_*" -ErrorAction SilentlyContinue |
		ForEach-Object {
			Get-ChildItem -Path $_.FullName -Filter "Godot_v*_mono_*.exe" -File -ErrorAction SilentlyContinue |
				Where-Object { $_.Name -notlike "*_console.exe" }
		} |
		Select-Object -First 1
	if ($found) {
		return $found.FullName
	}
	return $null
}

if (-not $GodotBin) {
	if ($env:GODOT_BIN -and (Test-Path -LiteralPath $env:GODOT_BIN)) {
		# Prefer GUI exe if env pointed at console
		$candidate = $env:GODOT_BIN
		if ($candidate -like "*_console.exe") {
			$gui = $candidate -replace "_console\.exe$", ".exe"
			if (Test-Path -LiteralPath $gui) {
				$GodotBin = $gui
			} else {
				$GodotBin = $candidate
			}
		} else {
			$GodotBin = $candidate
		}
	} else {
		$GodotBin = Resolve-DefaultGodotEditor
	}
}

if (-not $GodotBin -or -not (Test-Path -LiteralPath $GodotBin)) {
	Write-Error @"
Godot editor binary not found.
Place Godot 4.6.3 .NET under:
  Godot_v4.6.3-stable_mono_win64\Godot_v4.6.3-stable_mono_win64.exe
Or pass -GodotBin / set GODOT_BIN.
"@
}

$GodotBin = (Resolve-Path -LiteralPath $GodotBin).Path
Write-Host "Launching editor: $GodotBin"
Write-Host "Project: $RepoRoot"

# #region agent log
$godotDir = Join-Path $RepoRoot "Godot_v4.6.3-stable_mono_win64"
$cachePath = Join-Path $RepoRoot ".godot\editor\filesystem_cache10"
$cacheHasGodotV = $false
$cacheHasReports = $false
if (Test-Path -LiteralPath $cachePath) {
	$cacheText = Get-Content -LiteralPath $cachePath -Raw -ErrorAction SilentlyContinue
	if ($cacheText) {
		$cacheHasGodotV = $cacheText -like "*Godot_v4*"
		$cacheHasReports = $cacheText -like "*::res://reports/*"
	}
}
Write-AgentLog -HypothesisId "A" -Location "run-editor.ps1:pre-launch" -Message "filesystem scan context before editor launch" -Data @{
	resolveElapsedMs     = $ScriptSw.ElapsedMilliseconds
	godotDirExists       = (Test-Path -LiteralPath $godotDir)
	godotDirHasGdignore  = (Test-Path -LiteralPath (Join-Path $godotDir ".gdignore"))
	reportsHasGdignore   = (Test-Path -LiteralPath (Join-Path $RepoRoot "reports\.gdignore"))
	cacheHasGodotV       = $cacheHasGodotV
	cacheHasReports      = $cacheHasReports
	godotBin             = "$GodotBin"
}
# #endregion

Start-Process -FilePath $GodotBin -ArgumentList @("--path", "$RepoRoot", "--editor")

# #region agent log
Write-AgentLog -HypothesisId "B" -Location "run-editor.ps1:launched" -Message "Start-Process returned (editor spawning)" -Data @{
	scriptElapsedMs = $ScriptSw.ElapsedMilliseconds
}
# #endregion
