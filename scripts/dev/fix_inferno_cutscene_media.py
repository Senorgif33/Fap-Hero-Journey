#!/usr/bin/env python3
"""Copy Canto I cutscene MP4s into the live pack content/ and fix journey.json paths.

JSON-only scaffold installs never copy EP/unlock/credits media. Legacy folder-layout
paths (Inferno_C01_EP1/Inferno_C01_EP1.mp4) or doubled absolutes make GameLoop fail
open and auto-advance straight to the cooldown banner after Release.
"""
from __future__ import annotations

import json
import shutil
import sys
from datetime import datetime
from pathlib import Path

PACK = Path(r"E:\E-Stim\Fap.Hero.JOURNEY.v0.6.0.-.Windows.Build\Journeys\Erosphere_Inferno")
SRC = Path(r"E:\E-Stim\CH Inferno\Canto I\Seperated Rounds")
BUILD = Path(__file__).resolve().parents[2] / "local" / "journeys" / "erosphere-inferno"
CONTENT = PACK / "content"
JOURNEY = PACK / "journey.json"

CUTSCENE_FILES = [
    "Inferno_C01_EP1.mp4",
    "Inferno_C01_EP2.mp4",
    "Inferno_C01_EP3.mp4",
    "Inferno_C01_EP4.mp4",
    "Inferno_C01_EP5.mp4",
    "Inferno_C01_EP6.mp4",
    "Inferno_C01_EP7.mp4",
    "Inferno_C01_Credits.mp4",
    "Inferno_C01_I01_The_Amulet_of_Sustenance.mp4",
    "Inferno_C01_S01_Psychic_Divorce.mp4",
]


def main() -> int:
    if not JOURNEY.is_file():
        print(f"ERROR: missing {JOURNEY}", file=sys.stderr)
        return 1
    if not SRC.is_dir():
        print(f"ERROR: missing source dir {SRC}", file=sys.stderr)
        return 1

    BUILD.mkdir(parents=True, exist_ok=True)
    CONTENT.mkdir(parents=True, exist_ok=True)

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    bak = BUILD / f"journey.json.pack-backup-{stamp}.json"
    shutil.copy2(JOURNEY, bak)
    print(f"Backed up -> {bak}")

    copied = 0
    missing: list[str] = []
    for name in CUTSCENE_FILES:
        src = SRC / name
        dst = CONTENT / name
        if not src.is_file():
            missing.append(name)
            continue
        if (not dst.is_file()) or dst.stat().st_size != src.stat().st_size:
            shutil.copy2(src, dst)
            copied += 1
            print(f"Copied {name}")
        else:
            print(f"Exists {name}")

    if missing:
        print(f"ERROR: missing sources: {missing}", file=sys.stderr)
        return 1

    journey = json.loads(JOURNEY.read_text(encoding="utf-8"))
    fixed = 0
    still_bad: list[tuple[str, str]] = []
    for node in journey.get("Nodes", []):
        if node.get("type") != "cutscene":
            continue
        data = node.setdefault("data", {})
        vp = str(data.get("video_path") or "").replace("\\", "/")
        base = Path(vp).name if vp else ""
        nid = str(node.get("id") or "")
        if not base.endswith(".mp4"):
            still_bad.append((nid, vp))
            continue
        new_rel = f"content/{base}"
        if not (CONTENT / base).is_file():
            still_bad.append((nid, vp))
            continue
        if data.get("video_path") != new_rel:
            data["video_path"] = new_rel
            fixed += 1
            print(f"Fixed {nid} -> {new_rel}")
        else:
            print(f"OK {nid} already {new_rel}")

    JOURNEY.write_text(
        json.dumps(journey, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"Done. copied={copied} fixed={fixed} still_bad={still_bad}")

    if still_bad:
        print("ERROR: unresolved cutscene paths:", still_bad, file=sys.stderr)
        return 1

    for node in journey.get("Nodes", []):
        if node.get("type") != "cutscene":
            continue
        vp = str((node.get("data") or {}).get("video_path") or "")
        exists = (PACK / vp).is_file() if vp else False
        print(f"  check {node.get('id')}: {vp} exists={exists}")
        if not exists:
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
