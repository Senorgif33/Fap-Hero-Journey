#Requires -Version 5.1
<#
.SYNOPSIS
  Run GdUnit4 unit tests without exporting a game build.

.DESCRIPTION
  Defaults GODOT_BIN to the vendored Godot 4.6.3 .NET console binary under the
  repo root, then invokes addons/gdUnit4/runtest.cmd.

.EXAMPLE
  .\scripts\dev\run-tests.ps1

.EXAMPLE
  .\scripts\dev\run-tests.ps1 -GodotBin "D:\Godot\Godot_v4.6.3-stable_mono_win64_console.exe"
#>
[CmdletBinding()]
param(
	[string]$GodotBin = "",
	[Parameter(ValueFromRemainingArguments = $true)]
	[string[]]$RemainingArgs
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
Set-Location $RepoRoot
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
Write-AgentLog -HypothesisId "B" -Location "run-tests.ps1:start" -Message "run-tests started" -Data @{
	repoRoot = "$RepoRoot"
}
# #endregion

function Resolve-DefaultGodotConsole {
	$resolveSw = [System.Diagnostics.Stopwatch]::StartNew()
	$candidates = @(
		(Join-Path $RepoRoot "Godot_v4.6.3-stable_mono_win64\Godot_v4.6.3-stable_mono_win64_console.exe")
	)
	Get-ChildItem -Path $RepoRoot -Directory -Filter "Godot_v*_mono_*" -ErrorAction SilentlyContinue |
		ForEach-Object {
			Get-ChildItem -Path $_.FullName -Filter "*_console.exe" -File -ErrorAction SilentlyContinue
		} |
		ForEach-Object { $candidates += $_.FullName }

	foreach ($c in $candidates) {
		if ($c -and (Test-Path -LiteralPath $c)) {
			# #region agent log
			Write-AgentLog -HypothesisId "B" -Location "run-tests.ps1:Resolve-DefaultGodotConsole" -Message "resolved godot console" -Data @{
				elapsedMs = $resolveSw.ElapsedMilliseconds
				path      = (Resolve-Path -LiteralPath $c).Path
			}
			# #endregion
			return (Resolve-Path -LiteralPath $c).Path
		}
	}
	# #region agent log
	Write-AgentLog -HypothesisId "B" -Location "run-tests.ps1:Resolve-DefaultGodotConsole" -Message "godot console not found" -Data @{
		elapsedMs = $resolveSw.ElapsedMilliseconds
	}
	# #endregion
	return $null
}

if (-not $GodotBin) {
	if ($env:GODOT_BIN -and (Test-Path -LiteralPath $env:GODOT_BIN)) {
		$GodotBin = $env:GODOT_BIN
	} else {
		$GodotBin = Resolve-DefaultGodotConsole
	}
}

if (-not $GodotBin -or -not (Test-Path -LiteralPath $GodotBin)) {
	Write-Error @"
Godot console binary not found.
Place Godot 4.6.3 .NET under the repo (Godot_v4.6.3-stable_mono_win64/), or set:
  `$env:GODOT_BIN = 'C:\path\to\Godot_v4.6.3-stable_mono_win64_console.exe'
  .\scripts\dev\run-tests.ps1
Or pass -GodotBin.
"@
}

$env:GODOT_BIN = (Resolve-Path -LiteralPath $GodotBin).Path
Write-Host "GODOT_BIN=$($env:GODOT_BIN)"

$runtest = Join-Path $RepoRoot "addons\gdUnit4\runtest.cmd"
if (-not (Test-Path -LiteralPath $runtest)) {
	Write-Error "Missing gdUnit runner: $runtest"
}

$argLine = "--godot_binary `"$($env:GODOT_BIN)`""
if ($RemainingArgs -and $RemainingArgs.Count -gt 0) {
	$argLine = "$argLine $($RemainingArgs -join ' ')"
}
Write-Host "Running: $runtest $argLine"

# #region agent log
$godotDir = Join-Path $RepoRoot "Godot_v4.6.3-stable_mono_win64"
$cachePath = Join-Path $RepoRoot ".godot\editor\filesystem_cache10"
$cacheHasGodotV = $false
if (Test-Path -LiteralPath $cachePath) {
	$cacheText = Get-Content -LiteralPath $cachePath -Raw -ErrorAction SilentlyContinue
	if ($cacheText) { $cacheHasGodotV = $cacheText -like "*Godot_v4*" }
}
Write-AgentLog -HypothesisId "A" -Location "run-tests.ps1:pre-runtest" -Message "about to invoke gdUnit runtest" -Data @{
	scriptElapsedMs     = $ScriptSw.ElapsedMilliseconds
	godotDirHasGdignore = (Test-Path -LiteralPath (Join-Path $godotDir ".gdignore"))
	cacheHasGodotV      = $cacheHasGodotV
}
$runSw = [System.Diagnostics.Stopwatch]::StartNew()
# #endregion

$proc = Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", "`"$runtest`" $argLine") -WorkingDirectory $RepoRoot -Wait -PassThru -NoNewWindow

# #region agent log
Write-AgentLog -HypothesisId "C" -Location "run-tests.ps1:post-runtest" -Message "gdUnit runtest finished" -Data @{
	runtestElapsedMs = $runSw.ElapsedMilliseconds
	exitCode         = $proc.ExitCode
	totalElapsedMs   = $ScriptSw.ElapsedMilliseconds
}
# #endregion

exit $proc.ExitCode
