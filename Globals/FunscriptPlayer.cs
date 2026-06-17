using Godot;
using Godot.Collections;
using System;
using System.Collections.Generic;

public partial class FunscriptPlayer : Node
{
    private struct Action { public float AtMs; public int Pos; }

    // Per-axis state for secondary T-code channels (L1, L2, R0, R1, R2).
    // Serial-only — Buttplug ignores these entirely.
    private class AxisState
    {
        public List<Action> Actions = new List<Action>();
        public int Index = 0;
    }

    // Per-channel vibrator script state.
    // Channel 0 = vib1 (primary motor), channel 1 = vib2 (secondary motor).
    // Buttplug-only — serial devices ignore these.
    private class VibState
    {
        public List<Action> Actions = new List<Action>();
        public int Index = 0;
    }

    // Maps T-code axis name → its loaded script state.
    // Explicitly System.Collections.Generic — AxisState is a C# class, not a Godot Variant.
    private readonly System.Collections.Generic.Dictionary<string, AxisState> _axes =
        new System.Collections.Generic.Dictionary<string, AxisState>();

    // Maps vibrator channel index → its loaded script state.
    private readonly System.Collections.Generic.Dictionary<int, VibState> _vibScripts =
        new System.Collections.Generic.Dictionary<int, VibState>();

    private static readonly string[] KnownAxes = { "L1", "L2", "R0", "R1", "R2" };

    private enum OutputMode { Buttplug, Serial }

    private List<Action> _actions = new List<Action>();

    // "V motion" beats — local minima in the L0 track — for the optional beat-bar
    // visualiser. Each entry is (AtMs, depth) where depth is the 0–100 dip size.
    private readonly List<Vector2> _beats = new List<Vector2>();

    private bool _playing = false;
    private double _positionMs = 0.0;
    private int _actionIndex = 0;
    private bool? _isLinearDevice = null;
    private int _deviceIndex = -1;
    private int _vibChannelCount = 0; // resolved in ResolveOutput(); 0 for non-vibrators
    private bool _syncedThisFrame = false;
    private OutputMode _outputMode = OutputMode.Buttplug;
    private bool _outputResolved = false;
    private int _rangeMin = 0;
    private int _rangeMax = 100;

    // Per-axis range window for the secondary positional axes (L1/L2/R0/R1/R2),
    // independent of the stroke axis [_rangeMin,_rangeMax]. Seeded in ResolveOutput,
    // updated live by SetAxisRangeClamp. A missing axis falls back to full 0–100.
    private readonly System.Collections.Generic.Dictionary<string, (int Min, int Max)> _axisRanges =
        new System.Collections.Generic.Dictionary<string, (int Min, int Max)>();

    // Storyboard filler — alternating stroke played while a storyboard screen is
    // open so the device doesn't sit idle. Independent of _playing / the funscript.
    private bool _fillerActive = false;
    private double _fillerElapsedMs = 0.0;
    private int _fillerHalfCycleMs = 2000; // ms per half-stroke (hi→lo or lo→hi)
    private int _fillerLo = 0;
    private int _fillerHi = 100;
    private bool _fillerGoingToLo = false; // false = first command goes to hi
    private double _fillerVibTickMs = 0.0;
    private const double FillerVibTickIntervalMs = 50.0;

    // Ease-in state — blends output from neutral (50) toward the script position
    // at the start of each round, journey, or resume-from-pause.
    private bool _easing = false;
    private double _easeStartMs = 0.0;
    private double _easeDurationMs = 0.0;
    private const float EaseSpeedUnitsPerMs = 40f / 1000f; // 40 units/sec
    private const double EaseMinMs = 50.0;
    private const double EaseMaxMs = 1500.0;

    // Mirror-ease state — the "mirror" shop item flips position to 100-pos.
    // Toggling it on/off is eased through the centre rather than snapped: an
    // instant reversal into the opposite direction is jarring and unsafe on a
    // linear device. _mirrorBlend lerps 0↔1; at 0.5 every position maps to 50,
    // so the device passes through neutral instead of jumping extreme-to-extreme.
    private float _mirrorBlend = 0f;
    private double _mirrorClockMs = double.NaN; // last clock the blend advanced from
    private const double MirrorEaseMs = 700.0;

    public bool Playing => _playing;
    public int ActionCount => _actions.Count;

    /// Current playback clock in milliseconds — used by the beat-bar HUD so it
    /// stays in sync with the device whether video-driven or free-running.
    public double PositionMs => _positionMs;

    // Cached autoload references — resolved once instead of looked up per-call
    // (some were hit every frame, per axis, inside _Process). FunscriptPlayer is
    // a late autoload, so all of these exist by the time _Ready runs.
    private SerialDeviceService _serial;
    private ButtplugService _buttplug;
    private InventoryService _inventory;
    private ScoreService _score;
    private Node _settings;

    public override void _Ready()
    {
        _serial = GetNode<SerialDeviceService>("/root/SerialDeviceService");
        _buttplug = GetNode<ButtplugService>("/root/ButtplugService");
        _inventory = GetNode<InventoryService>("/root/InventoryService");
        _score = GetNode<ScoreService>("/root/ScoreService");
        _settings = GetNode("/root/SettingsService");
    }

    /// Push updated range-clamp values directly into the player.
    /// Called by the Options screen on every slider change so mid-playback
    /// adjustments take effect on the very next SendCommand without needing
    /// a round restart.
    public void SetRangeClamp(int min, int max)
    {
        _rangeMin = min;
        _rangeMax = max;
    }

    /// Live per-axis range update for one secondary positional axis (Options slider),
    /// mirroring SetRangeClamp for the stroke axis. `axis` is a T-code name (L1/R0/…).
    public void SetAxisRangeClamp(string axis, int min, int max) => _axisRanges[axis] = (min, max);

    // Current range window for a secondary axis; full 0–100 (no limiting) until seeded.
    private (int Min, int Max) GetAxisRange(string axis) =>
        _axisRanges.TryGetValue(axis, out var r) ? r : (0, 100);

    public void LoadFunscript(string path)
    {
        _actions.Clear();
        _actionIndex = 0;
        _positionMs = 0.0;
        _playing = false;
        // Fully invalidate the resolve cache — a new round must re-pick the
        // device. Resetting only _isLinearDevice would leave _outputResolved
        // true if Options had been opened between rounds (Pause → EaseToNeutral
        // → ResolveOutput re-sets it), so Play() would skip re-resolution and
        // _isLinearDevice would stay null. SendCommand then falls through to
        // the vibrator branch even for linear devices like the Handy.
        _isLinearDevice = null;
        _deviceIndex = -1;
        _outputResolved = false;

        foreach (var kv in _axes)
            kv.Value.Index = 0;
        foreach (var kv in _vibScripts)
            kv.Value.Index = 0;

        string absPath = ProjectSettings.GlobalizePath(path);
        using var funscriptFile = FileAccess.Open(absPath, FileAccess.ModeFlags.Read);
        if (funscriptFile == null)
        {
            GD.PrintErr($"FunscriptPlayer: cannot open {path}");
            return;
        }

        var parser = new Json();
        if (parser.Parse(funscriptFile.GetAsText()) != Error.Ok)
        {
            GD.PrintErr($"FunscriptPlayer: JSON parse error in {path}");
            return;
        }

        var funscript = parser.Data.AsGodotDictionary();
        var rawActions = funscript.ContainsKey("actions") ? funscript["actions"].AsGodotArray() : new Godot.Collections.Array();
        foreach (var rawAction in rawActions)
        {
            var action = rawAction.AsGodotDictionary();
            _actions.Add(new Action
            {
                AtMs = action.ContainsKey("at") ? action["at"].AsSingle() : 0f,
                Pos = action.ContainsKey("pos") ? action["pos"].AsInt32() : 0,
            });
        }

        _ExtractBeats();
    }

    // Finds every "V motion" — a local minimum where the track dips and rises
    // again — and records its timestamp and dip depth for the beat-bar HUD.
    private void _ExtractBeats()
    {
        _beats.Clear();
        for (int i = 1; i < _actions.Count - 1; i++)
        {
            int prev = _actions[i - 1].Pos;
            int cur  = _actions[i].Pos;
            int next = _actions[i + 1].Pos;
            if (prev > cur && cur < next)
            {
                float depth = Math.Min(prev, next) - cur;
                _beats.Add(new Vector2(_actions[i].AtMs, depth));
            }
        }
    }

    /// Returns the V-motion beats as Vector2(timeMs, depth 0-100) for the beat bar.
    public Godot.Collections.Array GetBeats()
    {
        var arr = new Godot.Collections.Array();
        foreach (var b in _beats)
            arr.Add(b);
        return arr;
    }

    // Home-position config — updated live by Options via SetHomePosition().
    // L0 only: secondary axes always home to 0.5 regardless of this setting.
    private int _homePosition = 50;   // 0–100, matches funscript scale
    private uint _homeEaseMs = 2000;  // milliseconds for the home ease move

    // Fixed duration used only when parking unloaded secondary axes at round start.
    private const uint AxisParkMs = 500;

    /// Push updated home-position config directly into the player so mid-session
    /// changes in Options take effect without a restart.
    public void SetHomePosition(int position, int easeMs)
    {
        _homePosition = Math.Clamp(position, 0, 100);
        _homeEaseMs = (uint)Math.Max(50, easeMs);
    }

    // Device latency compensation — shifts the funscript clock relative to the
    // video to offset device/Bluetooth lag. Positive = device acts earlier.
    private int _latencyOffsetMs = 0;

    // Vibrator output scale (0–1). Applied to every vibration command so the
    // user can dial overall strength down. No effect on linear devices.
    private float _vibeIntensity = 1.0f;

    // Max stroke speed for linear (L0) output, in funscript units/sec.
    // 0 = unlimited. Moves faster than the cap are slowed by stretching duration.
    private int _maxStrokeSpeed = 0;

    /// Live-update the device latency offset from Options.
    public void SetLatencyOffset(int offsetMs) => _latencyOffsetMs = offsetMs;

    /// Live-update the vibrator intensity scale from Options (percent 0–100).
    public void SetVibeIntensity(int percent) => _vibeIntensity = Math.Clamp(percent, 0, 100) / 100f;

    /// Live-update the max stroke speed cap from Options (units/sec, 0 = off).
    public void SetMaxStrokeSpeed(int unitsPerSec) => _maxStrokeSpeed = Math.Max(0, unitsPerSec);

    // Stretches a linear move's duration when it would exceed the configured
    // max stroke speed, so aggressive scripts are gently slowed instead of
    // snapping. _maxStrokeSpeed of 0 disables the cap.
    private uint _CapDuration(int fromPos, int toPos, uint durationMs)
    {
        if (_maxStrokeSpeed <= 0)
            return durationMs;

        int distance = Math.Abs(toPos - fromPos);

        if (distance == 0)
            return durationMs;
        uint minMs = (uint)Math.Ceiling(distance * 1000.0 / _maxStrokeSpeed);

        return Math.Max(durationMs, minMs);
    }

    // Load a secondary-axis funscript. Call before Play().
    // axis: T-code name, e.g. "L1", "R0".
    public void LoadAxisScript(string axis, string path)
    {
        var state = new AxisState();
        string absPath = ProjectSettings.GlobalizePath(path);

        using var funscriptFile = FileAccess.Open(absPath, FileAccess.ModeFlags.Read);
        if (funscriptFile == null)
        {
            GD.PrintErr($"FunscriptPlayer: cannot open axis script {path}");
            return;
        }

        var parser = new Json();
        if (parser.Parse(funscriptFile.GetAsText()) != Error.Ok)
        {
            GD.PrintErr($"FunscriptPlayer: JSON parse error in axis script {path}");
            return;
        }

        var funscript = parser.Data.AsGodotDictionary();
        var rawActions = funscript.ContainsKey("actions") ? funscript["actions"].AsGodotArray() : new Godot.Collections.Array();
        foreach (var rawAction in rawActions)
        {
            var action = rawAction.AsGodotDictionary();
            state.Actions.Add(new Action
            {
                AtMs = action.ContainsKey("at") ? action["at"].AsSingle() : 0f,
                Pos = action.ContainsKey("pos") ? action["pos"].AsInt32() : 0,
            });
        }
        _axes[axis] = state;
    }

    // Remove all secondary axis scripts (call before loading a new round).
    public void ClearAxisScripts()
    {
        _axes.Clear();
    }

    // Load a per-channel vibrator funscript. channel: 0 = vib1, 1 = vib2.
    // Call ClearVibScripts() before loading scripts for a new round.
    public void LoadVibScript(int channel, string path)
    {
        var state = new VibState();
        string absPath = ProjectSettings.GlobalizePath(path);
        using var file = FileAccess.Open(absPath, FileAccess.ModeFlags.Read);
        if (file == null)
        {
            GD.PrintErr($"FunscriptPlayer: cannot open vib script ch{channel}: {path}");
            return;
        }
        var parser = new Json();
        if (parser.Parse(file.GetAsText()) != Error.Ok)
        {
            GD.PrintErr($"FunscriptPlayer: JSON parse error in vib script ch{channel}: {path}");
            return;
        }
        var funscript = parser.Data.AsGodotDictionary();
        var rawActions = funscript.ContainsKey("actions") ? funscript["actions"].AsGodotArray() : new Godot.Collections.Array();
        foreach (var rawAction in rawActions)
        {
            var action = rawAction.AsGodotDictionary();
            state.Actions.Add(new Action
            {
                AtMs = action.ContainsKey("at") ? action["at"].AsSingle() : 0f,
                Pos  = action.ContainsKey("pos") ? action["pos"].AsInt32() : 0,
            });
        }
        _vibScripts[channel] = state;
    }

    // Remove all vibrator channel scripts (call before loading a new round).
    public void ClearVibScripts()
    {
        _vibScripts.Clear();
    }

    // Send all known axes that have NO loaded script to neutral (50 → 0.5) so the
    // device doesn't stay wherever it was from a previous round.
    // Only runs when at least one axis script is loaded — single-axis devices
    // (which have no axis scripts) receive no unnecessary secondary-axis traffic.
    private void _SendNeutralToUnloadedAxes()
    {
        if (_outputMode != OutputMode.Serial)
            return;
        if (_axes.Count == 0)
            return; // no multi-axis scripts → nothing to park

        var serial = _serial;
        if (serial == null || !serial.SerialConnected)
            return;

        foreach (var axis in KnownAxes)
        {
            if (!_axes.ContainsKey(axis))
                serial.SendAxis(axis, AxisParkMs, 0.5);
        }
    }

    public void Play()
    {
        _playing = true;
        ResolveOutput();
        _SendNeutralToUnloadedAxes();
        _StartEaseIn();
    }

    public void Pause()
    {
        _playing = false;
        _easing = false;
        EaseToNeutral();
    }

    public void Resume()
    {
        _playing = true;
        // Re-resolve in case the user changed the output mode or selected
        // device through the Options overlay while paused. Without this, a
        // device swap mid-round (or mid-transition) keeps sending to the
        // previous device or the wrong capability branch.
        _outputResolved = false;
        ResolveOutput();
        _StartEaseIn();
    }

    public void Stop()
    {
        _playing = false;
        _easing = false;
        _fillerActive = false; // cancel any storyboard filler that may still be running

        EaseToNeutral();
        _positionMs = 0.0;
        _actionIndex = 0;

        foreach (var kv in _axes)
            kv.Value.Index = 0;
        foreach (var kv in _vibScripts)
            kv.Value.Index = 0;

        _isLinearDevice = null;
        _deviceIndex = -1;
        _outputResolved = false;
    }

    // Begin the storyboard filler: alternating hi→lo→hi strokes at the given
    // half-cycle speed. Respects the device range clamp but not inventory effects.
    // lo/hi are in the same 0–100 scale as funscript positions.
    // Live setter for filler parameters. Used by the Options overlay so a user
    // tweaking the storyboard-filler sliders during an active storyboard sees
    // the device respond immediately rather than having to wait for the next
    // storyboard's filler to start. Safe to call any time; if filler isn't
    // running these values are seeded for the next StartFiller call.
    public void SetFillerParams(int lo, int hi, int halfCycleMs)
    {
        _fillerLo = lo;
        _fillerHi = hi;
        _fillerHalfCycleMs = Math.Max(100, halfCycleMs);
    }


    public void StartFiller(int lo, int hi, int halfCycleMs)
    {
        _fillerLo = lo;
        _fillerHi = hi;
        _fillerHalfCycleMs = Math.Max(100, halfCycleMs);
        _fillerElapsedMs = 0.0;
        _fillerGoingToLo = false; // first stroke goes to hi, then alternates
        _fillerVibTickMs = 0.0;
        _fillerActive = true;
        ResolveOutput();
        _SendFillerCommand(); // fire immediately so there's no leading silence
    }

    // Stop the filler and ease the device back to neutral.
    public void StopFiller()
    {
        if (!_fillerActive) return;
        _fillerActive = false;
        EaseToNeutral();
    }

    // Compute ease-in parameters from the first upcoming script action.
    // Duration is proportional to how far that position is from neutral (50),
    // so the device always approaches at a consistent speed regardless of gap size.
    // Skipped entirely for vibrators — intensity jumps are not jarring the way
    // sudden linear strokes are, so no ease is needed.
    private void _StartEaseIn()
    {
        if (_isLinearDevice == false)
            return; // vibrators: no ease-in

        if (_actions.Count == 0)
            return;

        int idx = Math.Min(_actionIndex, _actions.Count - 1);
        float gap = Math.Abs(_actions[idx].Pos - _homePosition);

        if (gap <= 2f)
        {
            _easing = false;
            return;
        }

        _easeDurationMs = Math.Clamp(gap / EaseSpeedUnitsPerMs, EaseMinMs, EaseMaxMs);
        _easeStartMs = _positionMs;
        _easing = true;
    }

    // Send a gentle "go to neutral" command so the device doesn't stay
    // mid-stroke or vibrating when playback halts. Linear → midpoint,
    // vibrator → 0 intensity. Safe to call when nothing is connected.
    // For serial devices, all loaded secondary axes are also returned to 0.5.
    private void EaseToNeutral()
    {
        ResolveOutput();

        double homeNorm = _homePosition / 100.0;

        if (_outputMode == OutputMode.Serial)
        {
            var serial = _serial;
            if (serial != null && serial.SerialConnected)
            {
                // L0 homes to the user-configured position.
                serial.SendLinear(_homeEaseMs, homeNorm);
                // Secondary axes always return to centre — home position is L0-only.
                foreach (var axis in _axes.Keys)
                    serial.SendAxis(axis, _homeEaseMs, 0.5);
            }
            return;
        }

        var bp = _buttplug;
        if (bp == null || !bp.BpConnected || _deviceIndex < 0)
            return;

        if (_isLinearDevice == true)
        {
            bp.SendLinear(_deviceIndex, _homeEaseMs, homeNorm);
        }
        else if (_vibScripts.Count > 0)
        {
            // Explicitly silence every vibration channel loaded from vib scripts.
            for (int ch = 0; ch < Math.Max(1, _vibChannelCount); ch++)
                bp.SendVibrateChannel(_deviceIndex, ch, 0.0);
        }
        else
        {
            bp.SendVibrate(_deviceIndex, 0.0);
        }
    }

    // Call this each frame from GameLoop to keep funscript in sync with the video clock.
    // Only updates _positionMs — _Process is responsible for dispatching due actions.
    public void SyncTo(double videoPositionSec)
    {
        _positionMs = videoPositionSec * 1000.0 + _latencyOffsetMs;
        _syncedThisFrame = true;
    }

    public override void _Process(double delta)
    {
        // Runs whenever playing — not gated on _actions having content, so vib /
        // axis scripts still dispatch even if the main L0 script is empty.
        if (_playing)
        {
            // When synced to a video clock, SyncTo already set _positionMs this frame.
            // Only accumulate delta in free-running mode (no video / funscript-only).
            if (_syncedThisFrame)
                _syncedThisFrame = false;
            else
                _positionMs += delta * 1000.0;

            while (_actionIndex < _actions.Count)
            {
                if (_actions[_actionIndex].AtMs > _positionMs)
                    break;

                SendCommand(_actionIndex);
                _actionIndex++;
            }

            // Dispatch secondary axes (serial only). Applies the same smoothstep
            // ease-in as L0 so all axes blend in together from neutral at round start.
            if (_outputMode == OutputMode.Serial)
            {
                var serial = _serial;
                if (serial != null && serial.SerialConnected)
                {
                    // Compute ease blend factor once for this batch of axis commands.
                    // _easing may already be false (cleared by L0's SendCommand above),
                    // which is fine — both axes will stop easing at the same moment.
                    float easeSmooth = 1f;
                    if (_easing)
                    {
                        double elapsed = _positionMs - _easeStartMs;
                        float t = (float)Math.Clamp(elapsed / _easeDurationMs, 0.0, 1.0);
                        easeSmooth = t * t * (3f - 2f * t); // smoothstep
                    }

                    foreach (var multiaxis in _axes)
                    {
                        string axis = multiaxis.Key;
                        AxisState state = multiaxis.Value;
                        while (state.Index < state.Actions.Count)
                        {
                            if (state.Actions[state.Index].AtMs > _positionMs)
                                break;

                            int idx = state.Index;
                            if (idx + 1 < state.Actions.Count)
                            {
                                int nextPos = state.Actions[idx + 1].Pos;
                                // Each secondary axis has its OWN range window, independent of the
                                // stroke axis. RESCALE 0–100 → [axisMin,axisMax] so a symmetric
                                // range compresses the swing around centre. Before the ease, then a
                                // safety clamp — mirrors SendCommand's order.
                                (int axisMin, int axisMax) = GetAxisRange(axis);
                                nextPos = RescaleToAxisRange(nextPos, axisMin, axisMax);
                                // Secondary axes always home to centre (50), so blend from 50.
                                if (_easing || easeSmooth < 1f)
                                    nextPos = (int)Math.Round(50f + (nextPos - 50f) * easeSmooth);
                                // Safety net: never send out-of-window (mirrors SendCommand).
                                nextPos = Math.Clamp(nextPos, axisMin, axisMax);

                                double targetNorm = nextPos / 100.0;
                                uint durMs = (uint)Math.Max(1, (int)(state.Actions[idx + 1].AtMs - state.Actions[idx].AtMs));
                                serial.SendAxis(axis, durMs, targetNorm);
                            }
                            state.Index++;
                        }
                    }
                }
            }

            // Dispatch vib scripts (Buttplug vibrators only).
            // Uses the same _positionMs clock as the main script so both are in sync.
            // Channel 0 (vib1) is mirrored to channel 1 when no vib2 script is loaded
            // and the device reports 2+ vibration channels.
            if (_outputMode == OutputMode.Buttplug && _isLinearDevice == false && _vibScripts.Count > 0)
            {
                var bpVib = _buttplug;
                if (bpVib != null && bpVib.BpConnected && _deviceIndex >= 0)
                {
                    bool hasCh1 = _vibScripts.ContainsKey(1);

                    foreach (var vibEntry in _vibScripts)
                    {
                        int channel = vibEntry.Key;
                        var vstate  = vibEntry.Value;
                        while (vstate.Index < vstate.Actions.Count)
                        {
                            if (vstate.Actions[vstate.Index].AtMs > _positionMs)
                                break;

                            double intensity = Math.Clamp(vstate.Actions[vstate.Index].Pos / 100.0, 0.0, 1.0) * _vibeIntensity;
                            bpVib.SendVibrateChannel(_deviceIndex, channel, intensity);

                            // Mirror channel 0 → channel 1 when no separate vib2 script.
                            if (channel == 0 && !hasCh1 && _vibChannelCount >= 2)
                                bpVib.SendVibrateChannel(_deviceIndex, 1, intensity);

                            vstate.Index++;
                        }
                    }
                }
            }
        }

        // Storyboard filler runs independently of normal funscript playback.
        if (_fillerActive)
        {
            _fillerElapsedMs += delta * 1000.0;
            if (_fillerElapsedMs >= _fillerHalfCycleMs)
            {
                _fillerElapsedMs -= _fillerHalfCycleMs;
                _fillerGoingToLo = !_fillerGoingToLo;
                _SendFillerCommand();
            }

            // Vibrators can't interpolate, so update them frequently with a
            // triangle-wave intensity that mirrors the linear stroke position.
            if (_isLinearDevice == false)
            {
                _fillerVibTickMs += delta * 1000.0;
                if (_fillerVibTickMs >= FillerVibTickIntervalMs)
                {
                    _fillerVibTickMs = 0.0;
                    _SendFillerVibrateTick();
                }
            }
        }
    }

    // Send a single linear command to the device for the current filler direction.
    private void _SendFillerCommand()
    {
        int target = _fillerGoingToLo ? _fillerLo : _fillerHi;
        target = Math.Clamp(target, _rangeMin, _rangeMax);
        uint dur = (uint)_fillerHalfCycleMs;

        if (_outputMode == OutputMode.Serial)
        {
            var serial = _serial;
            if (serial != null && serial.SerialConnected)
                serial.SendLinear(dur, target / 100.0);
            return;
        }

        var bp = _buttplug;
        if (bp == null || !bp.BpConnected || _deviceIndex < 0) return;

        if (_isLinearDevice == true)
            bp.SendLinear(_deviceIndex, dur, target / 100.0);
        // Vibrators are handled by _SendFillerVibrateTick, not here.
    }

    // Compute current triangle-wave intensity for a vibrator and send it.
    private void _SendFillerVibrateTick()
    {
        double t = Math.Clamp(_fillerElapsedMs / _fillerHalfCycleMs, 0.0, 1.0);
        double fromPos = _fillerGoingToLo ? _fillerHi : _fillerLo;
        double toPos = _fillerGoingToLo ? _fillerLo : _fillerHi;
        double pos = fromPos + (toPos - fromPos) * t;
        pos = Math.Clamp(pos, _rangeMin, _rangeMax);

        var bp = _buttplug;
        if (bp == null || !bp.BpConnected || _deviceIndex < 0) return;
        bp.SendVibrate(_deviceIndex, pos / 100.0 * _vibeIntensity);
    }

    private void ResolveOutput()
    {
        if (_outputResolved)
            return;

        string mode = _settings.Call("get_output_mode").AsString();
        _outputMode = mode == "serial" ? OutputMode.Serial : OutputMode.Buttplug;

        // Cache device range limits so SendCommand doesn't hit disk per-action.
        _rangeMin = _settings.Call("get_range_min").AsInt32();
        _rangeMax = _settings.Call("get_range_max").AsInt32();

        // Seed each secondary positional axis's own range window (SetAxisRangeClamp
        // overrides live from Options). KnownAxes = the T-code names we dispatch.
        foreach (var axis in KnownAxes)
            _axisRanges[axis] = (
                _settings.Call("get_axis_range_min", axis).AsInt32(),
                _settings.Call("get_axis_range_max", axis).AsInt32());

        // Cache home-position config. SetHomePosition() can override these live
        // (called by Options on every slider change), but we also read them here
        // so the first round after a fresh launch picks up the saved values.
        _homePosition = Math.Clamp(_settings.Call("get_home_position").AsInt32(), 0, 100);
        _homeEaseMs = (uint)Math.Max(50, _settings.Call("get_home_ease_ms").AsInt32());

        // Cache device latency offset and vibrator intensity scale. Both can be
        // overridden live by Options via their setters, but seed from disk here.
        _latencyOffsetMs = _settings.Call("get_latency_offset_ms").AsInt32();
        _vibeIntensity = Math.Clamp(_settings.Call("get_vibe_intensity").AsInt32(), 0, 100) / 100f;
        _maxStrokeSpeed = Math.Max(0, _settings.Call("get_max_stroke_speed").AsInt32());

        if (_outputMode == OutputMode.Serial)
        {
            // Serial T-code devices are always linear; nothing else to resolve.
            _isLinearDevice = true;
            _deviceIndex = 0;
        }
        else
        {
            var bp = _buttplug;
            if (bp != null)
            {
                _deviceIndex = bp.GetSelectedDeviceIndex();
                _isLinearDevice = _deviceIndex >= 0 && bp.DeviceSupportsLinear(_deviceIndex);
                // Vibration channel count is fixed for the resolved device — cache it
                // so the per-frame vib dispatch never re-enumerates device features.
                _vibChannelCount = (_isLinearDevice == false && _deviceIndex >= 0) ? bp.GetVibrationChannelCount(_deviceIndex) : 0;
            }
        }
        _outputResolved = true;
    }

    private void SendCommand(int index)
    {
        ResolveOutput();

        var inv = _inventory;
        var effects = inv?.GetActiveEffects();

        // Advance the eased mirror factor before any block early-out so it keeps
        // settling toward its target even while a block effect suppresses output.
        UpdateMirrorBlend(effects);

        if (effects != null && HasBlockEffect(effects))
            return;

        int currentPos = TransformPos(index, effects);
        int nextPos = index + 1 < _actions.Count ? TransformPos(index + 1, effects) : currentPos;

        // Apply the user-configured device range as a RESCALE (lerp 0–100 → [min,max]),
        // not a hard clamp: strokes keep their shape/rhythm at reduced amplitude rather
        // than flat-topping and dwelling at the limit. Runs after inventory effects so
        // shop/curse modifiers compose first, then the whole motion is fit to the window.
        currentPos = RescaleToRange(currentPos);
        nextPos = RescaleToRange(nextPos);

        // Ease-in blend: interpolate from neutral (50) toward the script positions
        // over the computed ease duration. Both current and next are blended so the
        // device doesn't receive an inconsistent target during the blend window.
        // Vibrators are exempt — _StartEaseIn() never sets _easing for them, but
        // guard here too so any stale flag can never affect vibrator output.
        if (_easing && _isLinearDevice != false)
        {
            double elapsed = _positionMs - _easeStartMs;
            float t = (float)Math.Clamp(elapsed / _easeDurationMs, 0.0, 1.0);
            // Smoothstep (ease-in-out Hermite) — feels natural for device motion.
            float smooth = t * t * (3f - 2f * t);
            // Blend from the home position (where the device actually is) toward
            // the script position. Secondary axes still use 50 as their anchor
            // since they always home to centre.
            currentPos = (int)Math.Round(_homePosition + (currentPos - _homePosition) * smooth);
            nextPos    = (int)Math.Round(_homePosition + (nextPos    - _homePosition) * smooth);
            if (elapsed >= _easeDurationMs)
                _easing = false;
        }

        // Safety net: the device must never receive an out-of-range command. The
        // rescale above keeps script motion in-window; this hard clamp backstops the
        // ease-from-home blend (home can sit outside a tight range) and any rounding.
        currentPos = Math.Clamp(currentPos, _rangeMin, _rangeMax);
        nextPos = Math.Clamp(nextPos, _rangeMin, _rangeMax);

        // Scoring is always driven by the main (L0) funscript's position deltas,
        // even when vib scripts are loaded and actually driving the device. This
        // keeps the scoring basis consistent regardless of the connected device.
        if (index + 1 < _actions.Count)
        {
            int amplitude = Math.Abs(nextPos - currentPos);
            _score?.AddStroke(amplitude);
        }

        if (_outputMode == OutputMode.Serial)
        {
            var serial = _serial;

            if (serial == null || !serial.SerialConnected)
                return;

            if (index + 1 >= _actions.Count)
                return;

            double targetNormalised = nextPos / 100.0;
            uint durationMs = (uint)Math.Max(1, (int)(_actions[index + 1].AtMs - _actions[index].AtMs));
            durationMs = _CapDuration(currentPos, nextPos, durationMs);
            serial.SendLinear(durationMs, targetNormalised);

            return;
        }

        var bp = _buttplug;
        if (bp == null || !bp.BpConnected || _deviceIndex < 0)
            return;

        if (_isLinearDevice == true)
        {
            if (index + 1 >= _actions.Count)
                return;

            double targetNormalised = nextPos / 100.0;
            uint durationMs = (uint)Math.Max(1, (int)(_actions[index + 1].AtMs - _actions[index].AtMs));
            durationMs = _CapDuration(currentPos, nextPos, durationMs);
            bp.SendLinear(_deviceIndex, durationMs, targetNormalised);
        }
        else
        {
            // Vibrators: hold the current keyframe intensity.
            // Skip if vib scripts are loaded — per-channel dispatch runs in _Process().
            if (_vibScripts.Count == 0)
                bp.SendVibrate(_deviceIndex, currentPos / 100.0 * _vibeIntensity);
        }
    }

    private static bool HasBlockEffect(Godot.Collections.Array effects)
    {
        foreach (var effectVariant in effects)
        {
            var effect = effectVariant.AsGodotDictionary();
            if (effect.ContainsKey("kind") && effect["kind"].AsString() == "block")
                return true;
        }
        return false;
    }

    // Advances the eased mirror factor toward its target — 1 when an odd number
    // of "reverse" effects are active (even counts cancel), else 0. Driven by the
    // playback clock so the ease freezes with playback and never jumps across a
    // pause; seeks / clock resets snap straight to the target.
    private void UpdateMirrorBlend(Godot.Collections.Array effects)
    {
        int reverseCount = 0;
        if (effects != null)
        {
            foreach (var effectVariant in effects)
            {
                var effect = effectVariant.AsGodotDictionary();
                if (effect.ContainsKey("kind") && effect["kind"].AsString() == "reverse")
                    reverseCount++;
            }
        }
        float target = (reverseCount % 2 != 0) ? 1f : 0f;

        double dt = double.IsNaN(_mirrorClockMs) ? 0.0 : _positionMs - _mirrorClockMs;
        _mirrorClockMs = _positionMs;
        // A negative or larger-than-ease-window gap is a seek/reset — treat the
        // ease as already elapsed so the blend snaps rather than crawling.
        if (dt < 0.0 || dt > MirrorEaseMs)
            dt = MirrorEaseMs;

        _mirrorBlend = Mathf.MoveToward(_mirrorBlend, target, (float)(dt / MirrorEaseMs));
    }

    // Applies the eased mirror flip to a single position (toward 100 - v).
    private float MirrorOne(float v)
    {
        return _mirrorBlend > 0f ? Mathf.Lerp(v, 100f - v, _mirrorBlend) : v;
    }

    // Transforms the action at `index`: mirror, then scale each stroke around its
    // LOCAL centre (the midpoint of its neighbours), then remap into clamp range.
    // Local-centre scaling grows/shrinks each stroke's amplitude in place rather
    // than around a global 50, so strokes near the rails keep their shape instead
    // of being squashed by the 0–100 clamp. Multiple scale effects stack
    // multiplicatively; clamps apply successively. The mirror uses the eased
    // _mirrorBlend so it is never an instant reversal — see UpdateMirrorBlend.
    // Maps a 0–100 script position into the user's device range window by RESCALING
    // (lerp), not hard-clamping — so a stroke keeps its shape and rhythm at reduced
    // amplitude instead of flat-topping/dwelling at the limit. Output is guaranteed
    // within [_rangeMin, _rangeMax] for in-range input; a final Math.Clamp safety
    // net at the send site backstops the ease-from-home blend and any rounding.
    private int RescaleToRange(int pos)
    {
        double n = Math.Clamp(pos, 0, 100) / 100.0;
        return (int)Math.Round(_rangeMin + (_rangeMax - _rangeMin) * n);
    }

    // Per-axis variant of RescaleToRange: maps a 0–100 script position into a
    // secondary axis's own [min,max] window. Lets each positional axis have an
    // independent travel range (see the multi-axis dispatch in _Process).
    private static int RescaleToAxisRange(int pos, int min, int max)
    {
        double n = Math.Clamp(pos, 0, 100) / 100.0;
        return (int)Math.Round(min + (max - min) * n);
    }

    private int TransformPos(int index, Godot.Collections.Array effects)
    {
        float pos = MirrorOne(_actions[index].Pos);

        if (effects == null || effects.Count == 0)
            return (int)Math.Round(Math.Clamp(pos, 0f, 100f));

        // Combined scale factor — all scale effects multiply.
        float scaleFactor = 1f;
        foreach (var effect in effects)
        {
            var effectProp = effect.AsGodotDictionary();
            if (effectProp.ContainsKey("kind") && effectProp["kind"].AsString() == "scale" && effectProp.ContainsKey("factor"))
                scaleFactor *= effectProp["factor"].AsSingle();
        }
        if (!Mathf.IsEqualApprox(scaleFactor, 1f))
        {
            // Scale around the midpoint of the neighbouring points (clamped to the
            // ends), so each stroke's amplitude scales about its own centre.
            float prev = MirrorOne(_actions[Math.Max(0, index - 1)].Pos);
            float next = MirrorOne(_actions[Math.Min(_actions.Count - 1, index + 1)].Pos);
            float center = (prev + next) * 0.5f;
            pos = center + (pos - center) * scaleFactor;
        }

        foreach (var effect in effects)
        {
            var effectProp = effect.AsGodotDictionary();
            if (effectProp.ContainsKey("kind") && effectProp["kind"].AsString() == "clamp")
            {
                float minV = effectProp.ContainsKey("min") ? effectProp["min"].AsSingle() : 0f;
                float maxV = effectProp.ContainsKey("max") ? effectProp["max"].AsSingle() : 100f;
                pos = minV + Math.Clamp(pos, 0f, 100f) / 100f * (maxV - minV);
            }
        }

        return (int)Math.Round(Math.Clamp(pos, 0f, 100f));
    }
}
