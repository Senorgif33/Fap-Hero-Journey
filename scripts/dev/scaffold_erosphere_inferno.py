#!/usr/bin/env python3
"""Scaffold Erosphere Inferno Format 2 journey under local/journeys/erosphere-inferno/.

Canto I main path + all C01 EP subgraphs (cooldown gaps, punish sessions, unlocks).
Media: content/ should be a directory junction/symlink to E:\\CYOA-Erosphere\\v1
(see scripts/dev/scaffold-erosphere-inferno.ps1).
"""
from __future__ import annotations

import json
import math
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT_DIR = REPO / "local" / "journeys" / "erosphere-inferno"
OUT_JSON = OUT_DIR / "journey.json"

X_STEP = 280
Y_MAIN = 0
Y_EP = 420


def round_node(
    nid: str,
    name: str,
    video: str,
    *,
    coins: int = 0,
    length_s: float = 0.0,
    out: str | None = None,
    items_blocked: bool = False,
    cooldown_days: int = 0,
    is_checkpoint: bool = False,
    release_jump: str | None = None,
    release_mode: str = "fail_jump",
    release_invert: bool = False,
    loop_until_clean: bool = False,
    pos: tuple[float, float] = (0, 0),
    set_flags: list[str] | None = None,
) -> dict:
    data: dict = {
        "name": name,
        "folder": nid,
        "funscript_path": "",
        "video_path": f"content/{video}" if video else "",
        "coins": coins,
        "round_type": "normal",
        "action_count": 0,
        "length_ms": int(round(length_s * 1000)) if length_s else 0,
        "is_checkpoint": is_checkpoint,
        "cooldown_days": cooldown_days,
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
    edges = [{"to": out}] if out else []
    return {"id": nid, "type": "round", "data": data, "out": edges, "pos": [pos[0], pos[1]]}


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
        "pos": [pos[0], pos[1]],
    }


def storyboard_node(
    nid: str,
    text: str,
    *,
    out: str | None,
    pos: tuple[float, float],
    item: str = "",
    coins: int = 0,
) -> dict:
    return {
        "id": nid,
        "type": "storyboard",
        "data": {
            "coins": coins,
            "item": item,
            "image": "",
            "lines": [{"speaker": "", "text": text, "image": ""}],
        },
        "out": [{"to": out}] if out else [],
        "pos": [pos[0], pos[1]],
    }


def fork_node(
    nid: str,
    title: str,
    choices: list[dict],
    *,
    pos: tuple[float, float],
) -> dict:
    return {
        "id": nid,
        "type": "fork",
        "data": {
            "title": title,
            "description": "",
            "resolution": "choice",
            "cond_metric": "score",
            "default_path": 0,
        },
        "out": choices,
        "pos": [pos[0], pos[1]],
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


def gap(
    nid: str,
    days: int,
    out: str,
    *,
    pos: tuple[float, float],
    label: str | None = None,
) -> dict:
    return round_node(
        nid,
        label or f"Cooldown ({days}d)",
        "",
        cooldown_days=days,
        items_blocked=True,
        out=out,
        pos=pos,
    )


def build() -> dict:
    nodes: list[dict] = []
    x = 0

    # ── Intro storyboard ──────────────────────────────────────────────
    nodes.append(
        storyboard_node(
            "c01_intro_sb",
            "Canto I — Inferno. Hold the edge. Release only when fate demands it.",
            out="inferno_C01_001",
            pos=(x, Y_MAIN),
        )
    )
    x += X_STEP

    # Main Canto I gameplay chain with release → EP jumps
    main = [
        ("inferno_C01_001", "Intro", "Inferno_C01_001_Intro.mp4", 15, 308.436, "inferno_C01_EP1"),
        ("inferno_C01_002", "The Cats Part I", "Inferno_C01_002_The_Cats_Part_I.mp4", 15, 377.21, "inferno_C01_EP2"),
        ("inferno_C01_003", "The Cats Part II", "Inferno_C01_003_The_Cats_Part_II.mp4", 15, 261.678, "inferno_C01_EP3"),
        ("inferno_C01_004", "Virgo's Training", "Inferno_C01_004_Virgo_s_Training.mp4", 15, 470.596, "inferno_C01_EP4"),
        ("inferno_C01_005", "Charon", "Inferno_C01_005_Charon.mp4", 15, 479.557, "inferno_C01_EP5"),
        ("inferno_C01_006", "The Battle of River Styx", "Inferno_C01_006_The_Battle_of_River_Styx.mp4", 0, 640.564, "inferno_C01_EP6"),
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
                pos=(x, Y_MAIN),
            )
        )
        x += X_STEP

    # Cum or Edge — release → Fate (007) → EP6; clean → fork 008
    nodes.append(
        round_node(
            "inferno_C01_006_5",
            "Cum or Edge",
            "Inferno_C01_006.5_Cum_or_Edge.mp4",
            coins=15,
            length_s=63.104,
            out="c01_008_fork",
            release_jump="inferno_C01_007",
            pos=(x, Y_MAIN),
        )
    )
    x += X_STEP

    # Fate video (story / items_blocked) → EP6
    nodes.append(
        round_node(
            "inferno_C01_007",
            "Fate",
            "Inferno_C01_007_Fate.mp4",
            length_s=45.921,
            items_blocked=True,
            out="inferno_C01_EP6",
            pos=(x, Y_MAIN - 200),
        )
    )

    # Decision fork: Canto II (flag) vs Anjelica path — drop VP paywall
    nodes.append(
        fork_node(
            "c01_008_fork",
            "Canto II or Anjelica's Reward",
            [
                # VP/achievement paywall dropped; flag gate can be added when C02 ships.
                edge("c01_canto2_gate", "Proceed to Canto II"),
                edge("inferno_C01_A01", "Dream of Anjelica (Bonus)"),
            ],
            pos=(x, Y_MAIN),
        )
    )
    x += X_STEP

    # Placeholder Canto II gate (storyboard until C02 authored)
    nodes.append(
        storyboard_node(
            "c01_canto2_gate",
            "Canto II graph not yet authored in this scaffold. End of Canto I main path.",
            out=None,
            pos=(x, Y_MAIN - 160),
        )
    )

    # Divine Summoning unlock video → Anjelica's Dream
    nodes.append(
        round_node(
            "inferno_C01_A01",
            "Divine Summoning",
            "Inferno_C01_A01_Divine_Summoning.mp4",
            length_s=6.249,
            items_blocked=True,
            out="c01_divine_shop",
            pos=(x, Y_MAIN + 160),
        )
    )
    nodes.append(
        shop_node(
            "c01_divine_shop",
            "Divine Summoning",
            ["erosphere_divine_summoning"],
            out="inferno_C01_009",
            pos=(x + X_STEP, Y_MAIN + 160),
        )
    )
    x2 = x + 2 * X_STEP

    nodes.append(
        round_node(
            "inferno_C01_009",
            "Anjelica's Dream",
            "Inferno_C01_009_Anjelica_s_Dream.mp4",
            length_s=683.713,
            out="inferno_C01_010",
            release_jump="inferno_C01_EP7",
            pos=(x2, Y_MAIN + 160),
        )
    )
    nodes.append(
        round_node(
            "inferno_C01_010",
            "Anjelica's Reward",
            "Inferno_C01_010_Anjelica_s_Reward.mp4",
            length_s=42.418,
            out="inferno_C01_credits",
            pos=(x2 + X_STEP, Y_MAIN + 160),
        )
    )
    nodes.append(
        round_node(
            "inferno_C01_credits",
            "Credits",
            "Inferno_C01_Credits.mp4",
            length_s=47.398,
            items_blocked=True,
            out=None,
            pos=(x2 + 2 * X_STEP, Y_MAIN + 160),
        )
    )

    # ── EP subgraphs (below main) ─────────────────────────────────────
    ep_x0 = 0

    # EP1: EP → Fate → gap(1) → C01_001
    nodes += [
        round_node(
            "inferno_C01_EP1",
            "Canto I: Epilogue 1",
            "Inferno_C01_EP1.mp4",
            items_blocked=True,
            out="inferno_C01_EP1_fate",
            pos=(ep_x0, Y_EP),
        ),
        round_node(
            "inferno_C01_EP1_fate",
            "EP1 Fate",
            "Inferno_C01_EP1_Fate.mp4",
            length_s=51.864,
            items_blocked=True,
            out="c01_ep1_cd",
            pos=(ep_x0 + X_STEP, Y_EP),
        ),
        gap("c01_ep1_cd", 1, "inferno_C01_001", pos=(ep_x0 + 2 * X_STEP, Y_EP)),
    ]

    # EP2 / EP3: same shape, 3-day → C01_001
    for ep, days in (("EP2", 3), ("EP3", 3)):
        base = f"inferno_C01_{ep}"
        y = Y_EP + (120 if ep == "EP2" else 240)
        nodes += [
            round_node(
                base,
                f"Canto I: Epilogue {ep[-1]}",
                f"Inferno_C01_{ep}.mp4",
                items_blocked=True,
                out=f"{base}_fate",
                pos=(ep_x0, y),
            ),
            round_node(
                f"{base}_fate",
                f"{ep} Fate",
                f"Inferno_C01_{ep}_Fate.mp4",
                items_blocked=True,
                out=f"c01_{ep.lower()}_cd",
                pos=(ep_x0 + X_STEP, y),
            ),
            gap(f"c01_{ep.lower()}_cd", days, "inferno_C01_001", pos=(ep_x0 + 2 * X_STEP, y)),
        ]

    # EP4: 3× (gap 1d → Virgo session) → C01_005; release during session restarts EP4
    y = Y_EP + 360
    nodes += [
        round_node(
            "inferno_C01_EP4",
            "Canto I: Epilogue 4",
            "Inferno_C01_EP4.mp4",
            items_blocked=True,
            out="inferno_C01_EP4_fate",
            pos=(ep_x0, y),
        ),
        round_node(
            "inferno_C01_EP4_fate",
            "EP4 Fate",
            "Inferno_C01_EP4_Fate.mp4",
            items_blocked=True,
            out="c01_ep4_cd1",
            pos=(ep_x0 + X_STEP, y),
        ),
    ]
    prev = "c01_ep4_cd1"
    for i in range(1, 4):
        sess = f"c01_ep4_s{i}"
        cd = f"c01_ep4_cd{i}"
        nxt_cd = f"c01_ep4_cd{i + 1}" if i < 3 else None
        nxt = nxt_cd if nxt_cd else "inferno_C01_005"
        nodes.append(gap(cd, 1, sess, pos=(ep_x0 + (1 + i * 2) * X_STEP, y), label=f"EP4 wait {i}"))
        nodes.append(
            round_node(
                sess,
                f"Virgo's Training (punish {i}/3)",
                "Inferno_C01_004_Virgo_s_Training.mp4",
                coins=15,
                length_s=470.596,
                items_blocked=True,
                out=nxt,
                release_jump="inferno_C01_EP4",
                pos=(ep_x0 + (2 + i * 2) * X_STEP, y),
            )
        )

    # EP5: 5× (gap 1d → Charon) → amulet unlock → C01_006; +75 on final only
    y = Y_EP + 520
    nodes += [
        round_node(
            "inferno_C01_EP5",
            "Canto I: Epilogue 5",
            "Inferno_C01_EP5.mp4",
            items_blocked=True,
            out="inferno_C01_EP5_fate",
            pos=(ep_x0, y),
        ),
        round_node(
            "inferno_C01_EP5_fate",
            "EP5 Fate",
            "Inferno_C01_EP5_Fate.mp4",
            items_blocked=True,
            out="c01_ep5_cd1",
            pos=(ep_x0 + X_STEP, y),
        ),
    ]
    for i in range(1, 6):
        sess = f"c01_ep5_s{i}"
        cd = f"c01_ep5_cd{i}"
        nxt = f"c01_ep5_cd{i + 1}" if i < 5 else "c01_amulet_vid"
        coins = 75 if i == 5 else 0
        nodes.append(gap(cd, 1, sess, pos=(ep_x0 + (1 + i * 2) * X_STEP, y), label=f"EP5 wait {i}"))
        nodes.append(
            round_node(
                sess,
                f"Charon (punish {i}/5)",
                "Inferno_C01_005_Charon.mp4",
                coins=coins,
                length_s=479.557,
                items_blocked=True,
                out=nxt,
                release_jump="inferno_C01_EP5",
                pos=(ep_x0 + (2 + i * 2) * X_STEP, y),
            )
        )
    nodes += [
        round_node(
            "c01_amulet_vid",
            "The Amulet of Sustenance",
            "Inferno_C01_I01_The_Amulet_of_Sustenance.mp4",
            items_blocked=True,
            out="c01_amulet_shop",
            pos=(ep_x0 + 13 * X_STEP, y),
        ),
        shop_node(
            "c01_amulet_shop",
            "Amulet of Sustenance",
            ["erosphere_amulet"],
            out="inferno_C01_006",
            pos=(ep_x0 + 14 * X_STEP, y),
        ),
    ]

    # EP6: 5× (gap 2d → Charon + Battle) → Psychic Divorce → C01_006_5
    y = Y_EP + 680
    nodes += [
        round_node(
            "inferno_C01_EP6",
            "Canto I: Epilogue 6",
            "Inferno_C01_EP6.mp4",
            items_blocked=True,
            out="inferno_C01_EP6_fate",
            pos=(ep_x0, y),
        ),
        round_node(
            "inferno_C01_EP6_fate",
            "EP6 Fate",
            "Inferno_C01_EP6_Fate.mp4",
            items_blocked=True,
            out="c01_ep6_cd1",
            pos=(ep_x0 + X_STEP, y),
        ),
    ]
    for i in range(1, 6):
        cd = f"c01_ep6_cd{i}"
        s_a = f"c01_ep6_s{i}a"
        s_b = f"c01_ep6_s{i}b"
        nxt_cd = f"c01_ep6_cd{i + 1}" if i < 5 else "c01_psychic_vid"
        coins_b = 90 if i == 5 else 0
        nodes.append(gap(cd, 2, s_a, pos=(ep_x0 + (1 + i * 3) * X_STEP, y), label=f"EP6 wait {i}"))
        nodes.append(
            round_node(
                s_a,
                f"Charon (EP6 {i}/5)",
                "Inferno_C01_005_Charon.mp4",
                length_s=479.557,
                items_blocked=True,
                out=s_b,
                release_jump="inferno_C01_EP6",
                pos=(ep_x0 + (2 + i * 3) * X_STEP, y),
            )
        )
        nodes.append(
            round_node(
                s_b,
                f"Battle Styx (EP6 {i}/5)",
                "Inferno_C01_006_The_Battle_of_River_Styx.mp4",
                coins=coins_b,
                length_s=640.564,
                items_blocked=True,
                out=nxt_cd,
                release_jump="inferno_C01_EP6",
                pos=(ep_x0 + (3 + i * 3) * X_STEP, y),
            )
        )
    nodes += [
        round_node(
            "c01_psychic_vid",
            "Psychic Divorce",
            "Inferno_C01_S01_Psychic_Divorce.mp4",
            items_blocked=True,
            out="c01_psychic_shop",
            pos=(ep_x0 + 18 * X_STEP, y),
        ),
        shop_node(
            "c01_psychic_shop",
            "Psychic Divorce",
            ["erosphere_psychic_divorce"],
            out="inferno_C01_006_5",
            pos=(ep_x0 + 19 * X_STEP, y),
        ),
    ]

    # EP7: EP → Fate → back to C01_009 (no Freeplay)
    y = Y_EP + 840
    nodes += [
        round_node(
            "inferno_C01_EP7",
            "Canto I: Epilogue 7",
            "Inferno_C01_EP7.mp4",
            items_blocked=True,
            out="inferno_C01_EP7_fate",
            pos=(ep_x0, y),
        ),
        round_node(
            "inferno_C01_EP7_fate",
            "EP7 Fate",
            "Inferno_C01_EP7_Fate.mp4",
            items_blocked=True,
            out="inferno_C01_009",
            pos=(ep_x0 + X_STEP, y),
        ),
    ]

    # First skill shop after Charon: only Feign Death (free unlock + pay-on-use).
    # Later skills unlock via their story shops / Canto II (not this stop).
    nodes.append(
        shop_node(
            "c01_skills_shop",
            "Feign Death",
            ["erosphere_feign_death"],
            out="inferno_C01_006",
            pos=(X_STEP * 5, Y_MAIN - 280),
        )
    )
    # Rewire Charon out through skills shop
    for n in nodes:
        if n["id"] == "inferno_C01_005":
            n["out"] = [{"to": "c01_skills_shop"}]
            break

    journey = {
        "Name": "Erosphere Inferno",
        "Author": "Erosphere (port)",
        "Description": "Canto I scaffold + EP punishment matrix. Canto II TBD. Media via content/ → v1 junction.",
        "Difficulty": "Hard",
        "Tags": ["erosphere", "inferno", "canto-i"],
        "MapEnabled": True,
        "MapFog": False,
        "MapFogReveal": 1,
        "UnlockPayPerUse": True,
        "Format": 2,
        "Start": "c01_intro_sb",
        "Nodes": nodes,
        "Comments": [],
        "Groups": [],
    }
    return journey


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    data = build()
    OUT_JSON.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {OUT_JSON} ({len(data['Nodes'])} nodes)")


if __name__ == "__main__":
    main()
