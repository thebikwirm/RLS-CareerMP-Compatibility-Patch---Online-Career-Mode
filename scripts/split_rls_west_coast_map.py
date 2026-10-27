"""Copy the RLS West Coast level into an additional standalone BeamMP map ZIP.

The original full RLS ZIP remains unchanged. Dry-run by default.
Requires a real, user-reviewed info.json from a compatible level, rather
than fabricating BeamNG level metadata.
"""
from __future__ import annotations

import argparse
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


def generate(source: Path, info: Path, output: Path) -> tuple[Path, int]:
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
    with zipfile.ZipFile(source, "r") as inp, zipfile.ZipFile(map_zip, "w") as level_out:
        for entry in inp.infolist():
            if entry.filename.startswith(LEVEL):
                level_out.writestr(entry, inp.read(entry.filename))
        level_out.writestr(INFO, payload, compress_type=zipfile.ZIP_DEFLATED)
    if INFO not in checked_names(map_zip):
        raise RuntimeError("Split validation failed")
    return map_zip, len(level_names)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--server-root", type=Path, default=Path("D:/beamng_server"))
    p.add_argument("--info-json", type=Path, required=True,
                   help="Reviewed, compatible info.json to add to RLS map")
    p.add_argument("--install", action="store_true",
                   help="Install additional map ZIP without touching the original RLS ZIP")
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
        map_zip, count = generate(source, args.info_json, Path(temp))
        print(f"Prepared {MAP_NAME}: {count} map files plus {INFO}")
        print(f"Original {RLS_NAME} remains unchanged")
        if not args.install:
            print("DRY RUN: no server files changed. Add --install after reviewing info.json.")
            return
        fd, temp_name = tempfile.mkstemp(prefix=".rls-map-", suffix=".zip", dir=client)
        os.close(fd)
        try:
            shutil.copy2(map_zip, temp_name)
            checked_names(Path(temp_name))
            os.replace(temp_name, map_dest)
        finally:
            Path(temp_name).unlink(missing_ok=True)
        print(f"Installed additional map resource: {map_dest}")
        print(f"Original full RLS ZIP unchanged: {source}")
        print("Keep the server Map path /levels/rls_west_coast/info.json and restart server.")
        print("NOTE: the duplicate map paths across two ZIPs may still cause VFS conflicts.")



if __name__ == "__main__":
    main()
