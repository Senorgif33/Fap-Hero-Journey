"""Restore Inferno media from v1 named files; place videos next to funscript folders; rewrite journey.json."""
from __future__ import annotations

import json
import os
import shutil
from pathlib import Path

JOURNEY = Path(r"E:\E-Stim\Fap.Hero.JOURNEY.v0.6.0.-.Windows.Build\Journeys\Erosphere_Inferno")
V1 = Path(r"E:\CYOA-Erosphere\v1")
CONTENT = JOURNEY / "content"
JSON_PATH = JOURNEY / "journey.json"
BAK = JOURNEY / "journey.json.pre_named_media.bak"


def norm_key(name: str) -> str:
    """Normalize for matching: drop .mp4/.funscript only, unify apostrophe forms.

    Do not use Path.stem on bare folder names — e.g. Inferno_C01_006.5_Foo would
    lose '.5_Foo' because pathlib treats the last dot-segment as a suffix.
    """
    s = Path(name).name
    low = s.lower()
    for ext in (".mp4", ".mkv", ".webm", ".funscript"):
        if low.endswith(ext):
            s = s[: -len(ext)]
            break
    s = s.replace("'s_", "_s_").replace("'", "_")
    return s.lower()


def link_or_copy(src: Path, dst: Path) -> str:
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists():
        if dst.stat().st_size == src.stat().st_size:
            return "exists"
        dst.unlink()
    try:
        os.link(src, dst)
        return "hardlink"
    except OSError:
        shutil.copy2(src, dst)
        return "copy"


def classify_funscript(stem: str, label_b_slug: str = "prostate") -> tuple[str, str] | None:
    """Return (slot, axis) or ('l0','') for main. Mirrors RestimAxisKit priority."""
    low = stem.lower()
    kit = [
        "pulse_interval_random",
        "pulse_frequency",
        "pulse_rise_time",
        "pulse_width",
        "sensor_suppression",
        "frequency",
        "volume",
        "alpha",
        "beta",
        "e1",
        "e2",
        "e3",
        "e4",
    ]
    # explicit .a. / .b.
    for slot in ("a", "b"):
        for axis in kit:
            if low.endswith(f".{slot}.{axis}") or low.endswith(f"_{slot}_{axis}"):
                return slot, axis
    # label-tagged
    for axis in kit:
        if low.endswith(f".{axis}-{label_b_slug}") or low.endswith(f"_{axis}_{label_b_slug}"):
            return "b", axis
    # plain kit
    for axis in kit:
        if low.endswith(f".{axis}") or low.endswith(f"_{axis}"):
            if axis.startswith("pulse_") or axis == "sensor_suppression":
                return "shared", axis
            return "a", axis
    # vib
    for vib in (".vib1", "_vib1", ".vibe1", "_vibe1", ".vib2", "_vib2", ".vibe2", "_vibe2"):
        if low.endswith(vib):
            return "vib", "vib1" if "1" in vib else "vib2"
    # main L0 if no kit suffix
    return "l0", ""


def main() -> None:
    # size -> v1 path
    v1_by_size: dict[int, Path] = {}
    for p in V1.glob("Inferno_*.mp4"):
        v1_by_size.setdefault(p.stat().st_size, p)

    # hash file -> v1
    hash_to_v1: dict[str, Path] = {}
    for p in CONTENT.glob("m_*.mp4"):
        src = v1_by_size.get(p.stat().st_size)
        if src is None:
            print(f"NO V1 MATCH for {p.name}")
            continue
        hash_to_v1[f"content/{p.name}"] = src
        print(f"map {p.name} -> {src.name}")

    # script folders by norm key
    folders: dict[str, Path] = {}
    for d in JOURNEY.iterdir():
        if d.is_dir() and d.name.startswith("Inferno_"):
            folders[norm_key(d.name)] = d

    # Place each unique video
    hash_to_new_rel: dict[str, str] = {}
    for rel, v1 in hash_to_v1.items():
        key = norm_key(v1.name)
        folder = folders.get(key)
        if folder is not None:
            # Name video to match funscript stem (= folder name)
            dest = folder / f"{folder.name}.mp4"
            mode = link_or_copy(v1, dest)
            new_rel = f"{folder.name}/{folder.name}.mp4".replace("\\", "/")
            print(f"  [{mode}] {new_rel}")
        else:
            dest = CONTENT / v1.name
            mode = link_or_copy(v1, dest)
            new_rel = f"content/{v1.name}".replace("\\", "/")
            print(f"  [{mode}] {new_rel} (no script folder)")
        hash_to_new_rel[rel] = new_rel

    # Also ensure every script folder has its video even if unused in journey yet
    for key, folder in folders.items():
        dest = folder / f"{folder.name}.mp4"
        if dest.exists():
            continue
        # find v1 by norm key
        hit = next((p for p in V1.glob("Inferno_*.mp4") if norm_key(p.name) == key), None)
        if hit is None:
            print(f"WARN no v1 video for folder {folder.name}")
            continue
        mode = link_or_copy(hit, dest)
        print(f"  [{mode}] extra folder video {folder.name}")

    # Patch journey.json
    if not BAK.exists():
        shutil.copy2(JSON_PATH, BAK)
        print(f"backup -> {BAK.name}")
    else:
        print(f"backup exists: {BAK.name}")

    data = json.loads(JSON_PATH.read_text(encoding="utf-8"))
    rounds_cleared = 0
    videos_rewritten = 0
    for node in data.get("Nodes", []):
        d = node.get("data") or {}
        vp = d.get("video_path") or ""
        if vp in hash_to_new_rel:
            d["video_path"] = hash_to_new_rel[vp]
            videos_rewritten += 1
        if node.get("type") == "round":
            # Clear scripts so SCAN FUNSCRIPTS fills from siblings
            d["funscript_path"] = ""
            d["action_count"] = 0
            d["length_ms"] = 0
            d["axis_scripts"] = {}
            d["vib_scripts"] = {}
            d["restim_axis_scripts"] = {"a": {}, "b": {}, "shared": {}}
            rounds_cleared += 1
            for pe in d.get("pool_entries") or []:
                if isinstance(pe, dict):
                    pvp = pe.get("video_path") or ""
                    if pvp in hash_to_new_rel:
                        pe["video_path"] = hash_to_new_rel[pvp]
                    pe["funscript_path"] = ""
                    pe["action_count"] = 0
                    pe["length_ms"] = 0
                    pe["axis_scripts"] = {}
                    pe["vib_scripts"] = {}
                    pe["restim_axis_scripts"] = {"a": {}, "b": {}, "shared": {}}

    JSON_PATH.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    print(f"rewrote video_path on {videos_rewritten} nodes; cleared scripts on {rounds_cleared} rounds")

    # Remove hashed leftovers
    removed = 0
    for p in CONTENT.glob("m_*.mp4"):
        p.unlink()
        removed += 1
    print(f"removed {removed} hashed content/m_*.mp4")

    # Verify no leftover hash refs
    raw = JSON_PATH.read_text(encoding="utf-8")
    if "content/m_" in raw:
        print("ERROR: journey.json still references content/m_")
    else:
        print("OK: no content/m_ refs left")


if __name__ == "__main__":
    main()
