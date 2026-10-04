# Restore Inferno Canto I media into the live pack + reinstall relative-path journey.json.
from __future__ import annotations

import json
import re
import shutil
import subprocess
from pathlib import Path

REPO = Path(r"F:\Github\Fap-Hero-Journey")
PACK = Path(
    r"E:\E-Stim\Fap.Hero.JOURNEY.v0.6.0.-.Windows.Build\Journeys\Erosphere_Inferno"
)
MEDIA_SRC = Path(r"E:\E-Stim\CH Inferno\Canto I\Seperated Rounds")
FS_SRC = MEDIA_SRC / "Funscripts"
LOCAL_JSON = REPO / "local/journeys/erosphere-inferno/journey.json"


def norm(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", s.lower().replace("'", ""))


def copy_media() -> None:
    PACK.mkdir(parents=True, exist_ok=True)
    fs_idx: dict[str, Path] = {}
    if FS_SRC.is_dir():
        for d in FS_SRC.iterdir():
            if not d.is_dir():
                continue
            for fs in d.glob("*.funscript"):
                fs_idx[norm(fs.stem)] = fs

    n_vid = n_fs = 0
    for mp4 in sorted(MEDIA_SRC.glob("*.mp4")):
        if mp4.name.startswith("CH Inferno") or "Combined" in mp4.name:
            continue
        stem = mp4.stem
        dest_dir = PACK / stem
        dest_dir.mkdir(parents=True, exist_ok=True)
        dest_mp4 = dest_dir / mp4.name
        if not dest_mp4.is_file() or dest_mp4.stat().st_size != mp4.stat().st_size:
            shutil.copy2(mp4, dest_mp4)
            n_vid += 1
            print("mp4", dest_mp4.relative_to(PACK))
        fs = fs_idx.get(norm(stem))
        if fs:
            dest_fs = dest_dir / (stem + ".funscript")
            if not dest_fs.is_file() or dest_fs.stat().st_size != fs.stat().st_size:
                shutil.copy2(fs, dest_fs)
                n_fs += 1
                print("fs ", dest_fs.relative_to(PACK))
    print(f"copied/updated mp4={n_vid} funscript={n_fs}")


def sanitize_and_install_json() -> None:
    # Prefer local scaffold output (relative paths). Fall back to rewriting pack JSON.
    if LOCAL_JSON.is_file():
        raw = json.loads(LOCAL_JSON.read_text(encoding="utf-8"))
    else:
        raw = json.loads((PACK / "journey.json").read_text(encoding="utf-8"))

    pack_prefix = PACK.resolve().as_posix().rstrip("/") + "/"
    doubled = pack_prefix + pack_prefix

    def fix_path(p: str) -> str:
        if not p:
            return p
        s = p.replace("\\", "/")
        while doubled in s:
            s = s.replace(doubled, pack_prefix)
        if s.startswith(pack_prefix):
            s = s[len(pack_prefix) :]
        # Also strip accidental absolute that isn't doubled
        if re.match(r"^[A-Za-z]:/", s):
            # keep only the last journey-relative segment if pack path appears
            idx = s.lower().find("erosphere_inferno/")
            if idx >= 0:
                s = s[idx + len("erosphere_inferno/") :]
        return s

    path_keys = (
        "video_path",
        "funscript_path",
        "image",
        "image_path",
    )
    for n in raw.get("Nodes", []):
        d = n.get("data")
        if not isinstance(d, dict):
            continue
        for k in path_keys:
            if k in d and isinstance(d[k], str):
                d[k] = fix_path(d[k])
        for nest in ("axis_scripts", "estim_scripts", "vib_scripts"):
            m = d.get(nest)
            if isinstance(m, dict):
                for ak, av in list(m.items()):
                    if isinstance(av, str):
                        m[ak] = fix_path(av)
        for e in n.get("out") or []:
            if isinstance(e, dict) and isinstance(e.get("image_path"), str):
                e["image_path"] = fix_path(e["image_path"])

    # Verify EP files exist for relative paths
    missing = []
    for n in raw.get("Nodes", []):
        if "EP" not in str(n.get("id", "")) and not str(n.get("id", "")).startswith(
            "unlock"
        ):
            continue
        vp = str((n.get("data") or {}).get("video_path") or "")
        if vp and not (PACK / vp).is_file():
            missing.append((n["id"], vp))

    payload = json.dumps(raw, indent=2) + "\n"
    LOCAL_JSON.parent.mkdir(parents=True, exist_ok=True)
    LOCAL_JSON.write_text(payload, encoding="utf-8")
    dest = PACK / "journey.json"
    # backup pack json
    if dest.is_file():
        bak = PACK / "journey.json.pre_media_restore.bak"
        shutil.copy2(dest, bak)
    dest.write_text(payload, encoding="utf-8")
    unlocks_src = REPO / "local/journeys/erosphere-inferno/skill_unlocks.json"
    if unlocks_src.is_file():
        shutil.copy2(unlocks_src, PACK / "skill_unlocks.json")

    print("installed journey.json with relative paths")
    if missing:
        print("STILL MISSING:")
        for nid, vp in missing:
            print(" ", nid, vp)
    else:
        print("all EP/unlock video paths resolve on disk")


def main() -> None:
    copy_media()
    # Regen from scaffold so paths match pack folders (sibling funscripts attach)
    subprocess.check_call(
        ["python", str(REPO / "scripts/dev/scaffold_erosphere_inferno.py")],
        cwd=str(REPO / "scripts/dev"),
    )
    sanitize_and_install_json()
    # Quick EP inventory
    eps = sorted(PACK.glob("Inferno_C01_EP*"))
    print("EP folders:", [p.name for p in eps if p.is_dir()])


if __name__ == "__main__":
    main()
