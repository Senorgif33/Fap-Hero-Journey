using Godot;
using System;
using System.Collections.Generic;
using System.Net.WebSockets;
using System.Text;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;

// Network T-code output to a running restim instance (e-stim).
// restim exposes a WebSocket T-code endpoint (default ws://127.0.0.1:12346/tcode)
// that accepts plain-text frames of whitespace-separated T-code commands, e.g.
// "L05000I100" or "L05000 V02000". This service is a thin WebSocket client that
// formats the game's normalized 0-1 axis values as T-code and streams them there.
//
// Wire format matches SerialDeviceService and the "E-Stim Full" profile's
// OutputPrecision:4 — "AABBBB[ICCCC]": 2-char axis id, 4-digit value (value/10000),
// optional interval in ms. restim clamps the value to 0-1 and remaps to the target range.
//
// The mapping from game funscript slots to restim axes (baked from MultiFunPlayer's
// "E-Stim Full" device profile) lives in the static members below; FunscriptPlayer
// owns the routing policy and calls SendTCode / SendBatch.
public partial class RestimService : Node
{
    [Signal] public delegate void ConnectedEventHandler();
    [Signal] public delegate void DisconnectedEventHandler();
    [Signal] public delegate void ErrorOccurredEventHandler(string message);

    public const string DefaultServer = "ws://127.0.0.1:12346";
    public const string DefaultPath = "/tcode";

    private const int ConnectTimeoutMs = 8000;
    private const int SendQueueCapacity = 256;

    public const string StrokeAxis = "L0";

    public static readonly System.Collections.Generic.Dictionary<string, string> MotionAxisMap =
        new System.Collections.Generic.Dictionary<string, string>
        {
            { "L1", "L1" },
            { "R0", "C0" },
            { "R2", "P0" },
            { "L2", "V1" },
            { "R1", "V2" },
        };

    public static readonly string[] AllAxes =
    {
        "L0", "L1", "C0", "P0", "V1", "V2",
        "V0", "P1", "P2", "P3", "V3", "V4", "V5", "V6", "V7", "V8", "V9", "W1",
    };

    private ClientWebSocket _ws;
    private CancellationTokenSource _cts;
    private Channel<string> _sendChannel;

    public bool RestimConnected => _ws != null && _ws.State == WebSocketState.Open;

    public override void _Ready()
    {
        var settings = GetNode("/root/SettingsService");
        if (!settings.Call("get_restim_auto_connect").AsBool())
            return;
        string server = settings.Call("get_restim_server").AsString();
        string path = settings.Call("get_restim_path").AsString();
        Connect(BuildAddress(server, path));
    }

    public static string BuildAddress(string server, string path)
    {
        server = (server ?? "").Trim().TrimEnd('/');
        path = (path ?? "").Trim();
        if (path.Length > 0 && !path.StartsWith("/"))
            path = "/" + path;
        return server + path;
    }

    public async void Connect(string address)
    {
        Disconnect();

        var ws = new ClientWebSocket();
        Uri uri;
        try
        {
            uri = new Uri(address);
        }
        catch (Exception e)
        {
            ws.Dispose();
            _EmitError($"Invalid restim address '{address}': {e.Message}");
            return;
        }

        try
        {
            using var connectCts = new CancellationTokenSource(ConnectTimeoutMs);
            await ws.ConnectAsync(uri, connectCts.Token).ConfigureAwait(false);

            _ws = ws;
            _cts = new CancellationTokenSource();
            _sendChannel = Channel.CreateBounded<string>(new BoundedChannelOptions(SendQueueCapacity)
            {
                FullMode = BoundedChannelFullMode.DropOldest,
                SingleReader = true,
            });

            _ = Task.Run(() => SendLoop(_ws, _sendChannel, _cts.Token));
            _ = Task.Run(() => ReceiveLoop(_ws, _cts.Token));

            Callable.From(() =>
            {
                var serial = GetNodeOrNull<SerialDeviceService>("/root/SerialDeviceService");
                serial?.Disconnect();
                GetNodeOrNull<VectorService>("/root/VectorService")?.Disconnect();
                EmitSignal(SignalName.Connected);
            }).CallDeferred();
        }
        catch (OperationCanceledException)
        {
            ws.Dispose();
            _EmitError("restim connection timed out — is restim running and its WebSocket server enabled?");
        }
        catch (Exception e)
        {
            ws.Dispose();
            _EmitError($"restim connection failed: {e.Message}");
        }
    }

    public void Disconnect()
    {
        var ws = _ws;
        var cts = _cts;
        var chan = _sendChannel;
        _ws = null;
        _cts = null;
        _sendChannel = null;

        if (ws == null)
            return;

        chan?.Writer.TryComplete();
        try { cts?.Cancel(); } catch { }
        try { _ = ws.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, null, CancellationToken.None); } catch { }
        try { cts?.Dispose(); } catch { }
        try { ws.Dispose(); } catch { }

        Callable.From(() => EmitSignal(SignalName.Disconnected)).CallDeferred();
    }

    public void SendTCode(string axis, double value01, uint intervalMs = 0)
    {
        var chan = _sendChannel;
        if (chan == null)
            return;
        chan.Writer.TryWrite(FormatCommand(axis, value01, intervalMs));
    }

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
            sb.Append(FormatCommand(axis, value01, intervalMs));
        }
        if (sb.Length > 0)
            chan.Writer.TryWrite(sb.ToString());
    }

    private static string FormatCommand(string axis, double value01, uint intervalMs)
    {
        int ticks = Math.Clamp((int)Math.Round(value01 * 9999.0), 0, 9999);
        return intervalMs > 0
            ? $"{axis}{ticks:D4}I{intervalMs}"
            : $"{axis}{ticks:D4}";
    }

    private async Task SendLoop(ClientWebSocket ws, Channel<string> chan, CancellationToken token)
    {
        try
        {
            while (await chan.Reader.WaitToReadAsync(token).ConfigureAwait(false))
            {
                while (chan.Reader.TryRead(out string msg))
                {
                    var bytes = Encoding.ASCII.GetBytes(msg);
                    await ws.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, token)
                        .ConfigureAwait(false);
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception e)
        {
            _OnLoopFailure(ws, $"restim send failed: {e.Message}");
        }
    }

    private async Task ReceiveLoop(ClientWebSocket ws, CancellationToken token)
    {
        var buffer = new byte[1024];
        try
        {
            while (!token.IsCancellationRequested && ws.State == WebSocketState.Open)
            {
                var result = await ws.ReceiveAsync(new ArraySegment<byte>(buffer), token).ConfigureAwait(false);
                if (result.MessageType == WebSocketMessageType.Close)
                {
                    _OnLoopFailure(ws, null);
                    return;
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception e)
        {
            _OnLoopFailure(ws, $"restim connection lost: {e.Message}");
        }
    }

    private void _OnLoopFailure(ClientWebSocket ws, string message)
    {
        if (_ws != ws)
            return;
        _ws = null;
        _sendChannel?.Writer.TryComplete();
        _sendChannel = null;
        try { _cts?.Cancel(); } catch { }
        if (!string.IsNullOrEmpty(message))
            Callable.From(() => EmitSignal(SignalName.ErrorOccurred, message)).CallDeferred();
        Callable.From(() => EmitSignal(SignalName.Disconnected)).CallDeferred();
    }

    private void _EmitError(string message)
    {
        Callable.From(() => EmitSignal(SignalName.ErrorOccurred, message)).CallDeferred();
    }

    public override void _Notification(int what)
    {
        if (what != NotificationWMCloseRequest && what != NotificationExitTree)
            return;

        var ws = _ws;
        if (ws == null || ws.State != WebSocketState.Open)
            return;

        try { _cts?.Cancel(); } catch { }

        try
        {
            var bytes = Encoding.ASCII.GetBytes("V00000 L05000");
            ws.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, CancellationToken.None)
                .Wait(200);
        }
        catch (Exception e)
        {
            GD.PrintErr($"RestimService: shutdown stop failed: {e.Message}");
        }
        try { ws.Abort(); } catch { }
        try { ws.Dispose(); } catch { }
        _ws = null;
    }
}
