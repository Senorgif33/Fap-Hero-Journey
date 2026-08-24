#!/usr/bin/env python3
"""Scaffold Erosphere Inferno Format 2 into a repo-local build folder.

Writes journey.json (+ skill_unlocks.json copy) under:
  <repo>/local/journeys/erosphere-inferno/

Does **not** write to the live Journeys pack. Install with:
  scripts/dev/scaffold-erosphere-inferno.ps1
(which copies only those generated files into the pack).

Canto I + II main path, EP subgraphs (cooldown gaps, punish sessions), Oblivion.
Skill unlock cutscenes (with award_item) come from erosphere-inferno/skill_unlocks.json.

Media discovery reads the live pack (PACK_DIR) for mp4/funscript siblings so paths in
the JSON match on-disk pack layout. This script never deletes pack files.

Layout: if pack or local journey.json already exists, each node's pos is preserved
across regen so Builder drag fixes are not wiped. New nodes still get scaffold placement.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

# Builder-assigned ids from an earlier hand-edit of Fate / 008 → stable scaffold ids.
POS_ID_ALIASES: dict[str, str] = {
    "n_0a8045c8df4edb0d": "inferno_C01_007",
    "n_4dd8146052bf4e04": "inferno_C01_008",
}

# E-stim parameter suffixes → restim T-code (mirrors JourneyData.ESTIM_SUFFIXES / ImportScanner).
# Longer names first so strip/detect prefer exact tails (e.g. pulse_interval_random before volume).
_ESTIM_SUFFIXES: tuple[tuple[str, str], ...] = (
    ("pulse_interval_random", "P2"),
    ("carrier_frequency", "C0"),
    ("pulse_frequency", "P0"),
    ("pulse_rise_time", "P3"),
    ("vib1_left_right_bias", "V6"),
    ("vib1_up_down_bias", "V7"),
    ("vib2_left_right_bias", "V8"),
    ("vib2_up_down_bias", "V9"),
    ("vib1_frequency", "V1"),
    ("vib1_strength", "V2"),
    ("vib1_random", "V3"),
    ("vib2_frequency", "V4"),
    ("vib2_strength", "V5"),
    ("vib2_random", "W1"),
    ("pulse_width", "P1"),
    ("volume", "V0"),
)

# Motion / position axis suffixes → T-code (alpha→L0 main, beta→L1). No dual A/B slots, no E1–E4.
_AXIS_SUFFIXES: tuple[tuple[str, str], ...] = (
    ("surge", "L1"),
    ("sway", "L2"),
    ("twist", "R0"),
    ("roll", "R1"),
    ("pitch", "R2"),
    ("alpha", "L0"),
    ("beta", "L1"),
    ("l1", "L1"),
    ("l2", "L2"),
    ("r0", "R0"),
    ("r1", "R1"),
    ("r2", "R2"),
)

REPO = Path(__file__).resolve().parents[2]
DATA_DIR = Path(__file__).resolve().parent / "erosphere-inferno"
UNLOCKS_PATH = DATA_DIR / "skill_unlocks.json"
# Stage generated JSON here (gitignored under /local/). Never write the live pack from Python.
BUILD_DIR = REPO / "local" / "journeys" / "erosphere-inferno"
BUILD_JSON = BUILD_DIR / "journey.json"
# Live pack: read media + preserve positions; install step copies JSON here.
PACK_DIR = Path(
    r"E:\E-Stim\Fap.Hero.JOURNEY.v0.6.0.-.Windows.Build\Journeys\Erosphere_Inferno"
)
PACK_JSON = PACK_DIR / "journey.json"

# Back-compat aliases (media helpers used to key off OUT_DIR).
OUT_DIR = PACK_DIR
OUT_JSON = BUILD_JSON

# Live pack layout: EP/Fate/unlock cutscenes under content/; main sessions under
# Inferno_C01_001_Intro/Inferno_C01_001_Intro.mp4 (apostrophes on disk).
_VIDEO_INDEX: dict[str, str] | None = None


def _norm_video_key(name: str) -> str:
    """Match Virgo_s_Training.mp4 ↔ Virgo's_Training.mp4."""
    return re.sub(r"[^a-z0-9.]+", "", name.lower().replace("'", ""))


def _video_index() -> dict[str, str]:
    global _VIDEO_INDEX
    if _VIDEO_INDEX is not None:
        return _VIDEO_INDEX
    idx: dict[str, str] = {}
    # Prefer live pack media; fall back to local build folder if present.
    for root in (PACK_DIR, BUILD_DIR):
        if not root.is_dir():
            continue
        for p in root.rglob("*.mp4"):
            idx.setdefault(_norm_video_key(p.name), p.relative_to(root).as_posix())
    _VIDEO_INDEX = idx
    return idx


def resolve_video(filename: str) -> str:
    """Map a basename to the pack-relative path that actually exists."""
    if not filename:
        return ""
    hit = _video_index().get(_norm_video_key(filename))
    if hit:
        return hit
    return f"content/{filename}"


def resolve_funscript(video_rel: str) -> str:
    if not video_rel.endswith(".mp4"):
        return ""
    cand = video_rel[:-4] + ".funscript"
    for root in (PACK_DIR, BUILD_DIR):
        if (root / cand).is_file():
            return cand
    return ""


def _classify_funscript_stem(stem: str) -> tuple[str, str]:
    """Return ('estim', T-code), ('axis', T-code), ('vib', vib1|vib2), or ('l0', '')."""
    low = stem.lower()
    # Plain vib channels must lose to estim vib*_frequency / strength / … (longer tails).
    for name, code in _ESTIM_SUFFIXES:
        if low.endswith(f".{name}") or low.endswith(f"_{name}"):
            return "estim", code
    for vib, key in (
        (".vib1", "vib1"),
        ("_vib1", "vib1"),
        (".vibe1", "vib1"),
        ("_vibe1", "vib1"),
        (".vib2", "vib2"),
        ("_vib2", "vib2"),
        (".vibe2", "vib2"),
        ("_vibe2", "vib2"),
    ):
        if low.endswith(vib):
            return "vib", key
    for name, code in _AXIS_SUFFIXES:
        if low.endswith(f".{name}") or low.endswith(f"_{name}"):
            # alpha maps to L0 main stroke — treat as primary funscript, not axis_scripts.
            if code == "L0" and name == "alpha":
                return "l0", ""
            return "axis", code
    return "l0", ""


def _strip_kit_suffix(stem: str) -> str:
    """Strip the longest recognised axis/estim/vib suffix so siblings share a base name."""
    low = stem.lower()
    best = 0
    candidates: list[str] = []
    for name, _code in _ESTIM_SUFFIXES:
        candidates.append(f".{name}")
        candidates.append(f"_{name}")
    for name, _code in _AXIS_SUFFIXES:
        candidates.append(f".{name}")
        candidates.append(f"_{name}")
    for vib in (".vib1", "_vib1", ".vibe1", "_vibe1", ".vib2", "_vib2", ".vibe2", "_vibe2"):
        candidates.append(vib)
    for suf in candidates:
        if low.endswith(suf) and len(suf) > best:
            best = len(suf)
    if best:
        return stem[:-best]
    return stem


def _norm_script_base(name: str) -> str:
    """Compare video/funscript bases ignoring apostrophe forms (Anjelica's ↔ Anjelica_s)."""
    return name.lower().replace("'s_", "_s_").replace("'", "_")


def attach_sibling_scripts(data: dict) -> None:
    """Fill funscript_path / axis_scripts / estim_scripts / vib_scripts from disk siblings.

    Never removes files — only writes journey.json field bindings.
    Scans the live pack first, then the local build folder.
    """
    video_rel = str(data.get("video_path") or "")
    if not video_rel:
        return
    root = None
    video_abs = None
    for candidate in (PACK_DIR, BUILD_DIR):
        abs_path = candidate / video_rel
        if abs_path.is_file() or abs_path.parent.is_dir():
            root = candidate
            video_abs = abs_path
            break
    if root is None or video_abs is None:
        return
    folder = video_abs.parent
    if not folder.is_dir():
        return
    base = _norm_script_base(_strip_kit_suffix(video_abs.stem))
    axis: dict[str, str] = {}
    estim: dict[str, str] = {}
    vib: dict[str, str] = {}
    main_fs = str(data.get("funscript_path") or "")

    for p in sorted(folder.glob("*.funscript")):
        stem = p.stem
        sib_base = _norm_script_base(_strip_kit_suffix(stem))
        if sib_base != base:
            continue
        rel = p.relative_to(root).as_posix()
        kind, key = _classify_funscript_stem(stem)
        if kind == "l0":
            if not main_fs:
                main_fs = rel
            continue
        if kind == "vib":
            vib.setdefault(key, rel)
            continue
        if kind == "estim":
            estim.setdefault(key, rel)
            continue
        if kind == "axis":
            axis.setdefault(key, rel)

    data["funscript_path"] = main_fs
    data["axis_scripts"] = axis
    data["estim_scripts"] = estim
    data["vib_scripts"] = vib
    data.pop("restim_axis_scripts", None)


# Map/editor convention: y = progress (top→down); main spine on the RIGHT.
# Columns left→right match Erosphere_Inferno_layout.png:
#   EP | Fate | punish/wait chain | unlocks | MAIN | Anjelica bonus
# GRID must match GraphLayout.GRID (Builder drag snap) so scaffold pos == editor snap.
GRID = 24.0
ROW = GRID * 6  # 144 — nearest on-grid to legacy 140
COL = GRID * 13  # 312 — nearest on-grid to legacy 320
X_EP = 0.0
X_FATE = COL
X_CHAIN = COL * 2
X_UNLOCK = COL * 3
X_MAIN = COL * 4
X_BONUS = COL * 5
X_BONUS_SHOP = COL * 6
X_FP = COL * 7  # freeplay round clones (right of bonus)
X_FP_HUB = X_BONUS + GRID * 8  # hub stack near Anjelica (on-grid, not COL*5.5)


def _snap_scalar(v: float) -> float:
    return float(round(v / GRID) * GRID)


def _snap_pos(x: float, y: float) -> tuple[float, float]:
    return _snap_scalar(x), _snap_scalar(y)


def load_skill_unlocks() -> dict:
    raw = json.loads(UNLOCKS_PATH.read_text(encoding="utf-8"))
    if not isinstance(raw.get("skills"), list):
        raise ValueError(f"{UNLOCKS_PATH} missing skills[]")
    return raw


def _set_out(nodes_by_id: dict[str, dict], nid: str, to: str) -> None:
    n = nodes_by_id.get(nid)
    if n is None:
        raise KeyError(f"skill_unlocks insert_after/video missing node: {nid}")
    n["out"] = [{"to": to}]


def apply_skill_unlocks(nodes: list[dict], unlocks: dict) -> None:
    """Wire unlock-video cutscenes with award_item from skill_unlocks.json (positions later)."""
    nodes_by_id = {n["id"]: n for n in nodes}
    for skill in unlocks.get("skills", []):
        if not skill.get("enabled", False):
            continue
        item_id = skill["item_id"]
        name = skill.get("name", item_id)
        video = skill.get("unlock_video", "")
        vid_id = skill["video_node_id"]
        continue_to = skill.get("continue_to")
        insert_after = skill.get("insert_after")

        if vid_id in nodes_by_id:
            nodes_by_id[vid_id]["data"]["award_item"] = item_id
            if continue_to:
                _set_out(nodes_by_id, vid_id, continue_to)
        else:
            vid = cutscene_node(
                vid_id,
                name,
                video,
                items_blocked=True,
                award_item=item_id,
                out=continue_to,
                pos=(0.0, 0.0),
            )
            nodes.append(vid)
            nodes_by_id[vid_id] = vid

        if insert_after:
            _set_out(nodes_by_id, insert_after, vid_id)


def _pos_of(nodes_by_id: dict[str, dict], nid: str) -> tuple[float, float]:
    p = nodes_by_id[nid].get("pos", [0, 0])
    return float(p[0]), float(p[1])


def load_existing_positions() -> dict[str, list[float]]:
    """Read node positions so regen does not wipe Builder layout edits.

    Prefers the live pack journey.json, then the local build copy.
    """
    for path in (PACK_JSON, BUILD_JSON):
        if not path.is_file():
            continue
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            print(f"warning: could not read existing positions from {path}: {exc}")
            continue
        out: dict[str, list[float]] = {}
        for n in raw.get("Nodes") or []:
            if not isinstance(n, dict):
                continue
            nid = str(n.get("id") or "")
            pos = n.get("pos")
            if not nid or not isinstance(pos, list) or len(pos) < 2:
                continue
            try:
                canon = POS_ID_ALIASES.get(nid, nid)
                out[canon] = [float(pos[0]), float(pos[1])]
            except (TypeError, ValueError):
                continue
        if out:
            print(f"Preserved positions from {path} ({len(out)} nodes)")
            return out
    return {}


def apply_preserved_positions(nodes: list[dict], preserved: dict[str, list[float]]) -> int:
    """Overwrite scaffold layout with pack positions for ids that already existed. Returns count."""
    if not preserved:
        return 0
    nodes_by_id = {n["id"]: n for n in nodes}
    n_applied = 0
    for nid, pos in preserved.items():
        if nid not in nodes_by_id:
            continue
        sx, sy = _snap_pos(pos[0], pos[1])
        nodes_by_id[nid]["pos"] = [sx, sy]
        n_applied += 1
    return n_applied


def _place(nodes_by_id: dict[str, dict], nid: str, x: float, y: float) -> None:
    if nid in nodes_by_id:
        sx, sy = _snap_pos(x, y)
        nodes_by_id[nid]["pos"] = [sx, sy]


def _resolve_overlaps(
    nodes_by_id: dict[str, dict], *, locked: set[str] | None = None
) -> None:
    """Nudge unlocked nodes off occupied cells. Locked ids (Builder layout) never move."""
    locked = locked or set()
    occupied: dict[tuple[float, float], str] = {}

    # Claim locked positions first — do not move them even if two locked nodes overlap.
    for nid in sorted(locked):
        if nid not in nodes_by_id:
            continue
        x, y = _snap_pos(*_pos_of(nodes_by_id, nid))
        key = (x, y)
        prev = occupied.get(key)
        if prev is not None and prev != nid:
            print(f"warning: preserved layout overlap at {key}: '{prev}' and '{nid}'")
        occupied[key] = nid
        nodes_by_id[nid]["pos"] = [x, y]

    for nid in sorted(nodes_by_id.keys()):
        if nid in locked:
            continue
        x, y = _snap_pos(*_pos_of(nodes_by_id, nid))
        placed = False
        for dy in range(0, 120):
            for dx in range(0, 60):
                x_offs = [0] if dx == 0 else [dx, -dx]
                for ox in x_offs:
                    cx = _snap_scalar(x + ox * GRID)
                    cy = _snap_scalar(y + dy * GRID)
                    key = (cx, cy)
                    owner = occupied.get(key)
                    if owner is None or owner == nid:
                        occupied[key] = nid
                        nodes_by_id[nid]["pos"] = [cx, cy]
                        placed = True
                        break
                if placed:
                    break
            if placed:
                break
        if not placed:
            raise RuntimeError(f"layout: could not place '{nid}' without overlapping another node")


def layout_side_branches(
    nodes: list[dict], unlocks: dict, *, resolve: bool = True, locked: set[str] | None = None
) -> None:
    """Place every node to match Erosphere_Inferno_layout.png.

    Right column = main spine. Left = EP → Fate → wait/punish chains feeding in.
    EP1–3 are short horizontal rows into Intro. EP4–6 are long vertical chains.
    Unlock cutscenes sit between the punish chain and main. Anjelica is bottom-right;
    EP7 runs along the bottom into Anjelica's Dream.
    """
    nodes_by_id = {n["id"]: n for n in nodes}

    # ── Main spine top cluster (tight): Always start → Intro → Cats → Virgo
    y = 0.0
    for nid in (
        "c01_intro_sb",
        "inferno_C01_001",
        "inferno_C01_002",
        "inferno_C01_003",
        "inferno_C01_004",
    ):
        _place(nodes_by_id, nid, X_MAIN, y)
        y += ROW

    intro_y = _pos_of(nodes_by_id, "inferno_C01_001")[1]
    virgo_y = _pos_of(nodes_by_id, "inferno_C01_004")[1]

    # ── EP1–3: stacked horizontal rows into Intro (top-left)
    for i, ep in enumerate(("EP1", "EP2", "EP3")):
        base = f"inferno_C01_{ep}"
        row_y = intro_y + i * ROW
        _place(nodes_by_id, base, X_EP, row_y)
        _place(nodes_by_id, f"{base}_fate", X_FATE, row_y)
        _place(nodes_by_id, f"c01_{ep.lower()}_cd", X_CHAIN, row_y)

    # ── EP4: vertical wait↔Virgo chain starting at Virgo height
    y4 = virgo_y
    _place(nodes_by_id, "inferno_C01_EP4", X_EP, y4)
    _place(nodes_by_id, "inferno_C01_EP4_fate", X_FATE, y4)
    py = y4 + ROW
    for i in range(1, 4):
        _place(nodes_by_id, f"c01_ep4_cd{i}", X_CHAIN, py)
        py += ROW
        _place(nodes_by_id, f"c01_ep4_s{i}", X_CHAIN, py)
        py += ROW
    # Charon on main aligns with last EP4 punish (clean-out lands here)
    y_charon = py - ROW
    _place(nodes_by_id, "inferno_C01_005", X_MAIN, y_charon)

    # ── EP5: Fate → Amulet unlock → wait↔Charon chain → Battle
    y5 = y_charon + ROW
    _place(nodes_by_id, "inferno_C01_EP5", X_EP, y5)
    _place(nodes_by_id, "inferno_C01_EP5_fate", X_FATE, y5)
    _place(nodes_by_id, "unlock_vid_amulet", X_UNLOCK, y5)
    py = y5 + ROW
    for i in range(1, 6):
        _place(nodes_by_id, f"c01_ep5_cd{i}", X_CHAIN, py)
        py += ROW
        _place(nodes_by_id, f"c01_ep5_s{i}", X_CHAIN, py)
        py += ROW
    y_s5 = py - ROW
    y_battle = y_s5 + ROW
    _place(nodes_by_id, "inferno_C01_006", X_MAIN, y_battle)

    # ── Fate 007 + EP6: Fate → Psychic unlock → Charon+Battle pairs → Cum or Edge
    y6 = y_battle + ROW
    _place(nodes_by_id, "inferno_C01_007", X_EP, y6 - ROW)
    _place(nodes_by_id, "inferno_C01_EP6", X_EP, y6)
    _place(nodes_by_id, "inferno_C01_EP6_fate", X_FATE, y6)
    _place(nodes_by_id, "unlock_vid_psychic", X_UNLOCK, y6)
    py = y6 + ROW
    for i in range(1, 6):
        _place(nodes_by_id, f"c01_ep6_cd{i}", X_CHAIN, py)
        py += ROW
        _place(nodes_by_id, f"c01_ep6_s{i}a", X_CHAIN, py)
        py += ROW
        _place(nodes_by_id, f"c01_ep6_s{i}b", X_CHAIN, py)
        py += ROW
    y_s5b = py - ROW
    y_cum = y_s5b + ROW
    _place(nodes_by_id, "inferno_C01_006_5", X_MAIN, y_cum)
    _place(nodes_by_id, "inferno_C01_008", X_MAIN, y_cum + ROW)
    _place(nodes_by_id, "c01_008_fork", X_MAIN, y_cum + ROW * 2)

    # ── Anjelica bonus (bottom-right, beside the Canto II fork)
    ay = y_cum + ROW * 2
    _place(nodes_by_id, "inferno_C01_009", X_BONUS, ay)
    ay += ROW
    _place(nodes_by_id, "inferno_C01_010", X_BONUS, ay)
    ay += ROW
    _place(nodes_by_id, "inferno_C01_credits", X_BONUS, ay)

    # ── EP7: bottom-left → freeplay hub (after Fate)
    dream_y = _pos_of(nodes_by_id, "inferno_C01_009")[1]
    _place(nodes_by_id, "inferno_C01_EP7", X_EP, dream_y)
    _place(nodes_by_id, "inferno_C01_EP7_fate", X_FATE, dream_y)

    # Place any enabled unlock still at the origin (future skills).
    for skill in unlocks.get("skills", []):
        if not skill.get("enabled", False):
            continue
        vid_id = skill["video_node_id"]
        if vid_id not in nodes_by_id:
            continue
        vx, vy = _pos_of(nodes_by_id, vid_id)
        if (vx, vy) != (0.0, 0.0):
            continue
        continue_to = skill.get("continue_to") or ""
        insert_after = skill.get("insert_after") or ""
        anchor = continue_to if continue_to in nodes_by_id else insert_after
        if anchor not in nodes_by_id:
            continue
        _ax, ay2 = _pos_of(nodes_by_id, anchor)
        _place(nodes_by_id, vid_id, X_UNLOCK, ay2)

    layout_freeplay(nodes_by_id)
    from scaffold_erosphere_c02 import layout_canto_ii

    layout_canto_ii(nodes_by_id)
    if resolve:
        _resolve_overlaps(nodes_by_id, locked=locked)


def round_node(
    nid: str,
    name: str,
    video: str,
    *,
    coins: int = 0,
    length_s: float = 0.0,
    out: str | None = None,
    items_blocked: bool = False,
    is_checkpoint: bool = False,
    release_jump: str | None = None,
    release_mode: str = "fail_jump",
    release_invert: bool = False,
    loop_until_clean: bool = False,
    release_flag: str = "",
    release_deadline_ms: int = 0,
    release_score_hit: int = 0,
    release_score_miss: int = 0,
    release_disabled_if_flag: str = "",
    pos: tuple[float, float] = (0, 0),
    set_flags: list[str] | None = None,
) -> dict:
    video_rel = resolve_video(video) if video else ""
    if video_rel and "/" in video_rel and not video_rel.startswith("content/"):
        folder = Path(video_rel).parent.as_posix()
    else:
        folder = Path(video_rel).stem if video_rel else nid
    data: dict = {
        "name": name,
        "folder": folder,
        "funscript_path": resolve_funscript(video_rel),
        "video_path": video_rel,
        "coins": coins,
        "round_type": "normal",
        "action_count": 0,
        "length_ms": int(round(length_s * 1000)) if length_s else 0,
        "is_checkpoint": is_checkpoint,
        "items_blocked": items_blocked,
        "axis_scripts": {},
        "vib_scripts": {},
        "release_enabled": False,
        "release_mode": "stamp_flag",
        "release_flag": "",
        "release_jump_to": "",
        "release_deadline_ms": 0,
        "release_score_hit": 0,
        "release_score_miss": 0,
        "release_remove_on_press": True,
        "release_invert": False,
        "release_disabled_if_flag": "",
    }
    if set_flags:
        data["set_flags"] = set_flags
    if release_jump:
        data["release_enabled"] = True
        data["release_mode"] = release_mode
        data["release_jump_to"] = release_jump
        data["release_invert"] = release_invert
    if loop_until_clean:
        data["release_enabled"] = True
        data["release_mode"] = "loop_until_clean"
    if release_flag:
        data["release_flag"] = release_flag
    if release_deadline_ms:
        data["release_deadline_ms"] = int(release_deadline_ms)
    if release_score_hit:
        data["release_score_hit"] = int(release_score_hit)
    if release_score_miss:
        data["release_score_miss"] = int(release_score_miss)
    if release_disabled_if_flag:
        data["release_disabled_if_flag"] = release_disabled_if_flag
    # stamp_flag / timed_window without a jump target
    if not data["release_enabled"] and (release_flag or release_deadline_ms):
        data["release_enabled"] = True
        if release_deadline_ms:
            data["release_mode"] = "timed_window"
        else:
            data["release_mode"] = "stamp_flag"
    attach_sibling_scripts(data)
    edges = [{"to": out}] if out else []
    sx, sy = _snap_pos(pos[0], pos[1])
    return {"id": nid, "type": "round", "data": data, "out": edges, "pos": [sx, sy]}


def shop_node(
    nid: str,
    title: str,
    items: list[str],
    *,
    out: str | None,
    pos: tuple[float, float],
) -> dict:
    return {
        "id": nid,
        "type": "shop",
        "data": {
            "title": title,
            "mode": "fixed",
            "count": len(items),
            "items": items,
            "guaranteed": [],
            "price_multiplier": 1.0,
        },
        "out": [{"to": out}] if out else [],
        "pos": list(_snap_pos(pos[0], pos[1])),
    }


def storyboard_node(
    nid: str,
    text: str = "",
    *,
    out: str | None,
    pos: tuple[float, float],
    item: str = "",
    coins: int = 0,
    set_flags: list[str] | None = None,
    lines: list[str] | None = None,
) -> dict:
    line_texts = lines if lines is not None else ([text] if text else [])
    data: dict = {
        "coins": coins,
        "item": item,
        "image": "",
        "lines": [{"speaker": "", "text": t, "image": ""} for t in line_texts],
    }
    if set_flags:
        data["set_flags"] = set_flags
    return {
        "id": nid,
        "type": "storyboard",
        "data": data,
        "out": [{"to": out}] if out else [],
        "pos": list(_snap_pos(pos[0], pos[1])),
    }


def fork_node(
    nid: str,
    title: str,
    choices: list[dict],
    *,
    pos: tuple[float, float],
    resolution: str = "choice",
    cond_metric: str = "score",
    default_path: int = 0,
    description: str = "",
) -> dict:
    return {
        "id": nid,
        "type": "fork",
        "data": {
            "title": title,
            "description": description,
            "resolution": resolution,
            "cond_metric": cond_metric,
            "cond_decider": "game",
            "default_path": default_path,
        },
        "out": choices,
        "pos": list(_snap_pos(pos[0], pos[1])),
    }


def edge(to: str, name: str, **extra) -> dict:
    e = {
        "to": to,
        "name": name,
        "description": "",
        "image_path": "",
        "weight": 1,
        "threshold": 0,
        "required_item": "",
        "cost": 0,
        "required_flag": "",
        "set_flags": [],
    }
    e.update(extra)
    return e


def cutscene_node(
    nid: str,
    name: str,
    video: str,
    *,
    out: str | None = None,
    items_blocked: bool = True,
    award_item: str = "",
    coins: int = 0,
    is_checkpoint: bool = False,
    length_s: float = 0.0,
    pos: tuple[float, float] = (0, 0),
) -> dict:
    """Watch-then-advance video (EP / Fate / Credits / unlock). No funscript."""
    data: dict = {
        "name": name,
        "video_path": resolve_video(video) if video else "",
        "items_blocked": items_blocked,
        "length_ms": int(round(length_s * 1000)) if length_s else 0,
        "award_item": award_item,
        "coins": coins,
        "is_checkpoint": is_checkpoint,
    }
    edges = [{"to": out}] if out else []
    return {
        "id": nid,
        "type": "cutscene",
        "data": data,
        "out": edges,
        "pos": list(_snap_pos(pos[0], pos[1])),
    }


def cooldown_node(
    nid: str,
    days: int,
    out: str,
    *,
    pos: tuple[float, float],
    label: str | None = None,
    message: str = "",
) -> dict:
    """Calendar lockout — Force Save & Quit, then Advance."""
    return {
        "id": nid,
        "type": "cooldown",
        "data": {
            "name": label or f"Cooldown ({days}d)",
            "days": max(1, int(days)),
            "message": message,
        },
        "out": [{"to": out}],
        "pos": list(_snap_pos(pos[0], pos[1])),
    }


def gap(
    nid: str,
    days: int,
    out: str,
    *,
    pos: tuple[float, float],
    label: str | None = None,
) -> dict:
    return cooldown_node(nid, days, out, pos=pos, label=label)


def fp_exit_fork(
    nid: str,
    campaign_to: str,
    *,
    pos: tuple[float, float],
    title: str = "Fate",
) -> dict:
    """After shared EP punish: freeplay flag → hub; else campaign landing."""
    return fork_node(
        nid,
        title,
        [
            edge("fp_hub_1", "Return", required_flag="from_freeplay"),
            edge(campaign_to, "Continue"),
        ],
        pos=pos,
        resolution="conditional",
        cond_metric="flag",
        default_path=1,
    )


def fp_release_gate(
    nid: str, ep_entry: str, *, text: str, pos: tuple[float, float]
) -> dict:
    """Stamp from_freeplay then enter the shared EP island."""
    return storyboard_node(
        nid,
        text,
        out=ep_entry,
        pos=pos,
        set_flags=["from_freeplay"],
    )


def failed_from_gate(
    nid: str, ep_entry: str, flag: str, *, text: str, pos: tuple[float, float]
) -> dict:
    """Stamp failed_from_* then enter a shared C02 EP island."""
    return storyboard_node(
        nid,
        text,
        out=ep_entry,
        pos=pos,
        set_flags=[flag],
    )


def failed_from_exit_fork(
    nid: str,
    returns: list[tuple[str, str, str]],
    *,
    default_to: str,
    pos: tuple[float, float],
    title: str = "Return",
) -> dict:
    """Conditional exit: required_flag edges first, default last."""
    choices = [
        edge(target, label, required_flag=flag) for flag, target, label in returns
    ]
    choices.append(edge(default_to, "Continue"))
    return fork_node(
        nid,
        title,
        choices,
        pos=pos,
        resolution="conditional",
        cond_metric="flag",
        default_path=len(choices) - 1,
    )


def layout_freeplay(nodes_by_id: dict[str, dict]) -> None:
    """Place freeplay hubs / clones / gates beside bonus + EP columns."""
    dream_y = _pos_of(nodes_by_id, "inferno_C01_009")[1]
    # Hub stack just right of Anjelica, starting at EP7 fate row
    hy = dream_y
    for i, hid in enumerate(("fp_hub_1", "fp_hub_2", "fp_hub_3")):
        _place(nodes_by_id, hid, X_FP_HUB, hy + i * ROW)

    # fp rounds: same Y as campaign twins, freeplay column
    for camp_id, fp_id in (
        ("inferno_C01_001", "fp_C01_001"),
        ("inferno_C01_002", "fp_C01_002"),
        ("inferno_C01_003", "fp_C01_003"),
        ("inferno_C01_004", "fp_C01_004"),
        ("inferno_C01_005", "fp_C01_005"),
        ("inferno_C01_006", "fp_C01_006"),
        ("inferno_C01_006_5", "fp_C01_006_5"),
    ):
        if camp_id in nodes_by_id and fp_id in nodes_by_id:
            _cx, cy = _pos_of(nodes_by_id, camp_id)
            _place(nodes_by_id, fp_id, X_FP, cy)

    # Gates left of EP entries (one row each — never share a cell)
    for ep, gate in (
        ("inferno_C01_EP1", "fp_gate_ep1"),
        ("inferno_C01_EP2", "fp_gate_ep2"),
        ("inferno_C01_EP3", "fp_gate_ep3"),
        ("inferno_C01_EP4", "fp_gate_ep4"),
        ("inferno_C01_EP5", "fp_gate_ep5"),
        ("inferno_C01_EP6", "fp_gate_ep6"),
        ("inferno_C01_007", "fp_gate_007"),
    ):
        if ep in nodes_by_id:
            ex, ey = _pos_of(nodes_by_id, ep)
            _place(nodes_by_id, gate, ex - COL * 0.5, ey)

    # Exit forks sit to the right of that EP's last chain node (unique Y per EP)
    for exit_id, anchor in (
        ("fp_exit_ep1", "c01_ep1_cd"),
        ("fp_exit_ep2", "c01_ep2_cd"),
        ("fp_exit_ep3", "c01_ep3_cd"),
        ("fp_exit_ep4", "c01_ep4_s3"),
        ("fp_exit_ep5", "c01_ep5_s5"),
        ("fp_exit_ep6", "c01_ep6_s5b"),
    ):
        if anchor in nodes_by_id:
            ax, ay = _pos_of(nodes_by_id, anchor)
            _place(nodes_by_id, exit_id, ax + GRID * 6, ay)


def build(*, preserved_positions: dict[str, list[float]] | None = None) -> dict:
    preserved = preserved_positions if preserved_positions is not None else {}
    nodes: list[dict] = []
    y = 0.0
    # Placeholder pos for side-branch nodes; layout_side_branches() sets final coords.
    Z = (0.0, 0.0)

    # ── Intro storyboard (main spine: x=0, y grows top→down) ───────────
    nodes.append(
        storyboard_node(
            "c01_intro_sb",
            lines=[
                "Welcome to Cock Hero Inferno. You are the legendary cockhero, and this journey is part of the Erosphere game universe.",
                "Your path forward leads deeper into the Inferno. Ahead await hours of indecent content; an erotic challenge that will leave you aching… if we don't break you. 😏",
                "Each round is a test of your stamina and virtue. We're going to work that cock. Let's see how long you last ♡",
                "Release before we give you permission, and you'll find out exactly what happens to boys who can't resist ;)",
                "Make it through a round without blowing your load, and you'll earn coins. Cum early, and you walk away with nothing but punishment.",
                "Spend your coins wisely. Some items can help you survive a round without spilling. Others take the sting out of a failure, but some only work once.",
                "How far you make it, and when you finally give in, is entirely up to you. We can't wait to see that cock throb and drip ♡",
            ],
            out="inferno_C01_001",
            pos=(X_MAIN, y),
        )
    )
    y += ROW

    # Main Canto I gameplay chain with release → EP jumps
    # Coins match live pack / V1 play: 004 + 006 + 006_5 = 0; 007 + 008 each pay 15
    # so clean path (no Fate) and release path both land at 75 before the fork.
    main = [
        ("inferno_C01_001", "Canto I: Intro", "Inferno_C01_001_Intro.mp4", 15, 308.436, "inferno_C01_EP1"),
        ("inferno_C01_002", "Canto I: The Cats Part I", "Inferno_C01_002_The_Cats_Part_I.mp4", 15, 377.21, "inferno_C01_EP2"),
        ("inferno_C01_003", "Canto I: The Cats Part II", "Inferno_C01_003_The_Cats_Part_II.mp4", 15, 261.678, "inferno_C01_EP3"),
        ("inferno_C01_004", "Canto I: Virgo's Training", "Inferno_C01_004_Virgo_s_Training.mp4", 0, 470.596, "inferno_C01_EP4"),
        ("inferno_C01_005", "Canto I: Charon", "Inferno_C01_005_Charon.mp4", 15, 479.557, "inferno_C01_EP5"),
        ("inferno_C01_006", "Canto I: The Battle of River Styx", "Inferno_C01_006_The_Battle_of_River_Styx.mp4", 0, 640.564, "inferno_C01_EP6"),
    ]
    for i, (nid, name, video, coins, dur, ep) in enumerate(main):
        nxt = main[i + 1][0] if i + 1 < len(main) else "inferno_C01_006_5"
        nodes.append(
            round_node(
                nid,
                name,
                video,
                coins=coins,
                length_s=dur,
                out=nxt,
                release_jump=ep,
                pos=(X_MAIN, y),
            )
        )
        y += ROW

    # Cum or Edge — release → Fate (007) → EP6; clean → 008 decision round → fork
    nodes.append(
        round_node(
            "inferno_C01_006_5",
            "Canto I: Cum or Edge",
            "Inferno_C01_006.5_Cum_or_Edge.mp4",
            coins=0,
            length_s=63.104,
            out="inferno_C01_008",
            release_jump="inferno_C01_007",
            pos=(X_MAIN, y),
        )
    )
    y += ROW

    # Fate — gameplay round (has Restim scripts); only on release from 006_5
    nodes.append(
        round_node(
            "inferno_C01_007",
            "Canto I: Fate",
            "Inferno_C01_007_Fate.mp4",
            coins=15,
            length_s=45.921,
            out="inferno_C01_EP6",
            pos=Z,
        )
    )

    # Decision video before the fork (pays the clean-path 15 that Fate would have)
    nodes.append(
        round_node(
            "inferno_C01_008",
            "Canto II or Anjelica's Reward",
            "Inferno_C01_008_Canto_II_or_Anjelica_s_Reward.mp4",
            coins=15,
            length_s=49.339,
            out="c01_008_fork",
            pos=(X_MAIN, y),
        )
    )
    y += ROW

    # Decision fork: Canto II vs Anjelica path
    nodes.append(
        fork_node(
            "c01_008_fork",
            "Canto II or Anjelica's Reward",
            [
                edge("inferno_C02_001", "Proceed to Canto II"),
                edge("inferno_C01_009", "Dream of Anjelica (Bonus)"),
            ],
            pos=(X_MAIN, y),
        )
    )
    fork_y = y
    y += ROW

    # Anjelica branch — right of fork (bonus path; EP/punish stay left of main)
    ay = fork_y
    nodes.append(
        round_node(
            "inferno_C01_009",
            "Anjelica's Dream",
            "Inferno_C01_009_Anjelica_s_Dream.mp4",
            length_s=683.713,
            out="inferno_C01_010",
            release_jump="inferno_C01_EP7",
            pos=(X_BONUS, ay),
        )
    )
    ay += ROW
    nodes.append(
        round_node(
            "inferno_C01_010",
            "Anjelica's Reward",
            "Inferno_C01_010_Anjelica_s_Reward.mp4",
            length_s=42.418,
            out="inferno_C01_credits",
            pos=(X_BONUS, ay),
        )
    )
    ay += ROW
    nodes.append(
        cutscene_node(
            "inferno_C01_credits",
            "Credits",
            "Inferno_C01_Credits.mp4",
            length_s=47.398,
            items_blocked=True,
            out=None,
            pos=(X_BONUS, ay),
        )
    )

    # ── EP subgraphs (wiring only; columns set by layout_side_branches) ─
    # EP1: EP → Fate → gap(1) → C01_001
    nodes += [
        cutscene_node(
            "inferno_C01_EP1",
            "Canto I: Epilogue 1",
            "Inferno_C01_EP1.mp4",
            items_blocked=True,
            out="inferno_C01_EP1_fate",
            pos=Z,
        ),
        cutscene_node(
            "inferno_C01_EP1_fate",
            "Canto I: Epilogue 1 — Fate",
            "Inferno_C01_EP1_Fate.mp4",
            length_s=51.864,
            items_blocked=True,
            out="c01_ep1_cd",
            pos=Z,
        ),
        gap("c01_ep1_cd", 1, "fp_exit_ep1", pos=Z),
    ]

    # EP2 / EP3: same shape, 3-day → C01_001
    for ep, days in (("EP2", 3), ("EP3", 3)):
        base = f"inferno_C01_{ep}"
        nodes += [
            cutscene_node(
                base,
                f"Canto I: Epilogue {ep[-1]}",
                f"Inferno_C01_{ep}.mp4",
                items_blocked=True,
                out=f"{base}_fate",
                pos=Z,
            ),
            cutscene_node(
                f"{base}_fate",
                f"Canto I: Epilogue {ep[-1]} — Fate",
                f"Inferno_C01_{ep}_Fate.mp4",
                items_blocked=True,
                out=f"c01_{ep.lower()}_cd",
                pos=Z,
            ),
            gap(f"c01_{ep.lower()}_cd", days, f"fp_exit_{ep.lower()}", pos=Z),
        ]

    # EP4: 3× (gap 1d → Virgo session) → C01_005
    nodes += [
        cutscene_node(
            "inferno_C01_EP4",
            "Canto I: Epilogue 4",
            "Inferno_C01_EP4.mp4",
            items_blocked=True,
            out="inferno_C01_EP4_fate",
            pos=Z,
        ),
        cutscene_node(
            "inferno_C01_EP4_fate",
            "Canto I: Epilogue 4 — Fate",
            "Inferno_C01_EP4_Fate.mp4",
            items_blocked=True,
            out="c01_ep4_cd1",
            pos=Z,
        ),
    ]
    for i in range(1, 4):
        sess = f"c01_ep4_s{i}"
        cd = f"c01_ep4_cd{i}"
        nxt = f"c01_ep4_cd{i + 1}" if i < 3 else "fp_exit_ep4"
        nodes.append(gap(cd, 1, sess, pos=Z, label=f"Canto I: Epilogue 4 — Cooldown {i}"))
        nodes.append(
            round_node(
                sess,
                f"Punishment: Virgo's Training — Session {i} of 3",
                "Inferno_C01_004_Virgo_s_Training.mp4",
                coins=15,
                length_s=470.596,
                items_blocked=True,
                out=nxt,
                release_jump="inferno_C01_EP4",
                pos=Z,
            )
        )

    # EP5: Fate → Amulet (skill_unlocks) → 5× (gap 1d → Charon) → C01_006
    nodes += [
        cutscene_node(
            "inferno_C01_EP5",
            "Canto I: Epilogue 5",
            "Inferno_C01_EP5.mp4",
            items_blocked=True,
            out="inferno_C01_EP5_fate",
            pos=Z,
        ),
        cutscene_node(
            "inferno_C01_EP5_fate",
            "Canto I: Epilogue 5 — Fate",
            "Inferno_C01_EP5_Fate.mp4",
            items_blocked=True,
            out="c01_ep5_cd1",
            pos=Z,
        ),
    ]
    for i in range(1, 6):
        sess = f"c01_ep5_s{i}"
        cd = f"c01_ep5_cd{i}"
        nxt = f"c01_ep5_cd{i + 1}" if i < 5 else "fp_exit_ep5"
        coins = 75 if i == 5 else 0
        nodes.append(gap(cd, 1, sess, pos=Z, label=f"Canto I: Epilogue 5 — Cooldown {i}"))
        nodes.append(
            round_node(
                sess,
                f"Punishment: Charon — Session {i} of 5",
                "Inferno_C01_005_Charon.mp4",
                coins=coins,
                length_s=479.557,
                items_blocked=True,
                out=nxt,
                release_jump="inferno_C01_EP5",
                pos=Z,
            )
        )

    # EP6: Fate → Psychic (skill_unlocks) → 5× (gap 2d → Charon + Battle) → C01_006_5
    nodes += [
        cutscene_node(
            "inferno_C01_EP6",
            "Canto I: Epilogue 6",
            "Inferno_C01_EP6.mp4",
            items_blocked=True,
            out="inferno_C01_EP6_fate",
            pos=Z,
        ),
        cutscene_node(
            "inferno_C01_EP6_fate",
            "Canto I: Epilogue 6 — Fate",
            "Inferno_C01_EP6_Fate.mp4",
            items_blocked=True,
            out="c01_ep6_cd1",
            pos=Z,
        ),
    ]
    for i in range(1, 6):
        cd = f"c01_ep6_cd{i}"
        s_a = f"c01_ep6_s{i}a"
        s_b = f"c01_ep6_s{i}b"
        nxt_cd = f"c01_ep6_cd{i + 1}" if i < 5 else "fp_exit_ep6"
        coins_b = 90 if i == 5 else 0
        nodes.append(
            gap(cd, 2, s_a, pos=Z, label=f"Canto I: Epilogue 6 — Cooldown {i}")
        )
        nodes.append(
            round_node(
                s_a,
                f"Punishment: Charon — Session {i} of 5",
                "Inferno_C01_005_Charon.mp4",
                length_s=479.557,
                items_blocked=True,
                out=s_b,
                release_jump="inferno_C01_EP6",
                pos=Z,
            )
        )
        nodes.append(
            round_node(
                s_b,
                f"Punishment: The Battle of River Styx — Session {i} of 5",
                "Inferno_C01_006_The_Battle_of_River_Styx.mp4",
                coins=coins_b,
                length_s=640.564,
                items_blocked=True,
                out=nxt_cd,
                release_jump="inferno_C01_EP6",
                pos=Z,
            )
        )

    # EP7: EP → Fate → freeplay hub
    nodes += [
        cutscene_node(
            "inferno_C01_EP7",
            "Canto I: Epilogue 7",
            "Inferno_C01_EP7.mp4",
            items_blocked=True,
            out="inferno_C01_EP7_fate",
            pos=Z,
        ),
        cutscene_node(
            "inferno_C01_EP7_fate",
            "Canto I: Epilogue 7 — Fate",
            "Inferno_C01_EP7_Fate.mp4",
            items_blocked=True,
            out="fp_hub_1",
            pos=Z,
        ),
    ]

    # ── Freeplay: release gates + post-punish exit forks ───────────────
    nodes += [
        fp_release_gate(
            "fp_gate_ep1",
            "inferno_C01_EP1",
            text="Anjelica's introduction has overwhelmed you. You have released in freeplay. Continue and learn your fate.",
            pos=Z,
        ),
        fp_release_gate(
            "fp_gate_ep2",
            "inferno_C01_EP2",
            text="You have succumbed to the Queen and her cats. You have released in freeplay. Continue and learn your fate.",
            pos=Z,
        ),
        fp_release_gate(
            "fp_gate_ep3",
            "inferno_C01_EP3",
            text="You have succumbed to the Queen and her cats. You have released in freeplay. Continue and learn your fate.",
            pos=Z,
        ),
        fp_release_gate(
            "fp_gate_ep4",
            "inferno_C01_EP4",
            text="Virgo's training was too much for you. You have released in freeplay. Continue and learn your fate.",
            pos=Z,
        ),
        fp_release_gate(
            "fp_gate_ep5",
            "inferno_C01_EP5",
            text="Charon's tease has pushed you over the edge. You have released in freeplay. Continue and learn your fate.",
            pos=Z,
        ),
        fp_release_gate(
            "fp_gate_ep6",
            "inferno_C01_EP6",
            text="You could not withstand Charon's full power. You have released in freeplay. Continue and learn your fate.",
            pos=Z,
        ),
        fp_release_gate(
            "fp_gate_007",
            "inferno_C01_007",
            text="You could not withstand Charon's full power. You have released in freeplay. Continue and learn your fate.",
            pos=Z,
        ),
        fp_exit_fork(
            "fp_exit_ep1",
            "inferno_C01_001",
            pos=Z,
            title="Canto I: Epilogue 1 — Punishment Complete",
        ),
        fp_exit_fork(
            "fp_exit_ep2",
            "inferno_C01_001",
            pos=Z,
            title="Canto I: Epilogue 2 — Punishment Complete",
        ),
        fp_exit_fork(
            "fp_exit_ep3",
            "inferno_C01_001",
            pos=Z,
            title="Canto I: Epilogue 3 — Punishment Complete",
        ),
        fp_exit_fork(
            "fp_exit_ep4",
            "inferno_C01_005",
            pos=Z,
            title="Canto I: Epilogue 4 — Punishment Complete",
        ),
        fp_exit_fork(
            "fp_exit_ep5",
            "inferno_C01_006",
            pos=Z,
            title="Canto I: Epilogue 5 — Punishment Complete",
        ),
        fp_exit_fork(
            "fp_exit_ep6",
            "inferno_C01_006_5",
            pos=Z,
            title="Canto I: Epilogue 6 — Punishment Complete",
        ),
    ]

    # Freeplay round clones (clear → hub; 006 → 006_5 → hub)
    fp_rounds = [
        ("fp_C01_001", "Canto I: Intro", "Inferno_C01_001_Intro.mp4", 15, 308.436, "fp_gate_ep1"),
        ("fp_C01_002", "Canto I: The Cats Part I", "Inferno_C01_002_The_Cats_Part_I.mp4", 15, 377.21, "fp_gate_ep2"),
        ("fp_C01_003", "Canto I: The Cats Part II", "Inferno_C01_003_The_Cats_Part_II.mp4", 15, 261.678, "fp_gate_ep3"),
        ("fp_C01_004", "Canto I: Virgo's Training", "Inferno_C01_004_Virgo_s_Training.mp4", 15, 470.596, "fp_gate_ep4"),
        ("fp_C01_005", "Canto I: Charon", "Inferno_C01_005_Charon.mp4", 15, 479.557, "fp_gate_ep5"),
        ("fp_C01_006", "Canto I: The Battle of River Styx", "Inferno_C01_006_The_Battle_of_River_Styx.mp4", 0, 640.564, "fp_gate_ep6"),
    ]
    for nid, name, video, coins, dur, gate in fp_rounds:
        out = "fp_C01_006_5" if nid == "fp_C01_006" else "fp_hub_1"
        nodes.append(
            round_node(
                nid,
                name,
                video,
                coins=coins,
                length_s=dur,
                out=out,
                release_jump=gate,
                pos=Z,
            )
        )
    nodes.append(
        round_node(
            "fp_C01_006_5",
            "Canto I: Cum or Edge",
            "Inferno_C01_006.5_Cum_or_Edge.mp4",
            coins=15,
            length_s=63.104,
            out="fp_hub_1",
            release_jump="fp_gate_007",
            pos=Z,
        )
    )

    # Paginated hubs (Back first, More last; never list 006_5)
    nodes.append(
        fork_node(
            "fp_hub_1",
            "Inferno",
            [
                edge("fp_C01_001", "Canto I: Intro"),
                edge("fp_C01_002", "Canto I: The Cats Part I"),
                edge("fp_C01_003", "Canto I: The Cats Part II"),
                edge("fp_hub_2", "More"),
            ],
            pos=Z,
        )
    )
    nodes.append(
        fork_node(
            "fp_hub_2",
            "Inferno",
            [
                edge("fp_hub_1", "Back"),
                edge("fp_C01_004", "Canto I: Virgo's Training"),
                edge("fp_C01_005", "Canto I: Charon"),
                edge("fp_hub_3", "More"),
            ],
            pos=Z,
        )
    )
    nodes.append(
        fork_node(
            "fp_hub_3",
            "Inferno",
            [
                edge("fp_hub_2", "Back"),
                edge("fp_C01_006", "Canto I: The Battle of River Styx"),
                edge("inferno_C01_009", "Dream of Anjelica"),
            ],
            pos=Z,
        )
    )

    # Build Canto II spine and EP islands BEFORE applying skill unlocks
    from scaffold_erosphere_c02 import build_canto_ii_nodes

    c02_nodes, _c02_y = build_canto_ii_nodes(y=y, Z=Z)
    nodes.extend(c02_nodes)

    unlocks = load_skill_unlocks()
    apply_skill_unlocks(nodes, unlocks)

    # Scaffold layout first; then restore any positions already authored in the pack.
    # C02 layout is scaffold-owned until stable — do not re-lock first-regen pile-ups.
    from scaffold_erosphere_c02 import is_c02_layout_owned

    layout_side_branches(nodes, unlocks, resolve=False)
    preserved_c01 = {k: v for k, v in preserved.items() if not is_c02_layout_owned(k)}
    n_kept = apply_preserved_positions(nodes, preserved_c01)
    locked = {nid for nid in preserved_c01 if any(n["id"] == nid for n in nodes)}
    _resolve_overlaps({n["id"]: n for n in nodes}, locked=locked)
    if preserved:
        skipped = len(preserved) - len(preserved_c01)
        print(
            f"Preserved layout for {n_kept}/{len(preserved_c01)} existing node position(s)"
            + (f" (skipped {skipped} C02 scaffold-owned)" if skipped else "")
        )

    journey = {
        "Name": "Erosphere Inferno",
        "Author": "Senorgif2",
        "Description": "Erosphere Inferno.",
        "Difficulty": "Hard",
        "Tags": ["erosphere", "inferno", "canto-i", "canto-ii"],
        "MapEnabled": True,
        "MapFog": False,
        "MapFogReveal": 1,
        "UnlockPayPerUse": bool(unlocks.get("unlock_pay_per_use", True)),
        "Format": 2,
        "Start": "c01_intro_sb",
        "Nodes": nodes,
        "Comments": [],
        "Groups": [],
    }
    return journey


def main() -> None:
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    # Ensure we never mutate pack media from this script.
    pack_funscripts_before: set[str] = set()
    if PACK_DIR.is_dir():
        pack_funscripts_before = {
            p.relative_to(PACK_DIR).as_posix() for p in PACK_DIR.rglob("*.funscript")
        }

    preserved = load_existing_positions()
    data = build(preserved_positions=preserved)
    if BUILD_JSON.is_file():
        bak = BUILD_DIR / "journey.json.pre_scaffold.bak"
        bak.write_text(BUILD_JSON.read_text(encoding="utf-8"), encoding="utf-8")
        print(f"Backup -> {bak}")
    payload = json.dumps(data, indent=2) + "\n"
    BUILD_JSON.write_text(payload, encoding="utf-8")
    (BUILD_DIR / "skill_unlocks.json").write_text(
        UNLOCKS_PATH.read_text(encoding="utf-8"), encoding="utf-8"
    )

    if PACK_DIR.is_dir():
        pack_funscripts_after = {
            p.relative_to(PACK_DIR).as_posix() for p in PACK_DIR.rglob("*.funscript")
        }
        lost = pack_funscripts_before - pack_funscripts_after
        if lost:
            print(f"ERROR: pack funscripts changed/removed: {sorted(lost)[:5]}")
        else:
            print(
                f"Live pack funscripts untouched ({len(pack_funscripts_after)} files)"
            )

    rounds_with_axes = 0
    for n in data["Nodes"]:
        if n.get("type") != "round":
            continue
        d = n.get("data") or {}
        if d.get("axis_scripts") or d.get("estim_scripts"):
            rounds_with_axes += 1
    print(
        f"Wrote {BUILD_JSON} ({len(data['Nodes'])} nodes; "
        f"{rounds_with_axes} rounds with axis/estim scripts)"
    )
    print(f"Wrote {BUILD_DIR / 'skill_unlocks.json'}")
    print(f"Install with: scripts/dev/scaffold-erosphere-inferno.ps1")


if __name__ == "__main__":
    main()
