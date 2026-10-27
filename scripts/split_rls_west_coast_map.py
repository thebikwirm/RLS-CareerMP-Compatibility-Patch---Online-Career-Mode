"""Split a FULL deployed RLS West Coast level into a standalone BeamMP map ZIP.

Run AFTER build.bat has patched the full installed RLS ZIP. Dry-run by default.
Requires a real, user-reviewed info.json from a compatible level, rather
than fabricating BeamNG level metadata.
"""
from __future__ import annotations

import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import shutil
import tempfile
import zipfile

LEVEL = "levels/rls_west_coast/"
INFO = LEVEL + "info.json"
RLS_NAME = "rls_career_overhaul_v2.8.0_beta.zip"
MAP_NAME = "rls_west_coast.zip"


def checked_names(path: Path) -> list[str]:
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        if len(names) != len(set(names)):
            raise RuntimeError(f"Duplicate ZIP entries: {path}")
        for name in names:
            if name.startswith("/") or "\\" in name or ".." in Path(name).parts:
                raise RuntimeError(f"Unsafe ZIP entry {name!r}")
        bad = z.testzip()
        if bad:
            raise RuntimeError(f"Corrupt ZIP entry {bad!r} in {path}")
        return names


def generate(source: Path, info: Path, output: Path) -> tuple[Path, Path, int]:
    names = checked_names(source)
    level_names = [n for n in names if n.startswith(LEVEL) and not n.endswith("/")]
    if not level_names:
        raise RuntimeError(f"{source} has no {LEVEL} entries; was map already split?")
    if INFO in names:
        raise RuntimeError(f"{INFO} already exists; review instead of overwriting metadata")
    if LEVEL + "main.level.lua" not in level_names:
        raise RuntimeError("Expected RLS level main.level.lua is missing")
    obj = json.loads(info.read_text(encoding="utf-8-sig"))
    if not isinstance(obj, dict):
        raise RuntimeError("info.json template must contain a JSON object")
    payload = (json.dumps(obj, indent=2, ensure_ascii=False) + "\n").encode("utf-8")

    output.mkdir(parents=True, exist_ok=True)
    map_zip = output / MAP_NAME
    core_zip = output / RLS_NAME
    with zipfile.ZipFile(source, "r") as inp, \
            zipfile.ZipFile(map_zip, "w") as level_out, \
            zipfile.ZipFile(core_zip, "w") as core_out:
        for entry in inp.infolist():
            dest = level_out if entry.filename.startswith(LEVEL) else core_out
            dest.writestr(entry, inp.read(entry.filename))
        level_out.writestr(INFO, payload, compress_type=zipfile.ZIP_DEFLATED)
    if INFO not in checked_names(map_zip) or INFO in checked_names(core_zip):
        raise RuntimeError("Split validation failed")
    return map_zip, core_zip, len(level_names)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--server-root", type=Path, default=Path("D:/beamng_server"))
    p.add_argument("--info-json", type=Path, required=True,
                   help="Reviewed, compatible info.json to add to RLS map")
    p.add_argument("--install", action="store_true",
                   help="Replace full RLS ZIP and install map ZIP with timestamped backups")
    args = p.parse_args()
    client = args.server_root / "Resources" / "Client"
    source = client / RLS_NAME
    map_dest = client / MAP_NAME
    if not source.is_file() or not args.info_json.is_file():
        p.error("Full server RLS ZIP and --info-json file are both required")
    if source.is_symlink() or map_dest.is_symlink():
        p.error("Symlink input/target is not supported")
    # Never silently clobber an existing independent map ZIP.
    if map_dest.exists():
        p.error(f"Target already exists: {map_dest}; move it aside first")
    with tempfile.TemporaryDirectory(prefix="rls-map-split-") as temp:
        map_zip, core_zip, count = generate(source, args.info_json, Path(temp))
        print(f"Prepared {MAP_NAME}: {count} map files plus {INFO}")
        print(f"Prepared {RLS_NAME}: all non-{LEVEL} entries retained")
        if not args.install:
            print("DRY RUN: no server files changed. Add --install after reviewing info.json.")
            return
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        backup = args.server_root / "rls-map-split-backups" / stamp
        backup.mkdir(parents=True, exist_ok=False)
        saved = backup / RLS_NAME
        shutil.copy2(source, saved)
        if saved.stat().st_size != source.stat().st_size or checked_names(saved) != checked_names(source):
            raise RuntimeError("Backup verification failed")
        try:
            # Files staged on same volume for atomic individual swaps.
            for prepared, destination in ((map_zip, map_dest), (core_zip, source)):
                fd, temp_name = tempfile.mkstemp(prefix=".rls-split-", suffix=".zip", dir=client)
                os.close(fd)
                try:
                    shutil.copy2(prepared, temp_name)
                    checked_names(Path(temp_name))
                    os.replace(temp_name, destination)
                finally:
                    Path(temp_name).unlink(missing_ok=True)
        except Exception:
            shutil.copy2(saved, source)
            map_dest.unlink(missing_ok=True)
            raise
        print(f"Installed {map_dest} and updated {source}")
        print(f"Original full ZIP backup: {saved}")
        print("Keep the server Map path /levels/rls_west_coast/info.json and restart server.")
        print("NOTE: subsequent build.bat RLS deployments can restore level files; rerun this split then.")


if __name__ == "__main__":
    main()
