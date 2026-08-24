"""Canto II spine + EP islands for scaffold_erosphere_inferno.build()."""
from __future__ import annotations

from scaffold_erosphere_inferno import (
    X_CHAIN,
    X_EP,
    X_FATE,
    X_MAIN,
    X_UNLOCK,
    COL,
    ROW,
    cutscene_node,
    edge,
    failed_from_exit_fork,
    failed_from_gate,
    fork_node,
    gap,
    round_node,
    storyboard_node,
    _place,
    _pos_of,
)

# V1 durations / coins (vpReward ΓåÆ coins)
C02_ROUNDS: list[tuple] = [
    # nid, name, video, coins, length_s, release_to (EP id or gate id or None)
    ("inferno_C02_001", "Canto II: Intro", "Inferno_C02_001_Intro.mp4", 20, 249.875, "inferno_C02_EP1"),
    ("inferno_C02_002", "Canto II: The Great Gate", "Inferno_C02_002_The_Great_Gate.mp4", 20, 372.957, "inferno_C02_EP2"),
    ("inferno_C02_003", "Canto II: The Guardians of the Gate", "Inferno_C02_003_The_Guardians_of_the_Gate.mp4", 20, 576.369, "inferno_C02_EP4"),
    ("inferno_C02_004", "Canto II: Calling the Valkyries", "Inferno_C02_004_Calling_the_Valkyries.mp4", 20, 400.942, "c02_gate_ep3_004"),
    ("inferno_C02_005", "Canto II: The Guardians Strike Back", "Inferno_C02_005_The_Guardians_Strike_Back.mp4", 20, 537.829, "c02_gate_ep5_005"),
]

# After 006 fork / Oblivion, spine continues from 007
C02_ROUNDS_AFTER_006: list[tuple] = [
    ("inferno_C02_007", "Canto II: The Valkyries", "Inferno_C02_007_The_Valkyries.mp4", 20, 259.456, "c02_gate_ep5_007"),
    ("inferno_C02_008", "Canto II: Spirit Binding", "Inferno_C02_008_Spirit_Binding.mp4", 20, 223.223, "c02_gate_ep3_008"),
    ("inferno_C02_008_5", "Canto II: The Arch Valkyrie", "Inferno_C02_008.5_The_Arch_Valkyrie.mp4", 0, 277.319, "c02_gate_ep5_008_5"),
    ("inferno_C02_009", "Canto II: A Sister of the Flame", "Inferno_C02_009_The_Sister_of_the_Flame.mp4", 0, 277.319, "c02_gate_ep7_009"),
    ("inferno_C02_010", "Canto II: Combining Forces", "Inferno_C02_010_Combining_Forces.mp4", 0, 102.353, "c02_gate_ep5_010"),
    ("inferno_C02_011", "Canto II: The Minions Demand Satisfaction", "Inferno_C02_011_The_Minions_Demand_Satisfaction.mp4", 20, 143.769, "c02_gate_ep7_011"),
    ("inferno_C02_012", "Canto II: Dani's Prophecy", "Inferno_C02_012_Dani_s_Prophecy.mp4", 0, 187.27, "c02_gate_ep3_012"),
    ("inferno_C02_013", "Canto II: The Summoning", "Inferno_C02_013_The_Summoning.mp4", 20, 211.462, "c02_gate_ep5_013"),
    ("inferno_C02_014", "Canto II: The Battle of the Great Gate", "Inferno_C02_014_The_Battle_of_the_Great_Gate.mp4", 20, 257.966, "inferno_C02_EP6"),
    ("inferno_C02_015", "Canto II: The Minions use their ASSets", "Inferno_C02_015_The_Minions_use_their_ASSets.mp4", 0, 128.67, "c02_gate_ep7_015"),
    ("inferno_C02_016", "Canto II: ASSault of the Valkyries", "Inferno_C02_016_The_Valkyies_Anal.mp4", 20, 163.33, "inferno_C02_EP6"),
]

VIRGO = ("Inferno_C01_004_Virgo_s_Training.mp4", 470.596)
CHARON = ("Inferno_C01_005_Charon.mp4", 479.557)
VALKYRIE_CALL = ("Inferno_C02_004_Calling_the_Valkyries.mp4", 400.942)
GUARDIANS = ("Inferno_C02_003_The_Guardians_of_the_Gate.mp4", 576.369)
GUARDIANS_BACK = ("Inferno_C02_005_The_Guardians_Strike_Back.mp4", 537.829)
OBLIVION = ("Inferno_C02_O_Oblivion.mp4", 749.159)


def build_canto_ii_nodes(*, y: float, Z: tuple[float, float]) -> tuple[list[dict], float]:
    """Append Canto II spine + EPs. Returns (nodes, next_main_y)."""
    nodes: list[dict] = []

    # ΓöÇΓöÇ Spine 001ΓÇô005 ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
    chain = list(C02_ROUNDS)
    for i, (nid, name, video, coins, dur, rel) in enumerate(chain):
        nxt = chain[i + 1][0] if i + 1 < len(chain) else "inferno_C02_006"
        nodes.append(
            round_node(
                nid,
                name,
                video,
                coins=coins,
                length_s=dur,
                out=nxt,
                release_jump=rel,
                pos=(X_MAIN, y),
            )
        )
        y += ROW

    # 006 video ΓåÆ fork (no timed choice)
    nodes.append(
        cutscene_node(
            "inferno_C02_006",
            "Canto II: The First Choice",
            "Inferno_C02_006_The_First_Choice.mp4",
            length_s=144.864,
            items_blocked=True,
            out="c02_006_fork",
            pos=(X_MAIN, y),
        )
    )
    y += ROW
    nodes.append(
        fork_node(
            "c02_006_fork",
            "Canto II: The First Choice",
            [
                edge("inferno_C02_007", "Go to The Valkyries"),
                edge("inferno_C02_O", "Resist The Valkyries"),
            ],
            pos=(X_MAIN, y),
        )
    )
    y += ROW

    # Standalone Oblivion ΓåÆ 007
    nodes.append(
        round_node(
            "inferno_C02_O",
            "Canto II: Oblivion",
            OBLIVION[0],
            length_s=OBLIVION[1],
            items_blocked=True,
            out="inferno_C02_007",
            loop_until_clean=True,
            pos=(X_MAIN + COL * 0.5, y - ROW),
        )
    )

    # Spine 007ΓÇô016
    after = list(C02_ROUNDS_AFTER_006)
    for i, (nid, name, video, coins, dur, rel) in enumerate(after):
        nxt = after[i + 1][0] if i + 1 < len(after) else "inferno_C02_017"
        nodes.append(
            round_node(
                nid,
                name,
                video,
                coins=coins,
                length_s=dur,
                out=nxt,
                release_jump=rel,
                pos=(X_MAIN, y),
            )
        )
        y += ROW

    # 017 video ΓåÆ fork (Unlock the Gate only; no Canto III)
    nodes.append(
        cutscene_node(
            "inferno_C02_017",
            "Canto II: The Second Choice",
            "Inferno_C02_017_The_Second_Choice.mp4",
            length_s=112.78,
            items_blocked=True,
            out="c02_017_fork",
            pos=(X_MAIN, y),
        )
    )
    y += ROW
    nodes.append(
        fork_node(
            "c02_017_fork",
            "Canto II: The Second Choice",
            [edge("inferno_C02_018", "Unlock the Gate")],
            pos=(X_MAIN, y),
        )
    )
    y += ROW

    nodes.append(
        round_node(
            "inferno_C02_018",
            "Canto II: Unlocking the Gate",
            "Inferno_C02_018_Unlocking_the_Gate.mp4",
            coins=20,
            length_s=293.502,
            out="inferno_C02_019",
            release_jump="inferno_C02_EP8",
            pos=(X_MAIN, y),
        )
    )
    y += ROW

    # Ending: 019 stamp ΓåÆ 021 timed_window ΓåÆ 022 credits
    nodes.append(
        round_node(
            "inferno_C02_019",
            "Canto II: Anjelica's Reward",
            "Inferno_C02_019_Anjelica_s_Reward.mp4",
            length_s=331.665,
            out="inferno_C02_021",
            release_mode="stamp_flag",
            release_flag="released_in_c02_019",
            pos=(X_MAIN, y),
        )
    )
    y += ROW
    nodes.append(
        round_node(
            "inferno_C02_021",
            "Canto II: Release Inside Dani",
            "Inferno_C02_021_Release_Inside_Dani.mp4",
            length_s=196.404,
            out="inferno_C02_022",
            release_mode="timed_window",
            release_deadline_ms=131000,
            release_score_hit=50,
            release_score_miss=20,
            release_disabled_if_flag="released_in_c02_019",
            pos=(X_MAIN, y),
        )
    )
    y += ROW
    nodes.append(
        cutscene_node(
            "inferno_C02_022",
            "Canto II: Credits",
            "Inferno_C02_022_Credits.mp4",
            length_s=108.15,
            items_blocked=True,
            out=None,
            pos=(X_MAIN, y),
        )
    )
    y += ROW

    # ΓöÇΓöÇ Shared EP release gates ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
    VALKYRIE_GATE = "You have succumbed to a Valkyrie. Continue and learn your fate."
    for gid, flag in (
        ("c02_gate_ep3_004", "failed_from_c02_004"),
        ("c02_gate_ep3_008", "failed_from_c02_008"),
        ("c02_gate_ep3_012", "failed_from_c02_012"),
        ("c02_gate_ep5_007", "failed_from_c02_007"),
        ("c02_gate_ep5_008_5", "failed_from_c02_008_5"),
        ("c02_gate_ep5_010", "failed_from_c02_010"),
        ("c02_gate_ep5_013", "failed_from_c02_013"),
    ):
        nodes.append(
            failed_from_gate(
                gid,
                "inferno_C02_EP3" if "ep3" in gid else "inferno_C02_EP5",
                flag,
                text=VALKYRIE_GATE,
                pos=Z,
            )
        )
    nodes.append(
        failed_from_gate(
            "c02_gate_ep5_005",
            "inferno_C02_EP5",
            "failed_from_c02_005",
            text="The Guardians have struck you down. Continue and learn your fate.",
            pos=Z,
        )
    )
    for gid, flag, text in (
        (
            "c02_gate_ep7_009",
            "failed_from_c02_009",
            "The sister has claimed your cum. Continue and learn your fate.",
        ),
        (
            "c02_gate_ep7_011",
            "failed_from_c02_011",
            "The minions received satisfaction. Continue and learn your fate.",
        ),
        (
            "c02_gate_ep7_015",
            "failed_from_c02_015",
            "The minions' ASSets proved irresistible. Continue and learn your fate.",
        ),
    ):
        nodes.append(
            failed_from_gate(
                gid,
                "inferno_C02_EP7",
                flag,
                text=text,
                pos=Z,
            )
        )

    # ΓöÇΓöÇ EP1: Fate ΓåÆ gap 3d ΓåÆ Charon ΓåÆ C02_001 ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
    nodes += [
        cutscene_node(
            "inferno_C02_EP1",
            "Canto II: Epilogue 1",
            "Inferno_C02_EP1.mp4",
            length_s=29.436,
            items_blocked=True,
            out="inferno_C02_EP1_fate",
            pos=Z,
        ),
        cutscene_node(
            "inferno_C02_EP1_fate",
            "Canto II: Epilogue 1 ΓÇö Fate",
            "Inferno_C02_EP1_Fate.mp4",
            length_s=42.752,
            items_blocked=True,
            out="c02_ep1_cd",
            pos=Z,
        ),
        gap(
            "c02_ep1_cd",
            3,
            "c02_ep1_s1",
            pos=Z,
            label="Canto II: Epilogue 1 ΓÇö Cooldown",
        ),
        round_node(
            "c02_ep1_s1",
            "Punishment: Charon ΓÇö Session 1 of 1",
            CHARON[0],
            length_s=CHARON[1],
            items_blocked=True,
            out="inferno_C02_001",
            release_jump="inferno_C02_EP1",
            pos=Z,
        ),
    ]

    # ΓöÇΓöÇ EP2: Fate ΓåÆ 3├ù Virgo ΓåÆ C02_001 ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
    nodes += [
        cutscene_node(
            "inferno_C02_EP2",
            "Canto II: Epilogue 2",
            "Inferno_C02_EP2.mp4",
            length_s=32.156,
            items_blocked=True,
            out="inferno_C02_EP2_fate",
            pos=Z,
        ),
        cutscene_node(
            "inferno_C02_EP2_fate",
            "Canto II: Epilogue 2 ΓÇö Fate",
            "Inferno_C02_EP2_Fate.mp4",
            length_s=32.993,
            items_blocked=True,
            out="c02_ep2_s1",
            pos=Z,
        ),
    ]
    for i in range(1, 4):
        nxt = f"c02_ep2_s{i + 1}" if i < 3 else "inferno_C02_001"
        nodes.append(
            round_node(
                f"c02_ep2_s{i}",
                f"Punishment: Virgo's Training ΓÇö Session {i} of 3",
                VIRGO[0],
                length_s=VIRGO[1],
                items_blocked=True,
                out=nxt,
                release_jump="inferno_C02_EP2",
                pos=Z,
            )
        )

    # ΓöÇΓöÇ EP3: shared ΓÇö 3├ù (gap 1d ΓåÆ 003+004) ΓåÆ failed_from exit ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
    nodes += [
        cutscene_node(
            "inferno_C02_EP3",
            "Canto II: Epilogue 3",
            "Inferno_C02_EP3.mp4",
            length_s=30.855,
            items_blocked=True,
            out="inferno_C02_EP3_fate",
            pos=Z,
        ),
        cutscene_node(
            "inferno_C02_EP3_fate",
            "Canto II: Epilogue 3 ΓÇö Fate",
            "Inferno_C02_EP3_Fate.mp4",
            length_s=46.101,
            items_blocked=True,
            out="c02_ep3_cd1",
            pos=Z,
        ),
    ]
    for i in range(1, 4):
        cd = f"c02_ep3_cd{i}"
        sa = f"c02_ep3_s{i}a"
        sb = f"c02_ep3_s{i}b"
        nxt = f"c02_ep3_cd{i + 1}" if i < 3 else "c02_exit_ep3"
        nodes.append(
            gap(cd, 1, sa, pos=Z, label=f"Canto II: Epilogue 3 ΓÇö Cooldown {i}")
        )
        nodes.append(
            round_node(
                sa,
                f"Punishment: The Guardians of the Gate ΓÇö Session {i} of 3",
                GUARDIANS[0],
                length_s=GUARDIANS[1],
                items_blocked=True,
                out=sb,
                release_jump="inferno_C02_EP3",
                pos=Z,
            )
        )
        nodes.append(
            round_node(
                sb,
                f"Punishment: Calling the Valkyries ΓÇö Session {i} of 3",
                VALKYRIE_CALL[0],
                coins=20,
                length_s=VALKYRIE_CALL[1],
                items_blocked=True,
                out=nxt,
                release_jump="inferno_C02_EP3",
                pos=Z,
            )
        )
    nodes.append(
        failed_from_exit_fork(
            "c02_exit_ep3",
            [
                ("failed_from_c02_004", "inferno_C02_004", "Return to Canto II: Calling the Valkyries"),
                ("failed_from_c02_008", "inferno_C02_008", "Return to Canto II: Spirit Binding"),
                ("failed_from_c02_012", "inferno_C02_012", "Return to Canto II: Dani's Prophecy"),
            ],
            default_to="inferno_C02_003",
            pos=Z,
            title="Canto II: Epilogue 3 ΓÇö Punishment Complete",
        )
    )

    # ΓöÇΓöÇ EP4: Fate ΓåÆ sacrifice 100 or free ΓåÆ C02_003 ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
    nodes += [
        cutscene_node(
            "inferno_C02_EP4",
            "Canto II: Epilogue 4",
            "Inferno_C02_EP4.mp4",
            length_s=31.0,
            items_blocked=True,
            out="inferno_C02_EP4_fate",
            pos=Z,
        ),
        cutscene_node(
            "inferno_C02_EP4_fate",
            "Canto II: Epilogue 4 ΓÇö Fate",
            "Inferno_C02_EP4_Fate.mp4",
            length_s=43.992,
            items_blocked=True,
            out="c02_ep4_fork",
            pos=Z,
        ),
        fork_node(
            "c02_ep4_fork",
            "Guardians' Toll",
            [
                edge("inferno_C02_003", "Sacrifice 100 coins", cost=100),
                edge("inferno_C02_003", "Refuse (free path)"),
            ],
            pos=Z,
            resolution="sacrifice",
        ),
    ]

    # ΓöÇΓöÇ EP5: Time Control (skill_unlocks) ΓåÆ 2├ù (gap 2d ΓåÆ 004) ΓåÆ exit ΓöÇ
    nodes += [
        cutscene_node(
            "inferno_C02_EP5",
            "Canto II: Epilogue 5",
            "Inferno_C02_EP5.mp4",
            length_s=29.663,
            items_blocked=True,
            out="inferno_C02_EP5_fate",
            pos=Z,
        ),
        cutscene_node(
            "inferno_C02_EP5_fate",
            "Canto II: Epilogue 5 ΓÇö Fate",
            "Inferno_C02_EP5_Fate.mp4",
            length_s=36.486,
            items_blocked=True,
            out="c02_ep5_cd1",
            pos=Z,
        ),
    ]
    for i in range(1, 3):
        cd = f"c02_ep5_cd{i}"
        sess = f"c02_ep5_s{i}"
        nxt = f"c02_ep5_cd{i + 1}" if i < 2 else "c02_exit_ep5"
        nodes.append(
            gap(cd, 2, sess, pos=Z, label=f"Canto II: Epilogue 5 ΓÇö Cooldown {i}")
        )
        nodes.append(
            round_node(
                sess,
                f"Punishment: Calling the Valkyries ΓÇö Session {i} of 2",
                VALKYRIE_CALL[0],
                coins=40,
                length_s=VALKYRIE_CALL[1],
                items_blocked=True,
                out=nxt,
                release_jump="inferno_C02_EP5",
                pos=Z,
            )
        )
    nodes.append(
        failed_from_exit_fork(
            "c02_exit_ep5",
            [
                ("failed_from_c02_005", "inferno_C02_005", "Return to Canto II: The Guardians Strike Back"),
                ("failed_from_c02_007", "inferno_C02_007", "Return to Canto II: The Valkyries"),
                ("failed_from_c02_008_5", "inferno_C02_008_5", "Return to Canto II: The Arch Valkyrie"),
                ("failed_from_c02_010", "inferno_C02_010", "Return to Canto II: Combining Forces"),
                ("failed_from_c02_013", "inferno_C02_013", "Return to Canto II: The Summoning"),
            ],
            default_to="inferno_C02_005",
            pos=Z,
            title="Canto II: Epilogue 5 ΓÇö Punishment Complete",
        )
    )

    # ΓöÇΓöÇ EP6: 3├ù Oblivion node copies ΓåÆ always C02_014 ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
    nodes += [
        cutscene_node(
            "inferno_C02_EP6",
            "Canto II: Epilogue 6",
            "Inferno_C02_EP6.mp4",
            length_s=30.892,
            items_blocked=True,
            out="inferno_C02_EP6_fate",
            pos=Z,
        ),
        cutscene_node(
            "inferno_C02_EP6_fate",
            "Canto II: Epilogue 6 ΓÇö Fate",
            "Inferno_C02_EP6_Fate.mp4",
            length_s=43.808,
            items_blocked=True,
            out="c02_ep6_o1",
            pos=Z,
        ),
    ]
    for i in range(1, 4):
        nid = f"c02_ep6_o{i}"
        nxt = f"c02_ep6_o{i + 1}" if i < 3 else "inferno_C02_014"
        nodes.append(
            round_node(
                nid,
                f"Punishment: Oblivion ΓÇö Session {i} of 3",
                OBLIVION[0],
                length_s=OBLIVION[1],
                items_blocked=True,
                out=nxt,
                release_jump="inferno_C02_EP6",
                pos=Z,
            )
        )

    # ΓöÇΓöÇ EP7: must-release ΓÇö 2├ù (gap 5d ΓåÆ 003+005 invert) ΓåÆ exit ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
    nodes += [
        cutscene_node(
            "inferno_C02_EP7",
            "Canto II: Epilogue 7",
            "Inferno_C02_EP7.mp4",
            length_s=34.118,
            items_blocked=True,
            out="inferno_C02_EP7_fate",
            pos=Z,
        ),
        cutscene_node(
            "inferno_C02_EP7_fate",
            "Canto II: Epilogue 7 ΓÇö Fate",
            "Inferno_C02_EP7_Fate.mp4",
            length_s=44.678,
            items_blocked=True,
            out="c02_ep7_cd1",
            pos=Z,
        ),
    ]
    for i in range(1, 3):
        cd = f"c02_ep7_cd{i}"
        sa = f"c02_ep7_s{i}a"
        sb = f"c02_ep7_s{i}b"
        nxt = f"c02_ep7_cd{i + 1}" if i < 2 else "c02_exit_ep7"
        nodes.append(
            gap(cd, 5, sa, pos=Z, label=f"Canto II: Epilogue 7 ΓÇö Cooldown {i}")
        )
        nodes.append(
            round_node(
                sa,
                f"Punishment: The Guardians of the Gate (Release Required) ΓÇö Session {i} of 2",
                GUARDIANS[0],
                length_s=GUARDIANS[1],
                items_blocked=True,
                out=sb,
                release_jump="inferno_C02_EP7",
                release_mode="punish_polarity",
                release_invert=True,
                pos=Z,
            )
        )
        nodes.append(
            round_node(
                sb,
                f"Punishment: The Guardians Strike Back (Release Required) ΓÇö Session {i} of 2",
                GUARDIANS_BACK[0],
                length_s=GUARDIANS_BACK[1],
                items_blocked=True,
                out=nxt,
                release_jump="inferno_C02_EP7",
                release_mode="punish_polarity",
                release_invert=True,
                pos=Z,
            )
        )
    nodes.append(
        failed_from_exit_fork(
            "c02_exit_ep7",
            [
                ("failed_from_c02_009", "inferno_C02_009", "Return to Canto II: A Sister of the Flame"),
                ("failed_from_c02_011", "inferno_C02_011", "Return to Canto II: The Minions Demand Satisfaction"),
                ("failed_from_c02_015", "inferno_C02_015", "Return to Canto II: The Minions use their ASSets"),
            ],
            default_to="inferno_C02_009",
            pos=Z,
            title="Canto II: Epilogue 7 ΓÇö Punishment Complete",
        )
    )

    # ΓöÇΓöÇ EP8 Death: Fate ΓåÆ 7d gap ΓåÆ terminal end ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
    nodes += [
        cutscene_node(
            "inferno_C02_EP8",
            "Canto II: Epilogue 8",
            "Inferno_C02_EP8.mp4",
            length_s=38.0,
            items_blocked=True,
            out="inferno_C02_EP8_fate",
            pos=Z,
        ),
        cutscene_node(
            "inferno_C02_EP8_fate",
            "Canto II: Epilogue 8 ΓÇö Fate",
            "Inferno_C02_EP8_Fate.mp4",
            length_s=56.761,
            items_blocked=True,
            out="c02_ep8_cd",
            pos=Z,
        ),
        gap(
            "c02_ep8_cd",
            7,
            "c02_ep8_death",
            pos=Z,
            label="Canto II: Epilogue 8 ΓÇö Cooldown",
        ),
        storyboard_node(
            "c02_ep8_death",
            "After a long wait, you have been resurrected. Begin your journey anew.",
            out=None,
            pos=Z,
        ),
    ]

    return nodes, y


def layout_canto_ii(nodes_by_id: dict[str, dict]) -> None:
    """Place C02 spine on main with a clear gap under Canto I; EP islands on the LEFT.

    Exit forks sit between the punish chain and the spine (X_UNLOCK) so returns
    run short to the main column without sharing a cell with Time Control (which
    sits on the fate row in the chain column). Extra blank rows separate EP bands.
    """
    if "c01_008_fork" not in nodes_by_id or "inferno_C02_001" not in nodes_by_id:
        return

    _fx, fork_y = _pos_of(nodes_by_id, "c01_008_fork")
    # Clear separation between Canto I (fork / Anjelica) and Canto II.
    anj_bottom = fork_y
    for aid in ("inferno_C01_009", "inferno_C01_010", "inferno_C01_credits"):
        if aid in nodes_by_id:
            anj_bottom = max(anj_bottom, _pos_of(nodes_by_id, aid)[1])
    canto2_top = max(fork_y, anj_bottom) + ROW * 4

    y = canto2_top
    spine = [
        "inferno_C02_001",
        "inferno_C02_002",
        "unlock_vid_feign",
        "inferno_C02_003",
        "inferno_C02_004",
        "unlock_vid_blinding",
        "inferno_C02_005",
        "inferno_C02_006",
        "c02_006_fork",
        "inferno_C02_007",
        "inferno_C02_008",
        "inferno_C02_008_5",
        "inferno_C02_009",
        "inferno_C02_010",
        "inferno_C02_011",
        "inferno_C02_012",
        "inferno_C02_013",
        "inferno_C02_014",
        "inferno_C02_015",
        "inferno_C02_016",
        "inferno_C02_017",
        "c02_017_fork",
        "inferno_C02_018",
        "inferno_C02_019",
        "inferno_C02_021",
        "inferno_C02_022",
    ]
    for nid in spine:
        if nid in nodes_by_id:
            _place(nodes_by_id, nid, X_MAIN, y)
            y += ROW

    # Oblivion right of the 006 fork (bonus side) ΓÇö keeps left free for EPs.
    if "inferno_C02_O" in nodes_by_id and "c02_006_fork" in nodes_by_id:
        _ox, oy = _pos_of(nodes_by_id, "c02_006_fork")
        _place(nodes_by_id, "inferno_C02_O", X_MAIN + COL, oy)

    # EP islands: left of main, sequential bands aligned under Canto II.
    band_y = canto2_top
    x_gate = X_EP - COL

    def _band_ep(
        ep: str,
        chain: list[str],
        *,
        gates: list[str] | None = None,
        exit_id: str | None = None,
        unlock_id: str | None = None,
    ) -> None:
        nonlocal band_y
        base = f"inferno_C02_{ep}"
        if base not in nodes_by_id:
            return
        row = band_y
        _place(nodes_by_id, base, X_EP, row)
        _place(nodes_by_id, f"{base}_fate", X_FATE, row)
        if unlock_id and unlock_id in nodes_by_id:
            # Fate row, chain column ΓÇö not X_UNLOCK (reserved for exit forks).
            _place(nodes_by_id, unlock_id, X_CHAIN, row)
        if gates:
            gy = row
            for g in gates:
                if g in nodes_by_id:
                    _place(nodes_by_id, g, x_gate, gy)
                    gy += ROW
            gate_bottom = gy
        else:
            gate_bottom = row + ROW
        py = row + ROW
        for cid in chain:
            if cid in nodes_by_id:
                _place(nodes_by_id, cid, X_CHAIN, py)
                py += ROW
        if exit_id and exit_id in nodes_by_id:
            # Between chain and spine ΓÇö short returns; clear of next band below.
            exit_y = (py - ROW) if chain else (row + ROW)
            _place(nodes_by_id, exit_id, X_UNLOCK, exit_y)
        band_y = max(py, gate_bottom) + ROW * 2

    _band_ep("EP1", ["c02_ep1_cd", "c02_ep1_s1"])
    _band_ep("EP2", ["c02_ep2_s1", "c02_ep2_s2", "c02_ep2_s3"])
    _band_ep("EP4", ["c02_ep4_fork"])
    _band_ep(
        "EP3",
        [
            "c02_ep3_cd1",
            "c02_ep3_s1a",
            "c02_ep3_s1b",
            "c02_ep3_cd2",
            "c02_ep3_s2a",
            "c02_ep3_s2b",
            "c02_ep3_cd3",
            "c02_ep3_s3a",
            "c02_ep3_s3b",
        ],
        gates=["c02_gate_ep3_004", "c02_gate_ep3_008", "c02_gate_ep3_012"],
        exit_id="c02_exit_ep3",
    )
    _band_ep(
        "EP5",
        ["c02_ep5_cd1", "c02_ep5_s1", "c02_ep5_cd2", "c02_ep5_s2"],
        gates=[
            "c02_gate_ep5_005",
            "c02_gate_ep5_007",
            "c02_gate_ep5_008_5",
            "c02_gate_ep5_010",
            "c02_gate_ep5_013",
        ],
        exit_id="c02_exit_ep5",
        unlock_id="unlock_vid_time",
    )
    _band_ep(
        "EP7",
        [
            "c02_ep7_cd1",
            "c02_ep7_s1a",
            "c02_ep7_s1b",
            "c02_ep7_cd2",
            "c02_ep7_s2a",
            "c02_ep7_s2b",
        ],
        gates=["c02_gate_ep7_009", "c02_gate_ep7_011", "c02_gate_ep7_015"],
        exit_id="c02_exit_ep7",
    )
    _band_ep("EP6", ["c02_ep6_o1", "c02_ep6_o2", "c02_ep6_o3"])
    _band_ep("EP8", ["c02_ep8_cd", "c02_ep8_death"])


# Node ids whose layout is owned by scaffold_canto_ii ΓÇö never preserve from pack
# (first-regen pile-ups would otherwise lock forever).
C02_LAYOUT_OWNED_PREFIXES: tuple[str, ...] = (
    "inferno_C02_",
    "c02_",
    "unlock_vid_feign",
    "unlock_vid_blinding",
    "unlock_vid_time",
)


def is_c02_layout_owned(nid: str) -> bool:
    return any(nid.startswith(p) or nid == p for p in C02_LAYOUT_OWNED_PREFIXES)
