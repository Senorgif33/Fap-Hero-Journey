# Test builds — how to run and smoke-test

This project is Godot **4.6.x .NET**. Day-to-day work does **not** need an exported `.exe`.

## Prerequisites

- **.NET 8 SDK**
- Local editor (recommended): unzip Godot **4.6.3 .NET** into the repo as `Godot_v4.6.3-stable_mono_win64/` (gitignored — do not commit)

## A. Play without exporting

```powershell
.\scripts\dev\run-editor.ps1
```

Or run `Godot_v4.6.3-stable_mono_win64\Godot_v4.6.3-stable_mono_win64.exe`, open this project, press **F5**.

## B. Unit tests without exporting

```powershell
.\scripts\dev\run-tests.ps1
```

Uses the vendored console Godot binary + `addons/gdUnit4/runtest.cmd`. Reports appear under `reports/`.

Manual equivalent:

```powershell
$env:GODOT_BIN = "$PWD\Godot_v4.6.3-stable_mono_win64\Godot_v4.6.3-stable_mono_win64_console.exe"
.\addons\gdUnit4\runtest.cmd
```

## C. Optional Windows export smoke build

1. Install matching **.NET export templates** for your editor version (Godot → Manage Export Templates).
2. Run:

```powershell
.\scripts\dev\export-windows.ps1
```

Output:

- `builds/windows/Fap Hero Journey.exe`
- `builds/Fap Hero JOURNEY v<version> - Windows Build.zip` (updater-style name)

`export_presets.cfg` is gitignored. If missing, the script copies `export_presets.cfg.example`.

CI: workflow **Export Windows** (manual `workflow_dispatch`) can upload a Windows artifact.

## Smoke checklist

### Editor (primary)

- [ ] Project opens in Godot 4.6.3 .NET
- [ ] Play (F5): journey select lists journeys
- [ ] One round: video + funscript clock advances; pause works
- [ ] Options: Buttplug / Intiface connect (when testing devices)
- [ ] Restim chain (when testing Restim plan): Fap-Hero → Intiface → Restim responds to L0
- [ ] After Release feature lands: **I came** / `R` on a fixture round hits the expected mode

### Export (optional)

- [ ] `.\scripts\dev\export-windows.ps1` succeeds
- [ ] `builds/windows/Fap Hero Journey.exe` launches without the editor
- [ ] Same play smoke as above on the exported build
