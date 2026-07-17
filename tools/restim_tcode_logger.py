#!/usr/bin/env python3
"""
Restim T-code diagnostic logger (log-only fake Restim WS server).

Pretends to be Restim's /tcode WebSocket endpoint so Fap-Hero can connect while
you watch decoded channel traffic. Does NOT forward to real Restim.

Slots A and B are independent: each has its own coalesce window and its own
log file (no cross-slot merging).

Usage:
  pip install websockets
  # Stop Restim (or free ports 12346/12347), then:
  python tools/restim_tcode_logger.py --ports 12346,12347

  Writes (cwd by default):
    restim_tcode_a.log
    restim_tcode_b.log

  Point Fap-Hero Options Restim A/B at:
    ws://127.0.0.1:12346/tcode
    ws://127.0.0.1:12347/tcode

  Optional:
    --out-prefix restim_tcode   file stem (default); creates {prefix}_{slot}.log
    --out-dir .                 directory for log files
    --hz 10                     max log lines per second per slot
    --coalesce-ms 5             merge near-simultaneous frames on ONE slot (default: 5)

Example line (one slot's file):
  22:53:01.123  L0=0.5001@80ms V0=0.8000@0ms P0=0.4200@80ms
"""

from __future__ import annotations

import argparse
import asyncio
import re
import sys
import time
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable, TextIO

try:
    from websockets.asyncio.server import ServerConnection, serve
    from websockets.http11 import Request, Response
except ImportError:
    print(
        "Missing dependency: pip install websockets",
        file=sys.stderr,
    )
    sys.exit(1)

# Matches RestimAxisKit.KIT / Fap-Hero RestimService axis ids.
AXIS_LABELS: dict[str, str] = {
    "L0": "alpha",
    "L1": "beta",
    "V0": "volume",
    "C0": "frequency",
    "P0": "pulse_frequency",
    "P1": "pulse_width",
    "P2": "pulse_interval_random",
    "P3": "pulse_rise_time",
    "E1": "e1",
    "E2": "e2",
    "E3": "e3",
    "E4": "e4",
    "S1": "sensor_suppression",
}

# Port → slot label (Fap-Hero defaults).
DEFAULT_PORT_SLOTS: dict[int, str] = {
    12346: "a",
    12347: "b",
}

_SPLIT = re.compile(r"[\s\n\r]+")
_TCODE = re.compile(
    r"^(?P<axis>[A-Za-z]\d)(?P<digits>\d+)(?:I(?P<interval>\d+))?$",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class ParsedCommand:
    axis: str
    label: str
    position: float  # 0..1 as Fap-Hero intends (ticks / 9999)
    interval_ms: int
    raw: str


class SlotLogger:
    """
    One Restim slot: accurate short coalesce + its own log file.
    Does not merge with other slots.
    """

    def __init__(
        self,
        slot: str,
        out: TextIO,
        coalesce_ms: float = 5.0,
        hz: float | None = None,
    ) -> None:
        self.slot = slot
        self.out = out
        self.coalesce_s = max(0.0, coalesce_ms) / 1000.0
        self.min_line_interval = (1.0 / hz) if hz and hz > 0 else 0.0
        self._pending: list[ParsedCommand] = []
        self._flush_handle: asyncio.TimerHandle | None = None
        self._last_flush_mono = 0.0
        self._dropped_batches = 0

    def emit(self, line: str) -> None:
        """Status / connect lines (always immediate)."""
        stamped = f"{_stamp()}  {line}"
        print(f"[{self.slot}] {stamped}", flush=True)
        self.out.write(stamped + "\n")
        self.out.flush()

    def add(self, cmds: list[ParsedCommand]) -> None:
        if not cmds:
            return
        self._pending.extend(cmds)
        loop = asyncio.get_running_loop()
        if self.coalesce_s <= 0:
            self.flush()
            return
        if self._flush_handle is not None:
            self._flush_handle.cancel()
        self._flush_handle = loop.call_later(self.coalesce_s, self.flush)

    def flush(self) -> None:
        self._flush_handle = None
        if not self._pending:
            return

        now = time.monotonic()
        if self.min_line_interval > 0 and (now - self._last_flush_mono) < self.min_line_interval:
            self._dropped_batches += 1
            self._pending.clear()
            return

        batch = self._pending
        self._pending = []
        dropped = self._dropped_batches
        self._dropped_batches = 0
        self._last_flush_mono = now

        line = format_slot_line(batch, dropped)
        stamped = f"{_stamp()}  {line}"
        print(f"[{self.slot}] {stamped}", flush=True)
        self.out.write(stamped + "\n")
        self.out.flush()


def parse_command(raw: str) -> ParsedCommand | None:
    raw = raw.strip()
    if not raw:
        return None
    if raw.upper() == "DSTOP":
        return ParsedCommand("DSTOP", "stop_all", 0.0, 0, raw)

    m = _TCODE.match(raw)
    if not m:
        return ParsedCommand("??", "unparsed", 0.0, 0, raw)

    axis = m.group("axis").upper()
    digits = m.group("digits")
    interval_s = m.group("interval")
    interval_ms = int(interval_s) if interval_s else 0

    # Fap-Hero always sends 4-digit 0..9999 ticks.
    ticks = int(digits)
    denom = 9999.0 if len(digits) >= 4 else float(10 ** len(digits))
    position = min(max(ticks / denom, 0.0), 1.0)

    label = AXIS_LABELS.get(axis, "??")
    return ParsedCommand(axis, label, position, interval_ms, raw)


def _stamp() -> str:
    return datetime.now().strftime("%H:%M:%S.%f")[:-3]


def format_cmd_token(cmd: ParsedCommand) -> str:
    if cmd.axis == "DSTOP":
        return "DSTOP"
    if cmd.axis == "??":
        return f"??={cmd.raw}"
    return f"{cmd.axis}={cmd.position:.4f}@{cmd.interval_ms}ms"


def format_slot_line(batch: list[ParsedCommand], dropped_batches: int = 0) -> str:
    # Last-write-wins per axis within the coalesce window; preserve first-seen order.
    by_axis: dict[str, ParsedCommand] = {}
    order: list[str] = []
    for cmd in batch:
        if cmd.axis not in by_axis:
            order.append(cmd.axis)
        by_axis[cmd.axis] = cmd

    tokens = [format_cmd_token(by_axis[ax]) for ax in order]
    drop_note = f"  (dropped {dropped_batches} batches)" if dropped_batches else ""
    return " ".join(tokens) + drop_note


def parse_message_cmds(msg: str) -> list[ParsedCommand]:
    cmds: list[ParsedCommand] = []
    for piece in _SPLIT.split(msg):
        cmd = parse_command(piece)
        if cmd is not None:
            cmds.append(cmd)
    return cmds


def make_process_request(logger: SlotLogger):
    async def process_request(
        connection: ServerConnection, request: Request
    ) -> Response | None:
        path = request.path.split("?", 1)[0]
        if path != "/tcode":
            logger.emit(f"404 path={request.path!r} (Restim requires /tcode)")
            return connection.respond(404, "Not Found\n")
        return None

    return process_request


def make_handler(logger: SlotLogger):
    async def handler(websocket: ServerConnection) -> None:
        peer = websocket.remote_address
        logger.emit(f"connected from {peer}")
        try:
            async for message in websocket:
                if isinstance(message, bytes):
                    try:
                        message = message.decode("utf-8")
                    except UnicodeDecodeError:
                        logger.emit("non-utf8 frame ignored")
                        continue
                logger.add(parse_message_cmds(message))
        finally:
            logger.flush()
            logger.emit(f"disconnected {peer}")

    return handler


async def run_servers(
    ports: list[tuple[str, int]],
    loggers: dict[str, SlotLogger],
    hz: float | None,
    coalesce_ms: float,
) -> None:
    servers = []
    for slot, port in ports:
        logger = loggers[slot]
        server = await serve(
            make_handler(logger),
            "127.0.0.1",
            port,
            process_request=make_process_request(logger),
        )
        servers.append((server, logger))
        logger.emit(f"listening on ws://127.0.0.1:{port}/tcode")

    print(f"{_stamp()}  Waiting for Fap-Hero... (Ctrl+C to stop)", flush=True)
    try:
        await asyncio.Future()  # run forever
    finally:
        for server, logger in servers:
            logger.flush()
            server.close()
            await server.wait_closed()


def parse_ports(spec: str) -> list[tuple[str, int]]:
    """
    Accept:
      12346
      12346,12347
      a:12346,b:12347
    """
    out: list[tuple[str, int]] = []
    used_slots: set[str] = set()
    auto_index = 0
    auto_letters = "abcdefghijklmnopqrstuvwxyz"

    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if ":" in part:
            slot, port_s = part.split(":", 1)
            slot = slot.strip().lower()
            port = int(port_s.strip())
        else:
            port = int(part)
            slot = DEFAULT_PORT_SLOTS.get(port, "")
            if not slot:
                while auto_index < len(auto_letters) and auto_letters[auto_index] in used_slots:
                    auto_index += 1
                if auto_index >= len(auto_letters):
                    raise ValueError(f"too many ports without explicit slot labels: {spec}")
                slot = auto_letters[auto_index]
                auto_index += 1
        if slot in used_slots:
            raise ValueError(f"duplicate slot label [{slot}]")
        used_slots.add(slot)
        out.append((slot, port))

    if not out:
        raise ValueError("no ports specified")
    return out


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Log-only fake Restim /tcode WebSocket server for Fap-Hero diagnostics.",
    )
    g = p.add_mutually_exclusive_group()
    g.add_argument(
        "--ports",
        default=None,
        help="Comma-separated ports, e.g. 12346,12347 or a:12346,b:12347",
    )
    g.add_argument(
        "--port",
        type=int,
        default=None,
        help="Single listen port (default: 12346)",
    )
    p.add_argument(
        "--out-dir",
        default=".",
        help="Directory for per-slot log files (default: current directory)",
    )
    p.add_argument(
        "--out-prefix",
        default="restim_tcode",
        help="Log file stem; writes {prefix}_{slot}.log (default: restim_tcode)",
    )
    p.add_argument(
        "--hz",
        type=float,
        default=None,
        help="Max log lines per second per slot (extra coalesce batches are dropped)",
    )
    p.add_argument(
        "--coalesce-ms",
        type=float,
        default=5.0,
        help="Merge commands on ONE slot arriving within this many ms (default: 5)",
    )
    return p


def main(argv: Iterable[str] | None = None) -> int:
    args = build_arg_parser().parse_args(list(argv) if argv is not None else None)
    try:
        if args.ports is not None:
            ports = parse_ports(args.ports)
        elif args.port is not None:
            ports = parse_ports(str(args.port))
        else:
            ports = parse_ports("12346")
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    files: list[TextIO] = []
    loggers: dict[str, SlotLogger] = {}
    try:
        for slot, _port in ports:
            path = out_dir / f"{args.out_prefix}_{slot}.log"
            fh = path.open("w", encoding="utf-8", newline="\n")
            files.append(fh)
            loggers[slot] = SlotLogger(
                slot=slot,
                out=fh,
                coalesce_ms=args.coalesce_ms,
                hz=args.hz,
            )
            print(f"{_stamp()}  [{slot}] logging to {path.resolve()}", flush=True)

        asyncio.run(run_servers(ports, loggers, args.hz, args.coalesce_ms))
    except KeyboardInterrupt:
        print("\nStopped.", flush=True)
    finally:
        for logger in loggers.values():
            logger.flush()
        for fh in files:
            fh.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
