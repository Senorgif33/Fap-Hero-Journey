using Godot;
using Godot.Collections;
using System;
using System.Collections.Generic;

public partial class FunscriptPlayer : Node
{
    private struct Action { public float AtMs; public int Pos; }

    // Per-axis state for secondary T-code channels (L1–L2, R0–R2, E1–E4).
    // Serial + Restim T-code — Buttplug ignores these entirely.
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

    // Activity-driven constrict (pneumatic squeeze) state machine. Pure logic — fed stroke activity
    // (funscript units/sec) + script progress, outputs a discrete level (0/1/2) with sustain + min-hold
    // hysteresis so it engages/releases smoothly instead of chattering. Config seeded in ResolveOutput.
    private sealed class ConstrictController
    {
        public int MaxLevel = 1;
        public double L1Threshold = 45.0, L1SustainMs = 5000.0;
        public double ReleaseThreshold = 25.0, ReleaseSustainMs = 10000.0;
        public double MinHoldMs = 12000.0;
        public bool L2Enabled = false;
        public double L2Threshold = 90.0, L2SustainMs = 8000.0, L2FinalPct = 12.0;
        public bool HoldOnPause = true;

        public int Level { get; private set; }
        private double _aboveL1Ms, _belowReleaseMs, _aboveL2Ms, _heldMs;

        public void Reset()
        {
            Level = 0;
            _aboveL1Ms = _belowReleaseMs = _aboveL2Ms = _heldMs = 0.0;
        }

        // Advance by dtMs with the current stroke activity (units/sec) and script progress (0–100).
        public void Update(double dtMs, double activity, double progressPct, bool playing)
        {
            if (!playing)
            {
                if (!HoldOnPause)
                    Reset();
                return; // held (frozen) while paused when HoldOnPause
            }

            if (Level == 0)
            {
                if (activity >= L1Threshold)
                {
                    _aboveL1Ms += dtMs;
                    if (_aboveL1Ms >= L1SustainMs)
                    {
                        Level = 1;
                        _heldMs = 0.0;
                        _belowReleaseMs = 0.0;
                        _aboveL2Ms = 0.0;
                    }
                }
                else
                {
                    _aboveL1Ms = 0.0;
                }
                return;
            }

            // Engaged (level >= 1).
            _heldMs += dtMs;

            // Level-2 promotion — enabled, allowed, and only in the final stretch of the script.
            if (Level == 1 && L2Enabled && MaxLevel >= 2)
            {
                if (activity >= L2Threshold && progressPct >= (100.0 - L2FinalPct))
                {
                    _aboveL2Ms += dtMs;
                    if (_aboveL2Ms >= L2SustainMs)
                        Level = 2;
                }
                else
                {
                    _aboveL2Ms = 0.0;
                }
            }

            // Release — sustained low activity AND the minimum hold has elapsed.
            if (activity < ReleaseThreshold)
            {
                _belowReleaseMs += dtMs;
                if (_belowReleaseMs >= ReleaseSustainMs && _heldMs >= MinHoldMs)
                    Reset();
            }
            else
            {
                _belowReleaseMs = 0.0;
            }
        }
    }

    // Maps T-code axis name → its loaded script state.
    // Explicitly System.Collections.Generic — AxisState is a C# class, not a Godot Variant.
    private readonly System.Collections.Generic.Dictionary<string, AxisState> _axes =
        new System.Collections.Generic.Dictionary<string, AxisState>();

    // Maps vibrator channel index → its loaded script state.
    private readonly System.Collections.Generic.Dictionary<int, VibState> _vibScripts =
        new System.Collections.Generic.Dictionary<int, VibState>();

    private static readonly string[] SsrAxes = { "L1", "L2", "R0", "R1", "R2" };

    private enum StrokeBackend { None, Serial, Buttplug, Restim }

    private List<Action> _actions = new List<Action>();

    // "V motion" beats — local minima in the L0 track — for the optional beat-bar
    // visualiser. Each entry is (AtMs, depth) where depth is the 0–100 dip size.
    private readonly List<Vector2> _beats = new List<Vector2>();

    private bool _playing = false;
    private double _positionMs = 0.0;
    private int _actionIndex = 0;
    // Resolved routing plan (rebuilt by BuildRoutingPlan): the stroke has one target; vibe actuators
    // fan out per their source (vibe1 / vibe2 / stroke); constrict actuators run the auto state machine.
    private StrokeBackend _strokeBackend = StrokeBackend.None;
    private int _strokeDeviceIndex = -1;   // Buttplug linear device index when _strokeBackend == Buttplug
    private readonly List<(int Index, int Channel, string Source)> _vibeRoutes = new List<(int Index, int Channel, string Source)>();
    private readonly List<(int Index, int Channel)> _constrictRoutes = new List<(int Index, int Channel)>();
    private bool _syncedThisFrame = false;

    // Constrict auto state machine — driven by smoothed stroke activity (units/sec), updated on a throttle.
    private readonly ConstrictController _constrict = new ConstrictController();
    private double _strokeActivity = 0.0;
    private double _constrictTickMs = 0.0;
    private int _lastConstrictLevel = -1;
    private const double ConstrictTickIntervalMs = 200.0;
    private const double ActivityDecayHalfLifeMs = 2000.0;
    private bool _outputResolved = false;
    private int _rangeMin = 0;
    private int _rangeMax = 100;

    // Per-axis range window for the secondary positional axes (L1/L2/R0/R1/R2/E1–E4),
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
    /// A positive delay pushes the device (and this reported position) LATER.
    public double PositionMs => _positionMs - StrokeDelay();

    // Cached autoload references — resolved once instead of looked up per-call
    // (some were hit every frame, per axis, inside _Process). FunscriptPlayer is
    // a late autoload, so all of these exist by the time _Ready runs.
    private SerialDeviceService _serial;
    private Node _restim;
    private ButtplugService _buttplug;
    private InventoryService _inventory;
    private ScoreService _score;
    private Node _settings;

    // The pure route resolver (GDScript static, unit-tested). Loaded once; called with the settings
    // config + the live Buttplug catalog to produce the dispatch plan.
    private GDScript _deviceRoutingScript;
    private GDScript _restimKit;

    public override void _Ready()
    {
        _serial = GetNode<SerialDeviceService>("/root/SerialDeviceService");
        _restim = GetNode("/root/RestimService");
        _buttplug = GetNode<ButtplugService>("/root/ButtplugService");
        _inventory = GetNode<InventoryService>("/root/InventoryService");
        _score = GetNode<ScoreService>("/root/ScoreService");
        _settings = GetNode("/root/SettingsService");
        _deviceRoutingScript = GD.Load<GDScript>("res://scripts/device/DeviceRouting.gd");
        _restimKit = GD.Load<GDScript>("res://scripts/device/RestimAxisKit.gd");
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
        // Fully invalidate the resolve cache — a new round must rebuild the routing plan.
        // _outputResolved = false forces Play()/Resume() to re-run BuildRoutingPlan even if Options
        // was opened between rounds (Pause → EaseToNeutral → ResolveOutput would otherwise leave it true).
        _strokeBackend = StrokeBackend.None;
        _strokeDeviceIndex = -1;
        _vibeRoutes.Clear();
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
            int cur = _actions[i].Pos;
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

    // Per-backend latency compensation — shifts each output stream's sample time relative to the
    // playback clock to offset device / Bluetooth / serial lag. Positive = that backend acts earlier.
    // Applied per stream in _Process (stroke uses its backend's delay; vibe = intiface; axes = serial).
    private int _serialDelayMs = 0;
    private int _intifaceDelayMs = 0;

    // Vibrator output scale (0–1). Applied to every vibration command so the
    // user can dial overall strength down. No effect on linear devices.
    private float _vibeIntensity = 1.0f;

    // Max stroke speed for linear (L0) output, in funscript units/sec.
    // 0 = unlimited. Moves faster than the cap are slowed by stretching duration.
    private int _maxStrokeSpeed = 0;

    /// Live-update both per-backend delays together (the legacy single Options slider). Slice 4's UI
    /// and the in-play hotkeys use the per-backend setters below.
    public void SetLatencyOffset(int offsetMs)
    {
        _serialDelayMs = offsetMs;
        _intifaceDelayMs = offsetMs;
    }

    /// Live-update the serial (T-code) output delay, in milliseconds.
    public void SetSerialDelay(int ms) => _serialDelayMs = ms;

    /// Live-update the Intiface (Buttplug) output delay, in milliseconds.
    public void SetIntifaceDelay(int ms) => _intifaceDelayMs = ms;

    // Delay for whichever backend currently drives the stroke (serial or Buttplug), 0 if none. Also
    // offsets PositionMs so the beat-bar HUD stays aligned with the stroker.
    private double StrokeDelay() =>
        _strokeBackend == StrokeBackend.Serial ? _serialDelayMs
        : (_strokeBackend == StrokeBackend.Buttplug ? _intifaceDelayMs : 0.0);

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
                Pos = action.ContainsKey("pos") ? action["pos"].AsInt32() : 0,
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
        if (_axes.Count == 0 || !ShouldDispatchAxisScripts())
            return;

        foreach (var axis in GetAutofillAxisKeys())
        {
            if (!_axes.ContainsKey(axis) && HasTcodeForAxis(axis))
                SendTcodeAxis(TcodeForAxisKey(axis), AxisParkMs, 0.5);
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

        // Release constrict actuators before dropping the routes, then reset the state machine.
        var bpc = _buttplug;
        if (bpc != null && bpc.BpConnected)
        {
            foreach (var route in _constrictRoutes)
                bpc.SendConstrictLevel(route.Index, route.Channel, 0);
        }
            
        _constrict.Reset();
        _lastConstrictLevel = -1;
        _strokeActivity = 0.0;

        _strokeBackend = StrokeBackend.None;
        _strokeDeviceIndex = -1;
        _vibeRoutes.Clear();
        _constrictRoutes.Clear();
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
        if (_strokeBackend == StrokeBackend.None)
            return; // no stroke target: nothing to ease

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

        // Stroke target homes to the user position.
        if (_strokeBackend == StrokeBackend.Buttplug)
        {
            var bp = _buttplug;
            if (bp != null && bp.BpConnected && _strokeDeviceIndex >= 0)
                bp.SendLinear(_strokeDeviceIndex, _homeEaseMs, homeNorm);
        }
        else if (IsTcodeStrokeBackend())
        {
            SendTcodeAxis("L0", _homeEaseMs, homeNorm);
            foreach (var axis in _axes.Keys)
            {
                string tcode = TcodeForAxisKey(axis);
                if (!string.IsNullOrEmpty(tcode))
                    SendTcodeAxis(tcode, _homeEaseMs, 0.5);
            }
        }

        // Vibe actuators → intensity 0.

        // Silence every mapped vibe actuator.
        var bpv = _buttplug;
        if (bpv != null && bpv.BpConnected)
            foreach (var route in _vibeRoutes)
                bpv.SendVibrateChannel(route.Index, route.Channel, 0.0);
    }

    // Call this each frame from GameLoop to keep funscript in sync with the video clock.
    // Only updates _positionMs — _Process is responsible for dispatching due actions.
    public void SyncTo(double videoPositionSec)
    {
        // Raw playback clock — per-backend delay is applied per stream in _Process, not baked in here.
        _positionMs = videoPositionSec * 1000.0;
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

            // A positive delay holds each action back (fires it LATER); negative fires it ahead.
            double strokeDelay = StrokeDelay();
            while (_actionIndex < _actions.Count)
            {
                if (_actions[_actionIndex].AtMs > _positionMs - strokeDelay)
                    break;

                SendCommand(_actionIndex);
                _actionIndex++;
            }

            // Secondary / Restim-kit axes → Restim (when it's the stroke) or Serial (connected).
            // Alpha is sent as L0; when present it replaces the sparse main L0 on T-code stroke backends.
            // Restim intensity is V0-only: never TransformPos FOC axes; scale/block/volume_attenuate
            // fold into a V0 multiplier (see ComputeRestimVolumeFactor).
            if (ShouldDispatchAxisScripts())
                DispatchAxisScripts();

            // Vibe scripts (vibe1 / vibe2) → their mapped actuators, on the same clock as L0.
            if (_vibScripts.Count > 0)
            {
                foreach (var vibEntry in _vibScripts)
                {
                    string source = vibEntry.Key == 0 ? "vibe1" : "vibe2";
                    var vstate = vibEntry.Value;
                    while (vstate.Index < vstate.Actions.Count)
                    {
                        if (vstate.Actions[vstate.Index].AtMs > _positionMs - _intifaceDelayMs)
                            break;

                        double intensity = vstate.Actions[vstate.Index].Pos / 100.0 * _vibeIntensity;
                        SendToVibeSource(source, intensity);
                        vstate.Index++;
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

            // Vibrators can't interpolate — update mapped actuators frequently with a triangle wave.
            if (_vibeRoutes.Count > 0)
            {
                _fillerVibTickMs += delta * 1000.0;
                if (_fillerVibTickMs >= FillerVibTickIntervalMs)
                {
                    _fillerVibTickMs = 0.0;
                    _SendFillerVibrateTick();
                }
            }
        }

        // Constrict auto state machine — throttled; runs even while paused so it can hold/release.
        if (_constrictRoutes.Count > 0)
        {
            _constrictTickMs += delta * 1000.0;
            if (_constrictTickMs >= ConstrictTickIntervalMs)
            {
                double dt = _constrictTickMs;
                _constrictTickMs = 0.0;

                // Decay activity so gaps between keyframes wind it down toward release.
                _strokeActivity *= Math.Pow(0.5, dt / ActivityDecayHalfLifeMs);
                double lastMs = _actions.Count > 0 ? _actions[_actions.Count - 1].AtMs : 0.0;
                double progressPct = lastMs > 0.0 ? Math.Clamp(_positionMs / lastMs * 100.0, 0.0, 100.0) : 0.0;
                _constrict.Update(dt, _strokeActivity, progressPct, _playing);

                if (_constrict.Level != _lastConstrictLevel)
                {
                    _lastConstrictLevel = _constrict.Level;
                    var bpc = _buttplug;
                    if (bpc != null && bpc.BpConnected)
                        foreach (var route in _constrictRoutes)
                            bpc.SendConstrictLevel(route.Index, route.Channel, _constrict.Level);
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

        // Linear filler → the stroke target. Vibrators are handled by _SendFillerVibrateTick.
        if (_strokeBackend == StrokeBackend.Buttplug)
        {
            var bp = _buttplug;
            if (bp != null && bp.BpConnected && _strokeDeviceIndex >= 0)
                bp.SendLinear(_strokeDeviceIndex, dur, target / 100.0);
        }
        else if (IsTcodeStrokeBackend())
        {
            SendTcodeAxis("L0", dur, target / 100.0);
        }
    }

    // Compute current triangle-wave intensity for a vibrator and send it.
    private void _SendFillerVibrateTick()
    {
        double t = Math.Clamp(_fillerElapsedMs / _fillerHalfCycleMs, 0.0, 1.0);
        double fromPos = _fillerGoingToLo ? _fillerHi : _fillerLo;
        double toPos = _fillerGoingToLo ? _fillerLo : _fillerHi;
        double pos = fromPos + (toPos - fromPos) * t;
        pos = Math.Clamp(pos, _rangeMin, _rangeMax);

        // Filler ignores per-actuator source (it's a global idle wave) → drive every vibe actuator.
        var bp = _buttplug;
        if (bp == null || !bp.BpConnected)
            return;
        double intensity = Math.Clamp(pos / 100.0 * _vibeIntensity, 0.0, 1.0);
        foreach (var route in _vibeRoutes)
            bp.SendVibrateChannel(route.Index, route.Channel, intensity);
    }

    private void ResolveOutput()
    {
        if (_outputResolved)
            return;

        // Cache device range limits so SendCommand doesn't hit disk per-action.
        _rangeMin = _settings.Call("get_range_min").AsInt32();
        _rangeMax = _settings.Call("get_range_max").AsInt32();

        // Seed each secondary axis range from settings (Restim ini autoload keys + SSR).
        foreach (var axis in GetAutofillAxisKeys())
            _axisRanges[axis] = (
                _settings.Call("get_axis_range_min", axis).AsInt32(),
                _settings.Call("get_axis_range_max", axis).AsInt32());

        // Cache home-position config. SetHomePosition() can override these live
        // (called by Options on every slider change), but we also read them here
        // so the first round after a fresh launch picks up the saved values.
        _homePosition = Math.Clamp(_settings.Call("get_home_position").AsInt32(), 0, 100);
        _homeEaseMs = (uint)Math.Max(50, _settings.Call("get_home_ease_ms").AsInt32());

        // Cache per-backend output delays + vibrator intensity scale. All can be overridden live via
        // their setters, but seed from disk here. The delay getters default to the legacy
        // latency_offset_ms, so existing setups carry their tuned value forward.
        _serialDelayMs = _settings.Call("get_serial_delay_ms").AsInt32();
        _intifaceDelayMs = _settings.Call("get_intiface_delay_ms").AsInt32();
        _vibeIntensity = Math.Clamp(_settings.Call("get_vibe_intensity").AsInt32(), 0, 100) / 100f;
        _maxStrokeSpeed = Math.Max(0, _settings.Call("get_max_stroke_speed").AsInt32());

        // Seed the constrict state machine's tuning from settings.
        _constrict.MaxLevel = _settings.Call("get_constrict_max_level").AsInt32();
        _constrict.L1Threshold = _settings.Call("get_constrict_level1_threshold").AsDouble();
        _constrict.L1SustainMs = _settings.Call("get_constrict_level1_sustain_ms").AsInt32();
        _constrict.ReleaseThreshold = _settings.Call("get_constrict_release_threshold").AsDouble();
        _constrict.ReleaseSustainMs = _settings.Call("get_constrict_release_sustain_ms").AsInt32();
        _constrict.MinHoldMs = _settings.Call("get_constrict_min_hold_ms").AsInt32();
        _constrict.L2Enabled = _settings.Call("get_constrict_level2_enabled").AsBool();
        _constrict.L2Threshold = _settings.Call("get_constrict_level2_threshold").AsDouble();
        _constrict.L2SustainMs = _settings.Call("get_constrict_level2_sustain_ms").AsInt32();
        _constrict.L2FinalPct = _settings.Call("get_constrict_level2_final_percent").AsDouble();
        _constrict.HoldOnPause = _settings.Call("get_constrict_hold_on_pause").AsBool();

        BuildRoutingPlan();
        _outputResolved = true;
    }

    // Rebuilds the stroke target + vibe routes from the saved routing config, resolved (by the pure
    // GDScript resolver) against the live Buttplug catalog. Falls back to the legacy
    // output_mode / selected_device when no routing has been configured yet, so existing single-device
    // setups keep working until they map devices in Options (Slice 4).
    private void BuildRoutingPlan()
    {
        _strokeBackend = StrokeBackend.None;
        _strokeDeviceIndex = -1;
        _vibeRoutes.Clear();
        _constrictRoutes.Clear();

        string strokeTarget = _settings.Call("get_stroke_target").AsString();
        var vibRoutes = _settings.Call("get_vibration_routes").AsGodotDictionary();
        var constrictRoutes = _settings.Call("get_constrict_routes").AsGodotDictionary();

        if (string.IsNullOrEmpty(strokeTarget) && vibRoutes.Count == 0)
        {
            BuildLegacyPlan();
            return;
        }

        var catalog = _buttplug != null ? _buttplug.GetDeviceCatalog() : new Godot.Collections.Array();
        var plan = _deviceRoutingScript
            .Call("resolve", strokeTarget, vibRoutes, constrictRoutes, catalog)
            .AsGodotDictionary();

        var stroke = plan["stroke"].AsGodotDictionary();
        if (stroke.Count > 0)
        {
            string backend = stroke["backend"].AsString();
            if (backend == "serial")
            {
                _strokeBackend = StrokeBackend.Serial;
            }
            else if (backend == "restim")
            {
                _strokeBackend = StrokeBackend.Restim;
            }
            else if (backend == "bp" && _buttplug != null)
            {
                int idx = _buttplug.GetDeviceIndexById(stroke["device"].AsString());
                if (idx >= 0)
                {
                    _strokeBackend = StrokeBackend.Buttplug;
                    _strokeDeviceIndex = idx;
                }
            }
        }

        foreach (var v in plan["vibration"].AsGodotArray())
        {
            var route = v.AsGodotDictionary();
            int idx = _buttplug != null ? _buttplug.GetDeviceIndexById(route["device"].AsString()) : -1;
            if (idx >= 0)
                _vibeRoutes.Add((idx, route["channel"].AsInt32(), route["source"].AsString()));
        }

        foreach (var c in plan["constrict"].AsGodotArray())
        {
            var route = c.AsGodotDictionary();
            int idx = _buttplug != null ? _buttplug.GetDeviceIndexById(route["device"].AsString()) : -1;
            if (idx >= 0)
                _constrictRoutes.Add((idx, route["channel"].AsInt32()));
        }
    }

    // Backward-compat: derive a plan from the pre-routing output_mode / selected_device so a user who
    // hasn't opened the new routing UI keeps their existing single device. Removed once routing is the
    // only path (Slice 4+).
    private void BuildLegacyPlan()
    {
        string mode = _settings.Call("get_output_mode").AsString();
        if (mode == "serial")
        {
            _strokeBackend = StrokeBackend.Serial;
            return;
        }
        if (mode == "restim")
        {
            _strokeBackend = StrokeBackend.Restim;
            return;
        }

        var bp = _buttplug;
        if (bp == null)
            return;
        int idx = bp.GetSelectedDeviceIndex();
        if (idx < 0)
            return;

        if (bp.DeviceSupportsLinear(idx))
        {
            _strokeBackend = StrokeBackend.Buttplug;
            _strokeDeviceIndex = idx;
        }
        else
        {
            // Vibrator: map each channel to its vib script, else follow the stroke — mirrors old behaviour.
            int channels = Math.Max(1, bp.GetVibrationChannelCount(idx));
            for (int ch = 0; ch < channels; ch++)
            {
                string source;
                if (_vibScripts.ContainsKey(ch))
                    source = ch == 0 ? "vibe1" : "vibe2";
                else if (_vibScripts.Count > 0)
                    source = "vibe1";
                else
                    source = "stroke";
                _vibeRoutes.Add((idx, ch, source));
            }
        }
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

        // Score from the post-effects amplitude BEFORE the comfort range-clamp, so narrowing the stroke
        // range to taste never costs points (range is comfort, not difficulty). Shop/curse effects are
        // already applied above and still count toward the score.
        int scoreAmplitude = Math.Abs(nextPos - currentPos);

        // Track smoothed stroke activity (raw script units/sec) for the constrict state machine.
        if (index + 1 < _actions.Count)
        {
            double segMs = _actions[index + 1].AtMs - _actions[index].AtMs;
            double speed = segMs > 0.0 ? Math.Abs(_actions[index + 1].Pos - _actions[index].Pos) / (segMs / 1000.0) : 0.0;
            _strokeActivity += (speed - _strokeActivity) * 0.5;
        }

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
        if (_easing)
        {
            double elapsed = _positionMs - _easeStartMs;
            float t = (float)Math.Clamp(elapsed / _easeDurationMs, 0.0, 1.0);
            // Smoothstep (ease-in-out Hermite) — feels natural for device motion.
            float smooth = t * t * (3f - 2f * t);
            // Blend from the home position (where the device actually is) toward
            // the script position. Secondary axes still use 50 as their anchor
            // since they always home to centre.
            currentPos = (int)Math.Round(_homePosition + (currentPos - _homePosition) * smooth);
            nextPos = (int)Math.Round(_homePosition + (nextPos - _homePosition) * smooth);
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
            _score?.AddStroke(scoreAmplitude);

        // Follow-stroke vibe actuators track the commanded stroke position as intensity.
        SendToVibeSource("stroke", currentPos / 100.0 * _vibeIntensity);

        // Stroke → the single stroke target. No target = score/vibe only.
        // When a Restim alpha track is loaded, L0 is driven from that axis script instead.
        if (index + 1 >= _actions.Count)
            return;
        if (IsTcodeStrokeBackend() && _axes.ContainsKey("alpha"))
            return;

        double targetNormalised = nextPos / 100.0;
        uint durationMs = (uint)Math.Max(1, (int)(_actions[index + 1].AtMs - _actions[index].AtMs));
        durationMs = _CapDuration(currentPos, nextPos, durationMs);

        if (_strokeBackend == StrokeBackend.Buttplug)
        {
            var bp = _buttplug;
            if (bp != null && bp.BpConnected && _strokeDeviceIndex >= 0)
                bp.SendLinear(_strokeDeviceIndex, durationMs, targetNormalised);
            return;
        }

        if (!IsTcodeStrokeBackend())
            return;

        SendTcodeAxis("L0", durationMs, targetNormalised);
    }

    private string[] GetAutofillAxisKeys()
    {
        if (_restimKit != null)
        {
            var arr = _restimKit.Call("all_autofill_axis_keys").AsGodotArray();
            var keys = new string[arr.Count];
            for (int i = 0; i < arr.Count; i++)
                keys[i] = arr[i].AsString();
            if (keys.Length > 0)
                return keys;
        }
        return SsrAxes;
    }

    private string TcodeForAxisKey(string axisKey)
    {
        if (_restimKit == null)
            return axisKey == "alpha" ? "L0" : axisKey;
        return _restimKit.Call("tcode_for", axisKey).AsString();
    }

    private bool HasTcodeForAxis(string axisKey) => !string.IsNullOrEmpty(TcodeForAxisKey(axisKey));

    private bool IsTcodeStrokeBackend() =>
        _strokeBackend == StrokeBackend.Serial || _strokeBackend == StrokeBackend.Restim;

    // Axis scripts play on Restim (stroke) or on Serial whenever a COM port is open
    // (SSR multi-axis alongside a Buttplug stroker).
    private bool ShouldDispatchAxisScripts() =>
        _strokeBackend == StrokeBackend.Restim
        || (_serial != null && _serial.SerialConnected);

    // Dispatches secondary / Restim-kit axes. On Restim stroke backend, intensity is
    // volume (V0) only: block mutes all axes + V0=0; scale and volume_attenuate multiply
    // V0; α/β/E1–E4 positions are never geometrically transformed.
    // Stock / linear journeys: when stroke backend is not Restim, volFactor stays 1 and
    // mute/inject never run — Handy/Buttplug/serial geometry is unchanged.
    private void DispatchAxisScripts()
    {
        var effects = _inventory?.GetActiveEffects();
        bool restimStroke = _strokeBackend == StrokeBackend.Restim;
        float volFactor = restimStroke
            ? ComputeRestimVolumeFactor(effects, includeScale: true)
            : 1f;
        bool muteAll = restimStroke && HasBlockEffect(effects);

        float easeSmooth = 1f;
        if (_easing)
        {
            double elapsed = _positionMs - _easeStartMs;
            float t = (float)Math.Clamp(elapsed / _easeDurationMs, 0.0, 1.0);
            easeSmooth = t * t * (3f - 2f * t); // smoothstep
        }

        if (muteAll)
        {
            // Consume due axis keyframes without sending FOC motion; hold V0 at silence.
            foreach (var multiaxis in _axes)
            {
                AxisState state = multiaxis.Value;
                while (state.Index < state.Actions.Count)
                {
                    if (state.Actions[state.Index].AtMs > _positionMs - _serialDelayMs)
                        break;
                    state.Index++;
                }
            }
            SendTcodeAxis("V0", 50, 0.0);
            return;
        }

        bool hasVolumeAxis = _axes.ContainsKey("volume");
        foreach (var multiaxis in _axes)
        {
            string axisKey = multiaxis.Key;
            AxisState state = multiaxis.Value;
            while (state.Index < state.Actions.Count)
            {
                if (state.Actions[state.Index].AtMs > _positionMs - _serialDelayMs)
                    break;

                int idx = state.Index;
                if (idx + 1 < state.Actions.Count)
                {
                    int nextPos = state.Actions[idx + 1].Pos;
                    (int axisMin, int axisMax) = GetAxisRange(axisKey);
                    nextPos = RescaleToAxisRange(nextPos, axisMin, axisMax);
                    if (_easing || easeSmooth < 1f)
                        nextPos = (int)Math.Round(50f + (nextPos - 50f) * easeSmooth);
                    nextPos = Math.Clamp(nextPos, axisMin, axisMax);

                    double targetNorm = nextPos / 100.0;
                    // Restim volume track: multiply scripted V0 by the intensity factor.
                    if (restimStroke && axisKey == "volume")
                        targetNorm = Math.Clamp(targetNorm * volFactor, 0.0, 1.0);

                    uint durMs = (uint)Math.Max(1, (int)(state.Actions[idx + 1].AtMs - state.Actions[idx].AtMs));
                    string tcode = TcodeForAxisKey(axisKey);
                    if (!string.IsNullOrEmpty(tcode))
                        SendTcodeAxis(tcode, durMs, targetNorm);
                }
                state.Index++;
            }
        }

        // No authored .volume script: inject constant V0 while intensity is attenuated.
        if (restimStroke && !hasVolumeAxis && !Mathf.IsEqualApprox(volFactor, 1f))
            SendTcodeAxis("V0", 50, Math.Clamp(volFactor, 0f, 1f));
    }

    /// <summary>
    /// Restim V0 intensity factor from active inventory/boss effects.
    /// Multiplies <c>volume_attenuate</c> factors; when <paramref name="includeScale"/>,
    /// also folds <c>scale</c> factors (Restim maps intensity to V0, not geometry).
    /// <c>block</c> forces 0. Result is clamped to [0, 1] at send time.
    /// Instance method so GDScript / tests can call it on the FunscriptPlayer autoload.
    /// </summary>
    public float ComputeRestimVolumeFactor(Godot.Collections.Array effects, bool includeScale = true)
    {
        if (effects == null || effects.Count == 0)
            return 1f;
        if (HasBlockEffect(effects))
            return 0f;

        float factor = 1f;
        foreach (var effectVariant in effects)
        {
            var effect = effectVariant.AsGodotDictionary();
            if (!effect.ContainsKey("kind"))
                continue;
            string kind = effect["kind"].AsString();
            if (!effect.ContainsKey("factor"))
                continue;
            if (kind == "volume_attenuate")
                factor *= effect["factor"].AsSingle();
            else if (includeScale && kind == "scale")
                factor *= effect["factor"].AsSingle();
        }
        return Mathf.Clamp(factor, 0f, 1f);
    }

    /// <summary>True when Restim axis scripts should be muted (block effect active).</summary>
    public bool RestimAxesMuted(Godot.Collections.Array effects) =>
        HasBlockEffect(effects);

    private bool RestimConnected() =>
        _restim != null && _restim.Get("RestimConnected").AsBool();

    private void SendTcodeAxis(string tcodeAxis, uint durationMs, double position)
    {
        if (string.IsNullOrEmpty(tcodeAxis))
            return;

        if (_strokeBackend == StrokeBackend.Restim && RestimConnected())
        {
            _restim.Call("SendAxis", tcodeAxis, (int)durationMs, position);
            return;
        }

        var serial = _serial;
        if (serial != null && serial.SerialConnected)
            serial.SendAxis(tcodeAxis, durationMs, position);
    }

    // Fan an intensity (0–1) out to every resolved vibe actuator whose source matches.
    private void SendToVibeSource(string source, double intensity)
    {
        if (_vibeRoutes.Count == 0)
            return;
        var bp = _buttplug;
        if (bp == null || !bp.BpConnected)
            return;
        double clamped = Math.Clamp(intensity, 0.0, 1.0);
        foreach (var route in _vibeRoutes)
            if (route.Source == source)
                bp.SendVibrateChannel(route.Index, route.Channel, clamped);
    }

    private static bool HasBlockEffect(Godot.Collections.Array effects)
    {
        if (effects == null)
            return false;
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

        // Combined scale factor — all scale / volume_attenuate effects multiply.
        // On Restim, intensity is folded into V0 instead (see ComputeRestimVolumeFactor);
        // skip geometric scale here so FOC players are not double-attenuated on L0.
        float scaleFactor = 1f;
        if (_strokeBackend != StrokeBackend.Restim)
        {
            foreach (var effect in effects)
            {
                var effectProp = effect.AsGodotDictionary();
                if (!effectProp.ContainsKey("kind") || !effectProp.ContainsKey("factor"))
                    continue;
                string kind = effectProp["kind"].AsString();
                if (kind == "scale" || kind == "volume_attenuate")
                    scaleFactor *= effectProp["factor"].AsSingle();
            }
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
