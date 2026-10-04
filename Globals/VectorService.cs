using Godot;
using System;
using System.Collections.Generic;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;

// T-code output to Vector 1A (MFP-style TCP listener on :12345).
// Sends L0 stroke (4-digit) plus T0/T1 session timeline (5-digit). Vector generates
// the remaining Restim axes and forwards to Restim over WebSocket.
public partial class VectorService : Node
{
    [Signal] public delegate void ConnectedEventHandler();
    [Signal] public delegate void DisconnectedEventHandler();
    [Signal] public delegate void ErrorOccurredEventHandler(string message);

    public const string DefaultHost = "127.0.0.1";
    public const int DefaultPort = 12345;
    public const string StrokeAxis = "L0";
    public const string TimelinePositionAxis = "T0";
    public const string TimelineDurationAxis = "T1";

    private const int ConnectTimeoutMs = 8000;
    private const int SendQueueCapacity = 256;

    private TcpClient _client;
    private NetworkStream _stream;
    private CancellationTokenSource _cts;
    private Channel<string> _sendChannel;

    // Named VectorConnected (not Connected) to avoid clashing with the generated Connected signal.
    public bool VectorConnected => _stream != null && _client?.Connected == true;

    public override void _Ready()
    {
        var settings = GetNode("/root/SettingsService");
        if (!settings.Call("get_vector_auto_connect").AsBool())
            return;
        if (!settings.Call("get_vector_enabled").AsBool())
            return;
        string host = settings.Call("get_vector_host").AsString();
        int port = settings.Call("get_vector_port").AsInt32();
        Connect(host, port);
    }

    public async void Connect(string host, int port)
    {
        Disconnect();

        host = string.IsNullOrWhiteSpace(host) ? DefaultHost : host.Trim();
        if (port <= 0)
            port = DefaultPort;

        var client = new TcpClient();
        try
        {
            using var connectCts = new CancellationTokenSource(ConnectTimeoutMs);
            await client.ConnectAsync(host, port, connectCts.Token).ConfigureAwait(false);

            _client = client;
            _stream = client.GetStream();
            _cts = new CancellationTokenSource();
            _sendChannel = Channel.CreateBounded<string>(new BoundedChannelOptions(SendQueueCapacity)
            {
                FullMode = BoundedChannelFullMode.DropOldest,
                SingleReader = true,
            });

            _ = Task.Run(() => SendLoop(_stream, _sendChannel, _cts.Token));

            Callable.From(() =>
            {
                var serial = GetNodeOrNull<SerialDeviceService>("/root/SerialDeviceService");
                serial?.Disconnect();
                GetNodeOrNull<RestimService>("/root/RestimService")?.Disconnect();
                EmitSignal(SignalName.Connected);
            }).CallDeferred();
        }
        catch (OperationCanceledException)
        {
            client.Dispose();
            _EmitError("Vector connection timed out — is Vector 1A listening on the configured port?");
        }
        catch (Exception e)
        {
            client.Dispose();
            _EmitError($"Vector connection failed: {e.Message}");
        }
    }

    public void Disconnect()
    {
        var stream = _stream;
        var client = _client;
        var cts = _cts;
        var chan = _sendChannel;
        _stream = null;
        _client = null;
        _cts = null;
        _sendChannel = null;

        if (stream == null && client == null)
            return;

        chan?.Writer.TryComplete();
        try { cts?.Cancel(); } catch { /* best effort */ }
        try { stream?.Close(); } catch { }
        try { client?.Close(); } catch { }
        try { cts?.Dispose(); } catch { }
        try { client?.Dispose(); } catch { }

        Callable.From(() => EmitSignal(SignalName.Disconnected)).CallDeferred();
    }

    // Queue a single 4-digit T-code command. value01 is 0-1; intervalMs>0 adds an "I" hint.
    public void SendTCode(string axis, double value01, uint intervalMs = 0)
    {
        var chan = _sendChannel;
        if (chan == null)
            return;
        chan.Writer.TryWrite(FormatTCode(axis, value01, intervalMs));
    }

    // Queue a 5-digit timeline axis (T0/T1) in absolute media seconds.
    public void SendTimelineAxis(string axis, double seconds)
    {
        var chan = _sendChannel;
        if (chan == null)
            return;
        chan.Writer.TryWrite(SessionTimeline.FormatTimelineAxis(axis, seconds));
    }

    // Queue several commands as one space-separated packet.
    public void SendBatch(IEnumerable<(string axis, double value01, uint intervalMs)> commands)
    {
        var chan = _sendChannel;
        if (chan == null)
            return;

        var sb = new StringBuilder();
        foreach (var (axis, value01, intervalMs) in commands)
        {
            if (sb.Length > 0)
                sb.Append(' ');
            sb.Append(FormatTCode(axis, value01, intervalMs));
        }
        if (sb.Length > 0)
            chan.Writer.TryWrite(sb.ToString());
    }

    public void SendStrokeAndTimeline(double stroke01, uint strokeIntervalMs, double t0Sec, double t1Sec)
    {
        var chan = _sendChannel;
        if (chan == null)
            return;

        var sb = new StringBuilder();
        sb.Append(FormatTCode(StrokeAxis, stroke01, strokeIntervalMs));
        sb.Append(' ');
        sb.Append(SessionTimeline.FormatTimelineAxis(TimelinePositionAxis, t0Sec));
        sb.Append(' ');
        sb.Append(SessionTimeline.FormatTimelineAxis(TimelineDurationAxis, t1Sec));
        chan.Writer.TryWrite(sb.ToString());
    }

    // "AABBBB[ICCCC]" — 4-digit value (matches SerialDeviceService / OutputPrecision:4).
    public static string FormatTCode(string axis, double value01, uint intervalMs = 0)
    {
        int ticks = Math.Clamp((int)Math.Round(value01 * 9999.0), 0, 9999);
        string suffix = intervalMs > 0 ? $"I{intervalMs}" : "";
        return $"{axis.ToUpperInvariant()}{ticks:D4}{suffix}";
    }

    // Queue one EVT trigger line (own TCP line — never batched with L0/T0). Skips if disconnected.
    public void SendEvt(string name, Godot.Collections.Dictionary parameters = null)
    {
        var chan = _sendChannel;
        if (chan == null)
            return;
        chan.Writer.TryWrite(FormatEvt(name, parameters));
    }

    // Overload without params — GDScript optional C# defaults are unreliable across the interop boundary.
    public static string FormatEvt(string name)
    {
        return FormatEvt(name, null);
    }

    // "EVT name=<name> key=value …" — Vector parse_evt_line (shlex); first token must be EVT.
    public static string FormatEvt(string name, Godot.Collections.Dictionary parameters)
    {
        var sb = new StringBuilder();
        sb.Append("EVT name=");
        sb.Append(name ?? "");
        if (parameters == null || parameters.Count == 0)
            return sb.ToString();

        foreach (var key in parameters.Keys)
        {
            sb.Append(' ');
            sb.Append(key.AsString());
            sb.Append('=');
            sb.Append(FormatEvtValue(parameters[key]));
        }
        return sb.ToString();
    }

    private static string FormatEvtValue(Variant value)
    {
        switch (value.VariantType)
        {
            case Variant.Type.Bool:
                return value.AsBool() ? "true" : "false";
            case Variant.Type.Int:
                return value.AsInt64().ToString(System.Globalization.CultureInfo.InvariantCulture);
            case Variant.Type.Float:
            {
                double d = value.AsDouble();
                if (!double.IsNaN(d) && !double.IsInfinity(d) && d == Math.Truncate(d)
                    && d >= long.MinValue && d <= long.MaxValue)
                    return ((long)d).ToString(System.Globalization.CultureInfo.InvariantCulture);
                return d.ToString(System.Globalization.CultureInfo.InvariantCulture);
            }
            default:
            {
                string s = value.AsString() ?? "";
                if (s.IndexOfAny(new[] { ' ', '\t', '"' }) >= 0)
                    return "\"" + s.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
                return s;
            }
        }
    }

    private async Task SendLoop(NetworkStream stream, Channel<string> chan, CancellationToken token)
    {
        try
        {
            while (await chan.Reader.WaitToReadAsync(token).ConfigureAwait(false))
            {
                while (chan.Reader.TryRead(out string msg))
                {
                    var bytes = Encoding.ASCII.GetBytes(msg + "\n");
                    await stream.WriteAsync(bytes, token).ConfigureAwait(false);
                }
            }
        }
        catch (OperationCanceledException) { /* normal on disconnect */ }
        catch (Exception e)
        {
            _OnLoopFailure($"Vector send failed: {e.Message}");
        }
    }

    private void _OnLoopFailure(string message)
    {
        if (_stream == null)
            return;
        _stream = null;
        _sendChannel?.Writer.TryComplete();
        _sendChannel = null;
        try { _cts?.Cancel(); } catch { }
        try { _client?.Close(); } catch { }
        try { _client?.Dispose(); } catch { }
        _client = null;
        if (!string.IsNullOrEmpty(message))
            Callable.From(() => EmitSignal(SignalName.ErrorOccurred, message)).CallDeferred();
        Callable.From(() => EmitSignal(SignalName.Disconnected)).CallDeferred();
    }

    private void _EmitError(string message)
    {
        Callable.From(() => EmitSignal(SignalName.ErrorOccurred, message)).CallDeferred();
    }

    // On app quit, neutralize stroke position then close.
    public override void _Notification(int what)
    {
        if (what != NotificationWMCloseRequest && what != NotificationExitTree)
            return;

        var stream = _stream;
        if (stream == null)
            return;

        try { _cts?.Cancel(); } catch { }

        try
        {
            var bytes = Encoding.ASCII.GetBytes($"{FormatTCode(StrokeAxis, 0.5)}\n");
            stream.Write(bytes, 0, bytes.Length);
        }
        catch (Exception e)
        {
            GD.PrintErr($"VectorService: shutdown stop failed: {e.Message}");
        }
        try { stream.Close(); } catch { }
        try { _client?.Close(); } catch { }
        try { _client?.Dispose(); } catch { }
        _stream = null;
        _client = null;
    }
}
