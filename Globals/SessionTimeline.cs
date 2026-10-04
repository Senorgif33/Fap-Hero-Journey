using System;

// Synthetic T0/T1 session timeline for Vector 1A media volume ramp.
// The game owns progress semantics; Vector applies floor/ceiling/curve from its GUI.
public sealed class SessionTimeline
{
    public const double TimelineScaleSeconds = 10000.0;
    public const int TimelineTcodeDigits = 5;

    private const double DefaultLevelDurationSec = 3600.0;
    private const double DefaultRampDurationSec = 600.0;
    private const double MinRampDurationSec = 180.0;

    private double _sittingElapsedSec;
    private double _rampDurationSec = DefaultRampDurationSec;
    private double _levelDurationSec = DefaultLevelDurationSec;
    private double _attenuationFactor = 1.0;
    private bool _running;

    public void ResetSitting()
    {
        _sittingElapsedSec = 0.0;
    }

    // Update the difficulty band for the current round without resetting sitting elapsed.
    public void ConfigureRound(int roundNumber, int totalRounds, double levelDurationSec,
        double stimRampMs = 0, double stimCeiling = 0)
    {
        if (levelDurationSec > 0)
            _levelDurationSec = levelDurationSec;
        else
            _levelDurationSec = DefaultLevelDurationSec;

        if (stimRampMs > 0)
        {
            _rampDurationSec = stimRampMs / 1000.0;
        }
        else
        {
            double t = totalRounds > 1
                ? Math.Clamp((roundNumber - 1.0) / (totalRounds - 1.0), 0.0, 1.0)
                : 0.0;
            // Later rounds ramp faster (shorter duration to reach ceiling).
            _rampDurationSec = Lerp(DefaultRampDurationSec, MinRampDurationSec, t);
        }

        // stimCeiling reserved for future journey meta; Vector GUI owns the actual curve today.
        _ = stimCeiling;
    }

    public void SetAttenuationFactor(double factor)
    {
        _attenuationFactor = Math.Clamp(factor, 0.0, 1.0);
    }

    public void SetRunning(bool running)
    {
        _running = running;
    }

    public void Tick(double deltaSec)
    {
        if (!_running || deltaSec <= 0)
            return;
        _sittingElapsedSec += deltaSec;
    }

    public (double t0Sec, double t1Sec) GetTimelineSeconds()
    {
        double progress = _rampDurationSec > 0
            ? Math.Clamp(_sittingElapsedSec / _rampDurationSec, 0.0, 1.0)
            : 1.0;
        progress *= _attenuationFactor;
        double t0 = progress * _levelDurationSec;
        return (t0, _levelDurationSec);
    }

    public double GetPositionSeconds() => GetTimelineSeconds().t0Sec;

    public double GetDurationSeconds() => GetTimelineSeconds().t1Sec;

    public double GetProgress()
    {
        double duration = GetDurationSeconds();
        return duration > 0 ? GetPositionSeconds() / duration : 0.0;
    }

    // Encode timeline axis seconds as 5-digit T-code (matches vector1a/timeline.py).
    public static string FormatTimelineAxis(string axis, double seconds)
    {
        double encoded = seconds / TimelineScaleSeconds;
        int ticks = Math.Clamp((int)Math.Round(encoded * Math.Pow(10, TimelineTcodeDigits)), 0,
            (int)Math.Pow(10, TimelineTcodeDigits) - 1);
        return $"{axis.ToUpperInvariant()}{ticks.ToString().PadLeft(TimelineTcodeDigits, '0')}";
    }

    private static double Lerp(double a, double b, double t) => a + (b - a) * t;
}
